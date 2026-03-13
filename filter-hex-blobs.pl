#!/usr/bin/env perl
use strict;
use warnings;

my %uuid_seen;
my %hex_seen;
my $uuid_next = 1;
my $hex_next  = 1;

while (my $line = <STDIN>) {

    # Replace UUIDs
    $line =~ s{
        \b
        ([0-9a-fA-F]{8}
        -[0-9a-fA-F]{4}
        -[0-9a-fA-F]{4}
        -[0-9a-fA-F]{4}
        -[0-9a-fA-F]{12})
        \b
    }{
        $uuid_seen{$1} //= sprintf("UUID%02d", $uuid_next++)
    }gex;

    # Replace 32-hex strings
    $line =~ s{
        \b([0-9a-fA-F]{32})\b
    }{
        $hex_seen{$1} //= sprintf("HEX%02d", $hex_next++)
    }gex;

    print $line;
}
