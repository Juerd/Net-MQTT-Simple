package Net::MQTT::Simple;

# use strict;    # might not be available (e.g. on openwrt)
# use warnings;  # same.

our $VERSION = '1.01';

# Please note that these are not documented and are subject to change:
our $KEEPALIVE_INTERVAL = 10;
our $MAX_LENGTH = 2097152;  # 2 MB

my $global;
my $socket_class =
      eval { require IO::Socket::IP; 1 }   ? "IO::Socket::IP"
    : eval { require IO::Socket::INET; 1 } ? "IO::Socket::INET"
    : die "Neither IO::Socket::IP nor IO::Socket::INET found";

# Carp might not be available either.
sub _croak {
    die sprintf "%s at %s line %d.\n", "@_", (caller 1)[1, 2];
}

sub _filter_as_regex {
    my ($filter) = @_;

    return "^(?!\\\$)" if $filter eq '#';   # Match everything except /^\$/
    return "^(?!\\\$)" if $filter eq '/#';  # Match everything except /^\$/

    $filter = quotemeta $filter;

    $filter =~ s{ \z (?<! \\ \/ \\ \# ) }"\\z"x;       # Anchor unless /#$/
    $filter =~ s{ \\ \/ \\ \#           }""x;
    $filter =~ s{ \\ \+                 }"[^/]*+"xg;
    $filter =~ s{ ^ (?= \[ \^ / \] \* ) }"(?!\\\$)"x;  # No /^\$/ if /^\+/

    return "^$filter";
}

sub import {
    my ($class, $server) = @_;
    @_ <= 2 or _croak "Too many arguments for use " . __PACKAGE__;

    $server or return;

    $global = $class->new($server);

    *{ (caller)[0] . "::publish" } = \&publish;
    *{ (caller)[0] . "::retain"  } = \&retain;
}

sub new {
    my ($class, $server) = @_;
    @_ == 2 or _croak "Wrong number of arguments for $class->new";

    # Add port for bare IPv6 address
    $server = "[$server]:1883" if $server =~ /:.*:/ and not $server =~ /\[/;

    # Add port for bare IPv4 address or bracketed IPv6 address
    $server .= ":1883" if $server !~ /:/ or $server =~ /^\[.*\]$/;

    return bless { server => $server }, $class;
}

sub _connect {
    my ($self) = @_;

    return if $self->{socket} and $self->{socket}->connected;

    $self->{socket} = $socket_class->new( PeerAddr => $self->{server} );
    $self->_send(
        "\x10" . pack("C/a*",
            "\0\x06MQIsdp\x03\x02\0\x3c" . pack("n/a*",
                "Net::MQTT::Simple[$$]"
            )
        )
    );

    $self->_send_subscribe;
}

sub _prepend_variable_length {
    # Copied from Net::MQTT::Constants
    my ($data) = @_;
    my $v = length $data;
    my $o = "";
    my $d;
    do {
        $d = $v % 128;
        $v = int($v/128);
        $d |= 0x80 if $v;
        $o .= pack "C", $d;
    } while $d & 0x80;
    return "$o$data";
}

sub _send {
    my ($self, $data) = @_;

    $self->_connect;
    my $socket = $self->{socket};
    syswrite $socket, $data
        or delete $self->{socket};  # reconnect on next message

    $self->{last_send} = time;
}

sub _send_subscribe {
    my ($self) = @_;

    return if not exists $self->{sub};

    # Hardcoded "packet identifier" \0\0 for now. Hello? This is TCP.
    $self->_send("\x82" . _prepend_variable_length(
        "\0\0" .
        join("", map "$_\0",
            map pack("n/a*", $_), keys %{ $self->{sub} } 
        )
    ));
}

sub _parse {
    my ($self) = @_;

    my $bufref = \$self->{buffer};

    return if length $$bufref < 2;

    my $offset = 1;

    my $length = do {
        my $multiplier = 1;
        my $v = 0;
        my $d;
        do {
            return if $offset >= length $$bufref;  # not enough data yet
            $d = unpack "C", substr $$bufref, $offset++, 1;
            $v += ($d & 0x7f) * $multiplier;
            $multiplier *= 128;
        } while ($d & 0x80);
        $v;
    };

    if ($length > $MAX_LENGTH) {
        # On receiving an enormous packet, just disconnect to avoid exhausting
        # RAM on tiny systems.
        # TODO: just slurp and drop the data
        delete $self->{socket};
        return;
    }

    return if $length > (length $$bufref) + $offset;  # not enough data yet

    my $first_byte = unpack "C", substr $$bufref, 0, 1;

    my $packet = {
        type   => ($first_byte & 0xF0) >> 4,
        dup    => ($first_byte & 0x08) >> 3,
        qos    => ($first_byte & 0x06) >> 1,
        retain => ($first_byte & 0x01),
        data   => substr($$bufref, $offset, $length),
    };

    substr $$bufref, 0, $offset + $length, "";  # remove the parsed bits.

    return $packet;
}

sub _incoming_publish {
    my ($self, $packet) = @_;

    # Because QoS is not supported, no packed ID in the data. It would
    # have been 16 bits between $topic and $message.
    my ($topic, $message) = unpack "n/a a*", $packet->{data};

    for my $cb (@{ $self->{callbacks} }) {
        if ($topic =~ /$cb->{regex}/) {
            $cb->{callback}->($topic, $message);
            return;
        }
    }
}

sub _publish {
    my ($self, $retain, $topic, $message) = @_;

    $message //= "" if $retain;

    utf8::encode($topic);
    utf8::encode($message);

    $self->_send(
        ($retain ? "\x31" : "\x30")
        . _prepend_variable_length(
            pack("n/a*", $topic) . $message
        )
    );
}

sub publish {
    my $method = ref($_[0]) eq __PACKAGE__;
    @_ == ($method ? 3 : 2) or _croak "Wrong number of arguments for publish";

    ($method ? shift : $global)->_publish(0, @_);
}

sub retain {
    my $method = ref($_[0]) eq __PACKAGE__;
    @_ == ($method ? 3 : 2) or _croak "Wrong number of arguments for retain";

    ($method ? shift : $global)->_publish(1, @_);
}

sub run {
    my ($self, @subscribe_args) = @_;

    $self->subscribe(@subscribe_args) if @subscribe_args;

    $self->tick( time() - $self->{ last_send } + $KEEPALIVE_INTERVAL )
        until $self->{stop_loop};

    delete $self->{stop_loop};
}

sub subscribe {
    my ($self, @kv) = @_;

    while (my ($topic, $callback) = splice @kv, 0, 2) {
        $self->{sub}->{ $topic } = 1;
        push @{ $self->{callbacks} }, {
            regex => _filter_as_regex($topic),
            callback => $callback,
        };
    }

    $self->_send_subscribe() if $self->{socket};
}

sub tick {
    my ($self, $timeout) = @_;

    $self->_connect;
    my $socket = $self->{socket};

    my $bufref = \$self->{buffer};

    my $r = '';
    vec($r, fileno($socket), 1) = 1;

    if (select $r, undef, undef, $timeout // 0) {
        sysread $socket, $$bufref, 8192, length $$bufref
            or delete $self->{socket};

        while (length $$bufref) {
            my $packet = $self->_parse() or last;
            $self->_incoming_publish($packet) if $packet->{type} == 3;
        }
    }

    if ($self->{last_send} <= time() + $KEEPALIVE_INTERVAL) {
        $self->_send("\xc0\0");  # PINGREQ
    }
}

1;

__END__

=head1 NAME

Net::MQTT::Simple - Minimal MQTT version 3 publisher

=head1 SYNOPSIS

    # One-liner that publishes sensor values from STDIN

    perl -MNet::MQTT::Simple=mosquitto.example.org \
         -nle'retain "topic/here" => $_'


    # Functional (single server only)

    use Net::MQTT::Simple "mosquitto.example.org";

    publish "topic/here" => "Message here";
    retain  "topic/here" => "Retained message here";


    # Object oriented (supports multiple servers)

    use Net::MQTT::Simple;

    my $mqtt1 = Net::MQTT::Simple->new("mosquitto.example.org");
    my $mqtt2 = Net::MQTT::Simple->new("mosquitto.example.com");

    for my $server ($mqtt1, $mqtt2) {
        $server->publish("topic/here" => "Message here");
        $server->retain( "topic/here" => "Message here");
    }


=head1 DESCRIPTION

This module consists of only one file and has no dependencies except core Perl
modules, making it suitable for embedded installations where CPAN installers
are unavailable and resources are limited.

Only the most basic MQTT publishing functionality is supported; if you need
more, you'll have to use the full-featured L<Net::MQTT> instead.

Connections are set up on demand, automatically reconnecting to the server if a
previous connection had been lost.

Because sensor scripts often run unattended, connection failures will result in
warnings (on STDERR if you didn't override that) without throwing an exception.

=head2 Functional interface

This will suffice for most simple sensor scripts. A socket is kept open for
reuse until the script has finished.

Instead of requesting symbols to be imported, provide the MQTT server on the
C<use Net::MQTT::Simple> line. A non-standard port can be specified with a
colon. The functions C<publish> and C<retain> will be exported.

=head2 Object oriented interface

Specify the server (possibly with a colon and port number) to the constructor,
C<< Net::MQTT::Simple->new >>. The socket is disconnected when the object goes
out of scope.

=head1 PUBLISHING MESSAGES

The two methods for publishing messages are the same, except for the state of
the C<retain> flag.

=head2 retain(topic, message)

Publish the message with the C<retain> flag on. Use this for sensor values or
anything else where the message indicates the current status of something.

To discard a retained topic, provide an empty or undefined message.

=head2 publish(topic, message)

Publishes the message with the C<retain> flag off. Use this for ephemeral
messages about events that occur (like that a button was pressed).

=head1 IPv6 PREREQUISITE

For IPv6 support, the module L<IO::Socket::IP> needs to be installed. It comes
with Perl 5.20 and is available from CPAN for older Perls. If this module is
not available, the older L<IO::Socket::INET> will be used, which only supports
Legacy IP (IPv4).

=head1 MANUAL INSTALLATION

If you can't use the CPAN installer, you can actually install this module by
creating a directory C<Net/MQTT> and putting C<Simple.pm> in it. Please note
that this method does not work for every Perl module and should be used only
as a last resort on systems where proper installers are not available.

To view the list of C<@INC> paths where Perl searches for modules, run C<perl
-V>. This list includes the current working directory (C<.>). Additional
include paths can be specified in the C<PERL5LIB> environment variable; see
L<perlenv>.

=head1 NOT SUPPORTED

=over 4

=item QoS (Quality of Service)

Every message is published at QoS level 0, that is, "at most once", also known
as "fire and forget".

=item DUP (Duplicate message)

Since QoS is not supported, no retransmissions are done, and no message will
indicate that it has already been sent before.

=item Authentication, encryption

No username and password are sent to the server and the connection will be set
up without TLS or SSL.

=item Subscriptions

This is a write-only implementation, meant for sensor equipment.

=item Last will

The server won't publish a "last will" message on behalf of us when our
connection's gone.

=item Keep-alives

You'll have to wait for the TCP timeout instead.

=back

=head1 LICENSE

Pick your favourite OSI approved license :)

http://www.opensource.org/licenses/alphabetical

=head1 AUTHOR

Juerd Waalboer <juerd@tnx.nl>

=head1 SEE ALSO

L<Net::MQTT>
