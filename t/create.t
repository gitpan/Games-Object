# -*- perl -*-

# Basic object creation tests

use strict;
use Test;

BEGIN { $| = 1; plan tests => 10 }

use Games::Object qw(Find);

# Basic object creation with specific IDs
my $obj1 = Games::Object->new(-id => "ThisObject");
ok( defined($obj1) );
my $obj2 = Games::Object->new(-id => "ThatObject");
ok( defined($obj2) );
ok( $obj1->id() eq 'ThisObject' && $obj2->id() eq 'ThatObject' );

# The Find() function
my $find1 = Find('ThisObject');
ok( defined($find1) && ref($find1) eq 'Games::Object'
	&& $find1->id() eq 'ThisObject' );
my $find2 = Find('ThatObject');
ok( defined($find2) && ref($find2) eq 'Games::Object'
	&& $find2->id() eq 'ThatObject' );
ok ( !Find('BogusObject') );

# Basic object creation with derived IDs.
my $obj3 = Games::Object->new();
ok( defined($obj3) );
my $obj4 = Games::Object->new();
ok( defined($obj4) );
ok( $obj3->id() ne $obj4->id() );

# Error check: Duplicate IDs.
my $obj5;
eval('$obj5 = Games::Object->new(-id => "ThatObject")');
ok ( !defined($obj5) && $@ =~ /duplicate/i );

exit (0);
