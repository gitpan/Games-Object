# -*- perl -*-

# Load and save capabilities

use strict;
use Test;

BEGIN { $| = 1; plan tests => 42 }

# Write a small Perl module that we will use for load/save of object references
use File::Basename;
my $pdir = dirname($0);
unshift @INC, $pdir;
my $pfile = "$pdir/GOTestModule.pm";
open PKG, ">$pfile" or die "Unable to open file $pfile\n";
print PKG '
package GOTestModule;

use strict;
use Exporter;
use vars qw(@ISA @EXPORT);

@ISA = qw(Exporter);
@EXPORT = qw($RESULT);

my %index = ();

sub new
{
	my $class = shift;
	my $obj = {};
	%$obj = @_;
	$index{$obj->{id}} = $obj;
	bless $obj, $class;
	$obj;
}

sub find_it
{
	shift if @_ > 1;
	my $id = shift;

	$index{id};
}

sub id_it { shift->{id}; }

sub load_me
{
	my $class = shift;
	my %args = @_;
	my $file = $args{file};
	my $obj = {};

	while (my $tag = <$file>) {
	    chomp $tag;
	    last if ($tag eq "ZOT");
	    my $val = <$file>;
	    chomp $val;
	    $obj->{$tag} = $val;
	}
	bless $obj, $class;
}

sub save_me
{
	my $obj = shift;
	my %args = @_;
	my $file = $args{file};

	foreach my $tag (keys %$obj) {
	    print $file "$tag\n$obj->{$tag}\n";
	}
	print $file "ZOT\n";
	1;
}

1;
';
close PKG;

use Games::Object qw(:attrflags RegisterClass TotalObjects);
use IO::File;

# Create an object from the test module for later use.
require GOTestModule;
my $testobj = GOTestModule->new(
    id	=> "ackthhbt",
    foo	=> 'blub',
    bar	=> 'blork',
    zog	=> 'yes, no',
);

# Create an object with some attributes.
my $filename = "./testobj.save";
my $obj1 = Games::Object->new(-id => "SaveObject");
$obj1->new_attr(
    -name	=> "TheAnswer",
    -type	=> "int",
    -value	=> 42,
);
$obj1->new_attr(
    -name	=> "TheQuestion",
    -type	=> "string",
    -value	=> "Unknown, computation did not complete.",
);
$obj1->new_attr(
    -name	=> "HarrysHouse",
    -type	=> 'string',
    -values	=> [qw(Gryffindor Ravenclaw Hufflepuff Slytherin)],
    -value	=> 'Gryffindor',
);
$obj1->new_attr(
    -name	=> "EnterpriseCommander",
    -type	=> 'string',
    -values	=> [qw(Archer Kirk Picard)],
    -map	=> {
	Archer	=> "First starship named Enterprise",
	Kirk	=> "Constitution class vessel",
	Picard	=> "Galaxy class vessel",
    },
    -value	=> 'Kirk',
);
$obj1->new_attr(
    -name	=> "PercentDone",
    -type	=> 'number',
    -value	=> 0,
    -real_value	=> 100,
    -tend_to_rate => 0.5,
);
$obj1->new_attr(
    -name	=> "ComplexData",
    -type	=> 'any',
    -value	=> {
	foo	=> 'bar',
	baz	=> [ 'fud', 'bop' ],
	blork	=> {
	    this	=> 'that',
	    here	=> 'there',
	}
    },
);
$obj1->new_attr(
    -name	=> "DisappearingData",
    -flags	=> ATTR_DONTSAVE,
    -type	=> "string",
    -value	=> "How not to be seen",
);
$obj1->new_attr(
    -name	=> "MagicalData",
    -flags	=> ATTR_AUTOCREATE | ATTR_DONTSAVE,
    -type	=> "string",
    -value	=> "Supercalifragilisticexpialadocious",
);

# Add an object reference. This first attempt should fail, as we have not
# registered the class.
eval('$obj1->new_attr(
    -name	=> "WeirdObject",
    -type	=> "object",
    -class	=> "GOTestModule",
    -store	=> "ref",
    -value	=> $testobj,
)');
ok( $@ =~ /unknown to the data module/ );

# Now register it and try again.
eval('RegisterClass(
    -class	=> "GOTestModule",
    -id		=> "id_it",
    -find	=> "find_it",
    -load	=> "load_me",
    -save	=> "save_me",
)');
ok( $@ eq '' );
eval('$obj1->new_attr(
    -name	=> "WeirdObject",
    -type	=> "object",
    -class	=> "GOTestModule",
    -store	=> "ref",
    -value	=> $testobj,
)');
ok( $@ eq '' );

# Save it to a file.
my $file1 = IO::File->new();
$file1->open(">$filename") or die "Cannot open file $filename\n";
eval('$obj1->save(-file => $file1)');
ok( $@ eq '' );
$file1->close();
my $size = -s $filename;
#print "# $filename is $size bytes\n";
ok( $size != 0 );

# Now reopen this file and try to create a new object from it. First let it
# fail with a duplicate ID error and check that the error is what is
# expected.
my $file2 = IO::File->new();
$file2->open("<$filename") or die "Cannot open file $filename\n";
my $obj2;
eval('$obj2 = Games::Object->new(-file => $file2)');
ok( !defined($obj2) && $@ =~ /already exists/i );

# Then try again but this time set a new ID so it will load.
$file2->seek(0, 0);
eval('$obj2 = Games::Object->new(-file => $file2, -id => "LoadObject")');
ok( defined($obj2) && $obj2->id() eq 'LoadObject');
$file2->close();

# Check that the attributes are the same. The pure DONTSAVE attribute should
# NOT be there, while the DONTSAVE + AUTOCREATE should be there but empty.
ok( $obj2->attr('TheAnswer') == 42 );
ok( $obj2->attr('TheQuestion') eq "Unknown, computation did not complete." );
ok( $obj2->attr('HarrysHouse') eq 'Gryffindor' );
ok( $obj2->attr('EnterpriseCommander') eq 'Constitution class vessel' );
ok( $obj2->raw_attr('EnterpriseCommander') eq 'Kirk' );
ok( $obj2->attr('PercentDone') == 0 );
my $data = $obj2->attr('ComplexData');
ok( $data->{foo} eq 'bar'
 && $data->{baz}[1] eq 'bop'
 && $data->{blork}{this} eq 'that' );
ok( !$obj2->attr_exists('DisappearingData') );
ok( $obj2->attr_exists('MagicalData') && $obj2->attr('MagicalData') eq '' );

# Check that the object reference was loaded and contains the right data.
# We cheat a little here in the interests of testing: we compare stringified
# references (to insure that a new object was indeed created and this is not
# just the old reference) and to check the values of the object's keys.
my $testobj2 = $obj2->attr('WeirdObject');
ok( "$testobj2" ne "$testobj" && ref($testobj2) eq 'GOTestModule' );
ok( $testobj2->{id} eq "ackthhbt"
 && $testobj2->{foo} eq 'blub'
 && $testobj2->{bar} eq 'blork'
 && $testobj2->{zog} eq 'yes, no' );

# Call process() on the first object. Make sure it updated but the new one
# did not, which should prove that they're distinct objects.
$obj2->process();
ok( $obj1->attr('PercentDone') == 0 );
ok( $obj2->attr('PercentDone') == 0.5 );

# Now attempt to load that file by its filename rather than opening the file
# ourselves.
my $obj3;
eval('$obj3 = Games::Object->new(-id => "LoadObject2", -filename =>$filename)');
ok( defined($obj3) && $obj3->id() eq 'LoadObject2' );
ok( $obj3->attr('TheAnswer') == 42 );
ok( $obj3->attr('TheQuestion') eq "Unknown, computation did not complete." );
ok( $obj3->attr('HarrysHouse') eq 'Gryffindor' );
ok( $obj3->attr('EnterpriseCommander') eq 'Constitution class vessel' );
ok( $obj3->raw_attr('EnterpriseCommander') eq 'Kirk' );
ok( $obj3->attr('PercentDone') == 0 );
my $testobj3 = $obj3->attr('WeirdObject');
ok( "$testobj3" ne "$testobj" && ref($testobj3) eq 'GOTestModule' );
ok( $testobj3->{id} eq "ackthhbt"
 && $testobj3->{foo} eq 'blub'
 && $testobj3->{bar} eq 'blork'
 && $testobj3->{zog} eq 'yes, no' );

# Finally, we need to test the ability to load multiple objects from the
# same file. First produce a file containing several objects in it.
unlink $filename;
$filename = "./testobjs.save";
my $file3 = IO::File->new();
$file3->open(">$filename") or die "Cannot open file $filename\n";
my $count = 0;
my @pspecs = (
    [ 'Mercury', 'Mercurial Mugwumps', 1.3 ],
    [ 'Venus', 'Venusian Voles', 2.9 ],
    [ 'Earth', 'Hectic Humans', 1.4 ],
    [ 'Mars', 'Martian Mammals', 12.7 ],
    [ 'Jupiter', 'Jovian Jehosephats', 5.9 ],
    [ 'Saturn', 'Saturine Satyrs', 0.6 ],
    [ 'Uranus', 'Uranian Ugnaughts', 0.9 ],
    [ 'Neptune', 'Neptunian Nymphs', 1.5 ],
    [ 'Pluto', 'Plutonian Plutocrats', 0.00005 ],
);
foreach my $spec (@pspecs) {
	$count++;
	my $obj = Games::Object->new(-id => 'Planet' . $count);
	$obj->new_attr(
	    -name	=> 'Name',
	    -type	=> 'string',
	    -value	=> $spec->[0],
	);
	$obj->new_attr(
	    -name	=> "Lifeform",
	    -type	=> 'string',
	    -value	=> $spec->[1],
	);
	$obj->new_attr(
	    -name	=> "GalacticCreditExchangeRate",
	    -type	=> 'number',
	    -value	=> $spec->[2],
	);
	$obj->save(-file => $file3);
}
$file3->close();
$size = -s $filename;
#print "# $filename is $size bytes\n";

# Now reopen the file and attempt to read them back in, validating as we go.
my $file4 = IO::File->new();
$file4->open("<$filename") or die "Cannot open file $filename\n";
while ($count) {
    my $spec = shift @pspecs;
    my $obj;
    my $pnum = 10 - $count;
    eval('$obj = Games::Object->new(-file =>$file4, -id => "NewPlanet" . $pnum)');
    if ($@) {
	print "# Load of $pnum failed\n";
	last;
    }
    if ($obj->attr('Name') ne $spec->[0]) {
	print "# attr Name is bad in $pnum\n";
	last;
    }
    if ($obj->attr('Lifeform') ne $spec->[1]) {
	print "# attr Lifeform is bad in $pnum\n";
	last;
    }
    if ($obj->attr('GalacticCreditExchangeRate') != $spec->[2]) {
	print "# attr GalacticCreditExchangeRate is bad in $pnum\n";
	last;
    }
    $count --;
}
$file4->close();
ok( $count == 0 );
unlink $filename;
unlink $pfile;

# Now for the final test, we try saving an object that's been subclassed
# and make sure that it gets re-blessed into the subclass on load.

# First, create the module.
my $subpfile = "$pdir/GOTestModuleSubclass.pm";
open PKG, ">$subpfile" or die "Unable to open file $subpfile\n";
print PKG '
package GOTestModuleSubclass;

use strict;
use Exporter;
use Games::Object;
use vars qw(@ISA);

@ISA = qw(Games::Object Exporter);

sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $obj = Games::Object->new(@_);

	bless $obj, $class;
	$obj;
}

# Test method just to make sure it REALLY got re-blessed properly ...

sub answer { 42; }

1;
';
close PKG;

# Now create an object
require GOTestModuleSubclass;
my $subobj = GOTestModuleSubclass->new(-id => "SubclassTestObject");
ok( ref($subobj) eq 'GOTestModuleSubclass' );

# Save it.
my $subfile_out = IO::File->new();
$subfile_out->open(">$filename") or die "Cannot open file $filename\n";
eval('$subobj->save(-file => $subfile_out)');
ok( $@ eq '' );
$subfile_out->close();

# Load it back in
my $subobj2;
eval('$subobj2 = Games::Object->new(
    -id => "SubclassTestObject2",
    -filename => $filename
)');
ok( $@ eq '' );
ok( ref($subobj2) eq 'GOTestModuleSubclass' );
my $ans;
eval('$ans = $subobj2->answer()');
ok( $ans == 42 );

# (Added v0.02) One final part of this test: We need to make sure that
# attributes with references to Games::Object-subclassed objects will save
# and load correctly. First create two objects.
my $refobj1 = GOTestModuleSubclass->new(-id => "RefTestObject1");
my $refobj2 = GOTestModuleSubclass->new(-id => "RefTestObject2");

# Now add attributes that have a reference to each other.
eval('$refobj1->new_attr(
    -name	=> "ObjectRef",
    -type	=> "any",
    -value	=> $refobj2
)');
ok( $@ eq '' );
eval('$refobj2->new_attr(
    -name	=> "ObjectRef",
    -type	=> "any",
    -value	=> $refobj1
)');
ok( $@ eq '' );

# Add some other arbitrary attributes.
$refobj1->new_attr(-name => "ArbitraryAttribute",
		   -type => "int",
		   -value => 1);
$refobj2->new_attr(-name => "ArbitraryAttribute",
		   -type => "int",
		   -value => 2);

# Save the number of objects that are present.
my $ot_before = TotalObjects();

# Save it to a file.
open(REFFILE_OUT, ">$filename") or die "Cannot open file $filename";
eval('$refobj1->save(-file => \*REFFILE_OUT)');
ok( $@ eq '' );
eval('$refobj2->save(-file => \*REFFILE_OUT)');
ok( $@ eq '' );
close(REFFILE_OUT);

# Load them back.
open(REFFILE_IN, "<$filename") or die "Cannot open file $filename";
my ($new_refobj1, $new_refobj2);
eval('$new_refobj1 = Games::Object->new(
	-file => \*REFFILE_IN,
	-id => "NewRefTestObject1")');
ok( $@ eq '' );
eval('$new_refobj2 = Games::Object->new(
	-file => \*REFFILE_IN,
	-id => "NewRefTestObject2")');
ok( $@ eq '' );
close REFFILE_IN;

# Make sure we gained EXACTLY two objects. If this is not the case, then
# the PLACEHOLDER functionality is broken and we're getting duplicate objects.
my $ot_after = TotalObjects();
ok( $ot_after == ($ot_before + 2) );
#print "# objects before = $ot_before objects after = $ot_after\n";

# Done.
unlink $subpfile;
unlink $filename;

exit (0);
