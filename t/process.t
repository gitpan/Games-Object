# -*- perl -*-

# Processing and events

use strict;
use Test;

BEGIN { $| = 1; plan tests => 38 }

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
}

sub mod_real_event {
    shift;
    my %args = @_;
    $args{method} = "mod_real_event";
    push @RESULTS, \%args;
}

sub mod_oob {
    shift;
    my %args = @_;
    $args{method} = "mod_oob";
    push @RESULTS, \%args;
}

1;
';
close PKG;

use Games::Object qw(RegisterEvent);
use IO::File;

# Create an object from the subclassed test module.
require GOTestModule;
my $obj = GOTestModule->new();
ok( defined($obj) && $obj->isa('Games::Object') );

# Register some event handlers.
eval('RegisterEvent("attrValueModified", "mod_event", foo => "bar")');
ok( $@ eq '' );
eval('RegisterEvent("attrRealValueModified", "mod_real_event", foo => "blork")');
ok( $@ eq '' );
eval('RegisterEvent("attrValueAttemptedOutOfBounds", "mod_event", foo => "borf")');
ok( $@ eq '' );
eval('RegisterEvent("attrValueOutOfBounds", "mod_event", foo => "blub")');
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
)');
ok( $@ eq '' );

# Process it. Insure that we see the event that the attribute was modified.
$obj->process();
ok( $obj->attr('SomeNumber') == 51 );
ok( @GOTestModule::RESULTS == 1
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 50
 && $GOTestModule::RESULTS[0]{new} == 51
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Add a persisent static modifier. It should not be applied until process()
# is called. Also, it should be applied only once. Note, however, that there
# will be two modify events.
eval('$obj->mod_attr(
    -name	=> "SomeNumber",
    -modify	=> 10,
    -persist_as	=> "StaticModifier",
)');
ok( $@ eq '' );
ok( $obj->attr('SomeNumber') == 51 );
$obj->process();
ok( $obj->attr('SomeNumber') == 62 );
ok( @GOTestModule::RESULTS == 2
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 51
 && $GOTestModule::RESULTS[0]{new} == 61
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[1]{old} == 61
 && $GOTestModule::RESULTS[1]{new} == 62
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();
$obj->process();
ok( $obj->attr('SomeNumber') == 63 );
@GOTestModule::RESULTS = ();

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
ok( @GOTestModule::RESULTS == 2
 && $GOTestModule::RESULTS[0]{event} eq 'attrRealValueModified'
 && $GOTestModule::RESULTS[0]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 100
 && $GOTestModule::RESULTS[0]{new} == 20
 && $GOTestModule::RESULTS[0]{method} eq "mod_real_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'blork'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{name} eq 'SomeNumber'
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
ok( @GOTestModule::RESULTS == 2
 && $GOTestModule::RESULTS[0]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[0]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[0]{old} == 62
 && $GOTestModule::RESULTS[0]{new} == 52
 && $GOTestModule::RESULTS[0]{method} eq "mod_event"
 && $GOTestModule::RESULTS[0]{foo} eq 'bar'
 && $GOTestModule::RESULTS[1]{event} eq 'attrValueModified'
 && $GOTestModule::RESULTS[1]{name} eq 'SomeNumber'
 && $GOTestModule::RESULTS[1]{old} == 52
 && $GOTestModule::RESULTS[1]{new} == 51
 && $GOTestModule::RESULTS[1]{method} eq "mod_event"
 && $GOTestModule::RESULTS[1]{foo} eq 'bar' );
@GOTestModule::RESULTS = ();

# Put another modifier on the real value that brings it above the current
# again, but make this one timed. Make sure everything works. Until we come
# to OOB testing, we'll just be checking that the number of events processed
# is correct, since we pretty much exercised the event functionality.
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
 && @GOTestModule::RESULTS == 2 );
@GOTestModule::RESULTS = ();

# Process two more times. The real value should not change.
$obj->process();
$obj->process();
ok( $obj->attr('SomeNumber') == 54
 && $obj->attr('SomeNumber', 'real_value') == 70
 && @GOTestModule::RESULTS == 2 );
@GOTestModule::RESULTS = ();

# Process one more time. Now the second modifier should be gone.
$obj->process();
ok( $obj->attr('SomeNumber') == 53
 && $obj->attr('SomeNumber', 'real_value') == 20
 && @GOTestModule::RESULTS == 2
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
 && @GOTestModule::RESULTS == 3
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
