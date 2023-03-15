use strict;
use warnings;
use Time::HiRes qw{time};
use Test::More tests => 1 + 16;
use_ok('Net::MQTT::Simple');

my $host = $ENV{'MQTT_HOST'};

SKIP: {
  skip '$ENV{"MQTT_HOST"} not set', 16 unless $host;
  my $mqtt = Net::MQTT::Simple->new($host);
  isa_ok($mqtt, 'Net::MQTT::Simple');
  can_ok($mqtt, 'one_shot');
  {
    my $timeout = 0.5;
    my $timer   = time();
    my $message = $mqtt->one_shot(my_topic => my_topic => my_message => $timeout); #loop back
    $timer      = time() - $timer;
    ok($timer < $timeout, 'timer is faster than timeout');
    is($message, 'my_message', 'one_shot test loopback');
  }
  {
    my $timeout = 0.5;
    my $timer   = time();
    my %message = $mqtt->one_shot(my_topic => my_topic => my_message => $timeout); #loop back
    $timer      = time() - $timer;
    ok($timer < $timeout, 'timer is faster than timeout');
    ok(exists($message{'topic'}), 'one_shot array context key topic exists');
    ok(exists($message{'message'}), 'one_shot array context key message exists');
    is($message{'topic'}, 'my_topic', 'one_shot array context topic value');
    is($message{'message'}, 'my_message', 'one_shot array context message value');
  }
  {
    my $timeout = 0.5;
    my $timer   = time();
    my $message = $mqtt->one_shot(my_timeout => my_topic => my_message => $timeout); #loop back
    $timer      = time() - $timer;
    ok($timer < $timeout * 1.5, 'timeout is less that 1.5 of timeout');
    is($message, undef, 'one_shot test timeout');
  }
  {
    my $timeout = 0.5;
    my $timer   = time();
    my %message = $mqtt->one_shot(my_timeout => my_topic => my_message => $timeout); #loop back
    $timer      = time() - $timer;
    ok($timer < $timeout * 1.5, 'timeout is less that 1.5 of timeout');
    ok(exists($message{'topic'}), 'one_shot array context key topic exists');
    ok(exists($message{'message'}), 'one_shot array context key message exists');
    is($message{'topic'}, undef, 'one_shot array context topic value');
    is($message{'message'}, undef, 'one_shot array context message value');
  }
}
