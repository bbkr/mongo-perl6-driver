use v6.c;
use Test;

use lib 't';
use Test-support;

use MongoDB;
use MongoDB::Client;
use MongoDB::MDBConfig;

#-------------------------------------------------------------------------------
drop-send-to('mongodb');
drop-send-to('screen');
#modify-send-to( 'screen', :level(* >= MongoDB::Loglevels::Debug));
info-message("Test $?FILE start");

my MongoDB::Test-support $ts .= new;

my MongoDB::Client $client;

my Hash $config = MongoDB::MDBConfig.instance.config;

my Str $rs1-s2 = $config<mongod><s2><replicate1><replSet>;
my Str $host = 'localhost';
my Int $p1 = $ts.server-control.get-port-number('s1');
my Int $p2 = $ts.server-control.get-port-number('s2');

#-------------------------------------------------------------------------------
subtest {

  diag "\nmongodb://:$p2,:$p1";
  $client .= new(:uri("mongodb://:$p2,:$p1"));
  my $server = $client.select-server;
  is $server.name, "localhost:$p1", "Server localhost:$p1 accepted";
  is $client.server-status('localhost:' ~ $p2), REJECTED-SERVER,
     "Server localhost:$p2 rejected";

  diag "mongodb://:$p2";
  $client .= new(:uri("mongodb://:$p2"));
  $server = $client.select-server(:2check-cycles);
  is $client.server-status('localhost:' ~ $p2), REJECTED-SERVER,
     "Server localhost:$p2 rejected";

  diag "mongodb://:$p1,:$p2/?replicaSet=unknownRS";
  $client .= new(:uri("mongodb://:$p1,:$p2/?replicaSet=unknownRS"));
  $server = $client.select-server(:2check-cycles);
  is $client.server-status('localhost:' ~ $p1), REJECTED-SERVER,
     "Server localhost:$p1 rejected";
  is $client.server-status('localhost:' ~ $p2), REJECTED-SERVER,
     "Server localhost:$p2 rejected";

  diag "mongodb://:$p1,:$p2/?replicaSet=$rs1-s2";
  $client .= new(:uri("mongodb://:$p1,:$p2/?replicaSet=$rs1-s2"));
  $server = $client.select-server;
  is $server.name, "localhost:$p2", "Server localhost:$p2 returned";
  is $client.server-status('localhost:' ~ $p1), REJECTED-SERVER,
     "Server localhost:$p1 rejected";
  is $client.server-status('localhost:' ~ $p2), REPLICASET-PRIMARY,
     "Server localhost:$p2 replicaset primary";

}, "Client behaviour with a replicaserver";

#-------------------------------------------------------------------------------
# Cleanup
#
info-message("Test $?FILE stop");
done-testing();
exit(0);