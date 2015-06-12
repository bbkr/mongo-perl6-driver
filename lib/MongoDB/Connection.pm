use v6;
use MongoDB::Protocol;
use MongoDB::Database;

package MongoDB {
  #-----------------------------------------------------------------------------
  #
  class X::MongoDB::Connection is Exception {
    has $.error-text;                     # Error text
    has $.error-code;                     # Error code if from server
    has $.oper-name;                      # Operation name
    has $.oper-data;                      # Operation data
    has $.database-name;                  # Database name

    method message () {
      return [~] "\n$!oper-name\() error:\n",
                 "  $!error-text",
                 $.error-code.defined ?? "\($!error-code)" !! '',
                 $!oper-data.defined ?? "\n  Data $!oper-data" !! '',
                 "\n  Database '$!database-name'\n"
                 ;
    }
  }

  #-----------------------------------------------------------------------------
  #
  class MongoDB::Connection does MongoDB::Protocol {

    has IO::Socket::INET $!sock;

    submethod BUILD ( Str :$host = 'localhost', Int :$port = 27017 ) {
      $!sock = IO::Socket::INET.new( host => $host, port => $port );
    #  $!sock = IO::Socket::INET.new( host => "$host/?connectTimeoutMS=3000", port => $port );
    }

    method _send ( Buf $b, Bool $has_response --> Any ) {
      $!sock.write($b);

      # some calls do not expect response
      #
      return unless $has_response;

      # Initialize bson buffer index to 0
      #
      self.wire._init_index;

      # check response size
      #
      my Buf $l = $!sock.read(4);
      my Int $w = self.wire._dec_int32($l.list) - 4;

      # receive remaining response bytes from socket
      #
      return $l ~ $!sock.read($w);
    }

    method database ( Str $name --> MongoDB::Database ) {
      return MongoDB::Database.new(
        connection  => self,
        name        => $name,
      );
    }

    # List databases using MongoDB db.runCommand({listDatabases: 1});
    #
    method list_databases ( --> Array ) {
      my $database = self.database('admin');
      my Pair @req = listDatabases => 1;
      my Hash $doc = $database.run_command(@req);

      if $doc<ok>.Bool == False {
        die X::MongoDB::Connection.new(
          error-text => $doc<errmsg>,
          oper-name => 'drop',
          oper-data => @req.perl,
          database-name => 'admin.$cmd'
        );
      }

      return @($doc<databases>);
    }

    # Get database names.
    #
    method database_names ( --> Array ) {
      my @db_docs = self.list_databases();
      my @names = map {$_<name>}, @db_docs; # Need to do it like this otherwise
                                            # returns List instead of Array.
      return @names;
    }
  }
}

