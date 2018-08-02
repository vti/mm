package App::mm::config;
use strict;
use warnings;
use YAML::Tiny;

sub parse {
    my $class = shift;
    my ($file) = @_;

    return YAML::Tiny->read($file)->[0];
}

1;
