# -*- perl -*-

# Processing

# Note that while this has some event processing in it, it is not a full
# test of events. Look at event.t for that.

use strict;
use Test;

BEGIN { $| = 1; plan tests => 43 }

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

use vars qw(@RESULTS);

@RESULTS = ();

sub mod_event {
    shift;
    my %args = @_;
    $args{method} = "mod_event";
    push @RESULTS, \%args;
    1;
}

sub mod_real_event {
    shift;
    my %args = @_;
    $args{method} = "mod_real_event";
    push @RESULTS, \%args;
    1;
}

sub mod_oob {
    shift;
    my %args = @_;
    $args{method} = "mod_oob";
    push @RESULTS, \%args;
    1;
}

1;
';
close PKG;

use Games::Object;
use IO::File;

# Create an object from the subclassed test module.
require GOTestModule;
my $obj = GOTestModule->new();
ok( defined($obj) && $obj->isa('Games::Object') );

# Register some event handlers.
eval('$obj->bind_event("attrValueModified", [ "mod_event", foo => "bar" ])');
ok( $@ eq '' );
eval('$obj->bind_event("attrRealValueModified", [ "mod_real_event", foo => "blork" ])');
ok( $@ eq '' );
eval('$obj->bind_event("attrValueAttemptedOutOfBounds", [ "mod_event", foo => "borf" ])');
ok( $@ eq '' );
eval('$obj->bind_event("attrValueOutOfBounds", [ "mod_event", foo => "blub" ])');
ok( $@ eq '' );

# Define an attribute.
eval('$obj->new_attr(
    -name	=> "SomeNumber",
    -type	=> "number",
    -value	=> 50,
    -real_value	=> 100,
    -minimum	=> 0,
    -maximum	=> 100,
    -tend_to_rate=> 1,
    -priority	=> 2,
)');
ok( $@ eq '' );

# Define a second attribute
eval('$obj->new_attr(
    -name	=> "SomeOtherNumber",
    -type	=> "number",
    -value	=> 70,
    -real_value	=> 150,
    -minimum	=> 0,
    -maximum	=> 150,
    -tend_to_rate=> 2,
    -priority	=> 1,
)');
ok( $@ eq '' );

# Process it. Insure that we see in the event that the attribute was modified.
$obj->process();
ok( $obj->attr('SomeNumber') == 51 );
ok( $obj->attr('SomeOtherNumber') == 72 );
ok( @GOTestModule::RESULTS == 2
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 50
 && $GOTestModule::RESULTS[0]{new} == 51
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{key} eq 'SomeOtherNumber'
 && $GOTestModule::RESULTS[1]{old} == 70
 && $GOTestModule::RESULTS[1]{new} == 72
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Add a persisent static modifier to SomeNumber. Do the same for
# SomeOtherNumber, but force it to take effect now.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -modify	=> 10,
    -persist_as	=> "StaticModifier",
)');
eval('$obj->mod_attr(
    -name	=> "SomeOtherNumber",
    -modify	=> 5,
    -persist_as	=> "StaticModifierDoNow",
    -apply_now	=> 1,
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber') == 51 );
ok( $obj->attr('SomeOtherNumber') == 77 );
# And the modification for SomeOtherNumber should already have triggered
# a modify event already.
ok( @GOTestModule::RESULTS == 1
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{key} eq 'SomeOtherNumber'
 && $GOTestModule::RESULTS[0]{old} == 72
 && $GOTestModule::RESULTS[0]{new} == 77
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar' );
# Clear the events results and process object. For SomeNumber, we should
# see both the tend-to modify and the pmod. For SomeOtherNumber, we should
# see ONLY the former.
@GOTestModule::RESULTS = ();
$obj->process();
ok( $obj->attr('SomeNumber') == 62 );
ok( $obj->attr('SomeOtherNumber') == 79 );
ok( @GOTestModule::RESULTS == 3
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 51
 && $GOTestModule::RESULTS[0]{new} == 61
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[1]{old} == 61
 && $GOTestModule::RESULTS[1]{new} == 62
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar'
 && $GOTestModule::RESULTS[2]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[2]{key} eq 'SomeOtherNumber'
 && $GOTestModule::RESULTS[2]{old} == 77
 && $GOTestModule::RESULTS[2]{new} == 79
 && $GOTestModule::RESULTS[2]{method} eq "mod_event"
 && $GOTestModule::RESULTS[2]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();
$obj->process();
ok( $obj->attr('SomeNumber') == 63 );
@GOTestModule::RESULTS = ();

# Note that from this point on in the test, we do not always check the
# parameters of the SomeOtherNumber mods, since it was added largely to
# test the -apply_now feature, but it is reflected in the total number
# of events.

# Add another persistent modifier, this time to the real value that places it
# below the current value. Process it and see that the tend-to reverses sense.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -modify_real	=> -80,
    -persist_as	=> "StaticModifierReal",
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber', 'real_value') == 100 );
$obj->process();
ok( $obj->attr('SomeNumber', 'real_value') == 20
 && $obj->attr('SomeNumber') == 62 );
ok( @GOTestModule::RESULTS == 3
 && $GOTestModule::RESULTS[0]{event} eq 'attrRealValueModified'
 && $GOTestModule::RESULTS[0]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 100
 && $GOTestModule::RESULTS[0]{new} == 20
 && $GOTestModule::RESULTS[0]{method} eq "mod_real_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'blork'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[1]{old} == 63
 && $GOTestModule::RESULTS[1]{new} == 62
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Now cancel the modifier on the current value. It should change only after
# a process() call, just like the original modifiers.
eval('$obj->mod_attr(
    -cancel_modify=> "StaticModifier",
)');
ok( $@ eq '' );
ok( $obj->attr("SomeNumber") == 62
 && $obj->attr("SomeNumber", 'real_value') == 20 );
$obj->process();
ok( $obj->attr("SomeNumber") == 51
 && $obj->attr("SomeNumber", 'real_value') == 20 );
ok( @GOTestModule::RESULTS == 3
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 62
 && $GOTestModule::RESULTS[0]{new} == 52
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{key} eq 'SomeNumber'
 && $GOTestModule::RESULTS[1]{old} == 52
 && $GOTestModule::RESULTS[1]{new} == 51
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Put another modifier on the real value that brings it above the current
# again, but make this one timed. Make sure everything works. Until we come
# to OOB testing, we'll just be checking that the number of events processed
# is correct, since we pretty much exercised the basic event functionality.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -modify_real	=> 50,
    -persist_as	=> "StaticModifierReal2",
    -time	=> 3,
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber') == 51
 && $obj->attr('SomeNumber', 'real_value') == 20 );
$obj->process();
ok( $obj->attr('SomeNumber') == 52
 && $obj->attr('SomeNumber', 'real_value') == 70
 && @GOTestModule::RESULTS == 3 );
@GOTestModule::RESULTS = ();

# Process two more times. The real value should not change.
$obj->process();
$obj->process();
ok( $obj->attr('SomeNumber') == 54
 && $obj->attr('SomeNumber', 'real_value') == 70
 && @GOTestModule::RESULTS == 4 );
@GOTestModule::RESULTS = ();

# Process one more time. Now the second modifier should be gone.
$obj->process();
ok( $obj->attr('SomeNumber') == 53
 && $obj->attr('SomeNumber', 'real_value') == 20
 && @GOTestModule::RESULTS == 3
 && $GOTestModule::RESULTS[0]{event} eq 'attrRealValueModified'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified' );
@GOTestModule::RESULTS = ();

# Now to perform some OOB testing. The default OOB mode should be 'use_up',
# so try to make the current value go over the top.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -modify	=> 80,
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber') == 100
 && $obj->raw_attr('SomeNumber') == 100);

# Process the events associated with it.
$obj->process();
ok( $obj->attr('SomeNumber') == 99
 && @GOTestModule::RESULTS == 4
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueAttemptedOutOfBounds'
 && $GOTestModule::RESULTS[0]{foo} eq 'borf'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{foo} eq 'bar'
 && $GOTestModule::RESULTS[2]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[2]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Now change the strategy of OOB to ignore and try again.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -out_of_bounds => "ignore",
    -modify	=> 80,
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber') == 99
 && $obj->raw_attr('SomeNumber') == 99);

# The final test is to see if the cancel-by-re functionality works. Create
# an attribute and some modifiers on it.
eval('$obj->new_attr(
    -name	=> "MultiCancelTest",
    -type	=> "int",
    -value	=> 10,
)');
ok( $@ eq '' );
eval('$obj->mod_attr(
    -name	=> "MultiCancelTest",
    -modify	=> 1,
    -persist_as	=> "FirstMultiModifier",
)');
ok( $@ eq '');
eval('$obj->mod_attr(
    -name	=> "MultiCancelTest",
    -modify	=> 1,
    -persist_as	=> "SecondMultiModifier",
)');
ok( $@ eq '');
eval('$obj->mod_attr(
    -name	=> "MultiCancelTest",
    -modify	=> 1,
    -persist_as	=> "SomeOtherModifier",
)');
ok( $@ eq '');
$obj->process();
ok( $obj->attr('MultiCancelTest') == 13 );

# Cancel two of them.
eval('$obj->mod_attr(
    -cancel_modify_re	=> "^.+MultiModifier\$",
)');
ok( $@ eq '' );
$obj->process();
ok( $obj->attr('MultiCancelTest') == 11 );

unlink $pfile;
exit (0);
