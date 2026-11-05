# Shen/JIT semantics

The behaviour Shen/JIT implements. The executable [contract examples](../contract/examples.shen) check every rule below that has an observable
result, and their output under Shen/Scheme is recorded in [contract/shen-scheme-0.53.txt](../contract/shen-scheme-0.53.txt).

Where Shen/JIT deliberately differs from Shen/Scheme, the rule says so and the example is marked as a deviation. Shen/Scheme's behaviour was observed by
running KLambda through `eval-kl`, not inferred from its source.

## 1. Inputs

| Input | Version |
| --- | --- |
| Kernel | The release that `tools/ci-deps.sh` names: its `klambda/`, and its tests |
| Stage 0 host | The release of Shen/JIT that `tools/ci-deps.sh` names, or the release of Shen/Scheme it names, which make the same files |
| SLJIT | Upstream commit `a0020dd49a21`: see `vendor/sljit/UPSTREAM.md` |

`tools/ci-deps.sh` fetches the kernel and Shen/Scheme by hash, and `generated.sha256` holds the hashes of what they make.

## 2. Values

All values are 64-bit words. The low bits are tags, with the spare pattern used for object headers:

| Low bits | Meaning |
| --- | --- |
| `..00` | Fixnum, 62-bit signed: -2^61 to 2^61-1. |
| `011` | Pair pointer. Pairs are two words with no header. |
| `001` | Pointer to an object with a header. |
| `101` | Pointer to a procedure (an object with a header). |
| `110` | Pointer to a symbol (an object with a header). |
| `010` | Special value; the payload is in the upper bits. |
| `111` | Object header. No value has this pattern. |

A word at the start of a heap object is therefore either a header (`111`) or
the head of a pair. The collector's scan and the image's relocation pass rely on
this. Objects are 8-byte aligned and at least two words long.

Special values: the empty list, `true`, `false`, the cleared stack value (also
used for unbound cells) and the forwarding marker used during collection. The
cleared value and the forwarding marker are never visible to Shen code.
`(fail)` is the symbol `shen.fail!`, as defined by the kernel, not a
special value.

Object families, each identified by a type field in its header, which also
states which fields hold values:

| Family | Contents |
| --- | --- |
| String | Byte length and bytes; immutable. |
| Symbol | Name string, name hash, global cell index. |
| Real | IEEE double. |
| Absvector | Length and that many values. |
| Closure | Code object and captured values; a `defun` is a closure with no captures. Raw native entry. |
| Primitive | Primitive table index and arity. Raw native entry. |
| Code object | Bytecode, constant slot base, frame size, arity, name. Raw native code pointer. |
| Exception | Message string, and a value that goes before it, or none. An error raised from C keeps the offending value apart; `error-to-string` builds the full message the first time it is asked. |
| Stream | Kind, direction, open flag; raw OS handle. |

There is no partial-application object: KLambda named calls are saturated (see
section 9), so only closures and primitives are ever applied.

Symbols are ordinary heap objects. The hash is computed from the name bytes when
the symbol is created, so it never depends on an address. The intern table is a
heap object that holds symbols weakly: a collection drops a symbol that nothing
else reaches, that has no value or function, and that no compiled code calls by
name, and its cell is reused. Interning the name again makes a new symbol, which
nothing can tell from the old one. `(intern "true")` and `(intern "false")`
return the Boolean specials.

Global cells (a value word and a function word per symbol) and constant slots
live in root arrays outside the heap. The arrays grow by adding fixed-size
chunks, so no cell moves. The heap refers to cells only by index; emitted code
embeds cell addresses. A code object owns its range of constant slots: the
collector copies them with it, and reuses them once it is dead (heap.c).

## 3. Numbers

- **Integers** are fixnums only. Any integer result outside the fixnum range
  raises a catchable "integer overflow" error. *Deviation:* Shen/Scheme has
  bignums.
- **Reals** are IEEE doubles. Mixed integer/real arithmetic produces a real.
- **Division:** `(/ A B)` of two integers is an integer when B divides A
  exactly and a real otherwise; any real operand gives a real. A zero divisor,
  integer or real, raises an error, as in Shen/Scheme. Other real operations
  follow IEEE, so infinities and NaN can arise from overflow.
- **Comparison:** `<`, `>`, `<=` and `>=` compare mathematical values across
  integers and reals; a non-number operand raises an error.
- **Equality:** `=` compares numbers by mathematical value, so `(= 8 8.0)` and
  `(= 0.0 -0.0)` are true and NaN equals nothing. *Deviation:* Shen/Scheme
  compiles `=` against a numeric literal to `eqv?`, so `(= 8.0 8)` with a
  computed real is false there, and its `hash` gives 8 and 8.0 different
  values.
- **Literals** are computed by the kernel reader with integer arithmetic
  (`shen.compute-integer`, and `shen.expt` for exponents), so a literal beyond
  the fixnum range, such as `1e300`, would overflow. Small overrides of
  `shen.compute-integer` and `shen.compute-E` make such literals the nearest real,
  or next to it if the digits before an exponent were already rounded, in a fraction
  or as more digits than a real holds. "8.0" still reads as the integer 8, as in Shen/Scheme.
  *Deviation:* Shen/Scheme reads such a literal as a bignum. So too the smallest
  fixnum: a minus sign applies after its digits are read, and those alone are past
  the range, so `-2305843009213693952` reads as a real, equal to that integer by
  value. `(- -2305843009213693951 1)` gives the integer itself.
- **Printing:** `str` prints integers in decimal and reals with the shortest
  digits that read back exactly, always with a decimal point or exponent
  (`(str (+ 0.5 0.5))` is "1.0"). The choice between positional and exponent
  notation is not a compatibility requirement.

## 4. Strings, symbols and characters

Strings are immutable byte sequences, and every string primitive works in
bytes; source text and files pass through as UTF-8 bytes without decoding.

- `(pos S N)`: the byte at fixnum index N as a one-byte string; an index outside
  0 to length-1 raises an error.
- `(tlstr S)`: S without its first byte; the empty string raises an error.
- `(cn A B)`: concatenation; a non-string raises an error.
- `(string->n S)`: the first byte; the empty string raises an error.
- `(n->string N)`: a one-byte string for N from 0 to 255; anything else raises
  an error. *Deviation:* Shen/Scheme accepts any Unicode scalar value and
  creates a one-unit string that cannot be written as a byte. The kernel calls
  `n->string` only on bytes.
- `(str X)`: for strings, the text in double quotes; symbols, their name;
  Booleans, "true" or "false"; numbers, as above; the empty list, "()". Other
  values give a description such as `#<procedure>`; `str` never raises.
- `(intern S)`: any string, including "" and "1"; a non-string raises an error.

## 5. Pairs and absvectors

- `cons` accepts any two values; `hd` and `tl` of a non-pair raise an error.
- `(absvector N)`: N must be a non-negative fixnum. Every element starts as the
  symbol `shen.fail!`, as in Shen/Scheme, so the `vector` override need not
  fill elements again.
- `(<-address V N)` and `(address-> V N X)`: N must be within 0 to length-1;
  `address->` returns V. Out-of-range indices and non-vectors raise errors.

The kernel catches out-of-range `<-address` errors to implement `vector?`,
`tuple?` and `shen.pvar?`, `pos` past the end in `shen.string->byte`, and
`value` of an unbound symbol in `bound?`. These errors must be cheap to raise
and catch.

## 6. Equality and hashing

`(= A B)` is true when A and B are numbers with the same mathematical value,
strings with the same bytes, pairs whose heads and tails are `=`, absvectors of
the same length whose elements are `=`, or the same symbol, special, procedure,
stream or exception. Closures compare by identity.

`(hash X N)`, for a positive N, returns an integer from 0 to N inclusive, as the
kernel's port performance guide states, and is consistent with `=`: numbers
hash by mathematical value (8, 8.0 and -0.0/0.0 agree), strings by bytes,
symbols by their stored name hash, pairs and absvectors by their elements.
Procedures, streams and exceptions hash by family, since a moving collector
gives them no stable address. *Deviation:* Shen/Scheme's hash distinguishes 8
from 8.0.

## 7. Globals

KLambda keeps separate value and function bindings. `(set S X)` requires a
symbol and returns X. `(value S)` of a symbol with no value raises a catchable
error; a non-symbol raises an error.

## 8. Errors and handlers

- `(simple-error S)` raises an exception with message S; a non-string raises an
  error instead.
- `(error-to-string E)` returns the message of an exception. *Deviation:* a
  non-exception raises an error; Shen/Scheme returns a description.
- `(trap-error X H)` evaluates X; if X raises, it applies H to the exception.
  If H is not a procedure, applying it raises a new error that propagates
  outward. X is never in tail position.
- Every primitive error is an ordinary catchable exception. Message wording is
  informative but not a compatibility requirement; the examples check only that
  an error occurred, except for `simple-error` messages.
- Messages name the offending value in Shen notation, cut after 60 bytes, as
  in `hd: 5 is not a pair`; arity errors name the function and both
  argument counts.

## 9. Control forms and application

- `if`, `cond`, `and` and `or` require Boolean conditions and raise an error
  otherwise. `and` and `or` short-circuit, and the second operand must also be
  a Boolean, as in Shen/Scheme.
- `cond` with no true clause raises an error. *Deviation:* Shen/Scheme returns
  an unspecified value.
- `let` binds one variable; `lambda` takes exactly one parameter; `freeze`
  creates a thunk; `type` returns its first argument and does not evaluate the
  second.
- A symbol in value position that is not lexically bound evaluates to itself.
- **Named calls** `(f A1 ... An)`, with `f` not lexically bound, call `f`'s
  function binding. If its arity differs from n, the call raises an error; if f
  has no function binding, the call raises an error. This matches Shen/Scheme.
  The Shen compiler already turns Shen-level partial applications into lambdas,
  and the kernel, stlib and extension KLambda contain no named call with
  the wrong argument count.
- **Other applications** `(E A1 ... An)` evaluate E, which must be a procedure.
  Closures are unary or nullary. Applying one to more arguments than it takes
  applies the result to the rest, left to right; the lowerer emits this as
  nested applications. Applying a closure to too few arguments, or applying
  anything that is not a procedure, raises an error.
- **Symbols are not procedures.** Applying a symbol raises an error, as in
  Shen/Scheme, where `(map f L)` with a bare function name fails; Shen code uses
  `(fn f)` or `(function f)`.

## 10. Definitions, redefinition and sealing

- `(defun F Params Body)` returns F. The lowerer validates the form; malformed
  definitions raise an error and leave any previous binding in place.
  *Deviation:* Shen/Scheme accepts some malformed bodies, such as a bare
  `(lambda)`, and fails only when they run.
- A definition is published only after it is fully prepared. Replacing a
  binding never invalidates existing closures or active frames; open calls see
  the new binding on their next call, and the arity may change.
- **Fixed names** are lowered directly and cannot be redefined: `defun` of one
  raises an error. They are the 39 KLambda primitives listed in the design
  document (`input+` is not one; the port defines it), the special forms `if`, `and`, `or`, `cond`, `let`, `lambda`,
  `defun`, `freeze`, `type` and `trap-error`, and the kernel functions `do` and
  `thaw`. *Deviation:* Shen/Scheme accepts such a `defun` but its compiled
  calls ignore it.
- **Sealing:**
  the kernel, port code and the lowerer are sealed. Calls to them, from the
  kernel and from user code alike, are bound once, and a `defun` of one of
  their names raises "F is sealed and cannot be redefined". The extensions
  stay open, since their tests reload their sources. `(shen-jit.seal +)`,
  `--seal` or `SHEN_JIT_SEAL=1` also seal user definitions. *Deviation:*
  Shen/Scheme accepts such a `defun`, as the paragraph below describes.
- **Sealing (as first decided):** calls between definitions lowered at stage 0 (kernel,
  stlib, overrides, port code and the lowerer) are sealed: they call fixed
  targets with known arities. A later `defun` of one of those names, which only
  raw `eval-kl` can do because the kernel rejects a Shen-level `define` of a
  system function, changes the binding seen by open calls (user code,
  `eval-kl` code and lambda forms) but not calls made inside the kernel. This is
  the arrangement the kernel's port performance guide describes, and Shen/Scheme
  behaves the same way for kernel-to-kernel calls: after an `eval-kl` `defun` of
  `shen.misc?`, `shen.alpha?` still uses the original. Shen/Scheme's compiler is
  in the same library as its kernel, so redefining `append` there leaves later
  compilation working. Calls from its user code are bound when compiled: code
  compiled before the `defun` keeps the original, and code compiled after it
  sees the new definition. In Shen/JIT the lowerer and port code are lowered at
  stage 0 and sealed with the kernel.

## 11. `eval-kl`

`(eval-kl X)` lowers X in guest code and installs the result. A `defun` returns
its name; any other form returns its value. Malformed forms raise an error.
`eval-kl` never enters C recursively. X that is not a list is its own value,
returned without lowering.

A definition's lambda form, which `fn` returns, is made the first time `fn`
asks for it, not when the definition is read; `shen.*gensym*` still moves as
if it had been made then. *Deviation:* until then, reading the
`shen.lambda-form` property directly gives a placeholder, an absvector tagged
`shen-jit.lazy-form`, where other ports give the closure.

## 12. Streams, files and time

- `(open Path Direction)`: Path is a string, Direction is `in` or `out`. The file
  opened is `(cn (value *home-directory*) Path)`, resolved by the operating
  system. `out` creates or truncates. Failures raise errors.
- `*home-directory*` is "" after stage 1, because stlib's initialization runs
  `(cd "")`, so relative paths resolve against the process's working directory,
  as in Shen/Scheme. Startup does not change it. This replaces the design
  document's earlier step that set it from the host.
- `(read-file-as-bytelist Path)` and `(read-file-as-string Path)` read the
  whole file in C, as Shen/Scheme's overrides do, with the path resolved and
  failures reported as for `open`. The kernel's read one byte at a time.
- `(read-byte S)`: a byte from 0 to 255, or -1 at end of file.
- `(write-byte B S)`: B from 0 to 255; returns B.
- Reading from an output stream, writing to an input stream, or using a closed
  stream raises an error. `(close S)` returns the empty list, and closing a
  closed stream does nothing.
- The standard streams are `*stinput*`, `*stoutput*` and `*sterror*`. Output to
  `*stoutput*` is flushed before any read from `*stinput*` and at exit.
- `(char-stream? S)` is false for every stream. `read-unit-string` and
  `write-string` raise "character streams are not supported", as in
  Shen/Scheme; the kernel only calls them for character streams.
- `(get-time run)` returns CPU seconds and `(get-time unix)` wall-clock seconds
  since the epoch, both as reals. Other arguments raise an error. Shen/Scheme
  also accepts `real`; Shen/JIT does not.

## 13. Stage 1 order and extensions

Stage 1 runs, in order: install the stage 0 definitions; set `*os*`,
`*language*`, `*implementation*`, `*release*`, `*port*` and `*porters*`; call
`shen.initialise`; call `shen.x.features.initialise` with the feature list
`[shen/shen-jit]`, then `shen.x.programmable-pattern-matching.initialise` and
`shen.x.namespaces.initialise`; load the remaining port sources; call
`stlib.initialise`; close every non-standard stream; write the image.

This follows Shen/Scheme's build. The factorise-defun, expand-dynamic and
type-annotations extensions are not initialized. As built, what `define`
produces is evaluated factorised by the kernel's `shen.factor`, as Shen/Scheme's
compiler factorises definitions; `ps`
shows the definition as `define` produced it, and `shen.*factorise?*` stays
false, as in Shen/Scheme. The command line is the
kernel's launcher extension: `main` passes the process arguments to
`shen.x.launcher.main`, which provides the `repl`, `script` and `eval` commands
Shen/Scheme also uses, so Shen/JIT needs no command-line parser in C.

## 14. Memory, stack and compilation failures

- **Heap.** When a collection does not free enough space, the heap grows.
  If growth fails, the allocation raises a catchable "out of memory" error,
  using a preallocated exception; the heap stays consistent because its regions
  are always the same size. The process aborts only if the collector itself
  cannot complete.
- **The heap's size,** what a collection keeps and the room for new objects
  together, starts at 32 MiB and doubles after a collection that leaves live
  data above 40% of it. It never shrinks in the first version.
- **Large objects:** vectors and strings of 32K words or more are allocated
  apart and never copied; collections mark them, scan them in place and
  free the dead ones. They count as live data for the 40% rule, and once
  toward `SHEN_JIT_MAX_HEAP`. An image holds them inside its heap.
- **Guest stack.** It starts at 64K slots, filled with the cleared value, and
  doubles on overflow up to a configurable maximum (default 1 GiB). Exceeding
  the maximum raises a catchable "stack overflow" error. The stack never shrinks
  while guest code runs.
- **Compilation.** If SLJIT cannot allocate executable memory or compilation
  fails, the process terminates with a diagnostic; there is no fallback.
  Debug builds abort on malformed bytecode.

## 15. Image format

An image is a header followed by sections and a trailer, all little-endian:

- **Header:** magic `SJHI`, format version, the executable's build identifier
  (an image loads only into the build that wrote it), word size, heap size, and
  the sizes of the root sections.
- **Heap:** the live heap after a final collection, with every pointer stored
  relative to the heap base and every raw native field stored as 0.
- **Roots:** the global-cell and constant-slot arrays, with relative pointers;
  the intern table; the primitive table size and a checksum of its names, so an
  image cannot load against a different primitive table.
- **Trailer:** the image's length in bytes and the magic `SJHI-END`. A loader
  reads it from the end of the file, so an image can be appended to another
  file: the executable carries its image this way.

Loading reads the heap into a region at least twice its size, adds the base
to every pointer in one linear pass over objects and pairs, does the same for
the root arrays, and then applies the reconstruction rules in
[design.md](design.md): native entries from each procedure's kind, the standard streams
rebound in place, and file streams left closed.
