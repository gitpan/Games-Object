package Games::Object;
require 5.005;

use strict;
use Exporter;

use Carp qw(carp croak);
use POSIX;
use IO::File;

use vars qw($VERSION @EXPORT_OK %EXPORT_TAGS @ISA);

$VERSION = "0.01";
@ISA = qw(Exporter);
@EXPORT_OK = qw(CreateFlag ModifyFlag Find RegisterEvent Process
		LockAttrMods UnlockAttrMods SetProcessList
		FetchParams RegisterClass IsClassRegistered
		ATTR_STATIC ATTR_DONTSAVE);
%EXPORT_TAGS = (
    functions		=> [qw(Flag Find RegisterEvent Process
			       LockAttrMods UnlockAttrMods SetProcessList
			       FetchParams RegisterClass IsClassRegistered)],
    objflags		=> [qw(OBJ_CHANGED OBJ_AUTOALLOCATED
			       OBJ_PLACEHOLDER OBJ_DESTROYED)],
    attrflags		=> [qw(ATTR_STATIC ATTR_DONTSAVE)],
    all			=> [qw(:functions :objflags :attrflags)],
);

# Define some attribute flags.
use constant ATTR_STATIC	=> 0x00000001;
use constant ATTR_DONTSAVE	=> 0x00000002;

# Define object flags
use constant OBJ_CHANGED        => 0x00000001;
use constant OBJ_AUTOALLOCATED  => 0x00000002;
use constant OBJ_PLACEHOLDER    => 0x00000004;
use constant OBJ_DESTROYED      => 0x00000008;

# Define a table that instructs this module how to deal with object references
# upon save and load. In this manner we can handle blessed objects and even
# provide for their automatic instantiation in the latter case. One entry is
# prepopulated, that for Games::Object. This also represents the defaults for
# other classes that are added.
my %class_info = (
    'Games::Object'     => {
        id      => 'id',
        find    => 'Find',
        load    => 'load',
        save    => 'save',
    },
);

# Define table that tracks which classes we have require()d
my %required = ();

# Define storage for created objects. Note that this means that objects will
# be persistent. They can go out of scope and still exist, since each is
# identified by a unique ID.
my %obj_index = ();

# Define a counter for creating objects when the user wants us to assume that
# every new object is unique.
my $obj_next = 0;

# And if we are doing this, we want to try and use space efficiently by
# reclaiming unused IDs. Thus we track the lowest available opening.
my $obj_reclaim = 1;
my $obj_avail = 0;

# Define storage for user-defined object flags.
my %user_flag = ();

# Define storage for event action routines. Note that we defined each one
# ahead of time as an initial do-nothing function so we can use this table
# to tell if an event is valid.
my %event_action = (
    attrValueModified			=> [ '_do_nothing' ],
    attrRealValueModified		=> [ '_do_nothing' ],
    attrValueOutOfBounds		=> [ '_do_nothing' ],
    attrRealValueOutOfBounds		=> [ '_do_nothing' ],
    attrValueAttemptedOutOfBounds	=> [ '_do_nothing' ],
    attrRealValueAttemptedOutOfBounds	=> [ '_do_nothing' ],
    flagModified			=> [ '_do_nothing' ],
);

# Define a table that shows what order process() is supposed to do things.
my @process_list = (
#    'LockAttrMods',	# So as to delay new mods generated til next turn.
    'process_queue',
#    'UnlockAttrMods',
    'process_pmod',
    'process_tend_to',
    'process_queue',
);

# Define a limit to how many times the same item can be processed in a queue
# (see process_queue() for details)
my $process_limit = 100;

# Define flag that indicates if new attribute modifiers are to be created 
# initially locked.
my $lock_mods = 0;

####
## INTERNAL FUNCTIONS

# Load a class.

sub _LoadClass
{
        my $class = shift;

        if (!$required{$class}) {
            eval("require $class");
            croak "Unable to load class '$class'" if ($@);
            $required{$class} = 1;
        }
        1;
}

# Return name of particular class method.

sub _ClassMethod
{
        shift if (@_ > 2);
        my ($class, $type) = @_;
        $class_info{$class}{$type};
}

# Save an item of data to a file.

sub _SaveData
{
	my ($file, $data) = @_;

	# Check for undef, as this takes special handling.
	if (!defined($data)) {
	    print $file "U\n";
	    return 1;
	}

	# Now handle everything else.
	my $ref = ref($data);
	if ($ref eq '' && $data =~ /\n/) {
	    # Multiline text scalar
	    my @lines = split(/\n/, $data);
	    print $file "M " . scalar(@lines) . "\n" .
			join("\n", @lines) . "\n";
	} elsif ($ref eq '') {
	    # Simple scalar.
	    print $file "S $data\n";
	} elsif ($ref eq 'ARRAY') {
	    # Array.
	    print $file "A " . scalar(@$data) . "\n";
	    foreach my $item (@$data) {
		_SaveData($file, $item);
	    }
	} elsif ($ref eq 'HASH') {
	    # Hash. WARNING: Hash keys cannot have newlines in them!
	    my @keys = keys %$data;
	    print $file "H " . scalar(@keys)  . "\n";
	    foreach my $key (@keys) {
		print $file "$key\n";
		_SaveData($file, $data->{$key});
	    }
	} elsif (defined($class_info{$ref})) {
	    # This is a registered class, so pass the work along to the
	    # defined method.
	    print $file "O $ref\n";
	    my $method = $class_info{$ref}{save};
	    $data->$method(file => $file);
	} else {
	    # SOL
	    croak("Cannot save reference to $ref object");
	}
	1;
}

# Load data from a file. This can take an optional second parameter. If present,
# this is taken to be a reference to a variable that will hold the data, rather
# than creating our own and returning the result (this applies only to
# non-scalar data). WARNING!! No check is made to insure that the reference
# type is compatible with what is in the file!

sub _LoadData
{
	my ($file, $store) = @_;
	my $line = <$file>;

	# The caller is responsible for calling this routine only when there
	# is data to read.
	croak("Unexepected EOF") if (!defined($line));

	# Check for something we recognize.
	chomp $line;
	my $tag = substr($line, 0, 1);
	my $val = substr($line, 2);
	if ($tag eq 'U') {
	    # Undef.
	    undef;
	} elsif ($tag eq 'S') {
	    # Simple scalar value
	    $val;
	} elsif ($tag eq 'M') {
	    # Multiline text, to be returned as scalar.
	    my @text = ();
	    foreach my $i (1 .. $val) {
		my $line2 = <$file>;
		croak("Unexepected EOF") if (!defined($line2));
		push @text, $line2;
	    }
	    join("\n", @text);
	} elsif ($tag eq 'A') {
	    # Build an array.
	    my $ary = $store || [];
	    foreach my $i (1 .. $val) {
		push @$ary, _LoadData($file);
	    }
	    $ary;
	} elsif ($tag eq 'H') {
	    # Reconstruct a hash.
	    my $hsh = $store || {};
	    foreach my $i (1 .. $val) {
		my $key = <$file>;
		chomp $key;
		$hsh->{$key} = _LoadData($file);
	    }
	    $hsh;
	} elsif ($tag eq 'O') {
	    # Object reference. We first make sure this is a registered class
	    # and if so, we pass this along to it.
	    if (defined($class_info{$val})) {
		my $method = $class_info{$val}{load};
		my $obj = $val->$method(file => $file);
		$obj;
	    } else {
		croak "Cannot load object of class '$val' as it has " .
			"not been registered";
	    }
	} else {
	    # Anything else is unrecognized.
	    croak("Unknown tag '$tag' in file, file may be corrupted");
	}

}

####
## FUNCTIONS

# Fetch parameters, checking for required params and validating the values.

sub FetchParams
{
	my ($args, $res, $opts, $del) = @_;
	$del = 0 if (!defined($del));

	# If the first item is the name of this class, shift it off.
	shift @$args if (@$args && $args->[0] =~ /^Games::Object/);

	# Now go down the opts list and see what parameters are needed.
	# Return the results in a hash.
	my %args = @$args;
	foreach my $spec (@$opts) {

	    # Fetch the values for this spec. Note that not all may be present,
	    # depending on the type.
	    my ($type, $name, $dflt, $rstr) = @$spec;

	    # Philosophy conflict: Many CPAN modules like args to be passed
	    # with '-' prefixing them. I don't. Useless use of an extra
	    # keystroke. However, I want to be consistent. Thus a compromise:
	    # I allow args to be passed with or without the '-', but it always
	    # gets stored internally without the '-'.
	    my $oname = $name;
	    $name = '-' . $name if (defined($args{"-${name}"}));

	    # Check the type.
	    if ($type eq 'req') {

		# Required parameter, so it must be provided.
	        croak("Missing required argument '$name'")
		  unless (defined($args{$name}));
		$res->{$oname} = $args{$name};

	    } elsif ($type eq 'opt') {

		# Optional parameter. If not there and a default is specified,
		# then set it to that.
		if (defined($args{$name})) { $res->{$oname} = $args{$name}; }
		elsif (defined($dflt))	     { $res->{$oname} = $dflt; }

	    }

	    # Delete item from args if requested.
	    delete $args{$name} if ($del);

	    # Stop here if we wound up with undef anyway or there are no
	    # restrictions on the parameter.
	    next if (!defined($res->{$oname}) || !defined($rstr));

	    # Check for additional restrictions.
	    if (ref($rstr) eq 'ARRAY') {

		# Value must be one of these
		my $found = 0;
		foreach my $item (@$rstr) {
		    $found = ( $item eq $res->{$oname} );
		    last if $found;
		}
		croak("Invalid value '$res->{$oname}' for param '$name'")
		    unless ($found);

	    } elsif ($rstr =~ /^(.+)ref$/) {

		my $reftype = uc($1);
		croak("Parameter '$name' must be $reftype ref")
		    if (ref($res->{$oname}) ne $reftype);

	    } elsif ($rstr eq 'int') {

		# Must be an integer.
		croak("Param '$name' must be an integer")
		    if ($res->{$oname} !~ /^[\+\-\d]\d*$/);

	    } elsif ($rstr eq 'number') {

		# Must be a number. Rather than trying to match against a
		# heinously long regexp, we'll intercept the warning for
		# a non-numeric when we try to int() it. TMTOWTDI.
		my $not_number = 0;
		local $SIG{__WARN__} = sub {
		    my $msg = shift;
		    if ($msg =~ /isn't numeric in int/) {
			$not_number = 1;
		    } else {
			warn $msg;
		    }
		};
		my $x = int($res->{$oname});
		croak("Param '$name' must be a number") if ($not_number);

	    } elsif ($rstr eq 'boolean') {

		# Must be a boolean. We simply convert to a 0 or 1.
		my $bool = ( $res->{$oname} eq '0' ? 0 :
			     $res->{$oname} eq ''  ? 0 :
			     1 );
		$res->{$oname} = $bool;

	    } elsif ($rstr eq 'string') {

		# Must not be a reference
		croak("Param '$name' must be a string, not a reference")
		  if (ref($res->{$oname}));

	    } elsif ($rstr eq 'file') {

		# Must be reference to an IO::File or FileHandler object
		croak("Param '$name' must be a file (IO::File or " .
			"FileHandler object acceptable)")
		  if (ref($res->{$oname}) !~ /^(IO::File|FileHandler)$/);

	    } elsif ($rstr eq 'object') {

		# Must be an object reference, and must be one that is known
		# to the class_info table.
		my $ref = ref($res->{$oname});
		croak("Param '$name' must be an object reference, not a " .
			"simple scalar") if (!$ref);
		croak("Param '$name' must be an object reference, not a " .
			"'$ref' reference")
		  if ($ref !~ /^(SCALAR|ARRAY|HASH|CODE|REF|GLOB|LVALUE)$/);
		croak("Param '$name' must be of a class known to this " .
			"module (did you forget to RegisterClass() class " .
			"'$ref'?)")
		  if (!defined($class_info{$ref}));

	    }
	}

	# Set args to trimmed amount if delete option requested.
	@$args = %args if ($del);

	$res;
}

# Register a class that this module is to know about for load/save

sub RegisterClass
{
	shift if (@_ && $_[0] eq __PACKAGE__);
	my %args = ();
	my $dflt = $class_info{'Games::Object'};

	# Fetch the parameters, using the Games::Object settings as the
	# default.
	FetchParams(\@_, \%args, [
	    [ 'req', 'class', undef, 'string' ],
	    [ 'opt', 'id', $dflt->{id}, 'string' ],
	    [ 'opt', 'find', $dflt->{find}, 'string' ],
	    [ 'opt', 'load', $dflt->{load}, 'string' ],
	    [ 'opt', 'save', $dflt->{save}, 'string' ],
	] );

	# Validate the specified method names. Unfortunately, this requires
	# us to call in this class as if we were going to use it.
	my $class = {};
	_LoadClass($args{class});
	foreach my $type (qw(id find load save)) {
	    croak "Class $args{class} does not have a method called " .
		    "'$args{$type}' or its superclasses"
		if (!UNIVERSAL::can($args{class}, $args{$type}));
	    $class->{$type} = $args{$type};
	}
	$class_info{$args{class}} = $class;
	1;
}

# Check that a class is valid (i.e. has been registered with RegisterClass())
# Note that either the class name or a reference to an object blessed into
# that class can be specified.

sub IsClassRegistered
{
	my $proto = shift;
	my $class = ref($proto) || $proto;

	defined($class_info{$class});
}

# Define a new user-defined flag.

sub CreateFlag
{
	my $flag = {};
	FetchParams(\@_, $flag, [
	    [ 'req', 'name' ],
	    [ 'opt', 'autoset', 0 ],
	]);
	my $name = delete $flag->{name};
	croak("Duplicate flag '$name'") if (defined($user_flag{$name}));
	$user_flag{$name} = $flag;
	1;
}

# Modify the options for a flag

sub ModifyFlag
{
	my %args = ();
	FetchParams(\@_, \%args, [
	    [ 'req', 'name', undef, 'string' ],
	    [ 'req', 'option', undef, [ 'autoset' ]],
	    [ 'req', 'value', undef, 'boolean' ],
	]);
	croak "Attempt to modify undefined flag '$args{name}'"
	  if (!defined($user_flag{$args{name}}));

	$user_flag{$args{name}}{$args{option}} = $args{value};
}

# "Find" an object (i.e. look up its ID)

sub Find
{
	shift if @_ > 1;
	my $id = shift;

	defined($obj_index{$id}) ? $obj_index{$id} : undef;
}

# Register an action for an event. The action must consist of a method name
# that will be invoked on the object that triggers the event (thus you cannot
# specify arbitrary coderefs, or any refs for that matter other than objects
# blessed and subclassed to Games::Object).

sub RegisterEvent
{
	shift if ($_[0] eq __PACKAGE__);
	my ($event, $method, @args) = @_;

	# If the method is undefined, then we are unregistering an event
	# and want it replaced with nothing.
	if (!defined($method)) {
	    $event_action{$event} = [ '_do_nothing' ];
	    return 1;
	}

	# Check that the event is valid.
	croak("Invalid event '$event'") if (!defined($event_action{$event}));

	# Store.
	$event_action{$event} = [ $method, @args ];
	1;
}

# Go down the complete list of objects and perform a method call on each. If
# no args are given, 'process' is assumed. This will call them in order of
# priority. Objects at the same priority do not guarantee any particular order
# of processing.

sub Process
{
	# Note that we grab the actual objects and not the ids in the sort.
	# This is more efficient, as each object is simply a reference (a
	# scalar with a fixed size) as opposed to a string (a scalar with
	# a variable size).
	my ($method, @args) = @_;
	$method = 'process' if (!defined($method));

	my @objs = sort { $b->{priority} <=> $a->{priority} } values %obj_index;
	foreach my $obj (@objs) {
	    $obj->$method(@args);
	}
	scalar(@objs);
}

# Lock attribute persistent mods. This simply means that new mods created
# while this is in force will not run the next time process_pmod() is called,
# but be delayed until the second time it is called. This is mainly to prevent
# the first run through process_queue() from process() to place new mods that
# are run immediately, which in most cases makes no sense.
#
# This only affects new mods, not existing ones. These are public functions
# in case the user wants to write his/her own process() method.

sub LockAttrMods { $lock_mods = 1; }

# Unlock attribute mods.

sub UnlockAttrMods { $lock_mods = 0; }

# Set the process list for the process() function. Note that the user is
# not limited to the methods found here. The methods can be in the subclass
# if desired. Note that we have no way to validate the method names here,
# so we take it on good faith that they exist.

sub SetProcessList { @process_list = @_; }

####
## INTERNAL METHODS

# Do absolutely nothing successfully.

sub _do_nothing { 1; }

# Do absolutely nothing, but fail at it.

sub _do_nothing_fail { 0; }

# Set an internal flag on object.

sub _set
{
	my ($obj, $flag) = @_;

	$obj->{_flags} |= $flag;
}

# Clear an internal flag on object.

sub _clear
{
	my ($obj, $flag) = @_;

	$obj->{_flags} &= (0xffffffff ^ $flag);
}

# Check if an internal flag is set.

sub _is
{
	my ($obj, $flag) = @_;

	($obj->{_flags} & $flag) == $flag;
}

# Wipe all values from object except for the ID and DONTSAVE attributes.

sub _wipe
{
	my $obj = shift;

	foreach my $key (keys %$obj) {
	    next if ($key eq 'id');
	    if ($key eq 'attr') {
		foreach my $aname (keys %{$obj->{attr}}) {
		    my $attr = $obj->{attr}{$aname};
		    delete $obj->{attr}{$aname}
			if ( !($attr->{flags} & ATTR_DONTSAVE) );
		}
	    } else {
	        delete $obj->{$key};
	    }
	}
	$obj;
}

# "Lock" a method call so that it cannot be called again, thus preventing
# recursion. If it is already locked, then this is a fatal error, indicating
# that recursion has occurred.

sub _lock_method
{
	my ($obj, $meth) = @_;
	my $lock = "__" . $meth;

	if (defined($obj->{$lock})) {
	    croak("Attempt to call '$meth' on '$obj->{id}' recursively");
	} else {
	    $obj->{$lock} = 1;
	}
}

# Unlock a method

sub _unlock_method
{
	my ($obj, $meth) = @_;
	my $lock = "__" . $meth;

	delete $obj->{$lock};
}

####
## CONSTRUCTOR

# Basic constructor.

sub new
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $obj = {};
	my $from_file = 0;
	my %args = ();

	# Fetch optional parameters.
	FetchParams(\@_, \%args, [
	    [ 'opt', 'id', undef, 'string' ],
	    [ 'opt', 'filename', undef, 'string' ],
	    [ 'opt', 'file', undef, 'file' ],
	] );
	croak "Cannot define both 'filename' and 'file' args to object " .
		"constructor"
	    if (defined($args{file}) && defined($args{filename}));

	if (defined($args{filename})) {

	    # Open this file and then proceed as if normal load.
	    $args{file} = IO::File->new();
	    $args{file}->open("<$args{filename}") or
		croak "Unable to open template file '$args{filename}'";

	}

	if (defined($args{file})) {

	    # Read the object information from the file. Note we just pass
	    # this on to the load() routine with a flag set indicating that
	    # the object must not exist already.
	    $obj = $class->load(%args, exists => 0);
	    $from_file = 1;

	} elsif (defined($args{id})) {

	    # The object is to have this specific ID and must not exist already.
	    my $id = $args{id};
	    croak("Attempt to create duplicate object '$id'")
		if (Find($id));
	    $obj->{id} = $id;
	    $obj_index{$id} = $obj;
	    bless $obj, $class;

	} else {

	    # Initialize the object here and give it an ID that we pick.
	    $obj_avail++ if ($obj_avail == $obj_next);
	    $obj->{id} = "$obj_next";
	    $obj_index{"$obj_next"} = $obj;
	    $obj_next++;
	    bless $obj, $class;
	    $obj->_set(OBJ_AUTOALLOCATED);

	}

	# Set some internal tables if not set already.
	$obj->{_flags} = 0 if (!defined($obj->{_flags}));
	$obj->{attr} = {} unless(defined($obj->{attr}));
	$obj->{flag} = {} unless(defined($obj->{flag}));
	$obj->{queue} = [] unless(defined($obj->{queue}));
	$obj->{priority} = 0 unless(defined($obj->{priority}));

	# If any flags have the autoset option, we need to set these, if
	# we're not here as the result of a load from file.
	unless ($from_file) {
	    while ( my ($fname, $fdata) = each %user_flag ) {
	        $obj->{flag}{$fname} = 1 if ($fdata->{autoset});
	    }
	}

	# If a filename had been defined, then we opened the file and we need
	# to close it.
	$args{file}->close() if (defined($args{filename}));

	# Done.
	$obj;
}

# Load an object from an open file. This can be used in a variety of
# circumstances, depending on the value of the 'exists' option. If
# not provided or undef, then load() will not care whether the object
# already exists in memory. If it does, it is overwritten; if it does not,
# it is created. If set to 0, the object MUST NOT exist already, or it is
# an error. If set to 1, the object MUST exist already, or it is an error.

sub load
{
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my %args = ();
	my $obj;

	FetchParams(\@_, \%args, [
	    [ 'req', 'file', undef, 'file' ],
	    [ 'opt', 'id', undef, 'string' ],
	    [ 'opt', 'exists', undef, 'boolean' ],
	]);

	# First check that the file really contains an object definition at
	# this point. We need to do this anyway since we need the ID stored
	# there.
	my $file = $args{file};
	my $line = <$file>;
	croak("Attempt to read object data past EOF") if (!defined($line));
	croak("File does not contain object data at present position")
	    if ($line !~ /^OBJ:(.+)$/);
	my $id = $1;

	# Now fetch the saved class of the object, so we can re-bless it into
	# the user's subclass.
	$line = <$file>;
	croak("Attempt to read object data past EOF") if (!defined($line));
	croak("File does not contain class data at present position")
	    if ($line !~ /^CL:(.+)$/);
	my $subclass = $1;

	# If the user overrides the ID, then we set that here.
	$id = $args{id} if (defined($args{id}));

	if (!defined($args{exists})) {

	    # Instantiate the object automatically if it does not exist.
	    $obj = Find($id);
	    $obj = $class->new($id) if (!$obj);

	} elsif ($args{exists}) {

	    # The object MUST exist.
	    croak("Object '$id' does not exist on load")
		if (!defined($obj = Find($id)));
	    $obj->_wipe();

	} else {

	    # The object MUST NOT exist. While new() would check for this
	    # anyway, I want an error more specific to where the problem lies.
	    # Exception: If the placeholder flag is set, then this was created
	    # to satisfy an OREF datum that had an ID that did not yet exist
	    # and we reuse it.
	    my $existing = Find($id);
	    if ($existing) {
		if ($existing->_is(OBJ_PLACEHOLDER)) {
		    $obj = $existing;
		    $obj->_clear(OBJ_PLACEHOLDER);
		} else {
		    croak("Object '$id' already exists on load");
		}
	    } else {
	        $obj = $class->new(id => $id);
	    }

	}

	# We now have an object ready to load into, so perform the load.
	$obj->_protect_attrs(\&_LoadData, $file, $obj);

	# Make sure the ID is what we expect.
	$obj->{id} = $id;

	# Done.
	bless $obj, $subclass if ($subclass ne 'Games::Object');
	$obj;
}

# Save an object to a file at the present position. At the moment, everything
# is saved in clear ASCII. This makes the file portable across architectures
# while sacrificing space and security. Later versions of this module will
# include other formats.

sub save
{
	my ($obj) = shift;
	my %args = ();

	FetchParams(\@_, \%args, [
	    [ 'req', 'file', undef, 'file' ]
	]);
	my $file = $args{file};

	# Save the ID
	print $file "OBJ:$obj->{id}\n";

	# Save the object class.
	print $file "CL:" . ref($obj) . "\n";

	# Now all we need to do is call _SaveData() on ourself. However, if
	# we use $obj directly, it will simply be saved as an ID. We need to
	# fool it into thinking its a hash. So we assign %$obj to an ordinary
	# hash and pass the ref to it. This forces the reference to lose its
	# magic. Even better, no duplicate of the hash is made. %hash internally
	# contains the same reference, but without the blessing magic on it.
	#
	# Note that we do not want to save DONTSAVE attributes, so we run it
	# through the special wrapper.
	my %hash = %$obj;
	$obj->_protect_attrs(\&_SaveData, $file, \%hash);

}

###
## FLAG METHODS

# Set one or more user-defined flags on object.

sub set
{
	my ($obj, @fnames) = @_;

	foreach my $fname (@fnames) {
	    croak("Attempt to set undefined user flag " .
		    "'$fname' on '$obj->{id}'")
	        unless (defined($user_flag{$fname}));
	    next if (defined($obj->{flag}{$fname}));
	    $obj->{flag}{$fname} = 1;
	    $obj->event('flagModified',
		flag	=> $fname,
		old	=> 0,
		new	=> 1,
	    );
	}
	$obj;
}

# Clear one or more flags.

sub clear
{
	my ($obj, @fnames) = @_;

	foreach my $fname (@fnames) {
	    croak("Attempt to clear undefined user flag " .
		    "'$fname' on '$obj->{id}'")
	        unless (defined($user_flag{$fname}));
	    next if (!defined($obj->{flag}{$fname}));
	    delete $obj->{flag}{$fname};
	    $obj->event('flagModified',
		flag	=> $fname,
		old	=> 1,
		new	=> 0,
	    );
	}
	$obj;
}

# Check to see if one or more flags are set on an object (all must be set
# to be true).

sub is
{
	my ($obj, @fnames) = @_;
	my $total = 0;

	foreach my $fname (@fnames) {
	    croak("Attempt to clear undefined user flag " .
		    "'$fname' on '$obj->{id}'")
	        unless (defined($user_flag{$fname}));
	    $total++ if (defined($obj->{flag}{$fname}));
	}
	$total == scalar(@fnames);
}

# Same as above, but returns true so long as at least one flag is present.

sub maybe
{
	my ($obj, @fnames) = @_;
	my $total = 0;

	foreach my $fname (@fnames) {
	    croak("Attempt to clear undefined user flag " .
		    "'$fname' on '$obj->{id}'")
	        unless (defined($user_flag{$fname}));
	    $total++ if (defined($obj->{flag}{$fname}));
	    last if $total;
	}
	$total;
}

####
## INTERNAL ATTRIBUTE METHODS

# Adjust integer attribute to get rid of fractionals.

sub _adjust_int_attr
{
	my ($obj, $aname) = @_;
	my $attr = $obj->{attr}{$aname};

	my $expr1 = '$attr->{value} = ' .
		    $attr->{on_fractional} .
		    '($attr->{value})';
	my $expr2 = '$attr->{real_value} = ' .
		    $attr->{on_fractional} .
		    '($attr->{real_value})';
	eval($expr1);
	eval($expr2) if (defined($attr->{real_value}));
}

# Set an attribute to a new value, taking into account limitations on the
# attribute's value, plus adjustments for fractionals and so on.

sub _set_attr
{
	my ($obj, $aname, %args) = @_;
	my $attr = $obj->{attr}{$aname};

	foreach my $key (qw(real_value value)) {

	    # Fetch old and new values.
	    next if (!defined($args{$key}));
	    my $old = $attr->{$key};
	    my $new = $args{$key};
	    my $epart = ( $key eq 'value' ? 'Value' : 'RealValue' );

	    # If this is a non-numeric data type, then set it, queue event
	    # if needed, and done.
	    if ($attr->{type} !~ /^(int|number)$/) {
		croak "Non-numeric attributes cannot have split values"
		    if ($key eq 'real_value');
		if ($attr->{type} eq 'object') {
		    # Some special handling is required. First we need to
		    # see if a conversion needs to be done.
		    if ($attr->{store} eq 'id' && ref($new)) {
			# Convert from object reference to ID string
			croak "Only objects of  class '$attr->{class}' " .
				"allowed in attribute"
			    if (ref($new) ne $attr->{class});
			my $method = _ClassMethod($attr->{class}, 'id');
			$new = $new->$method();
		    } elsif ($attr->{store} eq 'ref' && !ref($new)) {
			# Convert from ID string to object reference. 
			my $method = _ClassMethod($attr->{class}, 'find');
			my $class = $attr->{class};
			$new = $class->$method($new);
		    } elsif (ref($new)) {
			# Insure that it is of the proper class.
			my $class = ref($new);
			croak "Value must be of class '$attr->{class}' " .
				"(not '$class')"
			  if ($class ne $attr->{class});
		    }
		}
		$attr->{$key} = $new;
		$obj->event("attr${epart}Modified",
		    name	=> $aname,
		    old		=> $old,
		    new		=> $new,
		) if (!$args{no_event} && $old ne $new);
		next;
	    }

	    # Find out if the new value is out of bounds.
	    my $too_small = ( defined($attr->{minimum}) &&
				$new < $attr->{minimum} );
	    my $too_big   = ( defined($attr->{maximum}) &&
				$new > $attr->{maximum} );
	    my $oob = ( $too_small || $too_big );
	    if ($oob) {

		# Yes. Do we force it?
		if ($args{force}) {
		    # Yes, we do, so report an OOB condition. Note that this
		    # occurs before the modification event. This gives the
		    # OOB action the chance to cancel the modification action,
		    # since the modifier action is guaranteed to come first.
		    $obj->event("attr${epart}OutOfBounds",
			name		=> $aname,
			old		=> $old,
			new		=> $new,
		    ) if (!$args{no_event});
		} else {
		    # No, don't force it. But what do we do with the
		    # modification?
		    my $oob_what = $attr->{out_of_bounds};
		    if ($oob_what eq 'ignore') {
			# Ignore this change.
			next;
		    } else {
			# Either use up what we can up to limit, or track the
			# excess. In either case, we need to calculate the
			# amount of excess. Note that 'track' is kind of like
			# an implied force option.
			my $excess;
			if ($too_small) {
			    $excess = $attr->{minimum} - $new;
			    $new = $attr->{minimum} if ($oob_what eq 'use_up');
			} else {
			    $excess = $new - $attr->{maximum};
			    $new = $attr->{maximum} if ($oob_what eq 'use_up');
			}
			# Now invoke the attempted OOB event
			my $atmp = ( $oob_what eq 'use_up' ? "Attempted" : "" );
			$obj->event("attr${epart}${atmp}OutOfBounds",
			    name	=> $aname,
			    old		=> $old,
			    new		=> $new,
			    excess	=> $excess,
			) if (!$args{no_event});
		    }
		}  # if $args{force}

	    }  # if $oob;

	    # Set the new value.
	    $attr->{$key} = $new;

	    # Adjust it if fractional and we're not handling those.
	    $obj->_adjust_int_attr($aname)
		if ($attr->{type} eq 'int' && !$attr->{track_fractional});
	    $new = $attr->{$key};

	    # Invoke modified event, but ONLY if it was modified.
	    $obj->event("attr${epart}Modified",
		name	=> $aname,
		old	=> $old,
		new	=> $new,
	    ) if (!$args{no_event} && $old != $new);

	}  # foreach $key

	# Done.
	1;
}

# Save information in attribute to file.

sub _save_attr
{
	my ($obj, $file, $aname) = @_;
	my $attr = $obj->{attr}{$aname};

	# Attribute header
	print $file "ATTR:$aname\n$attr->{type}\n";

	# Attribute info.
	my @keys = (
	    $attr->{type} eq 'any' ?
		qw(value) :
	    $attr->{type} eq 'string' ?
		qw(value values map) :
	    $attr->{type} eq 'int' ?
		qw(value real_value tend_to_rate minimum maximum
		   track_fractional on_fractional) :
	    $attr->{type} eq 'number' ?
		qw(value real_value tend_to_rate minimum maximum) :
	    () );
	foreach my $key (@keys) {
	    print $file "$key\n";
	    _SaveData($file, $attr->{$key});
	}

	# Done.
	1;
}

# Run code with a wrapper designed to protect the DONTSAVE attributes.

sub _protect_attrs
{
	my ($obj, $code, @args) = @_;

	# Save off the DONTSAVE attributes and delete from object.
	my %temp = ();
	foreach my $aname (keys %{$obj->{attr}}) {
	    my $attr = $obj->{attr}{$aname};
	    if ($attr->{flags} & ATTR_DONTSAVE) {
		$temp{$aname} = $attr;
		delete $obj->{attr}{$aname};
	    }
	}

	# Run the indicated code.
	&$code(@args);

	# Put back the attributes that we temporarily nixed.
	foreach my $aname (keys %temp) {
	    $obj->{attr}{$aname} = $temp{$aname};
	}
}

####
## ATTRIBUTE METHODS

# Create a new attribute on an object.
#
# Attribute flags:
#    ATTR_STATIC	- Attribute is not to be altered. Attempts to do so
#			  are treated as an error.
#    ATTR_DONTSAVE	- Don't save attribute on a call to save(). Also,
#			  the existing value is preserved on a load().

sub new_attr
{
	my $obj = shift;
	my $attr = {};

	# Fetch params universal to all attribute types.
	FetchParams(\@_, $attr, [
	    [ 'req', 'name' ],
	    [ 'opt', 'type', 'any', [ qw(any int number string object) ] ],
	    [ 'opt', 'priority', 0, 'int' ],
	    [ 'opt', 'flags', 0, 'int' ],
	], 1 );

	# Fetch additional args for integer types. Note that we allow the
	# initial value to be fractional. We'll clean this up shortly.
	FetchParams(\@_, $attr, [
	    [ 'req', 'value', undef, 'number' ],
	    [ 'opt', 'real_value', undef, 'number' ],
	    [ 'opt', 'on_fractional', 'int', [ qw(int ceil floor round) ] ],
	    [ 'opt', 'track_fractional', '0', 'boolean' ],
	    [ 'opt', 'tend_to_rate', undef, 'number' ],
	    [ 'opt', 'minimum', undef, 'int' ],
	    [ 'opt', 'maximum', undef, 'int' ],
	    [ 'opt', 'out_of_bounds', 'use_up', [ qw(use_up ignore track) ] ],
	], 1 ) if ($attr->{type} eq 'int');

	# Fetch additional args for number types.
	FetchParams(\@_, $attr, [
	    [ 'req', 'value', undef, 'number' ],
	    [ 'opt', 'real_value', undef, 'number' ],
	    [ 'opt', 'tend_to_rate', undef, 'number' ],
	    [ 'opt', 'minimum', undef, 'number' ],
	    [ 'opt', 'maximum', undef, 'number' ],
	    [ 'opt', 'out_of_bounds', 'use_up', [ qw(use_up ignore track) ] ],
	    [ 'opt', 'precision', 2, 'int' ],
	], 1 ) if ($attr->{type} eq 'number');

	# Fetch additional args for string types.
	FetchParams(\@_, $attr, [
	    [ 'opt', 'values', undef, 'arrayref' ],
	    [ 'opt', 'value', undef, 'string' ],
	    [ 'opt', 'map', {}, 'hashref' ],
	], 1 ) if ($attr->{type} eq 'string');

	# Fetch additional args for object types. Note that the class must
	# be first registered.
	if ($attr->{type} eq 'object') {
	    FetchParams(\@_, $attr, [
	        [ 'opt', 'value', undef, 'string|object' ],
	        [ 'opt', 'class', 'Games::Object', 'string' ],
	        [ 'opt', 'store', 'ref', [ qw(id ref) ] ],
	    ], 1 );
	    croak "Class '$attr->{class}' is unknown to the data module " .
		    "(Did you forget to call RegisterClass()?)"
		if (!IsClassRegistered($attr->{class}));
	}

	# Fetch additional args for 'any' type.
	FetchParams(\@_, $attr, [
	    [ 'opt', 'value', undef, 'any' ],
	], 1 ) if ($attr->{type} eq 'any');

	# If there are any remaining arguments, sound a warning. Most likely
	# the caller forgot to put a 'type' parameter in.
	if (@_) {
	    my %args = @_;
	    my $extra = "'" . join("', '", keys %args) . "'";
	    carp("Warning: extra args $extra to new_attr($attr->{name}) " .
		  "of '$obj->{id}' ignored (did you forget a 'type' " .
		  "parameter?)");
	}

	# Store.
	my $aname = delete $attr->{name};
	$obj->{attr}{$aname} = $attr;

	# If an object type, call _set_attr() to perform any needed conversion
	$obj->_set_attr($aname, value => $attr->{value}, no_event => 1)
	    if ($attr->{type} eq 'object');

	# If a real_value was defined but no tend-to, drop the real_value.
	delete $attr->{real_value} if (!defined($attr->{tend_to_rate}));

	# And if there is a tend_to_rate but no real_value, set the latter
	# to the current value.
	$attr->{real_value} = $attr->{value}
	  if (defined($attr->{tend_to_rate}) && !defined($attr->{real_value}));

	# Adjust attribute values to get rid of fractionals if not tracking it.
	$obj->_adjust_int_attr($aname)
	    if ($attr->{type} eq 'int' && !$attr->{track_fractional});

	# Initialize persistent modifer table.
	$attr->{pmod} = {};
	$attr->{pmod_next} = 0;
	$attr->{pmod_active} = 0;

	# Done.
	$obj;
}

# Fetch value or properties of an attribute

sub attr
{
	my ($obj, $aname, $prop) = @_;
	$prop = 'value' if (!defined($prop));

	# Check to see if attribute exists.
	croak("Attribute '$aname' does not exist on '$obj->{id}'")
	  if (!defined($obj->{attr}{$aname}));

	# Check to see if the property exists.
	my $attr = $obj->{attr}{$aname};
	croak("Attribute '$aname' does not have property called '$prop'")
	  if (!defined($attr->{$prop}));

	# The value and real_value are special cases.
	if ($prop =~ /^(value|real_value)$/) {
	    my $result;
	    if ($attr->{type} eq 'int' && $attr->{track_fractional}) {
		# The value that the caller really sees is the integer.
		my $expr = '$result = ' . $attr->{on_fractional} .
			   '($attr->{$prop})';
		eval($expr);
	    } elsif ($attr->{type} eq 'string'
		 &&  defined($attr->{map})
		 &&  defined($attr->{map}{$attr->{$prop}}) ) {
		# Return the mapped value
		$result = $attr->{map}{$attr->{$prop}};
	    } else {
		# Return whatever is there.
		$result = $attr->{$prop};
	    }
	    # If this value is OOB, this must mean a force was done on a 
	    # mod_attr or the mode was set to 'track', so make sure we return
	    # only a value within the bounds.
	    $result = $attr->{minimum}
		if (defined($attr->{minimum}) && $result < $attr->{minimum});
	    $result = $attr->{maximum}
		if (defined($attr->{maximum}) && $result > $attr->{maximum});
	    $result;
	} else {
	    # No interpretation of the value needed.
	    $attr->{$prop};
	}
}

# Fetch the "raw" attribute property value. This bypasses the code that checks
# for fractional interpretations and mapping.

sub raw_attr
{
	my ($obj, $aname, $prop) = @_;
	$prop = 'value' if (!defined($prop));

	# Check to see if attribute exists.
	croak("Attribute '$aname' does not exist on '$obj->{id}'")
	  if (!defined($obj->{attr}{$aname}));

	# Check to see if the property exists.
	my $attr = $obj->{attr}{$aname};
	croak("Attribute '$aname' does not have property called '$prop'")
	  if (!defined($attr->{$prop}));

	# Return the value of the property.
	$attr->{$prop};
}

# Modify an attribute

sub mod_attr
{
	my $obj = shift;
	my %args = @_;

	# Check for a cancel operation.
	FetchParams(\@_, \%args, [
	    [ 'opt', 'cancel_modify', undef, 'string' ],
	    [ 'opt', 'cancel_modify_re', undef, 'string' ],
	    [ 'opt', 'immediate', 0, 'boolean' ],
	]);
	if (defined($args{cancel_modify})) {
	    # Normal cancel
	    my $id = $args{cancel_modify};
	    if (defined($obj->{pmod}{$id})) {

		# First check to see if the mod was incremental. If not,
		# then we need to reverse the change that it had effected.
		my $mod = $obj->{pmod}{$id};
		my $aname = $mod->{aname};
		if (!$mod->{incremental}) {
		    # Call myself to do the change.
		    my %opts = ( -name => $aname );
		    $opts{modify} = -$mod->{modify}
			if (defined($mod->{modify}));
		    $opts{modify_real} = -$mod->{modify_real}
			if (defined($mod->{modify_real}));
		    # By default, we queue this up and do it at next process(),
		    # to be consistent with the way modifiers are applied.
		    # Specifying an immediate of true forces us to do it now.
		    if ($args{immediate}) {
		        $obj->mod_attr(%opts);
		    } else {
		        $obj->queue('mod_attr', %opts);
		    }
		}
		delete $obj->{pmod}{$id};
		$obj->{pmod_active}--;
		$obj->{pmod_next} = 0 if ($obj->{pmod_active} == 0);
	        return 1;
	    } else {
		return 0;
	    }
	}
	if (defined($args{cancel_modify_re})) {
	    # Cancel all that match the regular expression. We do this by
	    # building a list of matching modifiers and call ourself for each.
	    my $re = $args{cancel_modify_re};
	    my @ids = grep { /$re/ } keys %{$obj->{pmod}};
	    delete $args{cancel_modify_re};
	    foreach my $id (@ids) {
		$args{cancel_modify} = $id;
		$obj->mod_attr(%args);
	    }
	    return scalar(@ids);
	}

	# Fetch parameters. We have to do a lot of verification ourselves of
	# the parameters, since there are so many possible combinations. Thus
	# only the attribute ID itself is required, and we need that first
	# before we can check some of the other args, hence the multiple
	# calls to FetchParams().
	FetchParams(\@_, \%args, [
	    [ 'req', 'name' ],
	], 1 );
	my $aname = $args{name};
	croak("Attempt to modify unknown attribute '$aname}' " .
		"on object $obj->{id}") if (!defined($obj->{attr}{$aname}));
	my $attr = $obj->{attr}{$aname};

	# Check for attempt to modify static attribute.
	croak("Attempt to modify static attr '$aname' on '$obj->{id}'")
	    if ($attr->{flags} & ATTR_STATIC);

	# Fetch basic modifier parameters.
	%args = ();
	my $vtype = ( defined($attr->{values}) ?
			$attr->{values} :
		      $attr->{type} eq 'int' && $attr->{track_fractional} ?
			'number' :
		      $attr->{type} eq 'object' ?
			'any' :
		      $attr->{type}
		    );
	FetchParams(\@_, \%args, [
	    [ 'opt', 'minimum',     undef,	$vtype ],
	    [ 'opt', 'maximum',     undef,	$vtype ],
	    [ 'opt', 'out_of_bounds', undef,	[ qw(ignore use_up track) ] ],
	    [ 'opt', 'tend_to_rate',  undef,	$vtype ],
	    [ 'opt', 'priority',    undef,	'int' ],
	    [ 'opt', 'value',       undef,      $vtype ],
	    [ 'opt', 'real_value',  undef,      $vtype ],
	    [ 'opt', 'modify',      undef,      $vtype ],
	    [ 'opt', 'modify_real', undef,      $vtype ],
	] );

	# Check for property modifiers first.
	my $pcount = 0;
	foreach my $prop (qw(minimum maximum on_fractional out_of_bounds
			     tend_to_rate priority)) {
	    next if (!defined($args{$prop}));
	    croak("Property '$prop' allowed only on numeric attribute")
		if ($vtype !~ /^(int|number)$/);
	    $attr->{$prop} = delete $args{$prop};
	    $pcount++;
	}

	# If at least one property set, we're allowed not to have any
	# modification parameters.
	my $acount = scalar(keys(%args));
	return 1 if ($pcount > 0 && $acount == 0);

	# Check for mod parameters
	croak("No modification parameter present") if ($acount == 0);
	croak("Cannot combine attribute absolute set and modification " .
		"in single mod_attr() call")
	  if ( (defined($args{value}) || defined($args{real_value}))
	  &&   (defined($args{modify}) || defined($args{modify_real})) );
	croak("Cannot set/modify real value when value not split")
	  if ( (defined($args{real_value}) || defined($args{modify_real}))
	  &&   !defined($attr->{real_value}) );

	# Check for a simple set operation.
	if (defined($args{value}) || defined($args{real_value})) {

	    # Yes, value is being set. Fetch all optional parameters.
	    FetchParams(\@_, \%args, [
	        [ 'opt', 'force',       0,          'boolean' ],
	        [ 'opt', 'defer',       0,          'boolean' ],
	        [ 'opt', 'no_tend_to',  0,          'boolean' ],
	    ] );

	    # Deferred? If so, queue it and we're done.
	    if ($args{defer}) {
		delete $args{defer};
		$args{name} = $aname;
		$obj->queue('mod_attr', %args);
		return 1;
	    }

	    # If dropped down to here, then this is to be done right now.
	    $obj->_set_attr($aname, %args);

	} else {

	    # No, this is a modification relative to the current value of
	    # the attribute. This is allowed only for numeric types.
	    croak("Attempt a relative modify on non-numeric attribute " .
		    "'$aname' of '$obj->{id}'")
		if ($attr->{type} !~ /^(int|number)$/);

	    # Fetch all possible parameters.
	    FetchParams(\@_, \%args, [
	        [ 'opt', 'persist_as',  undef,	'string' ],
	        [ 'opt', 'priority',    0,	'int' ],
	        [ 'opt', 'time',        undef,  'int' ],
	        [ 'opt', 'delay',       0,	'int' ],
	        [ 'opt', 'force',       0,      'boolean' ],
	        [ 'opt', 'incremental', 0,      'boolean' ],
	    ] );

	    # Is to be persistent?
	    if (defined($args{persist_as})) {

		# Yes, so don't do the change right now. Simply add it as
		# a new persistent modifier (pmod). If one already exists,
		# then replace it silently. The index value is used in sorting,
		# so that when pmods of equal priority are placed in the object,
		# they are guaranteed to run in the order they were created.
		my $id = $args{persist_as};
		my $was_pmod = defined($obj->{pmod}{$id});
		my $mod = {
		    aname	=> $aname,
		    index	=> ( $was_pmod ?
					$obj->{pmod}{$id}{index} :
					$obj->{pmod_next}++ ),
		    priority	=> $args{priority},
		    time	=> $args{time},
		    delay	=> $args{delay},
		    force	=> $args{force},
		    modify	=> $args{modify},
		    modify_real	=> $args{modify_real},
		    incremental	=> $args{incremental},
		    applied	=> 0,
		    locked	=> $lock_mods,
		};
		$obj->{pmod}{$id} = $mod;
		$obj->{pmod_active}++ unless ($was_pmod);

	    } else {

		# No, do the change now.
		$args{value} = $attr->{value} + $args{modify}
		  if (defined($args{modify}));
		$args{real_value} = $attr->{real_value} + $args{modify_real}
		  if (defined($args{modify_real}));
		$obj->_set_attr($aname, %args);

	    }

	}  # if defined($args{value}) || defined($args{real_value})
}

####
## QUEUING AND CALLBACK CONTROL

# Queue an action to be run when the object is processed. This must take the
# form of a method name that can be invoked with the object reference. This is
# so this data can be properly saved to an external file (CODE refs don't save
# properly). In fact, none of the args to the action can be references. The
# exception is that you can specify a reference to a Games::Object object
# or one subclassed from it. This is translated to a form that can be written
# to the file and read back again (via the unique object ID).
#
# FIXME: Currently this is a black hole. Actions that go in do not come out
# (i.e. they cannot be deleted or told not to run) unless the object is
# deleted.

sub queue
{
	my ($obj, $method, @args) = @_;

	# The method must be valid.
	croak("Attempt to queue action for '$obj->{id}' with non-existent " .
		"method name '$method'") if (!$obj->can($method));

	# Okay to be queued.
	push @{$obj->{queue}}, [ $method, @args ];
	1;
}

# Indicate that an event has occurred by queuing its associated action to
# run.

sub event
{
	my ($obj, $event, @args) = @_;

	# Make sure it is a valid event.
	croak("Invalid event '$event'") if (!defined($event_action{$event}));

	# Combine event args with stored args. The new args override any
	# of the same name in the stored args.
	my @action = @{$event_action{$event}};
	my $method = shift @action;
	my @allargs = ( @action, @args, event => $event );

	# Queue it.
	$obj->queue($method, @allargs);
	1;
}

####
## OBJECT PROCESSING METHODS

# Process an object. This is used to do such actions as executing pending
# actions on the queue, updating attributes, and so on. The real work is
# farmed out to other methods, and the @process_list array tells us which
# to call, which the user can alter with SetProcessList().
#
# Note that we do not allow methods to be called recursively.

sub process
{
	my $obj = shift;

	foreach my $method (@process_list) {
	    $obj->_lock_method($method);
	    $obj->$method();
	    $obj->_unlock_method($method);
	}
	1;
}

# Process all items on the object's queue until the queue is empty. To
# prevent potential endless loops (routine A runs, places B on the queue,
# routine B runs, places A on the queue, etc), we track how many times we
# saw a given method, and if it reaches a critical threshhold, we issue a
# warning and do not execute that routine any more this time through. This
# is controlled by the $process_limit variable.

sub process_queue
{
	my $obj = shift;
	my $queue = $obj->{queue};
	my %mcount = ();

	while (@$queue) {
	    my $callbk = shift @$queue;
	    my ($meth, @args) = @$callbk;
	    $mcount{$meth} = 0 if (!defined($mcount{$meth}));
	    if ($mcount{$meth} > $process_limit) {
		# Already gave a warning on this, so ignore it silently.
		next;
	    } elsif ($mcount{$meth} == $process_limit) {
		# Just reached it last time through, so issue warning.
		carp("Number of calls to '$meth' has reached processing " .
		      "limit of $process_limit for '$obj->{id}', will no " .
		      "longer invoke this method this time through queue " .
		      "(you may have an endless logic loop somewhere)");
		next;
	    }
	    $mcount{$meth}++;
	    $obj->$meth(@args);
	}

	1;
}

# Process all tend_to rates in attributes that have them.

sub process_tend_to
{
	my $obj = shift;
	my @anames = sort { $obj->{attr}{$b}{priority} <=>
			    $obj->{attr}{$a}{priority} } keys %{$obj->{attr}};

	foreach my $aname (@anames) {

	    # Skip if not applicable
	    my $attr = $obj->{attr}{$aname};
	    next if (!defined($attr->{tend_to_rate}));

	    # Get the new value.
	    my $inc = $attr->{tend_to_rate};
	    my $new = $attr->{value};
	    my $target = $attr->{real_value};
	    if ($new < $target) {
		$new += $inc;
		$new = $target if ($new > $target);
	    } elsif ($new > $target) {
		$new -= $inc;
		$new = $target if ($new < $target);
	    } else {
		# Nothing to do.
		next;
	    }

	    # Set to the new value. Note that it is possible for something
	    # modified with tend_to to go OOB, since we use the force option.
	    # (FIXME: Do we want this behavior? Should the user have a choice
	    # of behaviors? Min/max and tend_to_rates really don't mix very
	    # well)
	    $obj->_set_attr($aname, value => $new, force => 1);

	}

	1;
}

# Process persistent modifications.

sub process_pmod
{
	my $obj = shift;
	my @ids = sort {
	    my $amod = $obj->{pmod}{$a};
	    my $bmod = $obj->{pmod}{$b};
	    if ($amod->{priority} == $bmod->{priority}) {
		$amod->{index} <=> $bmod->{index};
	    } else {
		$bmod->{priority} <=> $amod->{priority};
	    }
	} keys %{$obj->{pmod}};

	foreach my $id (@ids) {

	    my $mod = $obj->{pmod}{$id};
	    my $aname = $mod->{aname};
	    my $attr = $obj->{attr}{$aname};
	    if ($mod->{locked}) {

		# Locked. Simply unlock so it can run next time.
		$mod->{locked} = 0;

	    } elsif ($mod->{delay} > 0) {

		# Delay factor. Decrement and done.
		$mod->{delay}--;

	    } elsif (defined($mod->{time}) && $mod->{time} <= 0) {

		# Time is up, so cancel this one.
		$obj->mod_attr(-name		=> $aname,
			       -cancel_modify	=> $id,
			       -immediate	=> 1);

	    } elsif ($mod->{applied} && !$mod->{incremental}) {

		# This is a non-incremental modifier that was applied already,
		# so simply count down the time if applicable.
		$mod->{time}-- if (defined($mod->{time}));

	    } else {

		# Change has not yet been applied or this is an incremental
		# change, so apply it.
		my %args = (
		    -name	=> $aname,
		    -force	=> $mod->{force},
		);
		$args{modify} = $mod->{modify}
		  if (defined($mod->{modify}));
		$args{modify_real} = $mod->{modify_real}
		  if (defined($mod->{modify_real}));
		$obj->mod_attr(%args);
		$mod->{applied} = 1;

		# Count down the time if applicable
		$mod->{time}-- if (defined($mod->{time}));

	    }
	}

	1;
}

####
## MISCELLANEOUS OBJECT METHODS

# Fetch the ID of object

sub id { shift->{id}; }

# Modify the ID of an object. The new ID must not already exist as another
# object.

sub new_id
{
	my ($obj, $id) = @_;

	if (Find($id)) {
	    croak("Attempt to rename '$obj->{id}' to '$id', which " .
		    "already exists.");
	} else {
	    my $old_id = $obj->{id};
	    $obj_index{$id} = $obj_index{$old_id};
	    delete $obj_index{$old_id};
	    $obj->{id} = $id;
	    $obj;
	}
}

# Fetch/set priority of object.

sub priority
{
	my $obj = shift;

	if (@_) {
	    $obj->{priority} = shift;
	} else {
	    $obj->{priority};
	}
}

####
## DESTRUCTORS

# Destroy the object and remove it from the internal table.

sub destroy
{
	my $obj = shift;

	return if (!defined($obj->{id}));
	my $id = $obj->{id};
	foreach my $key (keys %$obj) {
	    delete $obj->{$key};
	}
	delete $obj_index{$id};
}

# Hook into destroy() method if not called before undefed.

sub DESTROY { shift->destroy(); }

1;
__END__

=head1 NAME

Games::Object - Provide a base class for game objects

=head1 SYNOPSIS

    package YourGameObject;
    use Games::Object;
    use vars qw(@ISA);
    @ISA = qw(Games::Object);

    sub new {
	# Create object
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = $class::SUPER->new();
	bless $self, $class;

	# Add attributes
	$self->new_attr(-name => "hit_points",
			-type => 'int'
			-value => 20,
			-tend_to_rate => 1);
	$self->new_attr(-name => "strength",
			-type => 'int',
			-value => 12,
			-minimum => 3,
			-maximum => 18);
	...

	return $self;
    }

    ...

    1;

=head1 ABSTRACT

The purpose of this module is to allow a programmer to write a game in Perl
easily by providing a basic framework in the form of a module that can be
either subclassed to a module of your own or used directly as its own object
class. The most important items in this framework are:

=over 4

=item Attributes

You can define arbitrary attributes on objects with rules on how they may
be updated, as well as set up automatic update of attributes whenever the
object's C<process()> method is invoked. For example, you could set an
attribute on an object such that:

=over 4

=item *

It ranges from 0 to 100.

=item *

Internally it tracks fractional changes to the value but accessing the
attribute will always round the result to an integer.

=item *

It will automatically tend towards the maximum by 1 every time C<process()>
is called on the object.

=item *

A method in your subclass will be invoked automatically if the value falls
to 0.

=back

This is just one example of what you can do with attributes.

=item Flags

You can define any number of arbitrarily-named flags on an object. A flag
is a little like a boolean attribute, in that it can have a value of either
true or false. Flags can be added to the overall "universe" in which your
objects exist such that new objects created automatically get certain
flags set.

=item Load/Save functionality

Basic functionality is provided for saving data from an object to a file, and
for loading data back into an object. This handles the bulk of load game /
save game processing, freeing the programmer to worry about the mechanics
of the game itself.

The load functionality can also be used to create objects from object templates.
An object template would be a save file that contains a single object.

=back

It should be noted that many of the features of this module have definitely
been geared more towards RPG, strategy, and D&D-like games. However, there is
enough generic functionality for use in many other genres. Suggestions at ways
to add more generalized functionality are always welcome.

=head1 DESCRIPTION

=head2 Using Games::Object as a base class

This is the optimal way to use Games::Object. You define a game object class
of your own as a subclass of Games::Object. In your constructor, you create
a Games::Object classed object first, then re-bless it into your class. You
can then add your object class' customizations. To insure that all your
customizations can be potentially C<save()>ed at a later time, you should
add all your data to the object as attributes.

The main reason this is the ideal way to use this class will become clear when
you reach the section that talks about events. Briefly, an event is defined
as some change to the object, such as an attribute being modified or a boundary
condition being reached. If you wish to provide code to be executed when
the event is triggered, you must define it in the form of a method call. This
is due to the fact that you would want your event mappings to be C<save()>ed
as well as your attributes, and CODE references cannot be written out and
read back in.

=head2 Using Games::Object as a standalone module

Nothing explicitly prohibits the use of this module in this fashion. Indeed,
the very idea behind OOP is that a class does not need to know if it is being
subclassed or not. It is permissable to use "raw" Games::Object objects in
this manner.

The only limitation is that you may not be able to define event mappings,
due to the limitation stated above.

=head1 The Constructor

=head2 Creating an empty object

Creating an empty object can be done simply as follows:

    $obj = new Games::Object;

When an object is created in this fashion, it generally has nothing in it. No
attributes, no flags, nothing. There are no options at this time in the
constructor to automatically add such things at object creation.

There is one exception to this rule, however. If you have creatad user-defined
flags (see L<"User-defined Flags"> for details) with the I<autoset> option,
these flags will automatically be set on the object when it is created.

Each object that is created must have a unique ID. When you create an empty
object in this manner, a guaranteed unique ID is selected for the object, which
can be retrieved with the C<id()> method. If you wish to specify your own
ID, you can specify it as an argument to the constructor:

    $obj = new Games::Object(-id => "id-string");

Specifying an ID that already exists is a fatal error. You can check ahead of
time if a particular ID exists by using the C<Find()> function.
Given an ID, it will return the reference to the Games::Object that this
identifies, or undef if the ID is unused.

=head2 Creating an object from an open file

You can instantiate a new object from a point in an open file that contains
Games::Object data that was previous saved with C<save()> by passing the
open file to the constructor:

    $obj = new Games::Object(-file => \*INFILE);

The argument to I<-file> can be any sort of file reference, from a GLOB
reference to an IO::File object reference. So long as it has been opened for
reading already.

The constructor will use as the ID of the object the ID that was stored in the
file when it was saved. This means that this ID cannot already exist or it is
a fatal error.

A simple way to implement a load-game functionality that takes place at game
initialization would thus be to open the save file, and make repeated calls to
L<new()|"The Constructor"> until the end of file was reached.

Note that when loading an object from a file, autoset options on flags are
ignored. Instead, flags are set or cleared according to the data stored in the
file. Thus the object is guaranteed to look exactly like it does when it was
saved.

You can choose to override the ID stored in the file by passing an I<-id> option
to the constructor along with the I<-file> option. This would in essence allow
you to create duplicate objects if you were so minded. Example:

    my $fpos = tell INFILE;
    my $obj1 = new Games::Object(-file => \*INFILE);
    seek(INFILE, $fpos, SEEK_SET);
    my $obj2 = new Games::Object(-file => \*INFILE, -id => $obj1->id() . "COPY");

=head2 Creating an object from a template file

In this case "template" is simply a fancy term for "a file that contains a
single object definition". It is simply a convenience; rather than opening
a file yourself and closing it afterward just to read one object, this does
those operations for you:

    $obj = new Games::Object(-filename => "creatures/orc.object");

All it really is a wrapper around a call to open(), a call to the constructor
with a I<-file> argument whose value is the newly opened file, and a call to
close(). As with I<-file>, it obtains the ID of the object from the file, but
you can specify an I<-id> option to override this. Example:

    $obj = new Games::Object(-filename => "creatures/orc.object", -id => "Bob");

=head2 Objects are persistent

It is important to note that when you create an object, the object is
persistent even when the variable to which you have assigned the reference
goes out of scope. Thus when you do something like this:

    my $obj = new Games::Object;

At that moment, two references to the object exists. One is in I<$obj>, while
the other is stored in a hash internal to the Games::Object module. This is
needed so as to be able to later map the ID back to the object. It also frees
the game programmer from having to maintain his/her own similar list.

=head1 Retrieving a previously created object

As mentioned in the previous section, objects are persistent, even after the
initial variable containing the reference to it goes out of scope. If you
have the ID of the object, you can later retrieve a reference to the object
via C<Find()>, which can be called either as a function like this:

    my $obj = Find('Sam the ogre');

Or as a class-level method:

    my $obj = Games::Object->Find('Sam the ogre');

This will work no matter how the object was created, either through creating
a new object or loading an object from a file.

If the ID specified is not a valid object, C<Find()> will return undef.

=head1 Destroying objects

As mentioned in the previous section, objects are persistent, thus they never
get destroyed simply by going out of scope. In order to effect purposeful
destruction of an object, you must call the C<destroy()> method:

    $obj->destroy();

This will empty the object of all its data and remove it from the internal
table in Games::Object such that future calls to C<Find()> will return undef.
In addition, the object will no longer be found on any class-level methods
of functions that operate on the entire list of objects (such as C<Process()>).
In the above example, once I<$obj> goes out of scope, the actual memory inside
Perl for the object will be freed. You could conceivably simply avoid the
middleman and not even assign it to a local variable, so long as you're
confident that the object exists:

    Find('Dragonsbane')->destroy();

=head1 User-defined Flags

=head2 Creating flags

A user-defined flag is any arbitrary string that you wish to use to represent
some sort of condition on your objects. For example, you might want a flag
that indicates if an object can be used as a melee weapon. Flags are defined
globally, rather than on an object-per-object basis. This is done with the
function C<CreateFlag()>:

    CreateFlag(-name => "melee_weapon");

The only restriction on flag names is that they cannot contain characters that
could be interpretted as file-control characters (thus you can't have imbedded
newlines), or the "!" character (which is reserved for future planned
functionality). If you stick to printable characters, you
should be fine.

You can choose to set up a flag such that it is automatically set on new
objects that are created from that point in time forward by using the
I<-autoset> option:

    CreateFlag(-name => "melee_weapon", -autoset => 1);

If you later with to turn off I<-autoset>, you can do so with C<ModifyFlag()>:

    ModifyFlag(-name => "melee_weapon",
	       -option => "autoset",
	       -value => 0);

There is currently no requirement as to what order you perform you calls to
C<CreateFlag()> or L<new()|"The constructor">, other than you will not be able
to set or clear a flag until it has been defined. It is probably good practice
to define all your flags first and then create your objects.

=head2 Setting/clearing flags

You may set a user-defined flag on an object with the C<set()> method:

    $obj->set('melee_weapon');

You can choose to set multiple flags at one time as well:

    $obj->set('melee_weapon', 'magical', 'bladed');

Setting a flag that is already set has no effect and is not an error. The
method returns the reference to the object.

Clearing one or more flags is accomplished in similar fashion with the
C<clear()> method. Like C<set()>, it can clear multiple flags at once:

    $obj->clear('cursed', 'wielded');

=head2 Fetching flag status

Two methods are provided for fetching flag status, C<is()> and C<maybe()>.

The C<is()> method returns true if the flag is set on the object. If more than
one flag is specified, then ALL flags must be set. If even one is not set,
false is returned. For example:

    if ($weapon->is('cursed', 'wielded')) {
	print "It is welded to your hand!\n";
 	...
    }

The C<maybe()> method works the same as C<is()> for a single flag. If multiple
flags are present, however, it requires only that at least one of the specified
flags be set to be true. Only if none of the flags are present will it return
false. Example:

    if ($weapon->maybe('rusted', 'corroded', 'broken')) {
	print "It's not looking in good shape. Sure you want to use it?\n";
	...
    }

=head1 Attributes

This is the heart of the module. Attributes allow you to assign arbitrary data
to an object in a controlled fashion, as well as dictate the rules by which
attributes are modified and updated.

=head2 Creating Attributes

=over 4

=item Simple attributes

A simple attribute has a name that uniquely identifies it, a datatype, and the
starting value. The name needs to be unique only in the confines of the object
on which the attribute is defined. Two different objects with an attribute
of the same name retain separate copies of the attribute. They do not even
need to be the same datatype.

An attribute of type I<number> can take on any valid decimal numeric value
that Perl recognizes. Such an attribute can be created as follows:

    $obj->new_attr(-name => "price",
		   -type => "number",
		   -value => 1.99);

Any attempt to set this to a non-numeric value later would be treated
as an error.

The datatype of I<int> is similar to I<number> except that it restricts the
value to integers. Attempting to set the attribute to a numeric that is not
an integer, either when created or later modified, is not an error, but the
result will be silently truncated as if using the Perl C<int()> function.
An I<int> attribute can be created as follows:

    $obj->new_attr(-name => "experience",
		   -type => "int",
		   -value => 0);

An attribute of type I<string> is intended to contain any arbitrary, printable
text. This text can contain newlines and other text formatting characters such
as tabs. These will be treated correctly if the object is later saved to a
file. No special interpretation is performed on the data. Such an attribute
can be created as follows:

    $obj->new_attr(-name => "description",
		   -type => "string",
		   -value => "A long blade set in an ornamental scabbard of gold.");

The I<any> datatype is used for data that does not fall into any of the above
categories. No particular interpretation is performed on the data, and no
special abilities are associated with it. Use this datatype when you wish to
store references to arrays or hashes. The only caveat is that these complex
data structures must eventually work down to simple scalar types for the
data in the attribute to be C<save()>d correctly later. Do not use this for
object references, except for objects subclassed to Games::Object (this is
covered in more detail in an upcoming section). Here is an example of using
the I<any> datatype:

    $obj->new_attr(-name => "combat_skill_levels",
		   -type => "any",
		   -value => {
			melee		=> 4,
			ranged		=> 2,
			hand_to_hand	=> 3,
			magical		=> 5,
		   });

There is one more datatype called I<object>, which is intended to provided a
way for storing an object reference in an attribute. However, as there are
some special caveats and setup required, this is covered as a separate topic.

=item Split attributes

A "split" attribute is available only to datatypes I<number> and I<int>. An
attribute that is split maintains two separate values for the attribute, a
"real value" and a "current value" (or simply the "value"). An attribute that
is split in this way has the following properties:

=over 4

=item *

By default, when retrieving the value, the current value is returned.

=item *

The current value will "tend towards" the real value when the object's
C<process()> method is called (covered in a later section).

=item *

Both the current and real values can be manipulated independent of one another
(except where noted above with regards to the "tend to" processing).

=back

A split attribute is defined by specifying the additional parameter
I<-tend_to_rate>, as in this example:

    $obj->new_attr(-name => "health",
		   -type => "int",
		   -tend_to_rate => 1,
		   -value => 100);

This indicates that each time the object is processed, the current value will
tend towards the real by 1. The tend-to rate is always treated as a positive
number. Its sign is adjusted internally to reflect what direction the current
needs to go to reach the real (thus in this case if the real were less than
the current, 1 would be subtracted from the current when the object was
processed).

Note in the above example that in the absense of specifying what the starting
real value is, the real value will start off set to the current (in this case,
the value of 100). If you wish to start off the real at a different value
than the current, you add the I<-real_value> option, as in this example:

    $obj->new_attr(-name => "power",
		   -type => "number",
		   -tend_to_rate => 0.2,
		   -value => 0,
		   -real_value => 250);

=item Limited attributes

An attribute's value can be "limited", in that it is not allowed to go beyond
a certain range or a certain set of values.

Attributes of type I<number> and I<int> can be limited in range by adding the
I<-minimum> and I<-maximum> options when the attribute is created. Note that
you can choose to use one or the other or both. Example:

    $obj->new_attr(-name => "hit_points",
		   -type => "int",
		   -tend_to_rate => 1,
		   -value => 20,
		   -minimum => 0,
		   -maximum => 50);

By default, attempts to modify the attribute outside the range will cause the
modifying value to be "used up" as much as possible until the value is pegged
at the limit, and the remainder ignored. In the above example, if the current
value were 5, and an attempt to modify it by -7 were attempted, it would be
modified only by -5 as that would put it at the minimum of 0. This default
behavior can be modified with the I<-out_of_bounds> option, which is a string
that has one of the following values:

=over 4

=item use_up

Use up as much of the modifying value as possible (the default).

=item ignore

Ignore the modification entirely. The value of the attribute will not be
changed.

=item track

Operates like I<use_up>, except that the excess is tracked internally.
Subsequent attempts to modify the attribute the other way will have to use
up this amount first B<[NOTE: This is currently not implemented]>.

=back

Attributes of type I<string> can be limited by specifying a set of allowed
values for the attribute. This is done when the attribute is created by
adding the I<-values> option. This is a reference to an array of strings that
constitute the only allowable values for this attribute. For example:

    $obj->new_attr(-name => "status",
		   -values => [ 'quiet', 'moving', 'attacking', 'dead' ],
		   -value => 'quiet');

=item Mapped attributes

This feature is available only to I<string> attributes. This allows you to
map the actual value of the attribute such that when it is retrieved normally,
some other text is returned instead. This is done by adding a I<-map> option
when the attribute is created. The argument to I<-map> is a reference to a hash
containing the allowed values of the attribute as keys, and the corresponding
values to be returned when the attribute is fetched as values. For example:

    $obj->new_attr(-name => "status",
		   -values => [ 'quiet', 'moving', 'attacking', 'dead' ],
		   -value => 'quiet',
		   -map => {
			quiet	=> "It appears quiescent.",
			moving	=> "It is moving stealthily.",
			attacking => "It is attacking you!",
			dead	=> "It's dead, Jim.",
		   } );

Note that the above example used I<-map> with I<-values>, but you're not
required to do this. With this setup, retrieving the value of this attribute
when it is set internally to "dead" will cause "It's dead, Jim." to be
returned instead.

=item Object reference attributes

Games::Object offers a way to store object references in your attributes.
Object references in this case are broken down into two areas: easy and hard.

The easy references are references to Games::Object objects or objects from
subclasses of Games::Object. These references may be stored either as an
I<any> datatype, or as a scalar value from a complex data structure on an
I<any> datatype. When you store these references, upon saving the data to
an external file, the references are converted to ID strings and then back
again when reloaded. The code handles cases of objects not yet loaded but
references in an attribute automatically.

B<BEWARE!> If objects in your game frequently get created and destroyed, it
is probably NOT a good idea to store objects as references in your attributes.
This could set up a memory leak condition, as the memory for such objects may
never be freed back to Perl if references to them exists inside attributes of
other objects. You're really better off using the ID string and storing that
instead. You can always use L<Find()|"Retrieving a previously created object">
to retrieve the object reference again later.

The hard ones are references to other arbitrary object classes. This involves
a bit more work.

First, before you do anything, you must register the class. This gives the
Games::Object module information on how to deal with objects of this class
in terms of manipulating its data. This will require that the object class
in question:

=over 4

=item *

Assign a unique ID to each object, much in the same way that Games::Object
does.

=item *

Provide an object method for retrieval of an object's ID, as well as a class
method to convert an ID back to a reference.

=item *

Provide methods for loading and saving object data at the point in the file
where it is stored in the attribute. This means the load method must properly
create and bless the object.

=back

Thus this is not for the faint of heart. Registering a class requires calling
the C<RegisterClass> function like so:

    RegisterClass(-class => "Your::Class::Name");

This is the simplest way to register a class, and makes broad assumptions
about the names of the methods and functions, specifically:

=over 4

=item *

The object method to retrieve the Id of an object is C<id()>, which is called
with no arguments.

=item *

The class method to find a reference given an ID is C<Find()>, which is called
with a single argument (the ID string).

=item *

The class method to load an object is C<load()>, which is called with the
I<-file> parameter as the Games::Object method would be.

=item *

The object method to save an object is C<save()>,.

=back

These assumptions can be modified with extra parameters to C<RegisterClass()>:

=over 4

=item -id

Specify the name of the ID object method.

=item -find

Specify the name of the object find class method.

=item -load

Specify the name of the object load class method.

=item -save

Specify the name of the object save object method.

=back

For example:

    RegisterClass(-class => "Some::Other::Class",
		  -id => "identifer",
		  -find => "toObject",
		  -load => "read",
		  -save => "write");

Once you have registered the class, you can now place references to these
objects inside your attributes in the following manner:

    $other_obj = new Some::Other::Class;
    $obj->new_attr(-name => "some_other_object",
		   -type => "object",
		   -class => "Some::Other::Class",
		   -value => $other_obj);

And you can modify an existing value with C<mod_attr()>:

    $obj->mod_attr(-name => "some_other_object",
		   -value => $another_obj);

But both C<new_attr()> and C<mod_attr()> give you a neat feature: you can
specify the I<-value> parameter as either the object reference, or the object
ID. If you give either one a non-reference, it will assume that this is the ID
of the object and call the find method behind the scenes to obtain the
real object reference.

=item Other attribute tricks

There are a few more things you can do with attributes at creation time.

Recall above that I stated that by default, if you assign a fractional value
to an attribute that is of type I<int> that it stores it as if calling
the Perl C<int()> function. Well, this behavior can be modified. You can
specify the I<-on_fractional> option when creating the attribute. This can be
set to one of "ceil", "floor", or "round". When a fractional
value results from an assignment or modification, the corresponding function
in the Perl POSIX module is called on the result. Example:

    $obj->new_attr(-name => "time",
		   -type => "int",
		   -on_fractional => "round",
		   -value => 0);

There's even more you can do with fractional amounts on integer attributes. You
can instruct the object to track the fractional component rather than just
throw it away. Retrieving the value will still result in an integer, which
by default is derived by C<int()>ing the factional value. For example, say
that an attribute is defined like this initially:

    $obj->new_attr(-name => "level",
		   -type => "int",
		   -track_fractional => 1,
		   -value => 1,
		   -maximum => 10);

Initially, retrieving the value will result in 1. Say you later add 0.5 to it.
Internally, 1.5 is stored, but 1 still results when retreiving the value. If
later the value becomes 1.99999, 1 is still returned. Only when it reaches 2.0
or better will 2 be returned.

You can combine I<-track_fractional> and I<-on_fractional>. In this case,
I<-on_fractional> refers to how the value is retrieved rather than how it is
stored. Say we change the above definition to:

    $obj->new_attr(-name => "level",
		   -type => "int",
		   -track_fractional => 1,
		   -on_fractional => "round",
		   -value => 1,
		   -maximum => 10);

Now if the internal value is 1.4, retrieving it will result in 1. But if the
internal value reaches 1.5, now retrieving the value will return 2.

=back

=head2 Fetching Attributes

An attribute's value is fetched with the C<attr()> method:

    $str = $obj->attr('strength');

This is subject to all the interpretations mentioned above, which is summarized
below:

=over 4

=item *

If the attribute is split, the current value is returned.

=item *

If the attribute is an integer tracking fractionals, an integer is still
returned, calculated according to the value of the I<-on_fractional> option
when the attribute was created.

=item *

If the attribute is mapped, and there is a valid entry in the map table, the
mapped value is returned.

=back

To retrieve the real value as opposed to the current value in a split
attribute, specify the string "real_value" as the second argument:

    $realhp = $obj->attr('hit_points', 'real_value');

This is still subject to rules of factionals and mapping. To completely
bypass all of this, retrieve the value with C<raw_attr()> instead:

    $rawlev = $obj->raw_attr('level');
    $rawlev_real = $obj->raw_attr('level', 'real_value');

An important note when dealing with attributes of datatype I<any> that are
array or hash references: When you use either C<attr()> or C<raw_attr()> (which
are effectively the same thing in this case), you get back the reference. This
means you could use the reference to modify the elements of the array or
keys of the hash. This is okay, but modifications will not generate events.
Here is an example (building on the example above for creating an attribute
of this type):

    $cskill = $obj->attr('combat_skill_levels');
    $cskill->{melee} ++;

=head2 Modifying Attributes

Modifying attributes is where a lot of the strengths of attributes lie, as the
module tries to take into account typical modifier situations that are found
in various games. For example, sometimes an attribute needs to be modified
only temporarily. Or a modification could be thwarted by some other outside
force and thus negated. And so on.

=over 4

=item Simple modifiers

A simple modifier is defined as a modification that occurs immediately and is
not "remembered" in any way. No provisions are made for preventing multiple
modifications within a given cycle, either through time or code. The value
of the attribute is changed and the deed is done.

There are two ways to perform a simple modification. One is to set the value
directly, which would be done as in the following examples:

    $obj->mod_attr(-name => "color", -value => "red");
    $obj->mod_attr(-name => "price", -value => 2.58);
    $obj->mod_attr(-name => "description", -value => "A piece of junk.");

If an attribute is split, this would set the current value only. The real
value could be set by using I<-real_value> instead of I<-value>:

    $obj->mod_attr(-name => "health", -real_value => 0);

The other way is to modify it relative to the current value. This is available
only to numeric types (I<int> and I<number>) as in these examples:

    $obj->mod_attr(-name => "hit_points", -modify => -4);
    $obj->mod_attr(-name => "strength", -modify => -1);

In these cases, -modify modifies the current value if the attribute is split.
To change the real value, you would use I<-modify_real> instead.

=item Persistent modifiers

A persistent modifier is one that the object in question "remembers". This
means that this modifier can later be cancelled, thus rescinding the
blessing (or curse) that it bestowed on this attribute.

Currently, this type of modifier is limited to numeric types, and must be
of the relative modifier type (via I<-modify> or I<-modify_real>). In addition,
it should be noted that the results of a persistent modifier are NOT applied
immediately. They are instead applied the next time the object is
C<process()>ed. That said, all that is needed to turn a modifier into a
persistent one is adding a I<-persist_as> option:

    $obj->mod_attr(-name => "strength",
		   -modify => 1,
		   -persist_as => "spell:increase_strength");

The value of I<-persist_as> becomes the ID for that modifier, which needs to be
unique for that object. The ID should be chosen such that it describes what
the modification is, if for no other reason than your programming sanity.

What happens now is that the next time C<process()> is called on the object,
the "strength" attribute goes up by 1. This modification is done once. In other
words, the next time after that that C<process()> is called, it does NOT go up
by another 1.

However, this does not mean you can't have it keep going up by 1 each time if
that's what you really wanted. In order to accomplish this effect, add the
I<-incremental> option:

    $obj->mod_attr(-name => "health",
		   -modify => 3
		   -persist_as => "spell:super_healing",
		   -incremental => 1);

In this example, the "health" attribute will indeed increment by 3 EVERY time
C<process()> is called.

There is another important difference between incremental and non-incremental
persistent modifiers. A non-incremental modifier's effect is removed when
the modifer is later cancelled. Thus in the above example, if the "strength"
modifier caused it to go from 15 to 16, when the modifier is removed, it will
drop back from 16 to 15. However, in the case of the incremental modifier,
the effects are permanent. When the "health" modifier goes away, it does not
"take away" the accumulated additions to the attribute.

Note that the effects of modifiers and tend-to rates are cumulative. This
needs to be taken into account to make sure modifiers are doing what you
think they're doing. For instance, if the idea is to add a modifier that
saps away health by -1 each time C<process()> is called, but the health
attribute has a I<-tend_to_rate> of 1, the net effect will simply be to cancel
out the tend-to, which may or may not be what you wanted. Future directions
for this module may include ways to automatically nullify tend-to rates.

Also note that modifiers are still subject to limitations via I<-minimum> and
I<-maximum> options on the attribute.

=item Self-limiting modifiers

It was noted above that persistent modifiers stay in effect until they are
purposely cancelled. However, you can set up a modifier to cancel itself after
a given amount of time by adding the I<-time> option:

    $obj->mod_attr(-name => "wisdom",
		   -modify => 2,
		   -persist_as => "spell:increase_wisdom",
		   -time => 10);

In this case, -time refers to the number of times C<process()> is called (rather
than real time). The above indicates that the modification will last through
the next 10 full calls to C<process()>. These means that after the 10th call
to C<process()>, the modification is still in effect. Only when the 11th
call is made is the modifier removed.

A self-limiting modifier can still be manually cancelled like any other
persistent modifier.

=item Delayed-action modifiers

A persistent modifier, either one that is timed or not, can be set up such
that it does not take effect for a given number of iterations through the
C<process()> method. This is done via the I<-delay> option, as in this example:

    $obj->mod_attr(-name => "health",
		   -modify => -5,
		   -incremental => 1,
		   -persist_as => "food_poisoning",
		   -time => 5,
		   -delay => 3);

This means: For the next 3 calls to C<process()>, do nothing. On the 4th,
begin subtracting 5 from health for 5 more times through C<process()>. The
last decrement to health will take place on the 8th call to C<process()>. On
the 9th call, the modifier is removed.

Note that while this example combined I<-delay> with I<-time> and
I<-incremental> to show how they can work together, you do not have to combine
all these options.

A delayed-action modifier can be cancelled even before it has taken effect.

=item Cancelling persistent modifiers

Any persistent modifier can be cancelled at will. There are two ways to cancel
modifiers. One is to cancel one specific modifier:

    $obj->mod_attr(-cancel_modify => 'spell:increase_wisdom');

Note that the I<-name> parameter is not needed. This is because this information
is stored in the internal persistent modifier. You only need the ID that you
specified when you created the modifier in the first place.

Or, you can choose to cancel a bunch of modifiers at once:

    $obj->mod_attr(-cancel_modify_re => '^spell:.*');

The value of the I<-cancel_modify_re> option is treated as a Perl regular
expression that is applied to every modifier ID in the object. Each that matches
will be cancelled. Any matching modifiers on that object will be cancelled,
no matter what attribute they are modifying. This makes it easy to cancel
similar modifiers across multiple attributes.

For each non-incremental modifier that is cancelled, C<mod_attr()> will reverse
the modification that was made to the attribute, but not right away. It will
instead take place the next time C<process()> is called. To override this
and force the change at the very moment the cancellation is done, include
the I<-immediate> option set to true, as in this example:

    $obj->mod_attr(-cancel_modify_re => '^spell:.*',
		   -immediate => 1);

=back

=head2 The I<-force> option

Any modification of an attribute via C<mod_attr()> may take the I<-force>
option. Setting this to true will cause the modifier to ignore any bounds
checking on the attribute value. In this manner you can force an attribute
to take on a value that would normally be outside the range of the attribute.

For example, the following modification would force the value of the attribute
to 110, even though the current maximum is 100:

    $obj->new_attr(-name => "endurance",
		   -value => 90,
		   -minimum => 0,
		   -maximum => 100);
    ...
    $obj->mod_attr(-name => "endurance",
		   -modify => 20,
		   -persist_as => "spell:super_endurance",
		   -force => 1);

=head2 Modifying attribute properties

Various properties of an attribute normally set at the time the attribute is
created can be modified later. These changes always take effect immediately and
cannot be "remembered". The general format is:

    $obj->mod_attr(-name => ATTRNAME,
		   -PROPERTY => VALUE);

where PROPERTY is one of "minimum", "maximum", "tend_to_rate", "on_fractional",
"track_fractional", "out_of_bounds".

=head1 Events

=head2 Callback programming model

This section shows you how you can set up code to trigger automatically when
changes take place to objects. First, however, you must understand the concept
of "callback programming".

Callback programming is a technique where you define a chunk of code not to
be run directly by you, but indirectly when some external event occurs. If
you've ever done any graphics or signal programming, you've done this before.
For instance, in Tk you might define a button to call some arbitrary code
when it is pressed:

    $mainw->Button(
	-text	=> "Press me!",
	-command => sub {
	    print "Hey, the button was pressed!\n";
	    ...
	},
    )->pack();

Or you may have set up a signal handler to do something interesting:

    sub stop_poking_me
    {
	my $sig = shift;
	print "Someone poked me with signal $sig!\n";
    }

    $SIG{TERM} = \&stop_poking_me;
    $SIG{INT} = \&stop_poking_me;

These are examples of callback programming. Each example above defines a set
of code to be run when a particular condition (or "event") occurs. This is
very similar to the way it works in Games::Object, except you're dealing with
events that have to do with Game::Object entities. There is only one crucial
difference, which has to do with the way the module is structured, as you'll
see in the next section.

=head2 Registering an event handler

In order to deal with an event, you must define what is referred to as an
"event handler". But rather than a function or arbitrary CODE block, you are
required to specify a method name, i.e. a method that you have written in
your subclass to handle the event. Here is an example of registering an
event to deal with the modification of an attribute using the
C<RegisterEvent()> function:

    RegisterEvent('attrValueModified', 'attr_modified');

Your I<attr_modified> method would then look something like this:

    sub attr_modified {
	my $obj = shift;
	my %args = @_;

	...
    }

The I<$obj> variable would contain the reference to the object that was
affected (in this case, by an attribute value modification). I<%args> would
contain a series of parameters that describe the event that took place. While
most of the parameters will vary according to the event that was generated,
one parameter will be the same for each one. I<event> will be set to the
name of the event in question. In the above example, this would be
"attrValueModified".

=head2 List of events and parameters

The following is a list of events and the parameters that are passed to the
event handler:

=over 4

=item attrValueModified

This is invoked when the value (the current value in a split attribute) is
modified by whatever means. The event is generated at the time that the
value actually changes; thus adding a persistent modifier will not generate
the event until the modifier is actually applied.

The parameters passed are:

=over 4

=item name

Name of the attribute that was modified.

=item old

The old value of the attribute before it was modified.

=item new

The new value after it was modified.

=back

=item attrRealValueModified

This is the same as I<attrValueModified> except that it is invoked when the
real value rather than the current value of a split attribute is modified.
It is subject to the same rules as I<attrValueModified> and also has the
same parameters.

=item attrValueOutOfBounds

This event occurs when an attribute value (current value in a split attribute)
has been forced to take on a value outside its normal minimum and maximum,
generally through the use of the I<-force> option in a call to C<mod_attr>.
This is ONLY called when a value actually goes out of bounds, not every time
I<-force> is used. The modification has to actually result in a value that
is outside the bounds.

The following parameters are passed to the handler:

=over 4

=item name

The name of the attribute that went out of bounds.

=item old

The old value of the attribute prior to modification.

=item new

The new value of the attribute after modification.

=back

=item attrRealValueOutOfBounds

This is the same as I<attrValueOutOfBounds>, except for the real value of a
split attribute. It is subject to the same rules and conditions as
I<attrValueOutOfBounds>, and the parameters passed are the same.

=item attrValueAttemptedOutOfBounds

This event occurs when a modification of an attribute would have resulted in
an out of bounds value had the issue been forced, but in reality the value
was kept within the bounds of the attribute's defined range. Note that this
event is generated only if the attribute was defined with an I<-out_of_bounds>
option of "use_up" (which is the default). If it was defined as "ignore",
then this event will never be generated.

The following parameters are passed to the event handler:

=over 4

=item name

The name of the affected attribute.

=item old

The old value of the attribute. It is possible that this may be the same as
the new value, if the modification was attempted when the value was already
pegged at the boundary.

=item new

The new value of the attribute, which will be at one of the bounds.

=item excess

This is the excess amount that was not applied to the attribute due to the
boundary condition.

=back

=item attrRealValueAttemptedOutOfBounds

This is the same as I<attrValueAttemptedOutOfBounds>, except for the real
value of a split attribute. This is subject to the same rules and conditions
as I<attrValueAttemptedOutOfBounds>, and the parameters passed to the handler
are the same.

=item flagModified

This is generated when the flag on an object changes value, via either the
C<set()> or C<clear()> methods. It is generated ONLY if the flag actually was
modified; doing a C<set()> on a flag that is already set, or C<clear()> on
one that is already cleared will not generate an event.

The following parameters are passed to the handler:

=over 4

=item flag

The flag that was modified.

=item old

The old value of the flag (either 1 or 0 for true or false, respectively);

=item new

The new value of the flag (either 1 or 0 for true or false, respectively);

=back

When you register an event, you can choose to add your own arguments that
will be passed to the event handler. This is done by specifying these arguments
after the name of the handler in the call to C<RegisterEvent()>:

    RegisterEvent('attrValueModified', 'attr_modified',
		  foo => 'bar', this => 'that');

The values that can be passed in this manner are subject to the same rules
as the I<any> attribute data type. This means they can be simple scalars
or references to Games::Object-subclassed objects, or complex data structures
that ultimately result in simple scalars or Games::Object-subclassed objects.
This is so that queued events can be properly C<save()>d to a file.

=back

=head1 Processing objects

=head2 Processing a single object

In order for events, persistent modifiers, and tend-to rate calculations to
be performed on an object, the object in question must be processed. This is
done by calling the C<process()> method, which takes no arguments:

    $obj->process();

What this method really is is a wrapper around several other object methods
and function calls that are invoked to perform the invidual tasks involved
in processing the object. Specifically, C<process()> performs the following
sequence:

=over 4

=item process_queue

This processes all queued actions for this object. These actions are generally
events generated after the previous call to C<process()> completed, deferred
attribute modifications, and changes to attributes resulting from
cancelled persistent modifiers.

If event handlers perform actions that themselves generate more events, these
events get added to the end of the queue, and will also be processed until the
queue is empty. However, it is easy to see how such an arrangement could lead
to an infinite loop (event handler A generates event B, event handler B is
queued, event handler B generates event A, event handler A is queued,
event handler A generates event B ...). To prevent this, C<process_queue()>
will not allow the same action to execute more than 100 times by default on
a given call. If this limit is reached, a warning is issued to STDERR and
any further invokations of this action are ignored for this time through
C<process_queue()>.

=item process_pmod

This processes all persistent modifiers in the order that they were defined
on the object. Changes to attributes resulting from this processing may
generate events that cause your event handlers to be queued up again for
processing.

The default order that modifiers are processed can be altered. See the
section L<"Attribute modifier priority"> for further details.

=item process_tend_to

This processes all split attributes' tend-to rates in no particular order.
Like the previous phase, this one can also generate events based on attribute
changes.

You can exert some control over the order in which attributes are processed
in this phase. See section L<"Attribute tend-to priority"> for details.

=item process_queue

This is a repeat of the first phase to handle the events that were generated
during the previous two phases. It acts exactly like the first phase in that
it processes the queue until it is exhausted, and will not allow a method
to be executed more than a given number of times.

=back

=head2 Timing issues

There is one timing issue with the way events are processed in the default
C<process()> phase list.

Note that C<process_queue()> is called twice, once at the start and again at
the end. Your event handlers could potentially call C<mod_attr()> and add
a new persistent modifier. If the modifier is added as a result of an event
handler executed in the first call to C<process_queue()>, the modifier will
be processed this time through C<process()>. But if the modifier is instead
added during the second call to C<process_queue()>, then the modifier will
not be considered until the NEXT call to C<process()>.

This problem is considered to be a design flaw. Expect this to change in
later versions of this module. In the meantime, you can affect a workaround
by modifying the processing list for C<process()>, which is coming up in
the subsection L<"Modifying the default process sequence">.

=head2 Processing all objects

More likely than not, you are going to want to process all the objects that
have been created in a particular game at the same time. This can be done
with the C<Process()> function:

    Process();

That's all it takes. This will go through the list of objects (in no particular
order by default - see section L<"Priorities"> for details on changing this)
and call the C<process()> method on each.

The nice thing about C<Process()> is that it is a generic function. With
no arguments, it calls the C<process()> method. However, if you give it a
single argument, it will call this method instead. For example, say you
defined a method in your subclass called I<check_for_spells()>, and you wish
to execute it on every object in the game. You can call C<Process()> thusly:

    Process('check_for_spells');

Then there is yet one more form of this function call that allows you to
not only call the same method on all objects, but pass arguments to it as
well. For instance, here's how you can achieve a save of your game in one
command (assuming a file has been opened for the purpose in *SAVEFILE):

    Process('save', -file => \*SAVEFILE);

The C<Process()> function returns the number of objects that were processed,
which is the number of objects in the game as a whole.

=head2 Modifying the default process sequence

There are two ways to do this. The first is you can define your own
C<process()> method in your subclass, overriding the built-in one, and
thus call the other methods (and/or methods of your own devising) in any order
you choose.

Another way you can do it is by altering the internal list that Games::Object
uses to determine what methods to call. This can be done with the
C<SetProcessList()> function. For example, if you wished to remove processing
of events from the initial phases and reverse the order of processing persistent
modifiers and tend-to rates, you could make the following call:

    SetProcessList('process_tend_to', 'process_pmod', 'process_queue');

Note that these method calls can either be ones in Games::Object, or they can
be ones that you define. You have complete control over exactly how your
objects get processed.

=head1 Priorities

=head2 Object priority

Each object has what is called a priority value. This value controls what
order the object is processed in relation to the other objects when the
C<Process()> function is called. When an object is first created new (as opposed
to loading from a file, where it would get its priority there), it has a default
priority of 0. This default can be modified via the C<priority()> method:

    $obj->priority(5);

The higher the priority number, the further to the head of the list the object
is placed when C<Process()> is called. For example, say you created a series
of objects with IDs "Player1", "RedDragon", "PurpleWorm", "HellHound", and
then performed the following:

    Find('Player1')->priority(5);
    Find('RedDragon')->priority(3);
    Find('PurpleWorm')->priority(3);
    Find('HellHound')->priority(7);

If you then called C<Process()>, first the 'HellHound' object would be
processed, then the 'Player1' object, then the 'RedDragon' and 'PurpleWorm'
objects (but in no guaranteed or reproducible order). Assuming that all other
objects have a default priority, they would be processed at this point (again,
in no particular order).

Object priority can be changed at will, even from a user action being
executed from within a C<Process()> call (it will not affect the order that
the objects are processed this time around). The current priority of an object
can be obtained by specifying C<priority()> with no arguments.

Object priority can be a nice way of defining initiative in dungeon-type games.

=head2 Attribute tend-to priority

By default, tend-to rates on attributes are processed in no particular order
in C<process_tend_to()>. This can be changed by specifying a I<-priority>
value when creating the attribute in question. For example:

    $obj->new_attr(-name => "endurance",
		   -value => 100,
		   -minimum => 0,
		   -maximum => 100,
		   -tend_to_rate => 1,
		   -priority => 10);

The priority can also be later changed if desired:

    $obj->mod_attr(-name => "endurance",
		   -priority => 5);

The higher the priority, the sooner it is processed. If a I<-priority> is
not specified, it defaults to 0. Attributes with the same priority do not
process in any particular order that can be reliably reproduced between
calls to C<process_tend_to()>.

=head2 Attribute modifier priority

By default, persistent attribute modifiers are executed in C<process_pmod()>
in the order that they were created. This is can be altered when the modifier
is first created by adding the I<-priority> parameter. For example:

    $obj->mod_attr(-name => "health",
		   -modify => 2,
		   -incremental => 1,
		   -persist_as => "ability:extra_healing",
		   -priority => 10);

Assuming that other modifiers are added with the default priority of 0, or
with priorities less than 10, this guarantees that the modifier above
representing healing will execute before all other modifiers (like, for
example, that -15 health modifier from one angry red dragon ...).

The only drawback is that a modifier priority is currently set in stone when
it is first added. To change it, you would have to add the same modifier
back again in its entirety. This will probably be changed in a future release.

=head1 Queueing arbitrary actions

As explained above, there are many places where actions are queued up in an
object for later execution, such as when events are triggered, or persistent
modifiers are added. The module uses the C<queue()> method to accomplish
this, and you can use this method as well to queue up arbitrary actions. The
caveat is the same with events, that the action must be a method name defined
in your module.

The C<queue()> method takes the action method name as the first parameter,
followed by any arbitrary number of parameters to be passed to your method.
For example, if you were to make the following call:

    $obj->queue('kill_creature', who => 'Player1', how => "Dragonsbane");

Then when C<process_queue()> is next called on this object, the Games::Object
module will do the following:

    $obj->kill_creature(who => 'Player1', how => "Dragonsbane");

Your method would look something like this:

    sub kill_creature
    {
	my $obj = shift;
	my %args = @_;
	my $obj_who = Games::Object::Find($args{who});
	my $obj_how = Games::Object::Find($args{how});

	$obj_who->mod_attr(-name => "experience",
			   -modify => $obj->attr('kill_xp') +
				      $obj_how->attr('use_for_kill_xp') );
	...
    }

Of course, you don't have to use C<queue()> to execute a particular method
in your class. Use C<queue()> only if you're specifically looking to defer
the action until the next time C<process()> is called on the object, for the
purposes of synchronization.

=head1 Saving object data to a file

This is one of the more powerful features of Games::Object. This essentially
provides the functionality for a save-game action, freeing you from having
to worry about how to represent the data and so on.

Saving the data in an object is simple. Open a file for write, and then
call the C<save()> method on the object:

    $obj->save(-file => \*SAVEFILE);

You can pass it anything that qualifies as a file, so long as it is opened
for writing. Thus, for example, you could use an IO::File object. Essentially
anything that can be used between <> in a I<print()> statement is valid.

All the objects in the game can be easily saved at once by using the
C<Process()> function:

    Process('save', -file => \*SAVEFILE);

Loading a game could be accomplished by simply reading a file and creating
new objects from it until the file is empty. Here is a code snippet that would
do this:

    open(LOADFILE, "<./game.save") or die "Cannot open game save file\n";
    while (!eof(LOADFILE)) {
	my $obj = new Games::Object(-file => \*LOADFILE);
    }
    close(LOADFILE);

Note something about the above code: We called the constructor for the
Games::Object class, NOT your subclass. This is because on a C<save()>, the
subclass is saved to the file, and when the object is re-created from the file,
the Games::Object constructor is smart enough to re-bless it into your subclass.
This means you can define more than one subclass from Games::Object and
freely mix them in your game.

=head1 EXAMPLES

Please refer to specific sections above for examples of use.

Example data was chosen to approximate what one might program in a game, but
is not meant to show how it B<should> be done with regards to attribute names
or programming style. Most names were chosen out of thin air, but with at
least the suggestion of how it might look.

=head1 WARNINGS AND CAVEATS

This is currently an alpha version of this module. Interfaces may and
probably will change in the immediate future as I improve on the design.

If you look at the code, you will find some extra functionality that is not
explained in the documentation. This functionality is NOT to be considered
stable. There are no tests for them in the module's test suite. I left it out
of the doc for the alpha release until I have had time to refine it. If you
find it and want to use it, do so at your own risk. I hope to have this
functionality fully working and documented in the beta.

=head1 BUGS

Oh, plenty, I'm sure.

=head1 TO DO

Attributes currently cannot be deleted once added to an object.

There needs to be an option to mod_attr() that forces a persistent mod to
take effect immediately.

Cloning an object would be useful functionality to have.

Modifier cancel functionality needs improvement. There's no provision to check
for the case of where the attribute was already at max/min before it was
applied; in such a case, rescinding the modifier should rescind only what
was applied, if any.

Need to expand event functionality. I would like to model it like Tk's
bind() method. For example, I'd like to be able to register an event
handler for an attrValueModified for a specifically-named attribute, while
at the same time still retaining the functionality of defining an event handler
for the much broader case.

Processing order for objects in C<Process()> needs to be more consistent with
attribute persistent mods. The former has no defined order when priorities
are the same, while the latter specifies the order in which the mods were
added. What might be nice would be a way to choose a truly random order
for processing.

There needs to be a way to "encode" the game save data. Right now its in
clear ASCII, which would make it easy to cheat.

A form of "undo" functionality would be WAY cool. I have something like this
in another (but non-CPAN) module. I just need to port it over.

=cut
