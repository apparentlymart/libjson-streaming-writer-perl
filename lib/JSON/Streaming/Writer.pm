
package JSON::Streaming::Writer;

use strict;
use warnings;
use IO::File;
use Carp;
use B;

use constant ROOT_STATE => {};

sub for_stream {
    my ($class, $fh) = @_;

    my $self = bless {}, $class;

    $self->{fh} = $fh;
    $self->{state} = ROOT_STATE;
    $self->{state_stack} = [];
    $self->{used} = 0;

    return $self;
}

sub for_file {
    my ($class, $filename) = @_;

    my $fh = IO::File->new($filename, O_WRONLY);
    return $class->for_stream($fh);
}

sub for_stdout {
    my ($class, $filename) = @_;

    return $class->for_stream(\*STDOUT);
}

sub start_object {
    my ($self) = @_;

    Carp::croak("Can't start_object here") unless $self->_can_start_value;

    $self->_make_separator();
    $self->_print("{");
    my $state = $self->_push_state();
    $state->{in_object} = 1;
    return undef;
}

sub end_object {
    my ($self) = @_;

    Carp::croak("Can't end_object here: not in an object") unless $self->_in_object;
    $self->_pop_state();
    $self->_print("}");

    $self->_state->{made_value} = 1 unless $self->_state == ROOT_STATE;
}

sub start_property {
    my ($self, $name) = @_;

    Carp::croak("Can't start_property here") unless $self->_can_start_property;

    $self->_make_separator();
    my $state = $self->_push_state();
    $state->{in_property} = 1;
    $self->_print($self->_json_string($name), ":");
}

sub end_property {
    my ($self) = @_;

    Carp::croak("Can't end_property here: not in a property") unless $self->_in_property;
    Carp::croak("Can't end_property here: haven't generated a value") unless $self->_made_value;

    $self->_pop_state();
    $self->_state->{made_value} = 1;

    # end_property requires no output
}

sub start_array {
    my ($self) = @_;

    Carp::croak("Can't start_array here") unless $self->_can_start_value;

    $self->_make_separator();
    $self->_print("[");
    my $state = $self->_push_state();
    $state->{in_array} = 1;
    return undef;
}

sub end_array {
    my ($self) = @_;

    Carp::croak("Can't end_array here: not in an array") unless $self->_in_array;
    $self->_pop_state();
    $self->_print("]");

    $self->_state->{made_value} = 1 unless $self->_state == ROOT_STATE;
}

sub add_string {
    my ($self, $value) = @_;

    Carp::croak("Can't add_string here") unless $self->_can_start_simple_value;

    $self->_make_separator();
    $self->_print($self->_json_string($value));
    $self->_state->{made_value} = 1;
}

sub add_number {
    my ($self, $value) = @_;

    Carp::croak("Can't add_number here") unless $self->_can_start_simple_value;

    $self->_make_separator();
    $self->_print($value+0);
    $self->_state->{made_value} = 1;
}

sub add_boolean {
    my ($self, $value) = @_;

    Carp::croak("Can't add_boolean here") unless $self->_can_start_simple_value;

    $self->_make_separator();
    $self->_print($value ? 'true' : 'false');
    $self->_state->{made_value} = 1;
}

sub add_null {
    my ($self) = @_;

    Carp::croak("Can't add_null here") unless $self->_can_start_simple_value;

    $self->_make_separator();
    $self->_print('null');
    $self->_state->{made_value} = 1;
}

sub add_value {
    my ($self, $value) = @_;

    my $type = ref($value);

    if (! defined($value)) {
        $self->add_null();
    }
    elsif (! $type) {
        my $b_obj = B::svref_2object(\$value);
        my $flags = $b_obj->FLAGS;

        if (($flags & B::SVf_IOK or $flags & B::SVp_IOK or $flags & B::SVf_NOK or $flags & B::SVp_NOK) and !($flags & B::SVf_POK )) {
            $self->add_number($value);
        }
        else {
            $self->add_string($value);
        }
    }
    elsif ($type eq 'ARRAY') {
        $self->start_array();
        foreach my $item (@$value) {
            $self->add_value($item);
        }
        $self->end_array();
    }
    elsif ($type eq 'HASH') {
        $self->start_object();
        foreach my $k (keys %$value) {
            $self->add_property($k, $value->{$k});
        }
        $self->end_object();
    }
    else {
        Carp::croak("Don't know what to generate for $value");
    }
}

sub add_property {
    my ($self, $key, $value) = @_;

    $self->start_property($key);
    $self->add_value($value);
    $self->end_property();
}

sub _print {
    my ($self, @data) = @_;

    $self->{fh}->print(join('', @data));
}

sub _push_state {
    my ($self) = @_;

    Carp::croak("Can't add anything else: JSON output is complete") if $self->_state == ROOT_STATE && $self->{used};

    $self->{used} = 1;

    push @{$self->{state_stack}}, $self->{state};

    $self->{state} = {
        in_object => 0,
        in_array => 0,
        in_property => 0,
        made_value => 0,
    };

    return $self->{state};
}

sub _pop_state {
    my ($self) = @_;

    my $state = pop @{$self->{state_stack}};
    return $self->{state} = $state;
}

sub _state {
    my ($self) = @_;

    return $self->{state};
}

sub _in_object {
    return $_[0]->_state->{in_object} ? 1 : 0;
}

sub _in_array {
    return $_[0]->_state->{in_array} ? 1 : 0;
}

sub _in_property {
    return $_[0]->_state->{in_property} ? 1 : 0;
}

sub _made_value {
    return $_[0]->_state->{made_value} ? 1 : 0;
}

sub _can_start_value {

    return 0 if $_[0]->_in_property && $_[0]->_made_value;

    return $_[0]->_in_object ? 0 : 1;
}

sub _can_start_simple_value {
    # Can't generate simple values in the root state
    return $_[0]->_can_start_value && $_[0]->_state != ROOT_STATE;
}

sub _can_start_property {
    return $_[0]->_in_object ? 1 : 0;
}

sub _make_separator {
    $_[0]->_print(",") if $_[0]->_made_value;
}

my %esc = (
    "\n" => '\n',
    "\r" => '\r',
    "\t" => '\t',
    "\f" => '\f',
    "\b" => '\b',
    "\"" => '\"',
    "\\" => '\\\\',
    "\'" => '\\\'',
);
sub _json_string {
    my ($class, $value) = @_;

    $value =~ s/([\x22\x5c\n\r\t\f\b])/$esc{$1}/eg;
    $value =~ s/\//\\\//g;
    $value =~ s/([\x00-\x08\x0b\x0e-\x1f])/'\\u00' . unpack('H2', $1)/eg;

    return '"'.$value.'"';
}

sub DESTROY {
    my ($self) = @_;

    if ($self->_state != ROOT_STATE) {
        use Data::Dumper;
        print STDERR Data::Dumper::Dumper($self->_state);
        warn "JSON::Streaming::Writer object was destroyed with incomplete output";
    }
}

1;

=head1 NAME

JSON::Streaming::Writer - Generate JSON output in a streaming manner

=head1 SYNOPSIS

    my $jsonw = JSON::Streaming::Writer->for_stream($fh)
    $jsonw->start_object();
    $jsonw->add_simple_property("someName" => "someValue");
    $jsonw->add_simple_property("someNumber" => 5);
    $jsonw->start_property("someObject");
    $jsonw->start_object();
    $jsonw->add_simple_property("someOtherName" => "someOtherValue");
    $jsonw->add_simple_property("someOtherNumber" => 6);
    $jsonw->end_object();
    $jsonw->end_property();
    $jsonw->start_property("someArray");
    $jsonw->start_array();
    $jsonw->add_simple_item("anotherStringValue");
    $jsonw->add_simple_item(10);
    $jsonw->start_item();
    $jsonw->start_object();
    # No items; this object is empty
    $jsonw->end_object();
    $jsonw->end_item();
    $jsonw->end_array();

=head1 DESCRIPTION

Most JSON libraries work in terms of in-memory data structures. In Perl,
JSON serializers often expect to be provided with a HASH or ARRAY ref
containing all of the data you want to serialize.

This library allows you to generate syntactically-correct JSON without
first assembling your complete data structure in memory. This allows
large structures to be returned without requiring those
structures to be memory-resident, and also allows parts of the output
to be made available to a streaming-capable JSON parser while
the rest of the output is being generated, which may improve
performance of JSON-based network protocols.

=head1 INTERNALS

Internally this library maintains a simple state stack that allows
it to remember where it is without needing to remember the data
it has already generated.

The state stack means that it will use more memory for deeper
data structures.


