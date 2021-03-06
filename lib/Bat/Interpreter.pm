package Bat::Interpreter;

use utf8;

use Moo;
use Types::Standard qw(ConsumerOf);
use App::BatParser 0.005;
use Carp;
use Data::Dumper;
use Bat::Interpreter::Delegate::FileStore::LocalFileSystem;
use Bat::Interpreter::Delegate::Executor::PartialDryRunner;
use namespace::autoclean;

# VERSION

# ABSTRACT: Pure perl interpreter for a small subset of bat/cmd files

=encoding utf-8

=head1 SYNOPSIS

# EXAMPLE: examples/basic.pl
     
=head1 DESCRIPTION

Pure perl interpreter for a small subset of bat/cmd files.

=head1 METHODS

=cut

has 'batfilestore' => (
    is => 'rw',
    isa => ConsumerOf['Bat::Interpreter::Role::FileStore'],
    default => sub {
        Bat::Interpreter::Delegate::FileStore::LocalFileSystem->new;
    }
);

has 'executor' => (
    is => 'rw',
    isa => ConsumerOf['Bat::Interpreter::Role::Executor'],
    default => sub {
        Bat::Interpreter::Delegate::Executor::PartialDryRunner->new;
    }
);

=head2 run

Run the interpreter

=cut

sub run {
    my $self   = shift();
    my $filename     = shift();
    my $external_env = shift() // \%ENV;
    #$filename = $self->batfilestore->TraducirNombreArchivo($filename);
    #$filename = Path::Tiny::path($filename);

    my $parser = App::BatParser->new;

    my $ensure_last_line_has_carriage_return = "\r\n";
    if ($^O eq 'MSWin32') {
        $ensure_last_line_has_carriage_return = "\n";
    }

    my $parse_tree = $parser->parse( $self->batfilestore->get_contents($filename) . $ensure_last_line_has_carriage_return );
    if ($parse_tree) {
        my $lines = $parse_tree->{'File'}{'Lines'};

        my %environment = %$external_env;

        # Index file based on labels
        #Only for perl >= 5.020
        #my %line_from_label = List::AllUtils::pairmap { $b->{'Label'}{'Identifier'} => $a }
        #%{$lines}[ List::AllUtils::indexes { exists $_->{'Label'} } @$lines ];
        my %line_from_label;
        for ( my $i = 0; $i < scalar @$lines; $i++ ) {
            my $line = $lines->[$i];
            if ( exists $line->{'Label'} ) {
                $line_from_label{ $line->{'Label'}{'Identifier'} } = $i;
            }
        }
        $line_from_label{'EOF'} = scalar @$lines;
        $line_from_label{'eof'} = scalar @$lines;
        my $context = { 'ENV' => \%environment, 'IP' => 0, 'LABEL_INDEX' => \%line_from_label };

        # Execute lines in a nonlinear fashion
        for ( my $instruction_pointer = 0; $instruction_pointer < scalar @$lines; $instruction_pointer++ ) {
            my $current_instruction = $lines->[$instruction_pointer];
            $context->{'IP'} = $instruction_pointer;
            $self->_handle_instruction( $current_instruction, $context );
            $instruction_pointer = $context->{'IP'};

        }
        return $context->{'STDOUT'};
    } else {
        die "An error ocurred parsing the file";
    }
}

sub _handle_instruction {
    my $self   = shift();
    my $current_instruction = shift();
    my $context             = shift();

    my ($type) = keys %$current_instruction;

    if ( $type eq 'Comment' ) {

        #print "Comment \n";
    }

    if ( $type eq 'Label' ) {

        #print "Label \n";
    }

    if ( $type eq 'Statement' ) {
        my $statement = $current_instruction->{'Statement'};
        $self->_handle_statement( $statement, $context );
    }

}

sub _handle_statement {
    my $self   = shift();
    my $statement = shift();
    my $context   = shift();

    my ($type) = keys %$statement;

    if ( $type eq 'Command' ) {
        my $command = $statement->{'Command'};
        $self->_handle_command( $command, $context );
    }

}

sub _handle_command {
    my $self   = shift();
    my $command = shift();
    my $context = shift();

    if ( defined $command && $command ne '' ) {
        my ($type) = keys %$command;

        if ( $type eq 'SimpleCommand' ) {
            my $command_line = $command->{'SimpleCommand'};
            $command_line = $self->_variable_substitution( $command_line, $context );

            # Path adjustment
            $command_line = $self->_adjust_path($command_line);

            # Dispatch all commands throug supervisor
            # $command_line = "supervisor.pl " . $command_line;
            $self->_execute_command( $command_line, $context );
        }
        if ( $type eq 'SpecialCommand' ) {
            my $special_command_line = $command->{'SpecialCommand'};
            $self->_handle_special_command( $special_command_line, $context );
        }
    } else {

        #print "Empty command\n";
    }

}

sub _handle_special_command {
    my $self   = shift();
    my $special_command_line = shift();
    my $context              = shift();

    my ($type) = keys %$special_command_line;

    if ( $type eq 'If' ) {
        my $condition;
        my $statement;
        if ( exists $special_command_line->{$type}->{'NegatedCondition'} ) {
            $condition = $special_command_line->{$type}->{'NegatedCondition'}->{'Condition'};
            $statement = $special_command_line->{$type}->{'Statement'};
            if ( not $self->_handle_condition( $condition, $context ) ) {
                $self->_handle_statement( $statement, $context );
            }
        } else {
            ( $condition, $statement ) = @{ $special_command_line->{'If'} }{ 'Condition', 'Statement' };
            if ( $self->_handle_condition( $condition, $context ) ) {

                #print "True: " . Dumper($statement);
                $self->_handle_statement( $statement, $context );
            }
        }

    }

    if ( $type eq 'Goto' ) {
        my $label = $special_command_line->{'Goto'}{'Identifier'};
        $self->_goto_label( $label, $context );
    }

    if ( $type eq 'Call' ) {
        my $token = $special_command_line->{'Call'}{'Token'};
        $token = $self->_variable_substitution( $token, $context );
        $token = $self->_adjust_path($token);
        if ( $token =~ /^:/ ) {
            $self->_goto_label( $token, $context );
        } else {
           (my $first_word) = $token =~ /\A([^:\s]+)/;
           if ($first_word =~ /(\.[^.]+)$/) {
               (my $extension) = $first_word =~ /(\.[^.]+)$/;
               if ($extension eq '.exe') {
                   $self->_execute_command( $token, $context );
               } elsif ($extension eq '.bat' || $extension eq '.cmd') {
                    #print "Calling file: $token\n";
                    my $stdout = $self->run( $token, $context->{ENV} );
                    if ( !defined $context->{STDOUT} ) {
                        $context->{STDOUT} = [];
                    }
                    if ( defined $stdout ) {
                        push @{ $context->{STDOUT} }, @$stdout;
                    }
               }
           }
        }
    }

    if ( $type eq 'Set' ) {
        my ( $variable, $value ) = @{ $special_command_line->{'Set'} }{ 'Variable', 'Value' };
        $value                     = $self->_variable_substitution( $value, $context );
        $value                     = $self->_adjust_path($value);
        $context->{ENV}{$variable} = $value;
    }

    if ( $type eq 'For' ) {
        my $token = $special_command_line->{'For'}{'Token'};

        # Handle only simple cases
        if ( $token =~ /\s*?\/F\s*?"delims="\s*%%(?<variable_bucle>[A-Z0-9]+?)\s*?in\s*?\('(?<comando>.+)'\)/i ) {
            my $comando        = $+{'comando'};
            my $parameter_name = $+{'variable_bucle'};
            $comando = $self->_variable_substitution( $comando, $context );
            $comando = $self->_adjust_path($comando);
            $comando =~ s/%%/%/g;

            #print "Comando $comando\n";
            my $salida = $self->_for_command_evaluation($comando);

            #print "Salida $salida";
            my $statement = $special_command_line->{'For'}{'Statement'};

            # Inyectar el término de
            $context->{'PARAMETERS'}{$parameter_name} = $salida;

            #print Dumper($context->{'PARAMETERS'});
            $self->_handle_statement( $statement, $context );
            delete $context->{'PARAMETERS'}{$parameter_name};
        } elsif ($token =~ /\s*?%%(?<variable_bucle>[A-Z0-9]+?)\s*?in\s*?(\([\d]+(?:,[^,\s]+)+\))/i) {
            my $statement = $special_command_line->{'For'}{'Statement'};
            my $parameter_name = $+{'variable_bucle'};
            my $value_list = $2;
            $value_list =~ s/(\(|\))//g;
            my @values = split(/,/,$value_list);
            for my $value (@values) {
                $context->{'PARAMETERS'}->{$parameter_name} = $value;
                $self->_handle_statement($statement, $context);
                delete $context->{'PARAMETERS'}{$parameter_name};
            } 
            
        }
    }
}

sub _handle_condition {
    my $self   = shift();
    my $condition = shift();
    my $context   = shift();

    my ($type) = keys %$condition;
    if ( $type eq 'Comparison' ) {
        my ( $left_operand, $operator, $right_operand ) =
          @{ $condition->{'Comparison'} }{qw(LeftOperand Operator RightOperand)};

        # Variable sustitution
        $left_operand  = $self->_variable_substitution( $left_operand,  $context );
        $right_operand = $self->_variable_substitution( $right_operand, $context );

        if ( $operator eq '==' || $operator eq 'EQU' ) {
            #print "$left_operand == $right_operand\n";
            return $left_operand eq $right_operand;
        } elsif ($operator eq 'NEQ') {
            return $left_operand != $right_operand;
        } elsif ($operator eq 'LSS') {
            return $left_operand < $right_operand;
        } elsif ($operator eq 'LEQ') {
            return $left_operand <= $right_operand;
        } elsif ($operator eq 'GTR') {
            return $left_operand > $right_operand;
        } elsif ($operator eq 'GEQ') {
            return $left_operand >= $right_operand;
        }
        
        else {
            die "Operator: $operator not implemented";
        }

    }else{
        die "Condition type $type not implemented";
    }
    return 0;
}

sub _variable_substitution {
    my $self   = shift();
    my $string  = shift();
    my $context = shift();

    if ( !defined $context ) {
        Carp::cluck "Please provide a context for variable substitution";
    }

    my $parameters = $context->{'PARAMETERS'};
    if ( defined $parameters && scalar keys %$parameters > 0 ) {

        my $handle_parameter_sustitution = sub {
            my $parameter_name = shift();
            if ( exists $parameters->{$parameter_name} ) {
                return $parameters->{$parameter_name};
            } else {
                Carp::cluck "Parameter not defined: $parameter_name";
                return '';
            }
        };
        $string =~ s/%%([A-Za-z])/$handle_parameter_sustitution->($1)/eg;
    }

    my $handle_variable_manipulations = sub {
        my $variable_name = shift();
        my $manipulation  = shift();

        if ( defined $variable_name && $variable_name ne '' ) {

            my $result = $context->{'ENV'}{$1};
            if ( defined $result ) {
                if ( defined $manipulation && $manipulation ne '' ) {
                    $manipulation =~ s/^://;
                    if ( $manipulation =~ /~(?<from>\d+),(?<length>\d+)/ ) {
                        $result = substr( $result, $+{'from'}, $+{'length'} );
                    } elsif ( $manipulation =~ /\~(\-\d)+/ ) {
                        $result = substr( $result, $1 );
                    }
                }
                return $result;
            } else {
                print "Variable: $variable_name not defined\n";
            }
            return '';
        } else {
            return '%%';
        }
    };

    $string =~ s/%([\w\#\$\'\(\)\*\+\,\-\.\?\@\[\]\`\{\}\~]*?)(:.+?)?%/$handle_variable_manipulations->($1, $2)/eg;

    $string =~ s/%%/%/g;

    return $string;
}

sub _adjust_path {
    my $self   = shift();
    my $path = shift();
    if (!($^O =~ 'Win')) {
        $path =~ s/\\/\//g;
    }
    return $path;
}

sub _execute_command {
    my $self   = shift();
    $self->executor->execute_command(@_);
}

sub _goto_label {
    my $self   = shift();
    my $label   = shift();
    my $context = shift();
    $label =~ s/^://;
    $label =~ s/ //g;
    if ( $context->{'LABEL_INDEX'}{$label} ) {
        $context->{'IP'} = $context->{'LABEL_INDEX'}{$label};

        #print "Goto: " . $context->{'IP'} . " via $label\n";
    } else {
        die "Label: $label not indexed. Index contains: " . Dumper( $context->{'LABEL_INDEX'} );
    }
}

sub _for_command_evaluation {
    my $self   = shift();
    my $comando = shift();
    return $self->executor->execute_for_command($comando);
}

1;

__END__

=head1 BUGS

Please report any bugs or feature requests via github: L<https://github.com/pablrod/p5-Bat-Interpreter/issues>

