package Games::Object;
require 5.6.0;

use strict;
use Exporter;

use Carp qw(carp croak);
use POSIX;
use IO::File;

use vars qw($VERSION @EXPORT_OK %EXPORT_TAGS @ISA);

$VERSION = "0.04";
@ISA = qw(Exporter);
@EXPORT_OK = qw(TotalObjects CreateFlag ModifyFlag Find Id RegisterEvent Process
		SetProcessList FetchParams RegisterClass IsClassRegistered
		OBJ_CHANGED OBJ_AUTOALLOCATED OBJ_PLACEHOLDER OBJ_DESTROYED
		ATTR_STATIC ATTR_DONTSAVE ATTR_AUTOCREATE EVENT_NULL_CALLBACK);
%EXPORT_TAGS = (
    functions		=> [qw(TotalObjects Flag Find Id RegisterEvent Process
			       SetProcessList FetchParams
			       RegisterClass IsClassRegistered)],
    objflags		=> [qw(OBJ_CHANGED OBJ_AUTOALLOCATED
			       OBJ_PLACEHOLDER OBJ_DESTROYED)],
    attrflags		=> [qw(ATTR_STATIC ATTR_DONTSAVE ATTR_AUTOCREATE)],
    all			=> [qw(:functions :objflags :attrflags)],
);

# Define some attribute flags.
use constant ATTR_STATIC	=> 0x00000001;
use constant ATTR_DONTSAVE	=> 0x00000002;
use constant ATTR_AUTOCREATE	=> 0x00000004;

# Define object flags (internal)
use constant OBJ_CHANGED        => 0x00000001;
use constant OBJ_AUTOALLOCATED  => 0x00000002;
use constant OBJ_PLACEHOLDER    => 0x00000004;
use constant OBJ_DESTROYED      => 0x00000008;

# Define the null callback string.
use constant EVENT_NULL_CALLBACK	=> '__NULL_CALLBACK__';

# Define the ID of the global object
use constant GLOBAL_OBJ_ID	=> 'Games::Object::__GLOBAL__';

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
# [ NOT YET IMPLEMENTED ]
my $obj_reclaim = 1;
my $obj_avail = 0;

# Track the highest priority object so that we can insure the global object
# is higher.
my $highest_pri = 0;

# Define storage for user-defined object flags.
my %user_flag = ();

# Define a table that shows what order process() is supposed to do things.
my @process_list = (
    'process_queue',
    'process_pmod',
    'process_tend_to',
);

# Define a limit to how many times the same item can be processed in a queue
# (see process_queue() for details)
my $process_limit = 100;

####
## INTERNAL FUNCTIONS

# Round function provided for the -on_fractional option

sub round { int($_[0] + 0.5); }

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
	} elsif ($ref && UNIVERSAL::isa($data, 'Games::Object')) {
	    # Save the ID of the object.
	    print $file "G " . $data->id() . "\n";
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
	my $val = substr($line, 2) if ($tag ne 'U'); # Avoid substr warning
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
	} elsif ($tag eq 'G') {
	    # A Games::Object-subclassed object
	    my $obj = Find($val);
	    if (!$obj) {
		# This object may not have been loaded yet. So we create a
		# placeholder for it.
		$obj = Games::Object->new(-id => $val);
		$obj->_set(OBJ_PLACEHOLDER);
	    }
	    $obj;
	} else {
	    # Anything else is unrecognized.
	    croak("Unknown tag '$tag' in file, file may be corrupted");
	}

}

####
## FUNCTIONS

# Fetch the global object. Create it if it does not yet exist.

sub GlobalObject
{
	my $obj = Find(GLOBAL_OBJ_ID);

	$obj = Games::Object->new(-id => GLOBAL_OBJ_ID) if (!defined($obj));
	$obj->{priority} = $highest_pri + 1;
	
	$obj;
}

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

		# Must be reference to an IO::File or FileHandle object
		croak("Param '$name' must be a file (IO::File/" .
			"FileHandler object or GLOB reference acceptable)")
		  if (ref($res->{$oname}) !~ /^(IO::File|FileHandle|GLOB)$/);

	    } elsif ($rstr eq 'readable_filename' ) {

		# Must be the name of a file that exists and is readable.
		croak("Filename '$res->{$oname}' does not exist")
		    if (! -f $res->{$oname});
		croak("Filename '$res->{$oname}' is not readable")
		    if (! -r $res->{$oname});

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

# Return the number of objects in the universe.

sub TotalObjects { scalar keys %obj_index; }

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

# "Find" an object (i.e. look up its ID). If given something that is
# already a valid object, validates that the object is still valid. If the
# assertion flag is passed, an invalid object will result in a fatal error.

sub Find
{
	shift if ($_[0] eq __PACKAGE__);
	my ($id, $assert) = @_;

	$id = $id->{id} if (ref($id) && UNIVERSAL::isa($id, __PACKAGE__));
	if (defined($obj_index{$id})) {
	    $obj_index{$id};
	} elsif ($assert) {
	    my ($pkg, $file, $line) = caller();
	    croak "Assertion failed: '$id' is not a valid object ID\n" .
		  "Called from $pkg ($file) line $line";
	} else {
	    undef;
	}
}

# Function version of id(). If given a reference, it will check that it is
# really a Games::Object (or derivative); if given something already an
# ID, it validates that the Id exists. Like Find(), this takes an assertion
# flag as well.

sub Id
{
	my ($obj, $assert) = @_;

	if (ref($obj) && UNIVERSAL::isa($obj, __PACKAGE__)) {
	    $obj->id();
	} elsif (defined($obj_index{$obj})) {
	    $obj;
	} elsif ($assert) {
	    my ($pkg, $file, $line) = caller();
	    croak "Assertion failed: '$obj' is not a valid object\n" .
		  "Called from $pkg ($file) line $line";
	} else {
	    undef;
	}
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

	# Note also that we make a special exception in the case of method
	# 'destroy'. In such a case, the global object gets shuffled to the
	# end of the list. Otherwise, we would destroy it first, and the
	# very next object would magically reinstantiate it when it attempted
	# to spawn an objectDestoyed event.
	my @objs = sort { $b->{priority} <=> $a->{priority} } values %obj_index;
	if ($method eq 'destroy' && $objs[0]->id() eq GLOBAL_OBJ_ID) {
	    my $top = shift @objs;
	    push @objs, $top;
	}
	foreach my $obj (@objs) {
	    $obj->$method(@args);
	}
	scalar(@objs);
}

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
	if (!defined($obj->{pmod})) {
	    $obj->{pmod} = {};
	    $obj->{pmod_next} = 0;
	    $obj->{pmod_active} = 0;
	}

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

	# Look for snapshots of attributes that had been created with the
	# AUTOCREATE option and instantiate these, but ONLY if they do not
	# already exist (thus a load-in-place will not clobber them)
	foreach my $aname (keys %{$obj->{snapshots}}) {
	    if (!defined($obj->{attr}{$aname})) {
		my $attr = {};
		my $snapshot = $obj->{snapshots}{$aname};
		foreach my $key (keys %$snapshot) {
		    $attr->{$key} = (
			$key =~ /^(value|real_value)$/ ? (
			    ref($snapshot->{$key}) eq 'ARRAY' ? [ ] :
			    ref($snapshot->{$key}) eq 'HASH'  ? { } :
				$snapshot->{$key}
			) :
			$snapshot->{$key}
		    );
		}
		$obj->{attr}{$aname} = $attr;
	    }
	}

	# Make sure the ID is what we expect.
	$obj->{id} = $id;

	# Done. Rebless into this subclass and invoke any event binding
	# on the objectLoaded event.
	bless $obj, $subclass if ($subclass ne 'Games::Object');
	$obj->event('objectLoaded', $id, file => $file);
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

	# Invoke any event bindings.
	$obj->event('objectSaved', $obj->{id}, file => $file);

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
	    $obj->event('flagModified', $fname,
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
	    $obj->event('flagModified', $fname,
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
		$obj->event("attr${epart}Modified", $aname,
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
		    $obj->event("attr${epart}OutOfBounds", $aname,
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
			    $aname,
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
	    $obj->event("attr${epart}Modified", $aname,
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

	# Finally, if DONTSAVE and AUTOCREATE were used together, then
	# take a kind of "snapshot" of this attribute so it can be later
	# restored.
	if ( ($attr->{flags} & ATTR_DONTSAVE)
	  && ($attr->{flags} & ATTR_AUTOCREATE) ) {
	    my $type = $attr->{type};
	    my $snapshot = {};
	    foreach my $key (keys %$attr) {
		$snapshot->{$key} = (
		    $key =~ /^(value|real_value)$/	? (
		        $type =~ /^(int|number)$/	? (
			    defined($attr->{minimum})	?
				$attr->{minimum} : 0
			) :
		        $type eq 'string'		? '' :
		        $type eq 'any' &&
		          ref($attr->{$key}) eq 'ARRAY'	? [ ] :
		        $type eq 'any' &&
		          ref($attr->{$key}) eq 'HASH'	? { } :
		        undef
		    ) :
		    $attr->{$key}
	        );
	    }
	    $obj->{snapshots}{$aname} = $snapshot;
	}

	# Done.
	$obj;
}

# Delete an attribute.

sub del_attr
{
	my $obj = shift;
	my ($aname) = @_;

	# Do nothing if the attribute does not exist.
	return 0 if (!defined($obj->{attr}{$aname}));

	# Delete the attribute.
	delete $obj->{attr}{$aname};

	# Done.
	1;
}

# Check to see if an attribute exists.

sub attr_exists
{
	my $obj = shift;
	my ($aname) = @_;

	defined($obj->{attr}{$aname});
}

# Fetch value or properties of an attribute

sub attr
{
	my ($obj, $aname, $prop) = @_;
	$prop = 'value' if (!defined($prop));

	# Check to see if attribute exists.
	return undef if (!defined($obj->{attr}{$aname}));

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
	return undef if (!defined($obj->{attr}{$aname}));

	# Check to see if the property exists.
	my $attr = $obj->{attr}{$aname};
	croak("Attribute '$aname' does not have property called '$prop'")
	  if (!defined($attr->{$prop}));

	# Return the value of the property.
	$attr->{$prop};
}

# Fetch the reference to an attribute.

sub attr_ref
{
	my ($obj, $aname, $prop) = @_;

	$prop = 'value' if (!defined($prop));
	if (defined($obj->{attr}{$aname})) {
	    my $attr = $obj->{attr}{$aname};
	    defined($attr->{$prop}) ? \$attr->{$prop} : undef;
	} else {
	    carp "WARNING: Attempt to get reference to '$prop' of " .
		 "non-existent attribute '$aname'";
	    undef;
	}
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
	croak("Attempt to modify unknown attribute '$aname' " .
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
		    locked	=> 0,
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
## SPECIAL QUEUING INTERNAL METHODS

# Invoke a callback method of the format that would be specified for, say,
# an event, with optional addition args. Returns the return code of the callback
# method. If the callback passed is undef, returns 0.

sub _invoke
{
	my $obj = shift;
	my ($callbk, @moreargs) = @_;

	return 0 if (!defined($callbk));

	if (ref($callbk) eq 'ARRAY') {
	    # Check the first member of the array. If it is an object, then
	    # we're doing a proxy call. We invoke the callback on THIS
	    # object instead.
	    my @args = @$callbk;
	    if ($args[0] =~ /^Games::Object\((.+)\)$/) {
		my $pobj = Find($1);
		shift @args;
		my $meth = shift @args;
		$pobj->$meth(@args, @moreargs, object => $obj);
	    } else {
	        my $meth = shift @args;
	        $obj->$meth(@args, @moreargs);
	    }
	} else {
	    $obj->$callbk(@moreargs);
	}
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

# Bind an event to a corresponding action. This can actually be called as
# either an object or class method, depending on the scope of the action.

sub bind_event
{
	my $obj = shift;
	my ($key, $event, $callbk) = (
	    @_ == 1 ? ( '*', '*', $_[0] ) :
	    @_ == 2 ? ( '*', $_[0], $_[1] ) :
	    @_ == 3 ? @_ :
	    croak("Invalid number of arguments to bind_event()")
	);

	# If the class was specified, then we will be tying the binding to
	# the global object.
	$obj = GlobalObject() if (!ref($obj));

	# If the callback is an array and the first item is an object
	# reference, we want to convert this to something that will prevent
	# potential circular references.
	if (ref($callbk) eq 'ARRAY'
	&& UNIVERSAL::isa($callbk->[0], 'Games::Object') ) {
	    my $id = $callbk->[0]->id();
	    $callbk->[0] = "Games::Object($id)";
	}

	# Assign/delete the binding.
	if (!ref($callbk) && $callbk eq EVENT_NULL_CALLBACK) {
	    delete $obj->{binding}{$key}{$event};
	} else {
	    $obj->{binding}{$key}{$event} = $callbk;
	}

	1;
}

# Process an event.

sub event
{
	my ($obj, $event, $key, @args) = @_;

	# Events are never called directly on the global object.
	return 1 if ($event eq 'GLOBAL_OBJ_ID');

	my $gbl = GlobalObject();
	my $rc;

	# Add addition args.
	push @args, (
	    event	=> $event,
	    key		=> $key,
	);

	# Invoke all applicable callbacks.
	return $rc
	    if ($rc = $obj->_invoke($obj->{binding}{$key}{$event}, @args));
	return $rc
	    if ($rc = $obj->_invoke($gbl->{binding}{$key}{$event}, @args));
	return $rc
	    if ($rc = $obj->_invoke($obj->{binding}{'*'}{$event}, @args));
	return $rc
	    if ($rc = $obj->_invoke($gbl->{binding}{'*'}{$event}, @args));
	return $rc
	    if ($rc = $obj->_invoke($obj->{binding}{'*'}{'*'}, @args));
	return $rc
	    if ($rc = $obj->_invoke($gbl->{binding}{'*'}{'*'}, @args));
	0;
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

# Fetch/set priority of object. Note that you cannot set the priority of
# the global object, as this is controlled internally.

sub priority
{
	my $obj = shift;

	if (@_) {
	    if ($obj->id() eq GLOBAL_OBJ_ID) {
		carp "Cannot set priority of global object";
		return undef;
	    }
	    my $pri = shift;
	    if ($pri >= $highest_pri) {
		$highest_pri = $pri;
		my $global = Find(GLOBAL_OBJ_ID);
		$global->{priority} = $highest_pri + 1 if ($global);
	    }
	    my $oldpri = $obj->{priority};
	    $obj->{priority} = $pri;
	    $oldpri;
	} else {
	    $obj->{priority};
	}
}

####
## DESTRUCTORS

# Destroy the object and remove it from the internal table. The caller can
# pass in optional arbitrary parameters that are passed to any event binding.

sub destroy
{
	my $obj = shift;

	# This next statement will prevent a "double-destroy", as this method
	# is called again when the final reference is undefed.
	return if (!defined($obj->{id}));

	# Trigger event BEFORE deletion so that the event code can examine
	# the object
	my $id = $obj->{id};
	$obj->event('objectDestroyed', $id, @_);

	# Delete all keys so that it can no longer be used.
	foreach my $key (keys %$obj) {
	    delete $obj->{$key};
	}

	# Remove from internal table.
	delete $obj_index{$id};
}

1;
