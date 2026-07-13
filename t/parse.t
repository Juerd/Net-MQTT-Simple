#!/usr/bin/perl -w
use strict;
use Test::More;
use Net::MQTT::Simple;

# Intentional code duplication so we don't test the code against itself.
sub encode_length {
    my ($v) = @_;
    my $out = "";
    do {
        my $d = $v % 128;
        $v = int($v / 128);
        $d |= 0x80 if $v;
        $out .= chr $d;
    } while $v;
    return $out;
}

sub new_mqtt {
    return Net::MQTT::Simple->new("localhost:1883");
}

# MQTT v3.1.1: 2.2.3 Remaining Length
subtest "encode_length matches spec examples" => sub {
    is encode_length(0),         "\x00",             "value 0";
    is encode_length(127),       "\x7F",             "value 127";
    is encode_length(128),       "\x80\x01",         "value 128";
    is encode_length(16383),     "\xFF\x7F",         "value 16383";
    is encode_length(16384),     "\x80\x80\x01",     "value 16384";
    is encode_length(2097151),   "\xFF\xFF\x7F",     "value 2097151";
    is encode_length(268435455), "\xFF\xFF\xFF\x7F", "value 268435455 (max)";
};

subtest "empty or too-short buffer yields no packet" => sub {
    my $m = new_mqtt();
    is $m->_parse, undef, "empty buffer";

    $m->{buffer} = "\xd0";
    is $m->_parse, undef, "single byte buffer (no length byte yet)";
    is $m->{buffer}, "\xd0", "buffer left untouched";
};

subtest "incomplete variable-length-encoded remaining length" => sub {
    my $m = new_mqtt();
    # continuation bit set (0x80) but the next byte hasn't arrived yet
    $m->{buffer} = "\xd0\x80";
    is $m->_parse, undef, "dangling continuation byte -> not enough data";
    is $m->{buffer}, "\xd0\x80", "buffer left untouched";
};

subtest "incomplete payload (header+length OK, body not fully arrived)" => sub {
    my $m = new_mqtt();
    # Remaining length says 10 bytes are coming, but only 5 are here.
    $m->{buffer} = "\x30" . encode_length(10) . "ABCDE";
    is $m->_parse, undef, "partial body -> not enough data";
    is $m->{buffer}, "\x30" . encode_length(10) . "ABCDE",
        "buffer left completely untouched (nothing consumed prematurely)";

    # Now "the rest arrives" and parsing should succeed.
    $m->{buffer} .= "FGHIJ";
    my $packet = $m->_parse;
    ok $packet, "parses once full body present";
    is $packet->{data}, "ABCDEFGHIJ", "payload bytes correct";
    is $m->{buffer}, "", "buffer fully drained";
};

subtest "minimal packet: PINGRESP (type 13, no payload)" => sub {
    my $m = new_mqtt();
    $m->{buffer} = "\xd0\x00";
    my $packet = $m->_parse;
    ok $packet, "packet parsed";
    is $packet->{type},   13, "type";
    is $packet->{dup},     0, "dup";
    is $packet->{qos},     0, "qos";
    is $packet->{retain},  0, "retain";
    is $packet->{data},   "", "no payload";
    is $m->{buffer}, "", "buffer drained";
};

subtest "fixed-header flag bits (type/dup/qos/retain) decoded correctly" => sub {
    my $m = new_mqtt();
    # 0x3D = 0011_1101 -> type=3 (PUBLISH), dup=1, qos=2, retain=1
    $m->{buffer} = "\x3D" . encode_length(2) . "AB";
    my $packet = $m->_parse;
    ok $packet, "packet parsed";
    is $packet->{type},    3, "type extracted from top nibble";
    is $packet->{dup},     1, "dup bit (0x08)";
    is $packet->{qos},     2, "qos bits (0x06)";
    is $packet->{retain},  1, "retain bit (0x01)";
    is $packet->{data}, "AB", "payload";
};

subtest "multi-byte remaining length is decoded correctly (2 and 3 byte cases)" => sub {
    my $m = new_mqtt();

    # 2-byte remaining length: 200
    my $payload200 = "x" x 200;
    $m->{buffer} = "\x30" . encode_length(200) . $payload200;
    my $packet = $m->_parse;
    ok $packet, "200-byte payload (2-byte length) parsed";
    is length($packet->{data}), 200, "payload length correct";
    is $packet->{data}, $payload200, "payload content correct";

    # 3-byte remaining length: 20000
    my $payload20k = "y" x 20000;
    $m->{buffer} = "\x30" . encode_length(20000) . $payload20k;
    $packet = $m->_parse;
    ok $packet, "20000-byte payload (3-byte length) parsed";
    is length($packet->{data}), 20000, "payload length correct";
    is $packet->{data}, $payload20k, "payload content correct";
};

subtest "oversized packet triggers disconnect instead of buffering" => sub {
    my $m = new_mqtt();
    $m->{socket}       = "pretend-this-is-a-socket";
    $m->{last_connect} = time();

    # Remaining length bigger than MAX_LENGTH (2 MB by default). We don't
    # need to actually supply that much data: the MAX_LENGTH check prevents
    # even reading it.
    my $huge = $Net::MQTT::Simple::MAX_LENGTH + 1;
    $m->{buffer} = "\x30" . encode_length($huge);

    my @warnings;
    my $packet = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $m->_parse;
    };
    is $packet, undef, "no packet returned for oversized length";
    like "@warnings", qr/too big/, "warning emitted for oversized length";
    ok !exists $m->{socket}, "_drop_connection was called (socket cleared)";
    is $m->{last_connect}, 0, "_drop_connection reset last_connect";
};

subtest "boundary: length exactly at MAX_LENGTH is accepted" => sub {
    my $m = new_mqtt();
    my $max = $Net::MQTT::Simple::MAX_LENGTH;
    my $payload = "z" x $max;
    $m->{buffer} = "\x30" . encode_length($max) . $payload;

    my $packet = $m->_parse;
    ok $packet, "packet at exactly MAX_LENGTH is parsed, not rejected";
    is length($packet->{data}), $max, "full payload length matches MAX_LENGTH";
};

subtest "multiple packets in one buffer are parsed one at a time, in order" => sub {
    my $m = new_mqtt();
    my $ping = "\xc0\x00";  # PINGREQ
    my $pub  = "\x30" . encode_length(5) . "hello";  # PUBLISH-ish
    my $pong = "\xd0\x00";  # PINGRESP
    $m->{buffer} = $ping . $pub . $pong;

    my $p1 = $m->_parse;
    is $p1->{type}, 12, "first packet: PINGREQ (type 12)";

    my $p2 = $m->_parse;
    is $p2->{type}, 3,      "second packet: type 3";
    is $p2->{data}, "hello", "second packet payload";

    my $p3 = $m->_parse;
    is $p3->{type}, 13, "third packet: PINGRESP (type 13)";

    is $m->{buffer}, "", "buffer fully drained after 3 parses";
    is $m->_parse, undef, "nothing left to parse";
};

subtest "integration: _parse + _incoming_publish dispatches to the right callback" => sub {
    my $m = new_mqtt();

    my @received;
    $m->subscribe("sensors/+/temp" => sub {
        my ($topic, $message, $retain) = @_;
        push @received, [$topic, $message, $retain];
    });

    # Build a real-shaped PUBLISH packet: 2-byte topic length + topic + message.
    my $topic   = "sensors/kitchen/temp";
    my $message = "21.5";
    my $var_header_and_payload = pack("n/a*", $topic) . $message;

    # retain flag set (bit 0 of first byte), type 3 (PUBLISH) => 0x31
    $m->{buffer} = "\x31" . encode_length(length $var_header_and_payload)
                 . $var_header_and_payload;

    my $packet = $m->_parse;
    ok $packet, "PUBLISH packet parsed";
    is $packet->{type}, 3, "type is PUBLISH";
    is $packet->{retain}, 1, "retain flag decoded";

    $m->_incoming_publish($packet);

    is scalar(@received), 1, "callback fired exactly once";
    is $received[0][0], "sensors/kitchen/temp", "topic delivered correctly";
    is $received[0][1], "21.5", "message delivered correctly";
    is $received[0][2], 1, "retain flag passed through to callback";
};

done_testing;
