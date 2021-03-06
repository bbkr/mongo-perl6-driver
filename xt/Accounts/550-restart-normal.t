use v6.c;
use lib 't';

use Test;
use Test-support;

use MongoDB;
use MongoDB::Client;
#use MongoDB::HL::Users;
#use MongoDB::Database;
#use MongoDB::Collection;

use BSON::Document;
#use Auth::SCRAM;
#use OpenSSL::Digest;
use Base64;

#-------------------------------------------------------------------------------
drop-send-to('mongodb');
drop-send-to('screen');
#modify-send-to( 'screen', :level(MongoDB::MdbLoglevels::Trace));
my $handle = "xt/Log/550-restart-normal.log".IO.open(
  :mode<wo>, :create, :truncate
);
add-send-to( 'issue', :to($handle), :min-level(MongoDB::MdbLoglevels::Trace));
#set-filter(|<ObserverEmitter Timer Monitor Uri>);
set-filter(|<ObserverEmitter Timer>);
#set-filter(|< Timer Socket SocketPool >);

info-message("Test $?FILE start");

#-------------------------------------------------------------------------------
#my MongoDB::Test-support $ts .= new;

#`{{
# Example from https://github.com/mongodb/specifications/blob/master/source/auth/auth.rst
# C: n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL
# S: r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000
# C: c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=
# S: v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=
#
class MyClientDryRun {

  # send client first message to server and return server response
  method client-first ( Str:D $string --> Str ) {

    is $string, 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL', 'First client message';

    'r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000';
  }

  method client-final ( Str:D $string --> Str ) {

    is $string, 'c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=', 'Final client message';

    'v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=';
  }

  method mangle-password ( Str:D :$username, Str:D :$password --> Buf ) {

    my utf8 $mdb-hashed-pw = ($username ~ ':mongo:' ~ $password).encode;
    my Str $md5-mdb-hashed-pw = md5($mdb-hashed-pw).>>.fmt('%02x').join;
    Buf.new($md5-mdb-hashed-pw.encode);
  }

  method error ( Str:D $message --> Str ) {

    error-message($message);
  }
}

#-------------------------------------------------------------------------------
subtest 'dry run',  {

  my Auth::SCRAM $sc .= new(
    :username<user>,
    :password<pencil>,
    :client-object(MyClientDryRun.new),
  );

  $sc.c-nonce-size = 24;
  $sc.c-nonce = 'fyko+d2lbbFgONRv9qkxdawL';

  $sc.start-scram;

};
}}

#`{{
#-------------------------------------------------------------------------------
my MongoDB::Test-support $ts .= new;
my BSON::Document $user-credentials;

sub restart-to-authenticate( ) {

  my MongoDB::Client $client = $ts.get-connection(:server-key<s1>);
  my MongoDB::Database $db-admin = $client.database('admin');
  my MongoDB::Collection $u = $db-admin.collection('system.users');
  my MongoDB::Cursor $uc = $u.find( :criteria( user => 'Dondersteen',));
  $user-credentials = $uc.fetch;

  $client.cleanup;

  ok $ts.server-control.stop-mongod('s1'), "Server 1 stopped";
  ok $ts.server-control.start-mongod( 's1', 'authenticate'),
     "Server 1 in auth mode";

  # Try it again and see that we have no rights
  $client = $ts.get-connection(:server-key<s1>);
  $db-admin = $client.database('admin');
  $u = $db-admin.collection('system.users');
  $uc = $u.find( :criteria( user => 'Dondersteen',));

  my BSON::Document $doc = $uc.fetch;
  is $doc<code>, 13, 'error code 13';
  is $doc<$err>, "not authorized for query on admin.system.users", $doc<$err>;

  $client.cleanup;
};
}}

#-------------------------------------------------------------------------------
sub restart-to-normal( ) {

  my MongoDB::Test-support $ts .= new;
  my Hash $clients = $ts.create-clients;

  my Str $host = $clients<s1>.uri-obj.servers[0]<host>;
  my Int $port = $clients<s1>.uri-obj.servers[0]<port>.Int;

  my Str $username = 'site-admin';
  my Str $password = 'B3n!Hurry';

  my Str $uri = "mongodb://$username:$password@$host:$port/?authSource=admin";
  my BSON::Document $doc = $ts.server-control.stop-mongod( 's1', $uri);
  if $doc.defined {
    note $doc.perl;
    is $doc<ok>, 1, 'server stopped';
  }
  else {
    diag "old versions do not return status";
  }
#`{{
  # try to get other role
  my BSON::Document $req .= new: (
    :grantRolesToUser($username),
    roles => [
      ( :role<hostManager>, :db<admin>),
    ]
  );

  my MongoDB::Client $client .= new(:$uri);
  my MongoDB::Database $d = $client.database('admin');
  $doc = $d.run-command($req);
  is $doc<ok>, 1, "Role added";

  $doc = $ts.server-control.stop-mongod( 's1', $uri);
  if $doc.defined {
    is $doc<ok>, 1, 'server stopped';
  }
  else {
    diag "old versions do not return status";
  }
}}

  ok $ts.server-control.start-mongod('s1'), "Server 1 in normal mode";
}

#-------------------------------------------------------------------------------
restart-to-normal;
#restart-to-authenticate;

#-------------------------------------------------------------------------------
info-message("Test $?FILE stop");
done-testing();



=finish



class MyClientMDB {

  has MongoDB::Client $!client;
  has MongoDB::Database $!database;
  has Int $!conversation-id;

  #-----------------------------------------------------------------------------
  submethod BUILD ( ) {

    $!client = $ts.get-connection(:server-key<s1>);
    $!database = $!client.database('test');
  }

  #-----------------------------------------------------------------------------
  # send client first message to server and return server response
  method client-first ( Str:D $client-first-message --> Str ) {

    my BSON::Document $doc = $!database.run-command( BSON::Document.new: (
        saslStart => 1,
        mechanism => 'SCRAM-SHA-1',
        payload => encode-base64( $client-first-message, :str)
      )
    );

    if !$doc<ok> {
      skip 1;
      flunk "$doc<code>, $doc<errmsg>";
      done-testing;

      restart-to-normal;
      exit(1);
    }

    ok not $doc<done>, 'Not yet finished';

    $!conversation-id = $doc<conversationId>;
    my Str $server-first-message = Buf.new(decode-base64($doc<payload>)).decode;
    ok $server-first-message ~~ m/^ 'r=' /, 'Server nonce';
    ok $server-first-message ~~ m/ ',s=' /, 'Server salt';
    ok $server-first-message ~~ m/ ',i=' /, 'Server iterations';
    $server-first-message
  }

  #-----------------------------------------------------------------------------
  method client-final ( Str:D $client-final --> Str ) {

   my BSON::Document $doc = $!database.run-command( BSON::Document.new: (
        saslContinue => 1,
        conversationId => $!conversation-id,
        payload => encode-base64( $client-final, :str)
      )
    );

    if !$doc<ok> {
      skip 1, ;
      flunk "$doc<code>, $doc<errmsg>";
      done-testing;

      restart-to-normal;
      exit(1);
    }

    ok not $doc<done>, 'Not yet finished';

    my Str $server-final-message = Buf.new(decode-base64($doc<payload>)).decode;

    $server-final-message;
  }

  #-----------------------------------------------------------------------------
  method mangle-password ( Str:D :$username, Str:D :$password --> Buf ) {

    my utf8 $mdb-hashed-pw = ($username ~ ':mongo:' ~ $password).encode;
    my Str $md5-mdb-hashed-pw = md5($mdb-hashed-pw).>>.fmt('%02x').join;
    Buf.new($md5-mdb-hashed-pw.encode);
  }

  #-----------------------------------------------------------------------------
  method clean-up ( ) {

    # Some extra chit-chat
    my BSON::Document $doc = $!database.run-command( BSON::Document.new: (
        saslContinue => 1,
        conversationId => $!conversation-id,
        payload => encode-base64( '', :str)
      )
    );

    if !$doc<ok> {
      skip 1;
      flunk "$doc<code>, $doc<errmsg>";
      done-testing;

      restart-to-normal;
      exit(1);
    }

    ok $doc<done>, 'Login finished';
    is Buf.new(decode-base64($doc<payload>)).decode, '',
       'Empty string returned';

    $!client.cleanup;
  }

  #-----------------------------------------------------------------------------
  method error ( Str:D $message --> Str ) {

    error-message($message);
  }
}

subtest {

  my Auth::SCRAM $sc .= new(
    :username<Dondersteen>,
    :password<w@tD8jeDan>,
    :client-object(MyClientMDB.new),
  );

  $sc.start-scram;

}, 'Mongodb login';

#-------------------------------------------------------------------------------
# Cleanup
restart-to-normal;
info-message("Test $?FILE stop");
done-testing();
