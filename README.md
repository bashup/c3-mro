# C3 Linearization and Fast Method Dispatch for bash

Looking for polished, easy-to-use object-oriented extensions for bash (4.4+)?

If so, then keep looking, because this isn't that.  (Sorry!)

But if you're looking to *implement* your own OO extensions for bash, and want a solid, tested, and **fast** method dispatch mechanism, you've come to the right place.

c3-mro is a tiny (<3k), fast (>50k method calls/second), pure-bash implementation of C3 inheritance linearization and method dispatch.  It supports single or multiple inheritance, mixins, prototypes, or almost any other sort of OO involving a method lookup order.

And because it only handles inheritance ordering and method dispatch (including `super` calls), it doesn't lock you into a particular type system or way of implementing instances: you can make objects out of variables, functions, or anything else that strikes your fancy.  Your object system can use a class/instance approach (ala Python), an instance/prototype approach (ala JavaScript), or even a mix of the two, using whatever APIs or syntax sugar you wrap c3-mro with.

For example, here's a toy example of a prototype-based OO framework using bash functions to represent instances, implemented as three lines of syntax sugar over c3-mro's inheritance and lookup machinery:

~~~sh
  $ source c3-mro
  $ proto() { c3::resolve "$@"; c3::defun "$1" 'local this=$FUNCNAME; this "$@"'; }
  $ this()  { c3::call  "${c3_mro["$this"]}" "$@"; }
  $ super() { c3::super "${c3_mro["$this"]}" "${FUNCNAME[1]%::*}" "$@"; }

  $ proto dog
  $ dog::speak() { echo "bark"; }
  $ dog speak
  bark

  $ proto lapdog dog
  $ lapdog::speak() { echo "yap!"; }
  $ lapdog speak
  yap!

  $ proto barkley dog
  $ barkley::speak() { echo -n "barkley says: "; super speak; }
  $ barkley speak
  barkley says: bark

  $ proto barkley lapdog
  $ barkley speak
  barkley says: yap!
~~~

Or let's do it a little different - instead of making a function for each object, we could just use their names:

~~~sh
  $ proto() { c3::resolve "$@"; }
  $ tell() { local this=$1; c3::call "${c3_mro["$1"]}" "${@:2}"; }
  $ proto spot dog

  # No function created
  $ spot
  * spot: command not found (glob)
  [127]

  # But you can 'tell' the named object to do things
  $ tell spot speak
  bark

  $ tell barkley speak
  barkley says: yap!
~~~

Notice, by the way, that everything that isn't `c3`-prefixed in these examples is entirely up to you: you can have `$self` instead of `$this`, or have classes that own the MRO and instances with constructor methods that set up their member variables.  Or you can skip having instance variables altogether, if your program only uses singletons that can just use regular bash global variables, or local variables for the duration of its execution.  (Handy if you're doing the Template Method pattern.) Heck, you can store objects' MRO in a variable to support on-the-fly, instance-level mixins! (Using the `c3::mixin` function to add to an existing MRO.)

And since c3-mro doesn't dictate or interfere in any of these decisions, you can do whatever is appropriate for your app or framework. (Heck, creating wrappers like the above is so simple, you can literally customize it for whatever sort of app you're writing, in whatever way makes sense.)


## What It Does

c3-mro's primary purpose is to do fast method lookup and invocation, to select an appropriate method from one or more "method sets" arranged in some "method resolution order" (MRO).  Method sets are implemented as bash functions with a common prefix - e.g. the bash function `foo::bar` represents the method `bar` of method set `foo`.

Method sets can be created statically or dynamically, and can represent classes, prototypes, or even individual objects -- whatever works for the kind of OO system you want to implement.  The only hard-and-fast requirement is that both method names and method set names must be strings that would be valid to include in a bash function name, and so cannot include whitespace or `<>` characters.  (You should also avoid glob wildcard characters such as `[]*?` unless your entire script runs with `set -f`.)

A method resolution order, or MRO, consists of a list of method set names, arranged in the desired lookup order.  MROs are implemented as bash strings containing method set names surrounded by `<>`, without any whitespace or other punctuation.  So for example, if the bash string `"<foo><bar>"` is used as an MRO to search for a method named `baz`, then the function `foo::baz` will be checked before falling back to `bar::baz`.  (And if both methods exist, the `foo::baz` function can even make a "super" call to invoke `bar::baz`.)

Aside from doing the actual lookups, c3-mro's other main purpose is to do [C3 Linearization](https://en.wikipedia.org/wiki/C3_linearization): a specific algorithm for creating a linear method resolution order given an inheritance graph.  The algorithm supports single or multiple inheritance as well as traits or mixins and is used in a variety of languages (such as Python) because of its simplicity and stability.

## Installation, Requirements, and Use

Copy and paste the [code](bin/c3-mro) into your script, or place it on PATH and `source c3-mro`.  Bash 4.4 or better is required. (If you have basher, you can `basher install bashup/c3-mro` to get it installed on your PATH.)  You can also incorporate it into your library or app as an [mdsh](https://github.com/bashup/mdsh) module, by doing an `mdsh-source` on the [c3-mro.md source file](c3-mro.md).

For the full API reference, as well as the annotated source code and examples/test suite, see the [c3-mro.md source file](c3-mro.md).

## Design Limitations and Trade-offs

c3-mro's cache design is optimized for the case where most programs have a relatively static collection of method sets and MROs, perhaps with some extras being generated dynamically during program startup and cache warmup, but then remaining largely static for most of the program's execution.  So if your program or framework continually creates dynamic classes or methods (or new prototype-based method sets), cache performance will suffer despite consuming more and more memory for the cache.

For example, if you used the toy prototype-based implementation in this README, and then proceeded to make new `dog`-derived objects for each line in a ten-thousand-line input file (e.g. `proto dog1...`, `proto dog2...` and so on), it would consume a *lot* more memory and run a fair bit slower than if those objects all just shared a single `dog` MRO.

So if you're developing a prototype-based OO system, it's highly recommended that derived objects simply use their prototype's MRO until/unless they need to add instance-specific methods.  That way, even if you create tens of thousands of instances, it won't create tens of thousands of cache entries.
