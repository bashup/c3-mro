# c3-mro

This document is the source code, API documentation, and test suite for [c3-mro](bin/c3-mro).

The source is compiled using [mdsh](https://github.com/bashup/mdsh), with this configuration:

```bash @mdsh
@module "c3-mro.md"
@require pjeby/license @comment LICENSE
```

The test suite is run using [cram](https://github.com/pjeby/cram), using test code blocks that look like this:

~~~sh
  $ source c3-mro
~~~

## Contents

<!-- toc -->

- [Overview](#overview)
  * [Terms and Concepts](#terms-and-concepts)
  * [Implementation Details](#implementation-details)
- [Method Dispatching](#method-dispatching)
  * [c3::call *mro method args...*](#c3call-mro-method-args)
  * [c3::super *mro method-set method args...*](#c3super-mro-method-set-method-args)
  * [c3::invoke *mro method args...*](#c3invoke-mro-method-args)
  * [c3::find-method *mro method*](#c3find-method-mro-method)
  * [c3::unknown-method *mro method args...*](#c3unknown-method-mro-method-args)
- [MRO Generation](#mro-generation)
  * [c3::resolve *name [bases...]*](#c3resolve-name-bases)
  * [c3::mixin *varname method-set-names...*](#c3mixin-varname-method-set-names)
  * [c3::merge *mros...*](#c3merge-mros)
- [Code Generation](#code-generation)
  * [c3::defun *name body*](#c3defun-name-body)
  * [c3::methods-changed](#c3methods-changed)
  * [c3::undef *funcname...*](#c3undef-funcname)
  * [c3::exists *funcname*](#c3exists-funcname)

<!-- tocstop -->

## Overview

### Terms and Concepts

c3-mro exists to 1) look up and invoke methods using an appropriate method resolution order (MRO), and 2) optionally compute and record the MRO for method sets that inherit from other method sets, so they can be used for later lookups or further inheritance.

A *method set* is a (possibly empty) collection of *methods*, which your framework can use to implement classes, types, prototypes, instances, traits, mixins or whatever other kinds of method sets your framework needs.

A *method* is a bash function whose name is a method set name, followed by `::` and a method name.  (A method set can therefore have any name that is legal as a bash function name prefix, and method names can be anything that is legal as the suffix of a bash function name.)

A *method resolution order* or MRO is a sequence of method set names, represented as a bash string with `<>` around each name (e.g. `"<foo><bar>"`), and *no* whitespace or other punctuation.  You do not generally need to manually construct MRO strings or inspect their contents, though, since that's c3-mro's job!  You just need to keep track of the difference between a method set name (e.g. `"foo"`) and the MRO of that method set (e.g. `"<foo><bar>"`), so that you pass the right kinds of strings for the c3 APIs you're calling.

### Implementation Details

c3-mro itself is implemented as a method set (`c3`), so all its function names begin with `c3::`.  It also reserves a few global bash variables (associative arrays):

- `c3_mro` maps from method set names to their computed method resolution order, based on the last `c3::resolve` call for that method set name
- `c3_cache` is a method lookup cache, that avoids the need for repeated searches looking for the same method in a given MRO.
- `c3_seen` is an associative array tracking methods whose existence (or lack thereof) has affected the contents of `c3_cache`.  If a method named in it is created or deleted, it means the cache is no longer valid and must be cleared (via `c3::methods-changed`)

In case of repeated sourcing or duplicate inclusion of c3-mro, the cache variables are reset to empty (to avoid stale entries), but c3_mro is declared without any specific content, so that existing data won't be lost:

```bash @shell
declare -gA c3_mro c3_cache=() c3_seen=()
```

~~~sh
# Initially, all arrays are empty

  $ dump-tables c3_mro c3_cache c3_seen
  
  c3_mro  []
  ------  --
  
  c3_cache  []
  --------  --
  
  c3_seen  []
  -------  --

# Populate them by declaring inheritance and doing a lookup

  $ c3::resolve foo bar
  $ bar::baz(){ :;}
  $ c3::find-method "${c3_mro[foo]}" baz
  $ dump-tables c3_mro c3_cache c3_seen
  
  c3_mro  []
  ------  ----------
  bar     <bar>
  foo     <foo><bar>
  
  c3_cache       []
  -------------  --------
  baz<bar>       bar::baz
  baz<foo><bar>  bar::baz
  
  c3_seen   []
  --------  --
  bar::baz  
  foo::baz  

# Sourcing a second time clears the cache but not the MROs

  $ source c3-mro
  $ dump-tables c3_mro c3_cache c3_seen
  
  c3_mro  []
  ------  ----------
  bar     <bar>
  foo     <foo><bar>
  
  c3_cache  []
  --------  --
  
  c3_seen  []
  -------  --
~~~

## Method Dispatching

The core function of c3-mro is converting messages (a method name + arguments) into method (function) calls.  As it's done so often, it's extremely performance critical.  So c3-mro keeps a global method cache, keyed by method name and MRO.  This allows most dispatches to happen in roughly constant time, no matter how many method sets are in an MRO or how deeply buried in it a given method is.  So all of these dispatch methods try to look up a `c3_cache` entry for the target method name + MRO before doing anything more complex.  This makes repeated method calls extremely fast.

Of the APIs in this category, most frameworks will only need to use `c3::call` and `c3::super`, and to supply their own error handler (or dynamic lookup feaure) to replace `c3::unknown-method`.

### c3::call *mro method args...*

Find the first method of a method set in *mro* named *method* and invoke it with *args*.  If no such method exists, `c3::unknown-method` method is called with *mro method args...*.  You can override that function to control how unknown methods are handled (to do e.g. delegation, error messages, dynamic method generation etc.)

```bash @shell
c3::call(){ ${c3_cache["$2$1"]-c3::invoke "$1" "$2"} "${@:3}";}
```

### c3::super *mro method-set method args...*

Invoke the next available version of *method* in the subset of *mro* that follows *method-set*, if such a method exists.  If *method-set* is not present in *mro*, all method sets in *mro* are searched.

```bash @shell
c3::super(){ : "${1#*<$2>}"; ${c3_cache["$3$_"]-c3::invoke "$_" "$3"} "${@:4}";}
```

### c3::invoke *mro method args...*

This function is basically the same as `c3::call`, except slightly slower: it's the function that `c3::call` and `c3::super` fall back to if they get a cache miss.  So there is no reason to call it directly (unless perhaps you're writing a cache-optimized inlining of one of those other functions).

```bash @shell
c3::invoke(){ REPLY= c3::find-method "$1" "$2"; ${c3_cache["$2$1"]-c3::unknown-method "$1" "$2"} "${@:3}";}
```

### c3::find-method *mro method*

Return true if any method set in *mro* has a method named *method*, with `$REPLY` set to the method's full function name.  Successful results are cached for future use.  (Note: `$REPLY` is modified even if the lookup fails.)

Search occurs recursively, checking and updating the cache at each level of descent, thereby speeding lookups for method sets with common parents.

Method names whose existence is checked are cached in `c3_seen`, so that the cache can be invalidated if their state of existence changes.

```bash @shell
c3::find-method(){
	REPLY=("${c3_cache["$2$1"]-}");${REPLY:+return};REPLY=${1%%>*};REPLY=${REPLY#<}::$2
	c3_seen["$REPLY"]=
	if c3::exists "$REPLY"||{ [[ ${1#*>} ]]&& c3::find-method "${1#*>}" "$2";}
	then c3_cache["$2$1"]=$REPLY; else REPLY=; false; fi
}
```

### c3::unknown-method *mro method args...*

Hook for handling unknown methods when using `c3::call` and `c3::super`.

```bash @shell
c3::unknown-method(){ echo -n "Unknown method: $2 in $*; at ";caller 3;exit 70;} >&2
```

The default implementation of this function just prints an error message and exits with error 70 ([EX_SOFTWARE](https://man.freebsd.org/cgi/man.cgi?query=sysexits&sektion=3#DESCRIPTION)).  Most frameworks will want to replace it with a better error message at the least.  But you can also implement dynamic methods by looking up a different method name (similar to Python `__getattr__` or PHP `__call`), and then passing the method name and arguments to that method.

For example:

~~~sh
  $ proto(){ c3::resolve "$@"; c3::defun "$1" 'local this=$FUNCNAME; this "$@"';}
  $ this()  { c3::call  "${c3_mro["$this"]}" "$@";}

# Default behavior: error message, exit w/EX_SOFTWARE

  $ proto demo
  $ ( demo something 1 )
  Unknown method: something in <demo> something 1; at * (glob)
  [70]

# Custom framework handler for unknown method lookups

  $ c3::unknown-method(){
  >   if REPLY= c3::find-method "$1" unknown-method; then c3::call "$1" unknown-method "${@:2}"; else
  >       echo -n "Unknown method: $2 in $*; at "; caller 3; exit 70
  >   fi >&2
  > }

# Overridden behavior: same as before if no `unknown-method` method

  $ ( demo something 2 )
  Unknown method: something in <demo> something 2; at * (glob)
  [70]

# `unknown-method` method invoked if found

  $ demo::unknown-method(){ echo "got method $1; args = ${*:2}";}
  $ ( demo something 3 )
  got method something; args = 3
~~~

A replacement for this function can also inject data into the method cache, so that future calls can occur more quickly.  The cache entry for a method can even be set to something like `c3_cache["some-method<mset1><mset2>..."]="some-function some-arg..."` to pass arguments to the target, so long as the arguments themselves do not contain any whitespace or glob patterns.


## MRO Generation

### c3::resolve *name [bases...]*

Declare that *name* is a method set that inherits methods from the given *bases* (if any).  A method resolution order is calculated and stored in `${c3_mro[`*name*`]}`, based on the current MRO of the given bases (which you should have already set up with prior call(s) to `c3::resolve`).

If more than one base is provided, multiple inheritance is implemented using the C3 linearization algorithm, with the entire argument list expressing a constraint on the overall ordering.  An error is returned if a consistent linearization cannot be found.  (For example, if two bases inherit from two other bases in a different order from each other).

Note: This function overwrites any existing MRO for the named method set, but does *not* update any previously-calculated or stored MROs derived from the old MRO.

This means that you should not pass base names to `c3:resolve` that have not already had their own MROs previously set up using `c3::resolve`. And, if you want to support dynamically-changing inheritance (like setting Python's `__bases__` , or Javascript's `setPrototypeOf()`), you may need to recompute downstream MROs when such changes are made.

```bash @shell
c3::resolve(){
	local -n mro=c3_mro["$1"]
	case $# in 1|2) mro="<$1>${2:+${c3_mro[$2]=<$2>}}";; 0) return;;
	*) printf -v mro '<%s>' "$@"; c3::mixin mro "${@:2}"
	esac
}
```

~~~sh
  $ c3::resolve D O; echo ${c3_mro[D]}  # single inheritance of a root method set
  <D><O>

  $ c3::resolve B D; echo ${c3_mro[B]}  # single inheritance, depth 2
  <B><D><O>

  $ c3::resolve C F O; echo ${c3_mro[C]}  # multiple inheritance, root method sets
  <C><F><O>

  $ c3::resolve A B C; echo ${c3_mro[A]}  # multiple inheritance, depth 2
  <A><B><D><C><F><O>

  $ c3::resolve A C B; echo ${c3_mro[A]}  # the same, but with different ordering
  <A><C><F><B><D><O>
~~~

### c3::mixin *varname method-set-names...*

Merge the MROs of the named method sets into the MRO stored in the variable named *varname*.  The contents of the named variable are only updated if the resulting MRO can be consistently linearized.  (For example, if the new MRO would have any method sets appearing after a method-set they previously appeared before, or vice versa, this would be considered inconsistent.)  Note that while the named method sets will generally be added in the order they appear in the argument list, they may be merged in a different order as long as there is no conflict in the result.

False is returned if a consistent order could not be established.

```bash @shell
c3::mixin(){
	local REPLY t m=(); for t in "${@:2}"; do m+=("${c3_mro[$t]=<$t>}"); done
	c3::merge ${m[@]+"${m[@]}"} "${!1}" && printf -v "$1" %s "$REPLY"
}
```

### c3::merge *mros...*

Perform a C3 merge on the given MRO strings, returning success and a new, merged MRO string in `$REPLY`, or failure and a partial MRO string up to the point where an ordering conflict occurred.

~~~sh
  $ c3m(){ c3::merge "$@" && echo "$REPLY";}

  $ c3m "<x><o>"   # Single argument is returned as-is
  <x><o>

  $ c3m "<B><D><O>" "<B><O>"
  <B><D><O>

  $ c3m "<B><D><O>" "<C><F><O>" "<D><O>"
  <B><D><C><F><O>

  $ c3m "<B><D><O>" "<C><F><O>" "<D><O>" "<B><C><D>"
  <B><C><D><F><O>

  $ c3m "<B><D><C><O>" "<C><F><O>" "<D><O>" "<B><C><D>"  # no merge possible, C <-> D conflict
  [1]

  $ echo "$REPLY"   # after removing <B>, the list had <D><C><O>, <C><F><O>, and <C><D>
  <B>
~~~

```bash @shell
c3::merge(){
	if (($#==1)); then REPLY=("$1"); return; fi
	local list head f=$-; set -f; REPLY=("")
	while (($#)); do
		for list; do
			[[ $list ]] || continue; head="${list%%>*}>"
			if [[ "$*" == "${*/">$head"*/}" ]]; then
				REPLY[0]+=$head; set -- ${*//"$head"/}; continue 2
			fi
		done
		break # error, can't merge
	done
	[[ $f == *f* ]] || set +f
	((!$#))  # fail if unmerged args
}
```


## Code Generation


### c3::defun *name body*

Define a function named *name* with body *body*.  If *name* contains `::` and a function of that name doesn't already exist, the method lookup cache is cleared (unless the function was not part of any cached lookup since its last reset).

```bash @shell
c3::defun(){ [[ $1 != *::* ]]||c3::exists "$1"||${c3_seen["$1"]+c3::methods-changed};eval "$1(){ ${2:-:}"$'\n}';}
```

~~~sh
# Start with a known cache

  $ c3::methods-changed
  $ object::__init__(){ :;}
  $ c3::find-method "<object>" __init__
  $ dump-tables c3_cache c3_seen
  
  c3_cache          []
  ----------------  ----------------
  __init__<object>  object::__init__
  
  c3_seen           []
  ----------------  --
  object::__init__  

# Define a plain function

  $ c3::defun foo bar
  $ type foo
  foo is a function
  foo () 
  { 
      bar
  }

# Cache is unchanged after definition, since function name is not a method:

  $ dump-tables c3_cache c3_seen
  
  c3_cache          []
  ----------------  ----------------
  __init__<object>  object::__init__
  
  c3_seen           []
  ----------------  --
  object::__init__  

# Declaring a method doesn't wipe the cache if it's not in the seen table:

  $ c3::defun foo::bar baz
  $ dump-tables c3_cache c3_seen
  
  c3_cache          []
  ----------------  ----------------
  __init__<object>  object::__init__
  
  c3_seen           []
  ----------------  --
  object::__init__  

# or if it already exists:

  $ c3::find-method "<foo>" bar
  $ c3::defun foo::bar baz
  $ dump-tables c3_cache c3_seen
  
  c3_cache          []
  ----------------  ----------------
  __init__<object>  object::__init__
  bar<foo>          foo::bar
  
  c3_seen           []
  ----------------  --
  foo::bar          
  object::__init__  

# But deleting a seen function will clear it

  $ c3::undef foo::bar
  $ dump-tables c3_cache c3_seen
  
  c3_cache  []
  --------  --
  
  c3_seen  []
  -------  --

# Repopulate the cache

  $ c3::find-method "<object>" __init__
  $ c3::find-method "<foo>" bar
  [1]


# Even though the foo::bar lookup failed, the *fact* it failed affects the cache
# contents, so it's still tracked as a seen method:

  $ dump-tables c3_cache c3_seen
  
  c3_cache          []
  ----------------  ----------------
  __init__<object>  object::__init__
  
  c3_seen           []
  ----------------  --
  foo::bar          
  object::__init__  

# So creating the known-missing foo::bar will clear the cache again

  $ c3::defun foo::bar baz
  $ dump-tables c3_cache c3_seen
  
  c3_cache  []
  --------  --
  
  c3_seen  []
  -------  --
~~~


### c3::methods-changed

This function should be called whenever the method cache is invalidated, i.e. if you `unset` a method function, or create a new one.  `c3::defun` and `c3::undef` call this automatically if creating or deleting a method whose state has been queried for a cached lookup, but if you methods are created or deleted in some other way, you may need to call this to prevent inaccurate dispatching.

```bash @shell
c3::methods-changed(){ c3_cache=(); c3_seen=();}
```

### c3::undef *funcname...*

Delete the named functions (via `unset -f`), clearing the method lookup cache if any of the functions exist and were part of a cached lookup.

```bash @shell
c3::undef(){ local m; for m; do c3::exists "$m" && unset -f "$m" && ${c3_seen["$m"]+c3::methods-changed} ||:; done;}
```

### c3::exists *funcname*

Return truth if a function named *funcname* exists.

```bash @shell
c3::exists(){ declare -pF "$1" &>/dev/null;}
```
