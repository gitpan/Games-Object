# -*- perl -*-

# Priority processing.

use strict;
use Test;
use Games::Object qw(Process);
use File::Basename;

BEGIN { $| = 1; plan tests => 4 }

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

unlink $subpfile;

exit (0);
