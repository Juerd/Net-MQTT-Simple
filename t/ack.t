#!/usr/bin/perl -w
use strict;
use Test::More;
use Net::MQTT::Simple;

sub new_mqtt {
    my $m = Net::MQTT::Simple->new("localhost:1883");
    $m->{socket} = "pretend-socket";
    $m->{last_connect} = time();
    return $m;
}

sub warnings_from (&) {
    my ($code) = @_;
    my @caught;
    local $SIG{__WARN__} = sub { push @caught, $_[0] };
    $code->();
    return @caught;
}

subtest "CONNACK: success (return code 0) does nothing" => sub {
    my $m = new_mqtt();

    my @warned = warnings_from {
        $m->_incoming_connack({ data => "\x00\x00" }); # flags=0, rc=0 (accepted)
    };

    is scalar(@warned), 0, "no warning on successful CONNACK";
    ok exists $m->{socket}, "connection left intact on success";
};

subtest "CONNACK: each documented error code drops the connection" => sub {
    my %cases = (
        1 => "Unacceptable protocol version",
        2 => "Identifier rejected",
        3 => "Server unavailable",
        4 => "Bad user name or password",
        5 => "Not authorized",
    );

    for my $code (sort keys %cases) {
        my $m = new_mqtt();

        my @warned = warnings_from {
            $m->_incoming_connack({ data => pack("C C", 0, $code) });
        };

        ok !exists $m->{socket}, "code $code: connection dropped";
        isnt $m->{last_connect}, 0, "code $code: last_connect not reset by _drop_connection";
        is scalar(@warned), 1, "code $code: exactly one warning";
        like $warned[0], qr/\Q$cases{$code}\E/, "code $code: warning mentions '$cases{$code}'";
    }
};

subtest "CONNACK: unknown/future error code still drops the connection" => sub {
    my $m = new_mqtt();

    my @warned = warnings_from {
        $m->_incoming_connack({ data => pack("C C", 0, 42) });
    };

    ok !exists $m->{socket}, "connection dropped even for an unrecognised code";
    like $warned[0], qr/Unknown connection error/, "warning falls back to a generic message";
    like $warned[0], qr/42/, "warning includes the numeric code";
};

subtest "CONNACK: error still drops the connection when warnings are off" => sub {
    my $m = new_mqtt();
    $m->warnings(0);

    my @warned = warnings_from {
        $m->_incoming_connack({ data => pack("C C", 0, 5) }); # not authorized
    };

    is scalar(@warned), 0, "no warning is printed when warnings are disabled";
    ok !exists $m->{socket}, "but the connection is still dropped (spec-mandated, not optional)";
};

subtest "SUBACK: all-success return codes produce no warning" => sub {
    my $m = new_mqtt();

    # packet id (2 bytes) + three granted QoS-0 return codes
    my @warned = warnings_from {
        $m->_incoming_suback({ data => pack("n C C C", 1, 0, 0, 0) });
    };

    is scalar(@warned), 0, "no warning when every subscription was granted";
    ok exists $m->{socket}, "SUBACK failures never drop the connection (not spec-mandated)";
};

subtest "SUBACK: a 0x80 failure code warns (when warnings enabled)" => sub {
    my $m = new_mqtt();

    # packet id + [granted, refused, granted]
    my @warned = warnings_from {
        $m->_incoming_suback({ data => pack("n C C C", 1, 0, 0x80, 0) });
    };

    is scalar(@warned), 1, "exactly one warning for the one refused subscription";
    like $warned[0], qr/refused/, "warning text mentions refusal";
    ok exists $m->{socket}, "connection stays up despite the refusal";
};

subtest "SUBACK: multiple failures each produce their own warning" => sub {
    my $m = new_mqtt();

    my @warned = warnings_from {
        $m->_incoming_suback({ data => pack("n C C C C", 1, 0x80, 0, 0x80, 0x80) });
    };

    is scalar(@warned), 3, "one warning per refused subscription";
};

subtest "SUBACK: nothing is warned or computed when warnings are off" => sub {
    my $m = new_mqtt();
    $m->warnings(0);

    my @warned = warnings_from {
        $m->_incoming_suback({ data => pack("n C C", 1, 0x80) });
    };

    is scalar(@warned), 0, "no warning printed when warnings are disabled";
    ok exists $m->{socket}, "connection unaffected either way";
};

done_testing;
