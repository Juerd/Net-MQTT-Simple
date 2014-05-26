#!/usr/bin/perl -w
use strict;
use Test::More;
use Net::MQTT::Simple;

*far = \&Net::MQTT::Simple::filter_as_regex;

no warnings "qw";

# Boring spec tests, the "non normative comments" from the MQTT 3.1.1 draft

SECTION_4_7_1_2: {
    my ($regex, $filter, $topic);

    $regex = far($filter = "sport/tennis/player1/#");

    $topic = "sport/tennis/player1";
    like($topic, qr/$regex/, "4.7.1.2, '$topic' should match '$filter'");

    $topic = "sport/tennis/player1/ranking";
    like($topic, qr/$regex/, "4.7.1.2, '$topic' should match '$filter'");

    $topic = "sport/tennis/player1/wimbledon";
    like($topic, qr/$regex/, "4.7.1.2, '$topic' should match '$filter'");

    $regex = far($filter = "sport/#");

    $topic = "sport";
    like($topic, qr/$regex/, "4.7.1.2, '$topic' should match '$filter'");
}

SECTION_4_7_1_3: {
    my ($regex, $filter, $topic);

    $regex = far($filter = "sport/tennis/+");

    $topic = "sport/tennis/player1";
    like($topic, qr/$regex/, "4.7.1.3, '$topic' should match '$filter'");

    $topic = "sport/tennis/player2";
    like($topic, qr/$regex/, "4.7.1.3, '$topic' should match '$filter'");

    $topic = "sport/tennis/player1/ranking";
    unlike($topic, qr/$regex/, "4.7.1.3, '$topic' should not match '$filter'");

    $regex = far($filter = "sport/+");

    $topic = "sport";
    unlike($topic, qr/$regex/, "4.7.1.3, '$topic' should not match '$filter'");

    $topic = "sport/";
    like($topic, qr/$regex/, "4.7.1.3, '$topic' should match '$filter'");
}

SECTION_4_7_2_1: {
    my ($regex, $filter, $topic);

    $regex = far($filter = "#");
    $topic = "\$SYS/something";
    unlike($topic, qr/$regex/, "4.7.2.1, '$topic' should not match '$filter'");

    $regex = far($filter = "+/monitor/Clients");
    $topic = "\$SYS/monitor/Clients";
    unlike($topic, qr/$regex/, "4.7.2.1, '$topic' should not match '$filter'");

    $regex = far($filter = "\$SYS/#");
    $topic = "\$SYS/something";
    like($topic, qr/$regex/, "4.7.2.1, '$topic' should match '$filter'");

    $regex = far($filter = "\$SYS/monitor/+");
    $topic = "\$SYS/monitor/Clients";
    like($topic, qr/$regex/, "4.7.2.1, '$topic' should match '$filter'");
}

# Now, let's try a more systematic approach

my @matrix = (
    # Topic             Should match all of these, but none of the
    #                   other ones that are listed for other topics.
    [ "foo",            qw(# /# +   foo/# foo) ],
    [ "foo/bar",        qw(# /# +/+ foo/# foo/bar/# foo/+ +/bar) ],
    [ "/foo",           qw(# /# +/+ /foo /foo/#) ],
    [ "/\$foo",         qw(# /# +/+ /$foo /$foo/#) ],  # Not special
    [ "///",            qw(# /# +/+/+/+) ],
    [ "foo/bar/baz",    qw(# /# +/+/+ foo/# foo/bar/#
                           +/bar/baz foo/+/baz foo/bar/+ +/+/baz) ],
    [ "\$foo",          qw($foo $foo/#) ],  # Special because it begins with $
    [ "\$SYS/foo",      qw($SYS/# $SYS/+ $SYS/foo) ],
    [ "\$SYS/foo/bar",  qw($SYS/# $SYS/+/+ $SYS/foo/bar $SYS/+/bar $SYS/foo/+)],
);

my %all_filters;
for (@matrix) {
    $all_filters{ $_ }++ for @{ $_ }[ 1.. $#$_ ];
}

for (@matrix) {
    my $topic = shift @$_;
    my @should_match = @$_;
    my %should_not_match = %all_filters;

    for my $filter (@should_match) {
        delete $should_not_match{ $filter };
        my $regex = far( $filter );
        like($topic, qr/$regex/, "'$topic' should match '$filter'");
    }

    for my $filter (sort keys %should_not_match) {
        my $regex = far( $filter );
        unlike($topic, qr/$regex/, "'$topic' should not match '$filter'");
    }
}

done_testing;
