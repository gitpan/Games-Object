# -*- perl -*-

# Basic flag creation and modification tests

use strict;
use Test;

BEGIN { $| = 1; plan test => 28 }

use Games::Object qw(CreateFlag ModifyFlag);

# Create some flags.
eval('CreateFlag(-name => "this")');
ok( $@ eq '' );
eval('CreateFlag(-name => "that")');
ok( $@ eq '' );
eval('CreateFlag(-name => "the_other")');
ok( $@ eq '' );

# Create an object and verify that these flags are NOT set.
my $obj = Games::Object->new();
ok( !$obj->is('this') );
ok( !$obj->is('that') );
ok( !$obj->is('the_other') );
ok( !$obj->maybe('this', 'that', 'the_other') );

# Set two of the three flags on the object (separately).
eval('$obj->set("this")');
ok( $@ eq '' );
eval('$obj->set("that")');
ok( $@ eq '' );

# Check that they are set in a number of ways, and that the third is not.
ok( $obj->is('this') );
ok( $obj->is('that') );
ok( !$obj->is('the_other') );
ok( $obj->is('this', 'that') );
ok( !$obj->is('this', 'that', 'the_other') );
ok( $obj->maybe('this', 'that', 'the_other') );

# Clear a flag and see if that worked.
eval('$obj->clear("this")');
ok( $@ eq '' );
ok( !$obj->is('this') );
ok( $obj->is('that') );
ok( !$obj->is('the_other') );

# Try to set multiple flags.
eval('$obj->set("this", "the_other")');
ok( $@ eq '' );
ok( $obj->is("this", "that", "the_other") );

# Create a new flag with autoset, plus modify an existing one for autoset.
# Then create an object and make sure these (and ONLY these) are set.
eval('CreateFlag(-name => "some_other", -autoset => 1)');
ok( $@ eq '' );
eval('ModifyFlag(-name => "this", -option => "autoset", -value => 1)');
ok( $@ eq '' );
my $obj2 = Games::Object->new();
ok( $obj2->is('this', 'some_other') );
ok( !$obj2->maybe('that', 'the_other') );

# Turn off autoset for one of them and create a third object. See that the
# flag is not set.
eval('ModifyFlag(-name => "some_other", -option => "autoset", -value => 0)');
ok( $@ eq '' );
my $obj3 = Games::Object->new();
ok( $obj3->is('this') );
ok( !$obj3->maybe('that', 'the_other', 'some_other') );
