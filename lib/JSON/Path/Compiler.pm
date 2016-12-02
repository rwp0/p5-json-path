package JSON::Path::Compiler;

use strict;
use warnings;
use 5.008;

use Carp;
use Carp::Assert qw(assert);
use JSON::MaybeXS;
use JSON::Path::Constants qw(:operators);
use JSON::Path::Tokenizer qw(tokenize);
use Readonly;
use Scalar::Util qw/looks_like_number blessed/;
use Storable qw/dclone/;
use Sys::Hostname qw/hostname/;
use Try::Tiny;
our $AUTHORITY = 'cpan:POPEFELIX';
our $VERSION   = '1.00';

Readonly my $OPERATOR_IS_TRUE => 'IS_TRUE';

my $ASSERT_ENABLE =
    defined $ENV{ASSERT_ENABLE} ? $ENV{ASSERT_ENABLE} : hostname =~ /^lls.+?[.]cb[.]careerbuilder[.]com/;

sub _new {
    my $class = shift;
    my %args  = ref $_[0] eq 'HASH' ? %{ $_[0] } : @_;
    my $self  = {};
    $self->{root} = $args{root};
    bless $self, $class;
    return $self;
}

# JSONPath              Function
# $                     the root object/element
# @                     the current object/element
# . or []               child operator
# ..                    recursive descent. JSONPath borrows this syntax from E4X.
# *                     wildcard. All objects/elements regardless their names.
# []                    subscript operator. XPath uses it to iterate over element collections and for predicates. In Javascript and JSON it is the native array operator.
# [,]                   Union operator in XPath results in a combination of node sets. JSONPath allows alternate names or array indices as a set.
# [start:end:step]      array slice operator borrowed from ES4.
# ?()                   applies a filter (script) expression.
# ()                    script expression, using the underlying script engine.
#
# With JSONPath square brackets operate on the object or array addressed by the previous path fragment. Indices always start by 0.

my $OPERATOR_TYPE_PATH       = 1;
my $OPERATOR_TYPE_COMPARISON = 2;
Readonly my %OPERATORS => (
    $TOKEN_ROOT                => $OPERATOR_TYPE_PATH,          # $
    $TOKEN_CURRENT             => $OPERATOR_TYPE_PATH,          # @
    $TOKEN_CHILD               => $OPERATOR_TYPE_PATH,          # . OR []
    $TOKEN_RECURSIVE           => $OPERATOR_TYPE_PATH,          # ..
    $TOKEN_ALL                 => $OPERATOR_TYPE_PATH,          # *
    $TOKEN_FILTER_OPEN         => $OPERATOR_TYPE_PATH,          # ?(
    $TOKEN_SCRIPT_OPEN         => $OPERATOR_TYPE_PATH,          # (
    $TOKEN_FILTER_SCRIPT_CLOSE => $OPERATOR_TYPE_PATH,          # )
    $TOKEN_SUBSCRIPT_OPEN      => $OPERATOR_TYPE_PATH,          # [
    $TOKEN_SUBSCRIPT_CLOSE     => $OPERATOR_TYPE_PATH,          # ]
    $TOKEN_UNION               => $OPERATOR_TYPE_PATH,          # ,
    $TOKEN_ARRAY_SLICE         => $OPERATOR_TYPE_PATH,          # [ start:end:step ]
    $TOKEN_SINGLE_EQUAL        => $OPERATOR_TYPE_COMPARISON,    # =
    $TOKEN_DOUBLE_EQUAL        => $OPERATOR_TYPE_COMPARISON,    # ==
    $TOKEN_TRIPLE_EQUAL        => $OPERATOR_TYPE_COMPARISON,    # ===
    $TOKEN_GREATER_THAN        => $OPERATOR_TYPE_COMPARISON,    # >
    $TOKEN_LESS_THAN           => $OPERATOR_TYPE_COMPARISON,    # <
    $TOKEN_NOT_EQUAL           => $OPERATOR_TYPE_COMPARISON,    # !=
    $TOKEN_GREATER_EQUAL       => $OPERATOR_TYPE_COMPARISON,    # >=
    $TOKEN_LESS_EQUAL          => $OPERATOR_TYPE_COMPARISON,    # <=
);


# EXPRESSION                                    TOKENS
# $.[*].id                                      $ . [ * ] . id
# $.[0].title                                   $ . [ 0 ] . title
# $.[*].user[?(@.login == 'laurilehmijoki')]    $ . [ * ] . user [ ? ( @ . login =='laurilehmijoki' ) ]
# $..labels[?(@.name==bug)]                     $ .. labels [ ? ( @ . name ==bug ) ]
# $.addresses[?(@.addresstype.id == D84002)]    $ . addresses [ ? ( @ . addresstype . id ==D84002 ) ]
# $.store.book[(@.length-1)].title              $ . store . book [ ( @ . length -1 ) ] . title
# $.store.book[?(@.price < 10)].title           $ . store . book [ ? ( @ . price <10 ) ] . title
#
# $['store']['book'][0]['author']
# $['store']['book'][1]['author']
# $['store']['book'][2]['author']
# $['store']['book'][3]['author']
#

sub _hashlike {
    my $object = shift;
    return ( ref $object eq 'HASH' || ( blessed $object && $object->can('typeof') && $object->typeof eq 'HASH' ) );
}

sub _arraylike {
    my $object = shift;
    return ( ref $object eq 'ARRAY' || ( blessed $object && $object->can('typeof') && $object->typeof eq 'ARRAY' ) );
}

sub evaluate {
    my ( $json_object, $expression, $want_ref ) = @_;

    if (!ref $json_object) { 
        try { 
            $json_object = decode_json($json_object);
        }
        catch { 
            croak qq{Unable to decode $json_object as JSON: $_};
        }
    }

    my $self = __PACKAGE__->_new( root => $json_object );
    return $self->_evaluate( $json_object, [ tokenize($expression) ], $want_ref );
}

sub _evaluate {    # This assumes that the token stream is syntactically valid
    my ( $self, $obj, $token_stream, $want_ref ) = @_;

    $token_stream ||= [];

    if ( !@{$token_stream} ) {
        if ( !ref $obj ) {
            return $want_ref ? \$obj : $obj;
        }
        else {
            return $want_ref ? $obj : dclone($obj);
        }
    }

    while ( defined( my $token = get_token($token_stream) ) ) {
        next                                       if $token eq $TOKEN_CURRENT;
        next                                       if $token eq $TOKEN_CHILD;
        assert( $token ne $TOKEN_SUBSCRIPT_OPEN )  if $ASSERT_ENABLE;
        assert( $token ne $TOKEN_SUBSCRIPT_CLOSE ) if $ASSERT_ENABLE;
        if ( $token eq $TOKEN_ROOT ) {
            return $self->_evaluate( $self->{root}, $token_stream, $want_ref );
        }
        elsif ( $token eq $TOKEN_FILTER_OPEN ) {
            my @sub_stream;

            # Build a stream of just the tokens between the filter open and close
            while ( defined( my $token = get_token($token_stream) ) ) {
                last if $token eq $TOKEN_FILTER_SCRIPT_CLOSE;
                if ( $token eq $TOKEN_CURRENT ) {
                    push @sub_stream, $token, $TOKEN_CHILD, $TOKEN_ALL;
                }
                else {
                    push @sub_stream, $token;
                }
            }

            
            # Treat as @.foo IS TRUE
            my $rhs = pop @sub_stream;
            my $operator = pop @sub_stream;

            # This assumes that RHS is only a single token. I think that's a safe assumption.
            if ($OPERATORS{$operator} eq $OPERATOR_TYPE_COMPARISON) { 
                $rhs = normalize($rhs);
            }
            else { 
                push @sub_stream, $operator, $rhs;
                $operator = $OPERATOR_IS_TRUE;
            }

            # Evaluate the left hand side of the comparison first. NOTE: We DO NOT want to set $want_ref here.
            my @lhs = $self->_evaluate( $obj, [@sub_stream] );

            # FIXME: What if $obj is not an array?

            # get indexes that pass compare()
            my @matching = grep { compare( $operator, $lhs[$_], $rhs ) } ( 0 .. $#lhs );

            # Evaluate the token stream on all elements that pass the comparison in compare()
            my @ret = map { $self->_evaluate( $obj->[$_], dclone($token_stream), $want_ref ) } @matching;
            return @ret;
        }
        elsif ( $token eq $TOKEN_RECURSIVE ) {
            my $index = get_token($token_stream);
            my @ret = map { $self->_evaluate( $_, dclone($token_stream), $want_ref ) }
                _match_recursive( $obj, $index, $want_ref );
            return @ret;
        }
        else {
            my $index = normalize($token);
            
            assert( !$OPERATORS{$index}, qq{"$index" is not an operator} ) if $index ne $TOKEN_ALL;
            assert( ref $index eq 'HASH', q{Index is a hashref} ) if $ASSERT_ENABLE && ref $index;

            if ( _arraylike($obj) ) {
                if ( ref $index && $index->{slice} ) { 
                    return map { $self->_evaluate( $_, dclone($token_stream), $want_ref ) } _slice($obj, $index->{slice});
                }
                elsif ( ref $index && $index->{union} ) { 
                    my @union = @{$index->{union}};
                    return map { $self->_evaluate( $_, dclone($token_stream), $want_ref ) } @{$obj}[@union];
                }
                elsif ( $index eq $TOKEN_ALL ) {
                    return map { $self->_evaluate( $obj->[$_], dclone($token_stream), $want_ref ) } ( 0 .. $#{$obj} );
                }
                else {
                    return unless looks_like_number($index);
                    
                    # If we have found a scalar at the end of the path but we want a ref, pass a reference to
                    # that scalar.
                    my $evaluand = ( $want_ref && !ref $obj->[$index] ) ? \( $obj->[$index] ) : $obj->[$index];
                    
                    return $self->_evaluate( $evaluand, $token_stream, $want_ref );
                }
            }
            else {
                assert( _hashlike($obj) ) if $ASSERT_ENABLE;
                croak q{Slices are not supported on hash-like objects} if ref $index && $index->{slice};

                if (ref $index && $index->{union}) {
                    my @union = @{$index->{union}};
                    return map { $self->_evaluate( $_, dclone($token_stream), $want_ref ) } @{$obj}{@union};
                }
                elsif ( $index eq $TOKEN_ALL ) {
                    return map { $self->_evaluate( $_, dclone($token_stream), $want_ref ) } values %{$obj};
                }
                else {
                    return unless exists $obj->{$index};

                    # If we have found a scalar at the end of the path but we want a ref, pass a reference to
                    # that scalar.
                    my $evaluand = ( $want_ref && !ref $obj->{$index} ) ? \( $obj->{$index} ) : $obj->{$index};

                    return $self->_evaluate( $evaluand, $token_stream, $want_ref );
                }
            }
        }
    }
    1;
}

sub get_token {
    my $token_stream = shift;
    my $token        = shift @{$token_stream};
    return unless defined $token;

    if ( $token eq $TOKEN_SUBSCRIPT_OPEN ) {
        my @substream;
        my $close_seen;
        while (defined( my $token = shift @{$token_stream})) {
            if ($token eq $TOKEN_SUBSCRIPT_CLOSE) {
                $close_seen = 1;
                last;
            }
            push @substream, $token;
        }

        assert( $close_seen ) if $ASSERT_ENABLE;

        if ( grep { $_ eq $TOKEN_ARRAY_SLICE } @substream ) {
            # There are five valid cases:
            #
            # n:m   -> n:m:1
            # n:m:s -> n:m:s
            # :m    -> 0:m:1
            # ::s   -> 0:-1:s
            # n:    -> n:-1:1
            if ( $substream[0] eq $TOKEN_ARRAY_SLICE ) {
                unshift @substream, undef;
            }

            no warnings qw/uninitialized/;
            if ( $substream[2] eq $TOKEN_ARRAY_SLICE ) {
                @substream = ( @substream[ ( 0, 1 ) ], undef, @substream[ ( 2 .. $#substream ) ] );
            }
            use warnings qw/uninitialized/;

            my ( $start, $end, $step );
            $start = $substream[0] // 0;
            $end   = $substream[2] // -1;
            $step  = $substream[4] // 1;
            return { slice => [ $start, $end, $step ] };
        }
        elsif ( grep { $_ eq $TOKEN_UNION } @substream ) { 
            my @union = grep { $_ ne $TOKEN_UNION } @substream;
            return { union => \@union };
        }

        return $substream[0];
    }
    return $token;
}

sub _slice {
    my ( $array, $spec ) = @_;
    my ( $start, $end, $step ) = @{$spec};
    $start = $#{$array} if $start == -1;
    $end = $#{$array} if $end == -1;
    my @indices;
    if ($step < 0) { 
        @indices = grep { %_ % -$step == 0 } reverse ( $start .. $end );
    } 
    else { 
        @indices = grep { $_ % $step == 0 } ( $start .. $end );
    }

    return @{$array}[@indices];
}

sub _match_recursive {
    my ( $obj, $index, $want_ref ) = @_;
    my @match;
    if ( _arraylike($obj) ) {
        for ( 0 .. $#{$obj} ) {
            push @match, $want_ref ? \( $obj->[$_] ) : $obj->[$_] if $_ eq $index;
            push @match, _match_recursive( $obj->[$_], $index, $want_ref );
        }
    }
    elsif ( _hashlike($obj) ) {
        push @match, $want_ref ? \( $obj->{$index} ) : $obj->{$index} if exists $obj->{$index};
        push @match, _match_recursive( $_, $index, $want_ref ) for values %{$obj};
    }
    return @match;
}

sub normalize {
    my $string = shift;

    # NB: Stripping spaces *before* stripping quotes allows the caller to quote spaces in an index.
    # So an index of 'foo ' will be correctly normalized as 'foo', but '"foo "' will normalize to 'foo '.
    $string =~ s/\s+$//;                # trim trailing spaces
    $string =~ s/^\s+//;                # trim leading spaces
    $string =~ s/^['"](.+)['"]$/$1/;    # Strip quotes from index
    return $string;
}

sub compare {
    my ( $operator, $lhs, $rhs ) = @_;

    if ($operator eq $OPERATOR_IS_TRUE) { 
        return $lhs ? 1 : 0;
    }

    my $use_numeric = looks_like_number($lhs) && looks_like_number($rhs);

    if ( $operator eq '=' || $operator eq '==' || $operator eq '===' ) {
        return $use_numeric ? ( $lhs == $rhs ) : $lhs eq $rhs;
    }
    if ( $operator eq '<' ) {
        return $use_numeric ? ( $lhs < $rhs ) : $lhs lt $rhs;
    }
    if ( $operator eq '>' ) {
        return $use_numeric ? ( $lhs > $rhs ) : $lhs gt $rhs;
    }
    if ( $operator eq '<=' ) {
        return $use_numeric ? ( $lhs <= $rhs ) : $lhs le $rhs;
    }
    if ( $operator eq '>=' ) {
        return $use_numeric ? ( $lhs >= $rhs ) : $lhs ge $rhs;
    }
    if ( $operator eq '!=' || $operator eq '!==' ) {
        return $use_numeric ? ( $lhs != $rhs ) : $lhs ne $rhs;
    }
}
1;
__END__
