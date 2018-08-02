package App::mm::logger;
use strict;
use warnings;
use Time::Moment;

sub new {
    my $class = shift;

    my $self = {};
    bless $self, $class;

    return $self;
}

sub debug { shift->log( 'debug', @_ ) }
sub info  { shift->log( 'info',  @_ ) }
sub error { shift->log( 'error', @_ ) }

sub log {
    my $self  = shift;
    my $level = shift;
    my $msg   = shift;

    if (@_) {
        $msg = sprintf $msg, @_;
    }

    my $datetime = Time::Moment->now->strftime('%Y-%m-%d %T%f%z');

    print "[$datetime] [$level] $msg\n";
}

1;
