package App::mm;

use strict;
use warnings;

sub new {
    my $class = shift;
    my (%params) = @_;

    my $self = {};
    bless $self, $class;

    $self->{config} = $params{config};
    $self->{logger} = $params{logger};

    $self->{executions} = {};
    $self->{alerts}     = {};

    $self->_init;

    return $self;
}

sub reload_config {
    my $self = shift;
    my ($config) = @_;

    $self->{config} = $config;

    $self->_init;

    return $self;
}

sub log { shift->{logger} }

sub run {
    my $self = shift;

    while (1) {
        foreach my $check ( @{ $self->{checks} } ) {
            $self->_execute($check);
        }

        sleep 1;
    }
}

sub _init {
    my $self = shift;

    my @checks;
    foreach my $host ( @{ $self->{config}->{hosts} } ) {
        foreach my $host_check ( @{ $host->{checks} } ) {
            my $check = $self->_check_by_id( $host_check->{id} );

            %$host_check = ( %$host_check, %$check );

            push @checks, { %$host_check, host => $host };
        }
    }

    $self->{checks} = \@checks;

    return $self;
}

sub _check_by_id {
    my $self = shift;
    my ($id) = @_;

    my ($check) = grep { $_->{id} eq $id } @{ $self->{config}->{checks} };
    die 'check not found' unless $check;

    return $check;
}

sub _execute {
    my $self = shift;
    my ($check) = @_;

    my $check_id = join ':', $check->{host}->{id}, $check->{id};

    my $last_execution = $self->{executions}->{$check_id};

    if (   $last_execution
        && $last_execution->{time} + $check->{interval} > time )
    {
#$self->log->info('[%s] check=%s skip', $check->{host}->{hostname}, $check->{id});
        return;
    }

    my $result = 'ok';
    my $output = '';

    if ( my $cmd = $check->{cmd} ) {
        my @cmd = ($cmd);

        if ( my $args = $check->{args} ) {
            push @cmd, @$args;
        }

        if ( my $ssh = $check->{host}->{ssh} ) {
            my $hostname = $check->{host}->{hostname};
            if ( my $user = $ssh->{user} ) {
                $hostname = "$user\@$hostname";
            }
            unshift @cmd,
              ( 'ssh', $hostname, $ssh->{port} ? ( '-p', $ssh->{port} ) : () );
        }

        $self->log->debug(
            "[%s] check=%s cmd=\n%s",
            $check->{host}->{hostname},
            $check->{id}, join( ' ', @cmd )
        );

        my $fh = $self->run_command_pipe(@cmd);
        while ( defined( my $line = <$fh> ) ) {
            $output .= $line;
        }

        close $fh;

        my $exit_code = $? >> 8;

        $self->log->debug(
            "[%s] check=%s output=\n%s",
            $check->{host}->{hostname},
            $check->{id}, $output
        );

        my $parser_done;
        if ( my $parsers = $check->{parsers} ) {
            foreach my $level ( keys %$parsers ) {
                my $parser = $parsers->{$level};

                if ( $parser->{output} ) {
                    my $re = $parser->{output};
                    $re =~ s{^/}{};
                    $re =~ s{/$}{};

                    if ( $output =~ m/$re/ ) {
                        $result      = $level;
                        $parser_done = 1;
                        last;
                    }
                }
            }
        }

        if ( !$parser_done && $exit_code ) {
            $result = 'critical';
        }
    }

    $self->log->info(
        '[%s] check=%s result=%s',
        $check->{host}->{hostname},
        $check->{id}, $result
    );

    if ( my $alerts = $self->{config}->{alerts} ) {
        foreach my $alert (@$alerts) {
            $self->_alert( $check, $alert, $result, $output );
        }
    }

    $self->{executions}->{$check_id} = {
        result => $result,
        time   => time,
    };
}

sub _alert {
    my $self = shift;
    my ( $check, $alert, $result, $output ) = @_;

    my $alert_id = join ':', $check->{host}->{id}, $alert->{id};

    my $do_alert;

    my $last_alert = $self->{alerts}->{$alert_id};

    if ($last_alert) {
        if ( $last_alert->{result} ne $result ) {
            $do_alert = 'status changed';
        }
        elsif ( $result ne 'ok' ) {
            if ( $alert->{backoff} ) {
                my $backoff_time =
                  $alert->{backoff} - ( time - $last_alert->{time} );

                if ( $backoff_time <= 0 ) {
                    $do_alert = 'backoff finished';
                }
            }
            else {
                $do_alert = 'always';
            }
        }
    }
    elsif ( $result ne 'ok' ) {
        $do_alert = 'first failure';
    }

    return unless $do_alert;

    $self->log->info(
        '[%s] check=%s alert=%s (%s)',
        $check->{host}->{hostname},
        $check->{id}, $alert->{id}, $do_alert
    );

    if ( my $cmd = $alert->{cmd} ) {
        my @cmd =
          ( $cmd, $check->{host}->{hostname}, $check->{id}, $result, $output );

        $self->log->debug(
            "[%s] alert=%s cmd=%s",
            $check->{host}->{hostname},
            $check->{id}, $cmd
        );

        my $fh = $self->run_command_pipe(@cmd);
        while ( defined( my $line = <$fh> ) ) {
        }

        close $fh;

        my $exit_code = $? >> 8;

        if ($exit_code) {
            $self->log->error( 'alert failed (exit=%d)', $exit_code );
        }
    }

    $self->{alerts}->{$alert_id} = {
        time   => time,
        result => $result,
    };
}

sub run_command_pipe {
    my $self = shift;
    my (@cmd) = @_;

    my $pid = open my $fh, '-|';
    if ( not defined $pid ) {
        die("pipe failed: $!");
    }
    elsif ( $pid == 0 ) {
        open STDERR, '>&', STDOUT;
        STDOUT->autoflush(1);
        exec(@cmd);
    }

    return $fh;
}

1;
