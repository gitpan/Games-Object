# -*- perl -*-

# Events

use strict;
use Test;

BEGIN { $| = 1; plan tests => 32 }

# Write a small Perl module that we will use to subclass to Games::Object
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

use Games::Object;

@ISA = qw(Games::Object Exporter);
@EXPORT = qw(@RESULTS);

use vars qw(@RESULTS %RETCODE);

@RESULTS = ();
%RETCODE = ();

sub initialize
{
	@RESULTS = ();
	$RETCODE{event_global} = 1;
	$RETCODE{event_global_mod} = 1;
	$RETCODE{event_global_mod_attr1} = 1;
	$RETCODE{event_global_mod_attr2} = 1;
	$RETCODE{event_global_oob} = 1;
	$RETCODE{event_global_oob_attr1} = 1;
	$RETCODE{event_global_oob_attr2} = 1;
	$RETCODE{event_object} = 1;
	$RETCODE{event_object_mod} = 1;
	$RETCODE{event_object_mod_attr1} = 1;
	$RETCODE{event_object_mod_attr2} = 1;
	$RETCODE{event_object_oob} = 1;
	$RETCODE{event_object_oob_attr1} = 1;
	$RETCODE{event_object_oob_attr2} = 1;
}

# Note that not all of the following event methods may be used in the test,
# but all are defined in case the test needs to be expanded later.

sub event_global {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global};
}

sub event_global_mod {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_mod};
}

sub event_global_mod_attr1 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_mod_attr1};
}

sub event_global_mod_attr2 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_mod_attr2};
}

sub event_global_oob {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_oob};
}

sub event_global_oob_attr1 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_oob_attr1};
}

sub event_global_oob_attr2 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_global_oob_attr2};
}

sub event_object {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object};
}

sub event_object_mod {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_mod};
}

sub event_object_mod_attr1 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_mod_attr1};
}

sub event_object_mod_attr2 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_mod_attr2};
}

sub event_object_oob {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_oob};
}

sub event_object_oob_attr1 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_oob_attr1};
}

sub event_object_oob_attr2 {
	shift;
	my %args = @_;
	push @RESULTS, \%args;
	return $RETCODE{event_object_oob_attr2};
}

sub event_object_load {
	my $obj = shift;
	my %args = @_;
	my $file = $args{file};
	my $line = <$file>;
	chomp $line;
	push @RESULTS, $obj->id() . ": $line";
	1;
}

sub event_object_save {
	my $obj = shift;
	my %args = @_;
	my $number = $obj->attr("number");
	my $tree = $obj->attr("tree");
	my $file = $args{file};
	print $file "And now, number $number, the $tree\n";
	1;
}

sub event_object_destroy {
	my $obj = shift;
	my %args = @_;
	my $nn = $args{nudge_nudge};
	push @RESULTS, $obj->id() . ": $nn";
	1;
}

1;
';
close PKG;

use Games::Object qw(Find Process TotalObjects);
use IO::File;

# Create an object from the subclassed test module.
require GOTestModule;
my $obj = GOTestModule->new();
ok( defined($obj) && $obj->isa('Games::Object') );

# Create two attributes on the object.
$obj->new_attr(
    -name	=> "attr1",
    -type	=> "int",
    -value	=> 50,
    -maximum	=> 100,
);
$obj->new_attr(
    -name	=> "attr2",
    -type	=> "int",
    -value	=> 25,
    -maximum	=> 50,
);

# Modify these attibutes before registering events. No events should be called.
$obj->initialize();
$obj->mod_attr(-name => "attr1", -modify => 15);
$obj->mod_attr(-name => "attr2", -modify => 5);
ok( @GOTestModule::RESULTS == 0 );

# Add generic events for modifying an attribute
eval('$obj->bind_event("attrValueModified", [ "event_object_mod", foo => "bar" ])');
ok ( $@ eq '' );
eval('$obj->bind_event("attrValueAttemptedOutOfBounds", [ "event_object_oob", foo => "baz" ])');
ok ( $@ eq '' );

# Modify attributes again. We should get some events this time.
$obj->initialize();
$obj->mod_attr(-name => "attr1", -modify => 15);
$obj->mod_attr(-name => "attr2", -modify => 5);
ok( @GOTestModule::RESULTS == 2 );
ok( $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[0]{key} eq 'attr1'
 && $GOTestModule::RESULTS[0]{old} == 65
 && $GOTestModule::RESULTS[0]{new} == 80 );
ok( $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{key} eq 'attr2'
 && $GOTestModule::RESULTS[1]{old} == 30
 && $GOTestModule::RESULTS[1]{new} == 35 );

# Bind a global modify event and modify the attributes again. We still should
# get the same two events since all the return codes are 1.
$obj->initialize();
eval('Games::Object->bind_event("attrValueModified", [ "event_global_mod", foo => "fud" ])');
ok( $@ eq '' );
$obj->mod_attr(-name => "attr1", -modify => 15);
$obj->mod_attr(-name => "attr2", -modify => 5);
ok( @GOTestModule::RESULTS == 2 );
ok( $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[0]{key} eq 'attr1'
 && $GOTestModule::RESULTS[0]{old} == 80
 && $GOTestModule::RESULTS[0]{new} == 95 );
ok( $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{key} eq 'attr2'
 && $GOTestModule::RESULTS[1]{old} == 35
 && $GOTestModule::RESULTS[1]{new} == 40 );

# Now set the return code for the specific event to 1, and we should get five
# events (the four modify and one OOB)
$obj->initialize();
$GOTestModule::RETCODE{event_object_mod} = 0;
$obj->mod_attr(-name => "attr1", -modify => 15);
$obj->mod_attr(-name => "attr2", -modify => 5);
ok( @GOTestModule::RESULTS == 5 );
# Hmmm ... the OOB event comes before the modify. Is this what we ultimately
# want?
ok( $GOTestModule::RESULTS[0]{event} eq 'attrValueAttemptedOutOfBounds'
 && $GOTestModule::RESULTS[0]{foo} eq 'baz'
 && $GOTestModule::RESULTS[0]{key} eq 'attr1'
 && $GOTestModule::RESULTS[0]{old} == 95
 && $GOTestModule::RESULTS[0]{new} == 100
 && $GOTestModule::RESULTS[0]{excess} == 10 );
ok( $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{key} eq 'attr1'
 && $GOTestModule::RESULTS[1]{old} == 95
 && $GOTestModule::RESULTS[1]{new} == 100 );
ok( $GOTestModule::RESULTS[2]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[2]{foo} eq 'fud'
 && $GOTestModule::RESULTS[2]{key} eq 'attr1'
 && $GOTestModule::RESULTS[2]{old} == 95
 && $GOTestModule::RESULTS[2]{new} == 100 );
ok( $GOTestModule::RESULTS[3]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[3]{foo} eq 'bar'
 && $GOTestModule::RESULTS[3]{key} eq 'attr2'
 && $GOTestModule::RESULTS[3]{old} == 40
 && $GOTestModule::RESULTS[3]{new} == 45 );
ok( $GOTestModule::RESULTS[4]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[4]{foo} eq 'fud'
 && $GOTestModule::RESULTS[4]{key} eq 'attr2'
 && $GOTestModule::RESULTS[4]{old} == 40
 && $GOTestModule::RESULTS[4]{new} == 45 );

$obj->initialize();
$GOTestModule::RETCODE{event_object_mod} = 0;

# For the final set of tests, we'll check to see if the new load and save
# events work (added v0.03). Clear out all the existing objects and create
# some new ones. Set the save/load events on some of them.
undef $obj;
Process('destroy');
ok( TotalObjects() == 0 );
my $obj1 = GOTestModule->new(-id => 'Object 1');
my $obj2 = GOTestModule->new(-id => 'Object 2');
my $obj3 = GOTestModule->new(-id => 'Object 3');
ok( $obj1 && $obj2 && $obj3 );
$obj1->new_attr(
    -name	=> 'tree',
    -type	=> 'string',
    -value	=> 'larch',
);
$obj1->new_attr(
    -name	=> 'number',
    -type	=> 'int',
    -value	=> 1,
);
$obj2->new_attr(
    -name	=> 'tree',
    -type	=> 'string',
    -value	=> 'oak',
);
$obj2->new_attr(
    -name	=> 'number',
    -type	=> 'int',
    -value	=> 2,
);
$obj3->new_attr(
    -name	=> 'tree',
    -type	=> 'string',
    -value	=> 'horse chestnut',
);
$obj3->new_attr(
    -name	=> 'number',
    -type	=> 'int',
    -value	=> 3,
);
eval('$obj1->bind_event($obj1->id(), "objectSaved", "event_object_save")');
ok( $@ eq '' );
eval('$obj3->bind_event($obj3->id(), "objectSaved", "event_object_save")');
ok( $@ eq '' );
eval('$obj1->bind_event($obj1->id(), "objectLoaded", "event_object_load")');
ok( $@ eq '' );
eval('$obj3->bind_event($obj3->id(), "objectLoaded", "event_object_load")');
ok( $@ eq '' );
eval('$obj1->bind_event($obj1->id(), "objectDestroyed", "event_object_destroy")');
ok( $@ eq '' );
eval('$obj3->bind_event($obj3->id(), "objectDestroyed", "event_object_destroy")');
ok( $@ eq '' );

# Save all objects to a file.
my $file = IO::File->new();
my $filename = "./testobj.save";
$file->open(">$filename") or die "Cannot open file $filename\n";
Process('save', -file => $file);
$file->close();

# Destroy them and load them back. On destroy, insure that the proper events
# we called.
$obj1->initialize();
$obj1->priority(100);
undef $obj1;
undef $obj2;
undef $obj3;
Process('destroy', nudge_nudge => "Say no more");
ok( @GOTestModule::RESULTS == 2
 && $GOTestModule::RESULTS[0] eq 'Object 1: Say no more'
 && $GOTestModule::RESULTS[1] eq 'Object 3: Say no more' );
ok( TotalObjects() == 0 );
GOTestModule->initialize();
$file->open("<$filename") or die "Cannot open $filename for read\n";
while (!$file->eof()) { eval('Games::Object->new(-file => $file)'); }
$file->close();
ok( TotalObjects() >= 3 );

# Check that the events fired.
ok( @GOTestModule::RESULTS == 2 );
ok( $GOTestModule::RESULTS[0] eq "Object 1: And now, number 1, the larch"
 && $GOTestModule::RESULTS[1] eq "Object 3: And now, number 3, the horse chestnut" );

# And that the objects are intact.
$obj1 = Find("Object 1");
$obj2 = Find("Object 2");
$obj3 = Find("Object 3");
ok( $obj1 && $obj2 && $obj3 );
ok( $obj1->attr('number') == 1 && $obj1->attr('tree') eq 'larch'
 && $obj2->attr('number') == 2 && $obj2->attr('tree') eq 'oak'
 && $obj3->attr('number') == 3 && $obj3->attr('tree') eq 'horse chestnut' );

# Cleanup
unlink($filename);
unlink($pfile);

exit (0);
