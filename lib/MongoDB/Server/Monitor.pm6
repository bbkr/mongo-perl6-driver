use v6;

use MongoDB;
use MongoDB::ObserverEmitter;
use MongoDB::Server::Socket;
use MongoDB::Server::MonitorTimer;
use BSON;
use BSON::Document;
use Semaphore::ReadersWriters;

#-------------------------------------------------------------------------------
unit class MongoDB::Server::Monitor:auth<github:MARTIMM>;

#-------------------------------------------------------------------------------
enum SERVERDATA <<:ServerObj(0) WMRttMs>>;

my MongoDB::Server::Monitor $singleton-instance;

has %!registered-servers;

# Variables to control infinite monitoring actions
has Promise $!promise-monitor;

#has Supplier $!monitor-data-supplier;

# heartbeat frequency is the normal wait period between ismaster requests.
# settle frequency is a much shorter period to settle the typology until
# everything gets stable. $servers-settled is False when any server has
# a SS-UNKNOWN state
has Duration $!heartbeat-frequency-ms;
has Duration $!settle-frequency-ms;
has Bool $!servers-settled;

has BSON::Document $!monitor-command;
has BSON::Document $!monitor-result;
has MongoDB::Server::MonitorTimer $!monitor-timer;

has Semaphore::ReadersWriters $!rw-sem;

#-------------------------------------------------------------------------------
# Call before monitor-server to set the $!server object!
# Inheriting from Supplier prevents use of proper BUILD
#
submethod BUILD ( ) {

  $!settle-frequency-ms .= new(5e2);
  $!heartbeat-frequency-ms .= new(MongoDB::C-HEARTBEATFREQUENCYMS);
  $!servers-settled = False;
  debug-message("Monitor sleep time set to $!heartbeat-frequency-ms ms");

  $!rw-sem .= new;
  #$!rw-sem.debug = True;
  $!rw-sem.add-mutex-names(
    <m-loop m-servers>, :RWPatternType(C-RW-WRITERPRIO)
  );

  %!registered-servers = %();

#  $!monitor-data-supplier .= new;
  $!monitor-command .= new: (isMaster => 1);

  # observe heartbeat changes
  my MongoDB::ObserverEmitter $event-manager .= new;
  $event-manager.subscribe-observer(
    'set heartbeatfrequency ms',
    -> Int $heartbeat { self!set-heartbeat($heartbeat) },
    :event-key<m1>
  );

  # observe server registration
  $event-manager.subscribe-observer(
    'register server',
    -> MongoDB::ServerClassType:D $server { self!register-server($server) },
    :event-key<m2>
  );

  # observe server un-registration
  $event-manager.subscribe-observer(
    'unregister server',
    -> MongoDB::ServerClassType:D $server { self!unregister-server($server) },
    :event-key<m3>
  );

  # start the monitor
  debug-message("Start monitoring");
  self!start-monitor;
#  sleep(0.2);
}

#-------------------------------------------------------------------------------
# Prevent calling new(). Must use instance()
method new ( ) { !!! }

#-------------------------------------------------------------------------------
method instance ( --> MongoDB::Server::Monitor ) {

  $singleton-instance //= self.bless;
  $singleton-instance
}

#`{{
#-------------------------------------------------------------------------------
method get-supply ( --> Supply ) {

  $!monitor-data-supplier.Supply
}
}}

#-------------------------------------------------------------------------------
method !set-heartbeat ( Int:D $heartbeat-frequency-ms ) {

  $!rw-sem.writer( 'm-loop', {
      # Don't let looptime become lower than 100 ms
      $!heartbeat-frequency-ms .= new(
        $heartbeat-frequency-ms > 100 ?? $heartbeat-frequency-ms !! 100
      );
      debug-message(
        "Monitor sleep time modified to $!heartbeat-frequency-ms ms"
      );
    }
  );
}

#-------------------------------------------------------------------------------
method !register-server ( MongoDB::ServerClassType:D $server ) {
#note "register $server.name()";

  $!rw-sem.writer( 'm-servers', {
      if %!registered-servers{$server.name}:exists {
        warn-message("Server $server.name() already registered");
      }

      else {
        $!servers-settled = False;
        $!monitor-timer.cancel if $!monitor-timer.defined;

        debug-message("Server $server.name() registered");
        %!registered-servers{$server.name} = [
          $server,    # provided server
          0,          # init weighted mean rtt in ms
        ];
      } # else
    } # writer block
  ); # writer
}

#-------------------------------------------------------------------------------
method !unregister-server ( MongoDB::ServerClassType:D $server ) {

  $!rw-sem.writer( 'm-servers', {
      if %!registered-servers{$server.name}:exists {
        %!registered-servers{$server.name}:delete;
        debug-message("Server $server.name() un-registered");
      }

      else {
        warn-message("Server $server.name() not registered");
      } # else
    } # writer block
  ); # writer
}

#-------------------------------------------------------------------------------
method !start-monitor ( ) {
  # infinite
  Promise.start( {
      $!monitor-timer .= in(0.1);
note '.= in()';

      # start first run
      #$!promise-monitor .= start( { self.monitor-work } );
      $!promise-monitor = $!monitor-timer.promise.then( {
          self.monitor-work;
        }
      );
note '.then()';

      # then infinite loop
      loop {
note 'start loop';

        # wait for end of thread or when waittime is canceled
#        try {
          if $!promise-monitor.status ~~ PromiseStatus::Kept {
            $!promise-monitor.result;
          }

          elsif $!promise-monitor.status ~~ PromiseStatus::Broken {
            trace-message(
              'wait period interrupted: ' ~ $!promise-monitor.cause
            );
            trace-message("monitor heartbeat shortened for new data");
          }

#          CATCH {.note};
#        };

        # heartbeat can be adjusted with set-heartbeat() or $!servers-settled
        # demands shorter cycle using $!settle-frequency-ms
        my $heartbeat-frequency-sec =
          ( $!servers-settled ?? $!settle-frequency-ms
                              !! $!heartbeat-frequency-ms
          ) / 1000.0;
#        my $heartbeat-frequency-sec = $!heartbeat-frequency-ms / 1000.0;
        trace-message("heartbeat frequency: $heartbeat-frequency-sec sec");

  #`{{
        # set new thread to start after some time
        $!promise-monitor = Promise.in(
          $heartbeat-frequency-sec
        ).then(
          { self.monitor-work }
        );
  }}
note "start monitor";
        # create the cancelable thread
        $!monitor-timer .= in($heartbeat-frequency-sec);
        $!promise-monitor = $!monitor-timer.promise.then( {
            self.monitor-work;
          }
        );
note 'next loop';
      } # loop
note 'end loop';
    }   # Promise code
  );    # Promise.start
note 'end method';
}       # method

#-------------------------------------------------------------------------------
method monitor-work ( ) {

  my Duration $rtt;
  my BSON::Document $doc;
  my Int $weighted-mean-rtt-ms;
  my MongoDB::ObserverEmitter $monitor-data .= new;

  $!servers-settled = True;

  my Duration $loop-start-time-ms .= new(now * 1000);
  my %rservers = $!rw-sem.reader(
   'm-servers',
    sub () { %!registered-servers; }
  );

  trace-message("Servers to monitor: " ~ %rservers.keys.join(', '));

  for %rservers.keys -> $server-name {
    # Last check if server is still registered
    next unless $!rw-sem.reader(
      'm-servers',
      { %!registered-servers{$server-name}:exists; }
    );

    # get server info
    my $server = %rservers{$server-name}[ServerObj];
    ( $doc, $rtt) = $server.raw-query(
    'admin.$cmd', $!monitor-command, :!authenticate, :timed-query
    );

    my Str $doc-text = ($doc // '-').perl;
    trace-message("is-master request result for $server-name: $doc-text");

    # when doc is defined, the request ended properly. the ok field
    # in the doc will tell if the operation is succsessful or not
    if $doc.defined {
      # Calculation of mean Return Trip Time. See also
      # https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#calculation-of-average-round-trip-times
      %rservers{$server-name}[WMRttMs] = Duration.new(
        0.2 * $rtt * 1000 + 0.8 * %rservers{$server-name}[WMRttMs]
      );

      # set new value of waiten mean rtt if the server is still registered
      $!rw-sem.writer( 'm-servers', {
          if %!registered-servers{$server-name}:exists {
            %!registered-servers{$server-name}[WMRttMs] =
              %rservers{$server-name}[WMRttMs];
          }
        }
      );

      debug-message(
        [~] 'Weighted mean RTT: ', %rservers{$server-name}[WMRttMs],
            ' (ms) for server ', $server.name()
      );

      $monitor-data.emit(
        %!registered-servers{$server-name}[ServerObj].uri-obj.keyed-uri ~
        $server-name ~ ' monitor data', {
          :ok, :monitor($doc<documents>[0]),  # :$server-name,
          :weighted-mean-rtt-ms(%rservers{$server-name}[WMRttMs])
        }
      );
#      $!monitor-data-supplier.emit( {
#          :ok, :monitor($doc<documents>[0]), :$server-name,
#          :weighted-mean-rtt-ms(%rservers{$server-name}[WMRttMs])
#        } # emit data
#      );  # emit
    }     # if $doc.defined

    # no doc returned, server is in trouble or the connection
    # between it is down.
    else {
      warn-message("no response from server $server.name()");
      $!servers-settled = False;

      $monitor-data.emit(
        %!registered-servers{$server-name}[ServerObj].uri-obj.keyed-uri ~
        $server-name ~ ' monitor data', {
          :!ok, :reason('Undefined document') #, :$server-name
        }
      );
#      $!monitor-data-supplier.emit( %(
#          :!ok, reason => 'Undefined document', :$server-name
#        ) # emit data
#      );  # emit
    }     # else
  }       # for %rservers.keys

  trace-message(
    "Servers are " ~ ($!servers-settled ?? '' !! 'not yet') ~ ' settled'
  );
}
