# -*- perl -*-

# Basic attribute creation, modification, and retrieval tests

use strict;
use Test;

BEGIN { $| = 1; plan tests => 50 }

use Games::Object;

# Create object to use.
my $obj = Games::Object->new();
ok( defined($obj) );

# Integers
eval('$obj->new_attr(
	-name	=> "AnInteger",
	-type	=> "int",
	-value	=> 10,
)');
ok ( $@ eq '' );
ok ( $obj->attr('AnInteger') == 10 );
eval('$obj->mod_attr(
	-name	=> "AnInteger",
	-value	=> 12,
)');
ok ( $obj->attr('AnInteger') == 12 );
eval('$obj->mod_attr(
	-name	=> "AnInteger",
	-modify	=> -4,
)');
ok ( $obj->attr('AnInteger') == 8 );

# Fractional-handling with integers
eval('$obj->new_attr(
	-name	=> "AnIntegerFractional",
	-type	=> "int",
	-value	=> 10.56,
	-track_fractional => 1,
)');
ok ( $@ eq '' );
ok ( $obj->attr('AnIntegerFractional') == 10 );
ok ( $obj->raw_attr('AnIntegerFractional') == 10.56 );
ok ( $obj->attr('AnInteger') == 8 );
eval('$obj->mod_attr(
	-name	=> "AnIntegerFractional",
	-modify	=> 0.43,
)');
ok ( $obj->attr('AnIntegerFractional') == 10 );
ok ( $obj->raw_attr('AnIntegerFractional') == 10.99 );
eval('$obj->mod_attr(
	-name	=> "AnIntegerFractional",
	-modify	=> 0.02,
)');
ok ( $obj->attr('AnIntegerFractional') == 11 );
ok ( $obj->raw_attr('AnIntegerFractional') == 11.01 );
eval('$obj->new_attr(
	-name	=> "AnIntegerFractional2",
	-type	=> "int",
	-value	=> 10.56,
	-track_fractional => 1,
	-on_fractional => "ceil",
)');
ok ( $@ eq '' );
ok ( $obj->attr('AnIntegerFractional2') == 11 );
ok ( $obj->raw_attr('AnIntegerFractional2') == 10.56 );
eval('$obj->mod_attr(
	-name	=> "AnIntegerFractional2",
	-modify	=> -0.07,
)');
ok ( $obj->attr('AnIntegerFractional2') == 11 );
ok ( $obj->raw_attr('AnIntegerFractional2') == 10.49 );

# Numbers
eval('$obj->new_attr(
	-name	=> "ANumber",
	-type	=> "number",
	-value	=> 25.67,
)');
ok ( $@ eq '' );
ok ( $obj->attr("ANumber") == 25.67 );

# Strings
eval('$obj->new_attr(
	-name	=> "AString",
	-type	=> "string",
	-value	=> "How now brown cow?",
)');
ok ( $@ eq '' );
ok ( $obj->attr('AString') eq 'How now brown cow?' );

# Picklists
eval('$obj->new_attr(
	-name	=> "APicklist",
	-type	=> "string",
	-value	=> "the_other",
	-values  => [ "this", "that", "the_other", "something_or_other" ],
)');
ok ( $@ eq '' );
ok ( $obj->attr('APicklist') eq 'the_other' );

# Picklists with mapping
eval('$obj->new_attr(
	-name	=> "APicklistWithMapping",
	-type	=> "string",
	-value	=> "that",
	-values  => [ "this", "that", "the_other", "something_or_other" ],
	-map	=> {
	    this	=> "This one right here.",
	    that	=> "That one over there.",
	    the_other	=> "The other one way over there.",
	},
)');
ok ( $@ eq '' );
ok ( $obj->attr('APicklistWithMapping') eq 'That one over there.' );
ok ( $obj->raw_attr('APicklistWithMapping') eq 'that' );

# Split-value numbers
eval('$obj->new_attr(
	-name	=> "ASplitNumber",
	-type	=> "number",
	-value	=> 25.67,
	-tend_to_rate	=> 1,
	-real_value => 100.0,
)');
ok ( $@ eq '' );
ok ( $obj->attr("ASplitNumber") == 25.67 );
ok ( $obj->attr("ASplitNumber", "real_value") == 100.0 );
$obj->process();
ok ( $obj->attr("ASplitNumber") == 26.67 );

# Numbers with limits
eval('$obj->new_attr(
	-name	=> "ALimitedNumber",
	-type	=> "number",
	-value	=> 25.67,
	-minimum	=> 0,
	-maximum	=> 100,
)');
ok ( $@ eq '' );
ok ( $obj->attr("ALimitedNumber") == 25.67 );
eval('$obj->mod_attr(
	-name	=> "ALimitedNumber",
	-modify	=> -0.07,
)');
ok ( $obj->attr("ALimitedNumber") == 25.6 );
eval('$obj->mod_attr(
	-name	=> "ALimitedNumber",
	-modify	=> -30,
)');
ok ( $obj->attr("ALimitedNumber") == 0 );
eval('$obj->mod_attr(
	-name	=> "ALimitedNumber",
	-modify	=> 45.4,
)');
ok ( $obj->attr("ALimitedNumber") == 45.4 );
eval('$obj->mod_attr(
	-name	=> "ALimitedNumber",
	-modify	=> 75,
)');
ok ( $obj->attr("ALimitedNumber") == 100 );
eval('$obj->new_attr(
	-name	=> "AnotherLimitedNumber",
	-type	=> "number",
	-value	=> 25.67,
	-minimum	=> 0,
	-maximum	=> 100,
	-out_of_bounds => "ignore",
)');
ok ( $@ eq '' );
ok ( $obj->attr("AnotherLimitedNumber") == 25.67 );
eval('$obj->mod_attr(
	-name	=> "AnotherLimitedNumber",
	-modify	=> 75,
)');
ok ( $obj->attr("AnotherLimitedNumber") == 25.67 );
eval('$obj->mod_attr(
	-name	=> "AnotherLimitedNumber",
	-modify	=> -75,
)');
ok ( $obj->attr("AnotherLimitedNumber") == 25.67 );

# Object references (a very basic test only; more extensive testing can be found
# in class.t; this just tests storage and badic data conversion ID <-> ref)
my $robj1 = Games::Object->new(-id => "SampleObject1");
my $robj2 = Games::Object->new(-id => "SampleObject2");
my $res;
eval('$obj->new_attr(
	-name	=> "ObjectRef1",
	-type	=> "object",
	-store	=> "ref",
	-value	=> $robj1,
)');
ok( $@ eq '' );
$res = $obj->attr("ObjectRef1");
ok( defined($res) && ref($res) && $res->id() eq 'SampleObject1' );
eval('$obj->mod_attr(
	-name	=> "ObjectRef1",
	-value	=> "SampleObject2",
)');
$res = $obj->attr("ObjectRef1");
ok( defined($res) && ref($res) && $res->id() eq 'SampleObject2' );
eval('$obj->new_attr(
	-name	=> "ObjectRef2",
	-type	=> "object",
	-store	=> "id",
	-value	=> "SampleObject2",
)');
ok( $@ eq '' );
$res = $obj->attr("ObjectRef2");
ok( defined($res) && !ref($res) && $res eq 'SampleObject2' );
eval('$obj->mod_attr(
	-name	=> "ObjectRef2",
	-value	=> $robj1,
)');
$res = $obj->attr("ObjectRef2");
ok( defined($res) && !ref($res) && $res eq 'SampleObject1' );

# Perform some basic attribute existence tests.
ok( !defined($obj->attr("ThisDoesNotExist")) );
ok( !$obj->attr_exists("ThisDoesNotExist") );
ok( $obj->attr_exists("ObjectRef2") );

exit (0);
