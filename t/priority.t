# -*- perl -*-

# Priority processing.

use strict;
use Test;
use Games::Object qw(Process);
use File::Basename;

BEGIN { $| = 1; plan tests => 8 }

# Create a module to use for subclassing.
my $pdir = dirname($0);
unshift @INC, $pdir;
my $subpfile = "$pdir/GOTestModuleSubclass.pm";
open PKG, ">$subpfile" or die "Unable to open file $subpfile\n";
print PKG '
package GOTestModuleSubclass;

use strict;
use Exporter;
use Games::Object;
use vars qw(@ISA @EXPORT @RESULTS);

@ISA = qw(Games::Object Exporter);
@EXPORT = qw(@RESULTS);

@RESULTS = ();

sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $obj = Games::Object->new(@_);

	bless $obj, $class;
	$obj;
}

# arbitrary action method to be queued.

sub action
{
	my $obj = shift;
	my %args = @_;
	push @RESULTS, $args{foo};
}

# Basic attribute modify event to test pmod and tend_to priorities

sub modifier_event
{
	my $obj = shift;
	my %args = @_;
	push @RESULTS, $args{key};
	1;
}

1;
';
close PKG;

# Create two objects and give them different priorities.
require GOTestModuleSubclass;
my $subobj1 = GOTestModuleSubclass->new(-id => "SubclassTestObject1");
ok( $subobj1 && ref($subobj1) eq 'GOTestModuleSubclass' );
my $subobj2 = GOTestModuleSubclass->new(-id => "SubclassTestObject2");
ok( $subobj2 && ref($subobj2) eq 'GOTestModuleSubclass' );
$subobj1->priority(1);
$subobj2->priority(2);

# Queue up actions for each in reverse order of priorities.
$subobj1->queue('action', foo => 'bar');
$subobj2->queue('action', foo => 'baz');

# Process all objects
Process();

# Check that the actions were performed in the right order.
ok( $GOTestModuleSubclass::RESULTS[0] eq 'baz'
 && $GOTestModuleSubclass::RESULTS[1] eq 'bar' );

# Clear the results array, change priorities, and try again.
@GOTestModuleSubclass::RESULTS = ();
$subobj1->priority(10);
$subobj1->queue('action', foo => 'bar');
$subobj2->queue('action', foo => 'baz');
Process();
ok( $GOTestModuleSubclass::RESULTS[0] eq 'bar'
 && $GOTestModuleSubclass::RESULTS[1] eq 'baz' );

# Now to test tend-to priorities. First set things up by adding some event
# bindings and attributes.
Games::Object->bind_event('attrValueModified', 'modifier_event');
$subobj1->new_attr(
    -name => "obj1attr1",
    -type => 'int',
    -value => 50,
    -real_value => 100,
    -tend_to_rate => 1,
    -priority => 2,
);
$subobj1->new_attr(
    -name => "obj1attr2",
    -type => 'int',
    -value => 50,
    -real_value => 100,
    -tend_to_rate => 1,
    -priority => 4,
);
$subobj2->new_attr(
    -name => "obj2attr1",
    -type => 'int',
    -value => 50,
    -real_value => 100,
    -tend_to_rate => 1,
    -priority => 3,
);
$subobj2->new_attr(
    -name => "obj2attr2",
    -type => 'int',
    -value => 50,
    -real_value => 100,
    -tend_to_rate => 1,
    -priority => 1,
);

# Process these and check the results by seeing what order the attributes
# were updated, which we can check by seeing what order the events were
# triggered.
@GOTestModuleSubclass::RESULTS = ();
Process();
ok( $GOTestModuleSubclass::RESULTS[0] eq 'obj1attr2'
 && $GOTestModuleSubclass::RESULTS[1] eq 'obj1attr1'
 && $GOTestModuleSubclass::RESULTS[2] eq 'obj2attr1'
 && $GOTestModuleSubclass::RESULTS[3] eq 'obj2attr2' );

# Change the priority of the objects themselves. This should only affect
# the order of the objects, not the tend-tos within the objects.
@GOTestModuleSubclass::RESULTS = ();
$subobj1->priority(5);
$subobj2->priority(7);
Process();
ok( $GOTestModuleSubclass::RESULTS[0] eq 'obj2attr1'
 && $GOTestModuleSubclass::RESULTS[1] eq 'obj2attr2'
 && $GOTestModuleSubclass::RESULTS[2] eq 'obj1attr2'
 && $GOTestModuleSubclass::RESULTS[3] eq 'obj1attr1' );

# Now switch the priorities of the attributes in the second object and
# see that it works.
@GOTestModuleSubclass::RESULTS = ();
$subobj2->mod_attr(-name => 'obj2attr2', -priority => 10);
Process();
ok( $GOTestModuleSubclass::RESULTS[0] eq 'obj2attr2'
 && $GOTestModuleSubclass::RESULTS[1] eq 'obj2attr1'
 && $GOTestModuleSubclass::RESULTS[2] eq 'obj1attr2'
 && $GOTestModuleSubclass::RESULTS[3] eq 'obj1attr1' );

# Add a third attribute to the first object with a priority that is in the
# middle of the existing ones and try that.
$subobj1->new_attr(
    -name => "obj1attr3",
    -type => 'int',
    -value => 50,
    -real_value => 100,
    -tend_to_rate => 1,
    -priority => 3,
);
@GOTestModuleSubclass::RESULTS = ();
Process();
ok( $GOTestModuleSubclass::RESULTS[0] eq 'obj2attr2'
 && $GOTestModuleSubclass::RESULTS[1] eq 'obj2attr1'
 && $GOTestModuleSubclass::RESULTS[2] eq 'obj1attr2'
 && $GOTestModuleSubclass::RESULTS[3] eq 'obj1attr3'
 && $GOTestModuleSubclass::RESULTS[4] eq 'obj1attr1' );

unlink $subpfile;

exit (0);
