package Net::MQTT::Simple;

# use strict;    # might not be available (e.g. on openwrt)
# use warnings;  # same.

our $VERSION = '1.00';

my $global;
my $socket_class =
      eval { require IO::Socket::IP; 1 }   ? "IO::Socket::IP"
    : eval { require IO::Socket::INET; 1 } ? "IO::Socket::INET"
    : die "Neither IO::Socket::IP nor IO::Socket::INET found";

# Carp might not be available either.
sub _croak {
    die sprintf "%s at %s line %d.\n", "@_", (caller 1)[1, 2];
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
    my $socket = $self->{socket};
    print $socket $data;
}

sub _publish {
    my ($self, $retain, $topic, $message) = @_;

    $message //= "" if $retain;

    $self->_connect;
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

    my $mqtt1 = Net::MQTT::simple->new("mosquitto.example.org");
    my $mqtt2 = Net::MQTT::simple->new("mosquitto.example.com");

    for my $server ($mqtt1, $mqtt2) {
        $server->publish("topic/here", "Message here");
        $server->retain( "topic/here", "Message here");
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
