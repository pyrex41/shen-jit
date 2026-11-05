# Development log

What was done or rejected, why, and the numbers, by topic, with dates inside. The question it must answer quickly is "did anyone try X?", so rejected ideas are here on purpose:
search for "Rejected" before proposing something again without new evidence. How things work now is in the other documents in this directory.

Every figure belongs to its date and machine, and later changes moved many of them, so none is a current claim. Some compare against an earlier prototype, or come from harnesses and data that are not published.
That is history, and those figures are not meant to be reproduced: `make bench` and `make bench-independent` are what a reader can run.

Terms used throughout:

- **M3 Max:** an Apple M3 Max MacBook Pro, macOS, arm64. **Ryzen VM:** a Hyper-V virtual machine with 4 cores of an AMD Ryzen 5 5600X, Ubuntu 20.04, gcc 9.4 and glibc 2.31, x86-64.
- **Campaign:** an earlier prototype's benchmark set, 156 timed rows recorded on 2026-10-27 on the M3 Max with Shen/Scheme 0.50 and that prototype: 122 canonical rows in one process, and 34 "other drivers" for calls, Prolog and applications, among them a compile pipeline and a bytecode VM ("realistic" rows).
- **A/B:** interleaved runs of a change against the build just before it. A bare ratio is new time over old time, so below 1 is faster.
- **Open** is the default, with only kernel functions sealed. **Sealed** is `--seal`, with user definitions sealed too.
- **Kernel suite:** the Shen kernel's own test suite, which mostly loads and typechecks code.
- **CACHE** is the saved register holding the last result. **Stage 0** and **stage 1** are the build's stages.

Topics: [the JIT](#the-jit-and-native-code-generation), [the collector](#the-collector-memory-the-guest-stack-and-images), [the lowerer and the port](#the-lowerer-the-bytecode-the-kernel-port-and-prolog),
[the runtime and platforms](#runtime-threads-platforms-and-usability), [the C FFI](#c-ffi), [benchmark results](#benchmark-results).

## The JIT and native code generation

Lowering rules, the collector and the kernel port have their own sections.

### Engine decisions

- **Whole-function baseline JIT on SLJIT, no interpreter** (2026-11-01, design). Every function compiles at first
  entry and `eval-kl` takes the same path. No mixed execution, since mixed calls are what limited the baseline
  tier of an earlier bytecode VM.
- **Left out of the design** (2026-11-01): tracing, LLVM or Cranelift, a C compiler at run time, on-stack
  replacement, speculative inlining, general deoptimisation, cross-block SSA, global register allocation. Lazy
  basic block versioning only if a workload shows repeated checks dominating. Copy-and-patch and an operation
  generator stay open only if a complete implementation proves simpler than SLJIT with handwritten emitters.
- **Canonical frame slots** (2026-11-01, design). They let the collector scan the stack with no root maps, so
  registers below only cache slots or are written back before anything that may collect.
- **Rejected: a register allocator** (2026-11-01, estimate). Matching the earlier prototype on every row was
  estimated to need one, outside the size goal. That prototype's registers rest on thousands of lines of CFG,
  liveness and root maps; its own trials rejected registers across calls (code grew 18.9%) and promoting every
  local (one loop 0.016 to 0.014 s, another 0.025 to 0.033 s). On 2026-11-04 the campaign read 0.70 of its time
  open (M3 Max).

### Calls

- **Convention gates** (2026-11-01, M3 Max, generated `fib`). Sealed call site 12 instructions, open 15, entry 6,
  return 3, within the design's limit of about 15 for a caller. Before any optimisation, against Shen/Scheme 0.52:
  `fib` 30 6 against 4.4 ms, `nrev` 166 against 72 ms.
- **Where the time was** (2026-11-01, M3 Max). A call cost 1.1-1.4 ns against 0.8-1.0 in Chez, while four chained
  additions cost 1.3 ns each against 0.44, each value going to its slot and back.
- **Tail-call arguments computed in place** (2026-11-01, M3 Max, campaign). An unchanged one costs nothing. Open
  0.93 to 0.85 times Shen/Scheme, sealed 0.89 to 0.77.
- **First argument in CACHE as well as its slot** (2026-11-02, M3 Max, A/B). The callee read back what the caller
  had just stored. List rebuild 11.3 to 5.9 ms (Shen/Scheme 5.3), `append` 11.1 to 6.2 ms (4.3), realistic
  pipelines and VMs 11-13% faster, canonical 0.984.
- **Dynamic calls with all their arguments at once** (2026-11-02, M3 Max). A lambda returning lambdas, lowered at
  run time, got a second entry taking all parameters: `lambda with many arguments` 14.9 to 2.5 ms (Shen/Scheme 6.5,
  earlier prototype 7.8). Image +6.8 KB; entries in stage 0 code would have cost 35 KB more.
- **Calls through `fn`** (M3 Max). Sealed F is a direct call (2026-11-01, campaign: 3.1 ms against 23.8 open). A
  cache per call site for open F was deferred, as `put` would have to invalidate it. An inline arity test replaced
  it (2026-11-03): `cross-unit-global-unary-ordinary` 18.1 to 2.7 ms (earlier prototype 1.7).
- **Leaf code skips the stack check** (2026-11-03, M3 Max, A/B). A frame of at most 64 words runs inside what its
  caller reserved; code calling only in tail position skips it too, unless compiled once the REPL catches Ctrl-C.
  With results only the next instruction reads left unstored: returning calls 0.80-0.92 of their time, canonical
  0.998 open, 0.962 sealed.
- **Rejected: calls and returns through `blr`/`ret`** (2026-11-03, M3 Max). A callee reached from one of two random
  sites cost the same as from one: 69 and 70 ns at 16 random branches, 188 and 188 at 64, as C with `bl` and `ret`
  (67 and 69, 168 and 168). Other CPUs may differ.
- **Rejected: entering past the arity check; open calls patched to jump straight to the callee** (2026-11-03, M3
  Max). A build with no arity check timed `fib` and call-heavy loops the same, and a call too large to inline costs
  1.5 ns open against 1.6 sealed. What sealing gains is inlining.
- **Rejected: a second argument in a register** (2026-11-03, M3 Max). An accumulator passed second took 1.89-2.03
  ns per call open against 1.80 as the first argument, and sealed 1.70 against 1.88. Entry loads of later arguments
  hold 2 of 3,262 samples of the realistic VM.

### Sealing and inlining

- **Sealing** (2026-11-01, decision). Kernel functions are always sealed for user code; user code only with
  `--seal`. Redefining a sealed name raises. A sealed call to an undefined name binds on first call, so no file
  grouping is needed. Programs that redefine their own functions cannot run sealed.
- **Inlining small sealed callees** (2026-11-01, M3 Max, campaign, with sealing). At most 15 nodes, depth 2. Open
  1.00 to 0.93 times Shen/Scheme, sealed 0.89; `realistic-call-heavy` 0.119 s open against 0.073 s sealed
  (Shen/Scheme 0.068). Preparation up to 1.7 times slower sealed.
- **Rejected: an inline limit of 40 nodes** (2026-11-01, M3 Max). Image 1.24 to 1.72 MB, kernel suite 0.40 to 0.47
  s. `<-vector`, at 18 nodes, was split to fit instead (2026-11-02: 6.7 to 2.1 ns under a quiet handler).
- **Slot sharing for `let` of a variable** (2026-11-01, M3 Max). Each inlined level added two dependent moves per
  argument: sealed `realistic-call-heavy` 0.29 s against 0.12 open, then 0.073 s with sharing.
- **Open self tail calls, three steps.**
  - 2026-11-02, M3 Max, A/B: compare the cell with the running closure before testing its tag. Control loops 0.80
    to 0.67 ns, canonical 0.966. **Rejected:** taking the compare's own branch back, which saved 0.1 ns in
    allocating loops (canonical 0.948) but made a loop whose `=` called C take 5.4-6.6 ns instead of 3.9 at most of
    24 code addresses.
  - 2026-11-03, M3 Max: no check on arm64. The loop jumps straight back, and a redefinition rewrites that branch to
    the call through the name. Control loop 0.63 to 0.52 ns. **Rejected:** SLJIT's rewritable jump, four moves and
    an indirect branch, slower than the check.
  - 2026-11-03, Ryzen VM, A/B: the same on x86-64, with open inlining's guards. Open 0.931, sealed 0.999,
    `realistic-call-heavy` 0.45.
- **Open code inlines small callees** (2026-11-03, M3 Max, A/B). Behind a nop that a redefinition patches into a
  branch to the call. A small call 1.4 to 0.76 ns, a mutual tail call 1.05 to 0.54 ns, as sealed;
  `realistic-call-heavy` 0.48, other drivers 0.845. Bodies that make closures inline too: `closure allocation` 3.1
  to 2.1 ns (Shen/Scheme 2.39, earlier prototype 2.49).

### Registers and caching

- **Last result in a register** (2026-11-01, M3 Max, campaign). Results are still stored. Open 0.79 to 0.77 times
  Shen/Scheme; the realistic VM 1.63 to 1.27 open and 1.25 to 1.03 sealed; four chained additions 2.8 times faster.
- **Heap pointer in a register** (2026-11-01, M3 Max). Each `cons` waited on the one before through memory.
  `reverse` 7.0 to 4.6 ms (2.70 to 1.79 times Shen/Scheme).
- **Known pairs** (2026-11-01, M3 Max). A bit per slot, set where `cons?` falls through, so `hd` and `tl` skip the
  tag check. List patterns 7-20% faster. Kept across labels from 2026-11-02.
- **Loop registers, modelled first** (2026-11-02, M3 Max). Hand-written arm64, slots against registers: control
  loop 0.554 to 0.50 ns, `absvector-read` 1.07 to 1.05 ns, `reverse` 1.17 to 0.79 ns only with no frame stores in
  the loop. Counting loops gain 2-10%, not worth the 200-300 lines first estimated.
- **Loop registers, narrow version** (2026-11-02, M3 Max, A/B). Code looping through a self tail call, with no
  handlers and no calls but tail calls, keeps slots from 2 up in registers (frames up to 8 slots on arm64, 4 on
  x86-64), written back before C may collect or raise. About 70 lines. Canonical 0.981 open and 0.978 sealed, other
  drivers 0.991 and 0.973. Slower: `shen.sysfunc?` 11-15%.
- **What the model missed** (2026-11-02, M3 Max). `reverse` of 1,000 elements got slower run directly (1.6 to 1.8
  ns), though the same machine code ran at 0.82 ns in the model. A list surviving a copy was scattered: a scattered
  model list took 1.64 ns in registers and 1.63 in slots. The fix went in the collector.
- **Store-to-load layout** (2026-11-02, M3 Max). With values in slots, the control loop takes 0.55, 0.67 or 1.48 ns
  depending only on where a parameter's load sits after its store. Loops in registers do not vary.
- **Rejected: fewer instructions in `reverse`** (2026-11-02, M3 Max). Operands straight from CACHE (4 fewer) and
  `cons` moving the heap pointer first (2 fewer) read 1.001 and 1.013 overall. Keeping the next call's value in
  CACHE instead of the last result made `reverse` 12% slower.
- **Dead stores in pattern tests** (2026-11-02, M3 Max). A general "dead after one read" was deferred on
  2026-11-01: slow paths would have to store first, and the collector would not see the value. The narrow form
  skips a store only before a fused test with no slow path after which the slot dies. A/B: list pattern rows 38-46%
  faster, canonical 0.99 open and 0.984 sealed.
- **List walking** (2026-11-03, M3 Max, A/B). In register loops, moves, constants, `hd` and `tl` write straight to
  the slot's register, and `cons` tags into its destination. `reverse` of 32 items 33.0 to 25.2 ns (Shen/Scheme
  25.9, earlier prototype 29.3); canonical 0.97 open, 0.973 sealed.
- **Rejected: registers for all tail-calling code** (2026-11-03, M3 Max). Five eval cases failed, and the 12-clause
  list pattern took 1.25 times as long, as such code keeps nothing in CACHE.
- **Rejected: spare registers as copies of slots read** (2026-11-03, M3 Max, A/B). About 70 lines of state. A
  nested pattern's late mismatch 0.92-0.99, 12-clause pattern 1.00, canonical 1.007 open and 0.996 sealed.
- **Rejected: new closures and `symbol-kind` results in CACHE** (2026-11-03, M3 Max). Closure creation 3.0 against
  3.0 ns, `variable?` 1.04 against 1.05 ns.
- **Loop registers past fused tests' slots** (2026-11-03, Ryzen VM, A/B). A top slot holding only a fused test's
  unstored result no longer counts. x86-64 has two loop registers and the control loops were one over: 0.67 of
  their time (0.065 to 0.043 s), canonical 0.984.
- **Type tests leave the value in CACHE** (2026-11-03, A/B). Five lines. Ryzen VM 0.98, `nested list pattern
  (matching)` 0.56 (12.6 to 7.1 ms, Shen/Scheme 0.52 there 8.0); M3 Max 0.993, the same row 0.93.
- **Rejected: `hd` and `tl` loading straight into CACHE** (2026-11-04). No gain on the Ryzen VM, and on the M3 Max
  patterns of 16 and 24 elements took 1.2 and 1.5 times as long.
- **List walks are not bound by dependent loads** (2026-11-04). Corrects an earlier conclusion: walking a pattern
  takes 0.20 ns per element on the Ryzen VM and 0.14 on the M3 Max up to 12 elements, about one cycle.

### Branch shapes and code placement

- **Comparisons fused with branches** (2026-11-01, M3 Max). With other changes, `fib` 30 6.0 to 5.2 ms. Fused only
  where the slot is written before read on both paths, as 2 of the kernel's 2,643 pairs reuse the result.
- **Aligned loop heads** (2026-11-02, M3 Max). One instruction added on a cold path made `match list (single
  clause, not matching)` 24% slower. 16 bytes fixed that row, but a 32-item list walk still took 12 or 17 ms by
  what compiled before it, and canonical rows moved up to 40% between builds. Now loop heads take 32 bytes, and a
  body only when it loops, so calls run no padding, with one local patch to SLJIT. A/B: canonical 0.988.
- **Rejected: aligning the fill's paired stores** (2026-11-02, M3 Max). `vector create (big)` takes 22 or 30 ms by
  the heap pointer's parity, flipped by a file name five characters longer. The fix made other sizes up to 17%
  slower.
- **Rows that move with layout** (2026-11-02, M3 Max; 2026-11-03, Ryzen VM). `list traversal (32 items)`, `match
  vector` and `symbol? (true)` moved 15-40% between canonical runs of builds that do not touch them, and not at all
  alone. On the Ryzen VM, `literal integer equality (false)` and its identical float twin take 0.098 or 0.151 s.
- **Rejected: testing a shared clause test once before the chain** (2026-11-03, M3 Max). The 12-element pattern
  went from 22 compares to 12, and `match list (multiple clauses, matching)` stayed at 5.1 ns: the compares are
  predicted.
- **Exit tests out of line in loops** (2026-11-03, A/B). `=` with a constant whose true branch is only a return
  jumps to it from a stub, so a turn takes one jump instead of two. Ryzen VM 0.982 open and 0.975 sealed; M3 Max
  0.954 and 0.972. Slower: realistic pipelines 2-5%, whose short-list loops exit on their first test. **Rejected:**
  the same in all code, which also turned pattern clauses into jumps (pipelines 1.03-1.07).
- **`-falign-functions=32`** (2026-11-04, A/B, six rounds). An unrelated C edit moved `sj_equal` off a 32-byte
  boundary, and 32-item vector equality read 1.32 on the Ryzen VM. Ryzen VM 0.993 open and 0.990 sealed; M3 Max
  1.000 and 1.007. Not a general gain; kept for stability.
- **Rejected: a fact that a slot holds no object** (2026-11-04), to spare chains of fixnum compares the tag test.
  An unsound timing build: 0.40 to 0.24 ns per compare at 16 on the Ryzen VM, 0.25 to 0.22 on the M3 Max, and
  `match list` did not move. A correct version needs a lane for objects, and only 30 of 2,207 `=` tests have this
  shape.

### Constants and arithmetic

- **Constant operands** (2026-11-01, M3 Max, campaign). A literal is no longer copied to a slot and read back.
  Timed rows 12% faster on average, control loops 30-50%; 1.14 to 1.00 times Shen/Scheme.
- **Fixnum immediates** (2026-11-02, M3 Max, A/B). In `+`, `-`, `*`, comparisons, and constant indices below 4096
  in `<-address` and `address->`. About 50 lines. Canonical 0.977.
- **Mixed arithmetic before the dispatcher** (2026-11-02, M3 Max). Native code allocates the real and calls a
  helper that only computes. 4.9-5.3 to 2.8-3.1 ns (earlier prototype 1.96). **Not done:** inline floats, which
  would need floating-point registers in every prologue.

### Equality

- **Inline `=` by tag pair** (2026-11-01, M3 Max). `=` calling C was 54% of samples in the realistic benchmarks. A
  64-bit mask indexed by the two tags leaves only two pairs, two objects, or a fixnum and an object for C.
- **Structural `=`** (2026-11-01, M3 Max, campaign). Identical heads and same-header strings settle inline by
  words. `list equality (true)` 1.10 to 0.39 s, literal string equality 0.87 to 0.32 s, both 0.35 times
  Shen/Scheme.
- **`=` with a fixnum constant** (2026-11-02, 2026-11-03, M3 Max). Tests only the other value's tag, 4 instructions
  instead of 11. Objects other than reals are unequal before C, and a value result comes from the flags: failing
  1.61 to 1.34 to 1.08 ns (earlier prototype 1.08). **Rejected:** testing the header inline, which took the fixnum
  cases 0.75 to 1.00 and 0.88 to 1.25 ns.
- **`=` with a short constant string** (2026-11-03, M3 Max, A/B). Up to 32 bytes, against immediates. True 3.2 to
  1.05 ns (earlier prototype 1.64), canonical 0.971. **Rejected:** the same for constant reals, which helps only
  non-integral literals, as integral reals from 2^53 on equal more than one fixnum.
- **`=` on two variables** (2026-11-03, M3 Max). A fused test settles two values with tag bit 0 clear (fixnums,
  specials, symbols) with one test. **Rejected:** that test in every `=`, where differing took an extra jump
  (membership 1.06-1.10 times as slow).

### Allocation, lists, vectors and strings

- **Inline fast paths** (2026-11-01, M3 Max, against Shen/Scheme 0.52). Type tests, `<-address`, `*`, `absvector`,
  closures and handlers, with the `=` work and label lowering: overall 2.38 to 1.35 times Shen/Scheme.
- **Allocation primitives** (M3 Max). `@p` as one allocation (2026-11-01): `tuple create` 51 to 20 ms. `absvector`
  filling two words at a time (2026-11-02): 10^7 objects of 100 elements 0.32 to 0.19 s. A run of `cons` checking
  the heap once (2026-11-03): `[a b c d e f | X]` 5.6 to 5.1 ns, with the leaf change.
- **Constant-length `absvector`** (2026-11-02, M3 Max, A/B). Up to 15 elements, no loop, no length tests.
  `absvector create (small)` 2.25 to 1.5 ns open (earlier prototype 0.91), canonical 0.981. **Rejected:** dropping
  its fill value's test (2026-11-03), 1.41 against 1.43 ns.
- **Strings** (M3 Max). `tlstr` inline (2026-11-01): `string get tail` 0.75 to 0.23 s. `cn` inline (2026-11-02):
  prepending a character 10.2 to 4.3 ns; its copy in whole words (2026-11-03): 4.8 to 2.9 ns (earlier prototype
  4.1). **Rejected:** unaligned stores for the second string, 1.43 times as slow when the first's length is not a
  multiple of 8.
- **Rejected: `reverse` in C** (2026-11-03, M3 Max). 32 against 37 ns for 32 elements, but 3.3 against 2.4 for one
  and 320 against 233 for 256. `append` in C did pay (2026-11-02): 32 elements 61 to 32 ns.
- **Not done: touching the heap at startup** (2026-11-03, M3 Max). `absvector create (small)` takes 1.35 ns in the
  campaign and 0.92 alone, as the first row to fault in the semispaces, about 4 ms. Every process would pay that
  and 32 MB resident.
- **x86-64 allocation is bound by memory** (2026-11-03, Ryzen VM). `tuple create` 2.2 ns for 32 bytes and a `cons`
  1.1 for 16, about 14 GB/s against about 28 on the M3 Max.

### Errors and handlers

- **Lazy messages, quiet handlers** (2026-11-01, M3 Max). C errors build their message on request: from `value` 67
  to 11 ms. A handler ignoring its error gets no exception: `<-address` 10.4 to 5.5 ms.
- **`value` and `set` inline; errors as jumps** (2026-11-02, M3 Max, A/B). Under a quiet handler in the same code,
  failing `hd`, `tl`, `<-address`, `address->`, `value` and `set` jump to it. `value` under `trap-error` 6.1 to 1.8
  ns, failing `<-address` 5.5 to 1.85 ns, canonical 0.95 open and 0.946 sealed.
- **No handler stack at all** (2026-11-02, M3 Max, A/B). When only those jumps can reach the handler. `<-address`
  1.87 to 1.37 ns (earlier prototype 1.21), canonical 0.993.

### Compile time and code memory

- **SLJIT without debug checks** (2026-11-02, M3 Max). Runtime 307 to 225 KB, JIT compilation about 13% faster
  (9,000 lambda forms 34 to 30 ms).
- **Freeing dead native code** (2026-11-02, M3 Max). A weak list frees the code of uncopied objects after a
  collection: 20,000 definitions through `eval` free 40,003 of 40,206 code objects, peak 122 to 114 MB, time
  unchanged. The profiler's 23% for SLJIT's allocator was its bias toward returns from the kernel: all compilation
  took 23 ms of 645. **Rejected:** bigger allocator chunks (1 MB), no change.
- **Compile-time cost of open inlining** (2026-11-03, M3 Max). Re-evaluating eight realistic definitions: 253 to
  310 µs a round, 269 without open inlining, 308 at depth 1, so most of it is the inlined code. Workloads outside
  the benchmarks lost 3 to 5%: open inlining 1%, the rest most likely backtrace bookkeeping.

### Prolog and byte-buffer primitives

- **Inline `shen.lazyderef`** (2026-11-04, M3 Max). Variables are 1.00-1.04 steps from their value, so the cost was
  the call. `hamilton` 0.63, Einstein 0.76, kernel suite 0.96, executable 14 KB smaller. **Rejected:** fewer checks
  in it, through facts for slots known to hold absvectors (best of 15): `hamilton` 0.97, kernel suite 1.01, stlib
  install 1.02, for about 30 lines.
- **Byte buffers stay checked and in C** (2026-11-03, M3 Max). Checks cost 0.52 ns of a read: 1.36 ns against 0.84
  with none. No unchecked mode, or check per loop, until a real program shows the need. Written in Shen, only
  `bit-not`, `rotate32` and `bswap32` could move, freeing about 21 of 230 lines of C.

### Not tried yet

- **A bump-allocated code region, and a flag per cell for `redefine`'s scan** (2026-11-03, M3 Max). SLJIT's
  first-fit allocator held 28-36% of samples when re-evaluating definitions and the scan 8%, in a loop that
  redefines the same names. Either adds code without simplifying anything.
- **The lowerer computing `(cons (hd X) Acc)` before `(tl X)`** (2026-11-02). Would let `tl X` go straight to X's
  slot in `reverse`-style loops. Needs the lowerer to know X is a pair for the whole branch. No estimate.
- **Rotating loops, with the exit test repeated at the back edge** (2026-11-03). Its backward jump must meet the
  body label's state, and in open loops it would pass by the patched jump. No estimate.
- **Stores of pattern parts used further on** (2026-11-03, M3 Max). What remains of the pattern rows (a nested late
  mismatch 5.5 ns, Shen/Scheme 4.0) was judged to need a register allocator.
- **First-argument clause indexing** (2026-11-04, M3 Max). Sound. `hamilton` 0.66 with `edge` split by hand;
  estimated 6% on `subset`, 4% on `queens-8`, under 1% on the kernel suite. A lookup in 1,000 clauses takes 2.784
  µs against 0.043 for SWI-Prolog with -O.

## The collector, memory, the guest stack and images

Cheney semispace copying with inline bump allocation and no write barrier; a guest stack scanned linearly with no root
maps; an image is the live heap after a collection, with relative pointers. Ratios are new time over old. "Kernel suite"
is the Shen kernel's own test suite, which mostly loads and typechecks code, and "`tak`" is Prolog `tak`.

### Design choices (2026-11-01)

- **Semispace copying.** The earlier prototype's generational collector had a `heap.c` of about 2,900 lines, with
  non-moving old spaces, remembered sets and root maps. The first collector and image code here took 439 lines.
- **Rejected: precise root maps and values in registers across calls.** They need root analysis in the compiler, the
  largest source of complexity in the earlier prototype, whose own trials rejected those registers (18.9% more code).
- **Rejected: a non-moving mark-sweep old space** (page types, free lists, an estimated 400–600 lines). Reconsider only
  if long-running programs with large live heaps become a real workload, or C needs stable addresses.
- **Pairs stay two words with no header.** Rejected: a header on every pair (half as much memory again per pair) and
  separate pair storage with its own scan cursor.

### What collections copy (2026-11-01, Apple M3 Max)

Gate: stop if collection stays under about 10%. Share of time and longest pause: kernel suite 13.4%, 2.2 ms; the suite
four times in one process 23.3%, 10.3 ms; `tak` 46.5%, 12.8 ms; realistic applications 2%, 0.4 ms. The image, assumed to
be the main cost, is 141K words (1.2 MB), while a suite run copies 77K–700K words per collection besides it. Over four
runs global cells grow from 4.4K to 145K, with about 72K interned symbols, mostly `gensym` names, and constant slots from
7.9K to 45K.

**`tak` is not evidence** (decided 2026-11-04). It needlessly allocates big vectors, which a kernel hook could improve,
and its time moves with where collections land: allocating 4% less took it from 0.130 to 0.165 s (2026-11-01, M3 Max).
Nothing in the runtime changes for it alone.

### Non-moving image region: built twice, dropped twice

- **2026-11-01, with a write barrier** (M3 Max, against the plain collector), about 100 lines. Every suite passed, under
  stress too. Kernel suite: 25% less copied, collection 46 to 44–45 ms, longest pause slightly up. Applications:
  collection about three times less, on 2% of their run. `tak`: no better. The tightest vector-write loop got 5–12%
  slower. Reverted.
- **2026-11-04, without a barrier,** scanning the whole image at each collection, about 80 changed lines, to see whether
  it made smaller semispaces pay. Ryzen 5 5600X virtual machine, against the code before at 32 MB, at 16 MB with and
  without it: kernel suite 1.06, 1.07; short lists 0.96, 1.01; deep recursion 0.95, 0.99; `tuple create` 0.74, 0.80. A
  collection on short lists at 4 MB took about 217 µs instead of 330, where a fifth was hoped for: reading 700 KB through
  cold caches is bound by memory as well. Reverted.

### Copying (2026-11-02, M3 Max, against the build before)

- **No `memcpy` per object,** about 10 lines. `memmove` was 61% of a run that spent 63.5% collecting. Kernel suite
  collection 0.052 to 0.039 s, longest pause 2.65 to 2.1 ms; `tak` 0.136 to 0.107 s.
- **List spines copied at once,** about 15 lines. Breadth-first copying scattered a surviving list's pairs among the live
  heap. `reverse` of such a list 1.67 to 0.90–1.11 ns per element at 1,000 elements, 1.85 to 1.15 at 10,000; the benchmark
  campaign 1.006 open and 0.997 sealed; `shen.sysfunc?` 14–22% faster.
- **Repeated pointers in a scan,** about 5 lines. `absvector` fills every slot with `shen.fail!`, and a Prolog query's
  vector holds a million. `tak`'s 26 collections 0.193 to 0.147 s.
- **Large objects apart,** about 170 lines. Vectors and strings of 32K words (256 KB) or more get their own block, marked
  and scanned in place. A dead block is kept until the next collection for an object of the same size, so a query does not
  touch 8 MB of new pages each time. `tak` collection 0.120 to 0.046 s and the run 0.247 to 0.179 s; short-lived pairs
  beside a live 2M-element vector 0.075 to 0.040 s. First try: leaving them out of the semispace sizing kept 32 MB, doubled
  the collections and lost the gain.

### Symbols and dead code (2026-11-02, M3 Max)

- **Weak intern table,** about 60 lines, after a 14-line lowerer fix that stopped a `gensym` per inlined argument. After four
  kernel-suite runs in one process, before, with the fix and with the table: symbols 86.4K, 61.1K, 16.5K; live heap 12.1, 9.3,
  6.7 MB; time collecting 22.8%, 19.2%, 15.7%; longest pause 10.2, 4.5, 3.2 ms. It keeps symbols with a value or function, or
  called by name from compiled code, which holds only a cell index.
- **A bug this allows** (2026-11-04). `save-executable` interned a symbol and kept only its cell across more allocation. A
  collection freed both, and the saved binary ran as the launcher. It showed at stress 1 and 10, and at 1000 on a release
  build.
- **Constants of dead code,** about 110 lines. After four runs, 26.9K of 45.3K constant slots (59%) were dead code's, and kept
  5,027 code objects alive. A code object now owns its slots, and one pass after collection frees the unreached. Live heap
  6.67 to 5.62 MB, code objects 13.5K to 8.4K. Rejected: a weak list of code objects for that pass, as reading each header
  added 20–30 µs per collection.
- **Native code of dead code,** about 60 lines, through a weak list, at 7 µs per collection in the kernel suite. Defining
  20,000 functions through `eval` frees 40,003 of 40,206 code objects, peak memory 122 to 114 MB, time unchanged. The 23% a
  profiler gave the allocator was its bias toward returns from the kernel, and 1 MB chunks for SLJIT's allocator changed
  nothing.
- **What else grows, left as it is.** After four runs, `*property-vector*` reaches 4,043 KB from 70 KB, 75% of the live heap,
  almost all `shen.source`. Each `(datatype ...)` defines new `gensym`-named helpers, about 0.5 MB of source per run here. It
  is the kernel's behaviour in every port.

### Semispace size and growth

- **2026-11-01.** 32 MB each at the start, doubling when live data passes 40%, never shrinking. At `SHEN_JIT_MAX_HEAP`
  (2026-11-02) the last tenth is a reserve, so that raising a catchable "out of memory" has room.
- **A smaller default: rejected** (2026-11-04). Ryzen virtual machine, best of 3 to 7, at 32, 16, 8 and 4 MB: `tuple create`
  2.05, 1.63, 2.11, 3.64 ns; short lists 1.00, 1.01, 1.20, 1.72; kernel suite 1.00, 1.07, 1.14, 1.15. Each collection copies
  the kernel's data, about 330 µs. `SHEN_JIT_SEMISPACE` makes it a choice: on the M3 Max, `hamilton` at the same sizes takes
  62.8, 63.7, 66.3, 73.6 µs and peaks at 72, 37, 21, 12 MB, against SWI-Prolog's 8 MB.
- **Starting at 64 MB: rejected** (2026-11-04). Ryzen, then M3 Max: stlib install 0.83, 0.84; kernel suite 0.99, 0.97; short
  lists 1.02, 1.12; a long list kept 1.43, 1.52. Not measured since growth got cheaper.
- **Growing in place** (2026-11-04). Growing copied live data a second time into a new block. Both semispaces now lie in one
  reserved block, and growing commits more. Best of 15, against the code before, Ryzen then M3 Max: stlib install 0.86, 0.91,
  longest pause 25.7 to 12.3 and 18.4 to 10.2 ms; a long list kept 0.75, 0.78; non-tail recursion over it 0.80, 0.92; short
  lists 1.00, 1.00; kernel suite 1.03, 1.00. The 1.03 is unexplained, as that run never grows. Ruled out: code placement, the
  reservation's size, the heap's start alignment, the field's place in the VM struct, `PROT_NONE` against a writable mapping.
  Rejected on paper: swapping in a larger block at the next collection, no help when the space is full after the first copy.
- **Reservation size** (2026-11-04, macOS, M3 Max). Startup 2.74 ms before; 4.51 at 1 TiB each, 3.18 at 256 GiB, 2.85 at 64
  GiB, 2.78 at 16 GiB. Linux shows none. Kept 64 GiB.
- **Staggered spaces** (2026-11-04, Ryzen). A reservation apart, low address bits match and collections take longer: 0.033 s
  against 0.028 on short lists, 0.126 against 0.085 on recursion. Probably the L1 way predictor, not measured. 33 MiB and 64
  KiB more cures it. A shift of 4 KiB works there and is less than a whole page on the Mac.
- **Huge pages on Linux** (2026-11-04, Ryzen, against in-place growth), one `madvise`: a long list kept 0.76, stlib install
  0.93, kernel suite 0.98, short lists 0.99. A bare start takes 5 MB instead of 4.
- **First writes: not done.** The first row to touch the semispaces pays about 4 ms of page faults (2026-11-03, M3 Max), and
  Windows 10 about 13 ms against Linux's 3 on the same Ryzen (2026-11-04). Touching the heap at startup would put 32 MB
  resident in every process. A smaller start means more collections. Large pages on Windows need a privilege.

### The guest stack

- **2026-11-01, dirty mark.** Slots above the top are kept cleared for the linear scan, and clearing to the end of the stack
  meant 64 MB per collection after a 10⁶-deep recursion. Entry checks now compare against a mark above which all is clear, and
  collections clear only to it.
- **Rejected 2026-11-02: scanning only frames pushed since the last collection.** Every collection moves every object, so
  every slot needs updating. It needs a nursery whose older objects stay put.
- **2026-11-04, a missing reservation.** A nested call from C near the end of the stack wrote past its block, as leaves skip
  the stack check: one bus error in about 6,000 runs. Guard Malloc named the writer, and the CLI tests now sweep those
  alignments under it on macOS.

### GC stress and poisoning

- **2026-11-01.** Stress collects after every N words. At N=1 the kernel suite would take hours, so suites use 1,000. Loops
  under N=1 must stay short: two cases of 3,000,000 iterations took about 15 minutes, and 20,000 test the same path in 12 s
  (2026-11-03).
- **2026-11-03.** gcc on x86-64 evaluates arguments in another order than clang, which exposed two test programs reading a
  value before another argument's allocation moved it.
- **2026-11-04, old space poisoned under stress.** Before, a stale pointer read what was still there. The suites found no
  stale read beyond the one its first test was written to show: C roots shared by threads, which crashed 3 runs of 3 and pass
  3 of 3 per thread. Its limit: the semispaces take turns, so after an even number of collections a stale pointer is back
  inside the heap.

### Images and executables

- **2026-11-01.** An image loads only into the build that wrote it, and holds no native code: code compiles at first entry.
  First kernel image, Apple silicon: 1.26 MB, startup 3.4 ms against Shen/Scheme 0.52's 188 ms, resident memory 3.6 MB
  against 57.
- **Byte-identical round trip.** An image written from a loaded image must match it. This found 28 words from transient roots
  (2026-11-01), and made the weak table rebuild the same way from any layout of the same symbols (2026-11-02). Large objects
  are copied into the heap first, so the format stayed.
- **Size.** Dictionaries ignore the requested size, so the property vector has 256 buckets instead of 20,000: image 1.27 to
  1.12 MB (2026-11-01). Bytecode as variable-length integers: 699 to 181 KB, image 1.22 to 0.70 MB, live heap at startup 1.1
  to 0.6 MB, with startup and collections unchanged (2026-11-02, M3 Max). 16-bit operands, considered first, would have
  roughly halved it.
- **Executables.** A trailer gives an image's length, so one appended to the runtime is found from the end of the file
  (2026-11-02). `save-executable` (2026-11-03) is about 90 lines of C and gives 1.0 MB on macOS. It ends the process, as an
  image holds no frames, and writes beside the path and renames, so a binary can replace itself.

### What a future collector should know

- **Costs** (2026-11-04, M3 Max). A root pass is about 0.7 ns per word, 7 µs with the kernel loaded and 25 µs during the
  kernel suite. A copied word is 2–4 ns. Live kernel data is about 660 KB. x86-64 allocation is bound by memory: about 14 GB/s
  on the Ryzen virtual machine against about 28 on the M3 (2026-11-03).
- **The C API leaves room for a collector like OCaml's** (2026-11-05). C stores values only through `shen_vector_set` and
  `shen_root_set`, where `caml_modify` would go, and holds nothing across an allocation outside roots. The header names no
  layout beyond the fixnum encoding and a few constants. One assumption is left: the heap does not move while a thread holds
  the lock and makes no API call, which `bytes_data` and `string_bytes` need.
- **Each step lands alone,** with stress tests, the image round trip, the benchmark comparison and a line count, and deletes
  what it replaces. The set of barrier sites stays closed and documented.

### Not tried yet

**A generational nursery:** sized and deliberately left out for now (2026-11-04), with a collector revision wanted someday.
Real programs would gain 6–15% and allocation loops on x86-64 15–27%, against about twice the time where data lives and a
barrier every C store must honour for good. About 200 lines by estimate: today's semispaces as the old space, survivors
promoted at once, remembered slots in a fixed buffer, no barrier on cells and constants. Nothing below ran with a real one.

- **Survivors at 4 and 16 MB** (M3 Max, throwaway build): kernel suite 2.9%, 1.5%; stlib install 23%, 24%; short lists 1.0%,
  0.3%; a long list kept 100%; an old vector filled with new pairs 38%, 10%.
- **1 MB does not work** (M3 Max). Short lists fill it every 77 µs, root passes take 9% of their time, and projected collection
  is three times today's (0.05 s against 0.017).
- **The gate,** set before measuring: x86-64 time outside collection down 15% or more on the kernel suite and short lists. Ryzen
  virtual machine, best of 9, collecting every 16, 4 and 1 MB: kernel suite 0.99, 0.98, 0.98; short lists 0.92, 0.85, 0.84;
  tuples 0.86, 0.77, 0.76. Short lists reach it and the kernel suite does not.
- **Projected whole time at 4 and 16 MB.** Ryzen: kernel suite 0.94, 0.94; stlib install 0.85, 0.89; short lists 0.84, 0.85;
  tuples 0.73, 0.78. M3 Max, where data lives: a long list kept 1.9, 1.9; non-tail recursion over it 2.3, 2.0; an old vector
  filled with new pairs 1.9–2.3, 1.5–1.9. Every survivor is copied once more.
- **Risks.** C may store into an object it allocated before a later allocation, as `grow` in `dict.c` does, and with promotion
  that object can be old by then. Stress finds a missed barrier only if a minor collection falls in that window. A failed
  `address->` check under a quiet handler jumps straight to the handler, so a barrier leaving by that path loses stores under
  `trap-error`, as a forced store did in the throwaway build. So keep the barrier inline.

**Smaller ideas:**

- A port override of `shen.record-kl` that skips the source of the kernel's `shen.consume*` helpers: about 5 lines, about 0.5 MB
  per run in the workload above.
- A kernel hook for Prolog's big vector. Lazy Prolog state was measured and left out (2026-11-04, M3 Max): queries use a mean of
  53 of 10,000 slots in the kernel suite, yet lowering `prolog-memory` to 1000 reads 1.00, as a dead vector is never copied.
- Shrinking the semispaces or the guest stack, and walking frames instead of scanning the stack linearly.

## The lowerer, the bytecode, the kernel port and Prolog

Terms used below. Before → after numbers and bare ratios compare a change with the build just before it, unless the
entry says otherwise, and a ratio is new time over old, so 0.76 is faster. The campaign is an earlier prototype's
benchmark set of 156 timed rows: canonical micro-benchmarks, and "other drivers" for calls, applications and Prolog.
"× Shen/Scheme" is a multiple of the campaign's recorded Shen/Scheme time. Open code can be redefined; sealed code
cannot. The kernel suite is the kernel's `tests/runme.shen`; the stlib install loads the standard library.

### Bytecode and lowering rules

- **Register bytecode, lowerer in Shen** (design, 2026-11-01). An earlier bytecode VM's profiles had constant, stack and global traffic
  dominating retired instructions, so the JIT's only input is register bytecode with resolved slots and literal
  operands, with no interpreter. The lowerer emits symbolic Shen lists that C encodes by name, so no encoder is
  generated. Semantic decisions stay in Shen: that VM had removed a C pass that found match plans in bytecode.
- **Constant operands** (2026-11-01, Apple M3 Max, campaign). A literal used to be copied to a slot and read back.
  Overall 1.14 → 1.00 × Shen/Scheme.
- **Tail-call arguments in place** (2026-11-01, Apple M3 Max, campaign). A named tail call uses window 0, so each
  argument goes straight to its parameter slot. 0.93 → 0.85 × Shen/Scheme open, 0.89 → 0.77 sealed.
- **Closures removed by rule** (2026-11-01, Apple M3 Max, campaign). `((lambda X Body) A)` is a `let`: a call to
  another package's function 23 → 2.2 ns. A freeze thawed once becomes its body: `lexical-known thunk` 8.5 → 2.7 ms
  (Shen/Scheme 1.1). The factoriser's `GoTo` freezes become labels when every thaw is in tail position.
- **Calls with all arguments at once.** Rejected on 2026-11-01: closures linking to parents, or multi-argument calls,
  looked like a large change for one row at 2.6 × Shen/Scheme. Done on 2026-11-02 in a smaller way (Apple M3 Max): a
  lambda returning lambdas, lowered at runtime, gets a second copy of its innermost body, at most 400 nodes. `lambda
  with many arguments` 14.9 → 2.5 ms (Shen/Scheme 6.5, earlier prototype 7.8), image +6.8 KB. Stage 0 code gets none:
  the kernel does not apply its own chains that way, and it would have added 35 KB.
- **List literals as constants** (2026-11-02, Apple M3 Max). `list equality (true)` 0.326 → 0.107 s (earlier prototype
  0.108). Lists of 64 nodes or more stay code, or the kernel's start-up tables would be kept alive by their code.
- **Packed bytecode** (2026-11-02, Apple M3 Max). Variable-length integers, where 16-bit operands had been the earlier
  idea. Kernel bytecode 3.9 times smaller, image 1.22 → 0.70 MB, startup and benchmarks unchanged.
- **Calls through `fn`.** Sealed F became a direct call (2026-11-01, Apple M3 Max, campaign: 3.1 ms sealed against
  23.8 open). For open F a cache per call site was rejected, as it needs a hook in `put`. An inline arity test did it
  instead (2026-11-03, Apple M3 Max): `cross-unit-global-unary-ordinary` 18.1 → 2.7 ms (earlier prototype 1.7).

### Sealing and inlining

- **What is sealed** (2026-11-01). First decided as in Shen/Scheme: a later `defun` of a kernel name changes open
  calls only. Revised the same day: redefining a kernel, port or lowerer name raises, also through `eval-kl`, so that
  user code can inline them. Extensions stay open, as their tests reload them. Sealing user code is an option, off by
  default; a sealed call to an undefined name binds at its first call, so no file grouping is needed. With inlining
  and slot sharing (Apple M3 Max, campaign): open 1.00 → 0.93 × Shen/Scheme, sealed 0.89.
- **Limit of 15 nodes, two levels deep** (2026-11-01, Apple M3 Max, against 15). A limit of 40 grew the image 1.24 →
  1.72 MB and slowed the kernel suite 0.40 → 0.47 s. Bodies with real literals are refused, since stage 0's host and
  Shen/JIT may read their last bits differently.
- **Slot sharing** (2026-11-01, Apple M3 Max, campaign). A `let` of one variable to another shares its slot. Without
  it, sealed `realistic-call-heavy` took 0.29 s against 0.12 s open; with it, 0.073 s.
- **Open callees inlined too** (2026-11-03, Apple M3 Max). Measured first: a build with no arity check timed the same,
  and a call too large to inline costs the same open or sealed (1.5 against 1.6 ns), so entering past the arity check
  and patching open call entries were rejected. Open calls inline behind a guard that a redefinition patches: a small
  callee 1.4 → 0.76 ns, `realistic-call-heavy` 0.48, other drivers 0.845.
- **Compile time, accepted** (2026-11-03, Apple M3 Max, re-evaluating eight definitions, against a build from earlier
  that day). 253 → 310 µs a round, 269 without open inlining and 308 with one level of it, so taking it back means
  inlining less. Compile-heavy workloads lost 3-5%; switching open inlining off takes 1% back.

### Factorisation

- **No factoriser in the lowerer** (design, 2026-11-01). That VM's bytecode compiler took about 3.4k lines with
  factorisation and pattern work. The lowerer uses the kernel's `shen.factor`, as Shen/Scheme does.
- **`define`'s output factorised** (2026-11-02, Apple M3 Max, without `(factorise +)`). Only that output, since
  `shen.factor` raises on a `cond` with no final `true` clause; `ps` still shows it as written. A 12-element list
  pattern 17.4 → 3.6 ns, twelve clauses 263 → 5.9 ns.
- **Bodies reuse what tests bound** (2026-11-03, Apple M3 Max). The factoriser binds parts of the argument inside the
  `and` chain, out of the body's reach, so the lowerer makes the chain nested ifs failing to a label: `nested list
  pattern (matching)` 9.2 → 6.4 ns. This first made the kernel's failure continuation a closure on every call:
  `realistic-pipeline` 1.15-1.22 times as slow, caught by a campaign rerun and fixed that day.
- **That rule made clause chains cubic** (2026-11-04, Apple M3 Max). One `defprolog` of 400 facts loaded in 23.3 s,
  now 0.23 s (Shen/Scheme 0.30). 5000 facts take 43 s against 24; the rest is the kernel's compiler, left alone.
- **Rejected: testing shared clause tests once before the chain** (2026-11-03, Apple M3 Max, trial build). A
  12-element pattern went from 22 compares to 12, and `match list (multiple clauses, matching)` stayed at 5.1 ns
  (earlier prototype 4), as the compares are predicted.

### Kernel overrides

Each override needs its own measurement; none is applied because another port has it. Reviewed on 2026-11-02 against
all that Shen/Scheme and the earlier prototype replace.

- **Left as the kernel's** (2026-11-02, Apple M3 Max, against Shen/Scheme 0.52). `not`, `boolean?` and
  `shen.byte->digit` inline as they are. `pr`: 2 MB of output in 40 ms against 41; writing a string at once waits for
  an output-heavy program. `element?`: 1.1 ns per element against 2.4.
- **`symbol?`** (2026-11-01). The kernel's relies on `str` raising on non-atoms, which `str` here never does, as in
  Shen/Scheme, so closures and Prolog variables read as symbols: all 12 first failures of the kernel suite.
- **Numbers** (2026-11-01). Integers are fixnums and overflow raises, where Shen/Scheme has bignums. Literals beyond
  that range become reals, and `8.0` reads as 8, as in Shen/Scheme, so KLambda source cannot write the real `0.0`.
- **Small functions split or replaced** (2026-11-02, Apple M3 Max). The kernel's `integer?` took 21 ns for 7 and 1 µs
  for 1.0e15, now 0.86-2.6 ns (Shen/Scheme about 1). `<-vector`, at 18 nodes, missed the limit of 15, so its failure
  could not reach a caller's quiet handler by a jump: under one 6.7 → 2.1 ns. `shen.+vector?` split and
  `shen.+string?` testing the type first: failing patterns 0.57-0.62.
- **Reader rules** (2026-11-02, Apple M3 Max). Loops over runs of bytes where the kernel's rules build a parse result
  per byte. Reading 1,000 definitions 10.6 → 5.8 ms; 13 packaged kernel sources 26 → 22 ms (Shen/Scheme 86).
- **`append` in C, `reverse` not** (Apple M3 Max, against the kernel's). `append` copies in one pass into the free
  space (2026-11-02): 32 elements 61 → 32 ns (Shen/Scheme 43), one element 0.5 ns slower. The same for `reverse`
  (2026-11-03) was rejected: 37 → 32 ns at 32 elements, but 2.4 → 3.3 ns at one and 233 → 320 ns at 256.
- **Loading** (2026-11-02, Apple M3 Max). `shen.record-kl`'s `adjoin` made loading quadratic: a name with no
  `shen.source` property now goes straight on the list. Files read in C were first judged not worth it, at most 8% of
  `load`, then done, as the kernel's `read-file-as-string` is quadratic too. Both: 9,000 definitions 636 → 245 ms.
- **Lazy lambda forms** (2026-11-02, Apple M3 Max). Reading a definition compiled a curried lambda that `fn` rarely
  needs. A placeholder holding the arity now waits for `fn`, and `shen.*gensym*` still moves by the arity, so later
  gensyms are unchanged. Reading the property directly shows the placeholder. With `eval-kl` returning a non-list
  uncompiled, 3,000 definitions compile 208 code objects, not 6,217.

### Prolog

Prolog `tak` is not evidence for runtime changes: it needlessly allocates big vectors, and a kernel hook could fix
that. Its readings decided nothing below.

- **Head patterns as `let`s** (2026-11-02, Apple M3 Max). The Prolog compiler binds a curried lambda per head pattern.
  Each use becomes `let`s, copies adding 1,500 nodes at most: `subset` 0.74, `nreverse` 0.75, Einstein 0.75. A split
  `shen.deref` was rejected then: `queens-8` level, Einstein 6% faster, `subset` 12% slower.
- **Immediate variables** (2026-11-04, Apple M3 Max, interleaved, best of 15, and then Ryzen 5 5600X VM). The kernel's
  absvector per variable was 12.4% of the kernel suite's bytes. Einstein 0.77 and 0.86, `nreverse` 0.91 and 0.84,
  kernel suite 0.97 and 0.96. The one reader of an offset outside the kernel's Prolog was fixed in kernel 43.2.
- **Rejected: lazy Prolog state** (2026-11-04, Apple M3 Max, trial runs). Queries use a mean of 53 of 10,000 slots in
  the kernel suite, but `prolog-memory` at 1000 reads 1.00 on it and on the stlib install: a dead vector is never
  copied, and only its fill costs. It would add a load to every binding access.
- **Closures, in three steps** (2026-11-04, Apple M3 Max and then Ryzen 5 5600X VM, against the build before them).
  Einstein's closures were 92% of its allocation, 69% of those from unifying lists. A unifier with no closure per
  element; `shen.bind!` with its continuation in place; a let-bound freeze reaching only `thaw` and `shen.bind!`, and
  an inlined body thawing a literal freeze once. Einstein 0.66 and 0.64, `subset` 0.84 and 0.83, kernel suite 1.00 and
  0.99, stlib install 1.03 and 1.02. Tried: copying from the outside in was exponential, `subset` taking 10 s to load;
  a limit of 1,500 nodes read 1.05 on the kernel suite and 1.06 on the stlib install, so freezes copy within 100.
  Later that day, against the build before it, a closure too large to copy waited for an atom pattern's tests:
  `hamilton` 0.85, stlib install 1.02.
- **Trail with `is` in place** (2026-11-04, Apple M3 Max). The unifier returns the variables it bound, or undoes them
  and returns false, so nested lists make no closure either. `nreverse` 0.91, Einstein 0.98, stlib install 1.02. The
  trail without the lowering rule read 1.02-1.07, so they go together, and the continuation is then never a tail call.
  With the occurs check off the unifier kept the kernel's `=` on two lists for terms that hold themselves, which made
  Einstein slower off than on (1141 against 825 µs); an identity test ends those terms too.
- **`shen.lazyderef` as an inline primitive** (2026-11-04, Apple M3 Max). Nearly every variable is one step from its
  value (mean 1.00 to 1.04 on seven programs), so the cost was the call, about 2.7 ns. Binding the younger variable to
  the older, as a WAM does, would not help for the same reason. `hamilton` 0.63, Einstein 0.76, kernel suite 0.96.
  `shen.deref` followed, inline for all but pairs: `queens-8` 0.87.
- **Rejected: a unifier shaped for loop registers** (2026-11-04, Apple M3 Max). Its frame has 10 slots where 8 fit, so
  it never got them, and its helper cost the kernel suite 1.01 and the stlib install 1.03, for the same Einstein 0.92
  as the change kept: heads that are not pairs unified with no recursive call.
- **Rejected: fewer checks in `shen-jit.deref`** (2026-11-04, Apple M3 Max, best of 15). Slots known to hold
  absvectors, about 30 lines: Einstein 0.99, `hamilton` 0.97, but the kernel suite 1.01 and stlib install 1.02.
- **Rejected: first-argument clause indexing** (2026-11-04, Apple M3 Max, estimated from counts and a hand-split
  `edge`). Sound, and left out. At about 2 ns per failed clause `subset` would gain about 6%, the kernel suite under
  1%; `hamilton` by hand 0.66. Only large fact tables fall behind: a lookup in 1000 clauses takes 2.784 µs against
  0.043 for SWI-Prolog -O, and a real index needs a hash or jump table.
- **Standing** (2026-11-04, Apple M3 Max, CPU time per iteration, seven programs, geometric means). 0.85 of SWI-Prolog
  10.0.2 -O and 0.50 of Shen/Scheme 0.52 when first compared, 0.65 and 0.38 after the changes above.

### Native code written by hand

- **Level** (plan, 2026-11-02). Of KLambda through `eval-kl`, bytecode, and SLJIT operations, we chose bytecode:
  portable, checked, and the result is an ordinary procedure. SLJIT stays an option at about 400-700 lines.
- **`define-native`** (2026-11-03, Apple M3 Max, against a `define` that also tests for `[]`). A macro over forms,
  since brackets in Shen mean lists; `shen-jit.assemble` and `shen-jit.install-code` take lists, for generated code.
  The checker's rules moved to `lib/native.shen`, so one set holds the lowerer's output and hand-written code. Two
  rules are new, as the JIT relied on them unchecked: handlers nest in code order, and a handler reads no slot written
  since its push. Summing a list takes 0.83 of the `define`'s time. Fuzzing: 3,500 mutated code objects, about 390
  accepted and run, no crash.
- **Byte buffers in place of raw slots** (2026-11-03, Apple M3 Max). Lifetime, images and bounds do not arise for a
  heap object with its length in its header. No unchecked mode until a real program shows it matters: the checks are
  0.52 ns of a 1.36 ns `u8`, in a loop that sums bytes (no checks 0.84, C not vectorised 0.32).
- **Rejected: buffers and bit operations in Shen** (2026-11-03, Apple M3 Max, against the C primitives). Only three
  could move, freeing about 21 of 230 lines of C. `copy-bytes` is 34 times slower at 64 B.

### Kernel pins and reproducible stage 0

- **Self-hosting check** (2026-11-01, Apple M3 Max). The lowerer inside Shen/JIT must give stage 0's output exactly:
  1,162 defuns in 0.29 s, against 0.36 s under Shen/Scheme. It found: `read-file` macroexpands, so stage 0 reads
  KLambda unprocessed; `symbol?` differs between hosts, so the lowerer has an exact primitive, also making it 13 times
  faster inside Shen/JIT; `strtod` and Shen's reader can differ in a real's last bit, so stage 0 writes what it read.
- **Manifest and host independence** (2026-11-03). `generated.sha256` holds the hashes of the 51 generated files, and
  a tarball builds from them with a C compiler alone. Stage 0 on Linux x86-64 with Shen/Scheme's v0.52 release binary
  gives them byte for byte as on macOS arm64 with the pinned checkout.
- **Released kernels only** (2026-11-03). A pin check does not cover `klambda/`, git-ignored in the kernel, and the
  copy in use predated commits the pin included. We keep the latest release and do not rebuild from main; an
  unreleased type-checker optimisation stayed out, though it read 0.91 on the kernel suite (271 → 247 ms, Apple M3
  Max). Since 2026-11-04 CI takes the kernel's and Shen/Scheme's release archives, checked by hash.
- **Kernel 43.2** (2026-11-04, against 43.1). The type checker dereferences a term once per call: kernel suite 0.89 on
  Apple M3 Max (215 → 191 ms) and 0.93 on Ryzen 5 5600X VM (301 → 279 ms), stlib install 1.00 on both.

- **A previous `shen-jit` as the stage 0 host** (2026-11-05, Apple M3 Max, tried and not yet the default). Stage 0 ran in about 1 s against about 6
  under Shen/Scheme, 48 of the 52 generated files came out byte for byte, and the system built from that output passed the eval cases, the self-hosting
  check with 0 differences, the kernel's tests, the CLI tests and the FFI suites. It needs no hook in the host's runtime, only in the build tools: the lowerer's own names are sealed in the host's image, so a new lowerer loads
  under other names; the host's `define` must know the arity of `shen-jit.inline-body`; and `filter` is Shen/Scheme's, so the tools define it. Of the four files that differ, `port/lower.kl` and the two made from it differ as the host compiles
  and numbers things its own way, and `kl/ops.sbc` as `-2305843009213693952`, the smallest fixnum, reads as a real under `shen-jit`, its digits overflowing before the sign applies. So the manifest would have to follow one host, or those be normalised.
- **The smallest fixnum as a literal: a reader fix rejected** (2026-11-05). `-2305843009213693952` reads as a real, because `shen.compute-integer` gets only the digits, which are past the range, and the kernel's `shen.<number>` applies the sign
  afterwards. A fix would override `shen.<number>`, 1.4 KB of generated code to keep in step with the kernel, for one value in 2^62. `docs/semantics.md` records the limit, and `tests/kl/ops.kl` computes the value instead, which takes
  `kl/ops.sbc` out of the files that differ by host: lowered under `shen-jit` and under Shen/Scheme it is now the same byte for byte, where one line differed before.
- **A previous release is the default host** (2026-11-05, Apple M3 Max). `v0.1` makes the generated files, in 1.4 s against 5.5 under Shen/Scheme 0.53, which stays as the way in that does not start from Shen/JIT. All 52 files are now the same byte for byte under both, so one manifest
  serves them and CI's `shen-scheme-host` job checks it: `port/lower.kl`, and the two files made from it, differed only in how the compiler numbered variables, from a gensym count that depends on the host, and `tokl.shen` now starts it from zero in each definition. That also stops a change to one
  function renaming the rest. The rename the experiment above needed is a build step, so both hosts take one path: `build/tools/lower.shen` has the lowerer under `stage0.lower.`, as its real names are sealed in a host that is Shen/JIT.

### Not tried yet

- **Correctly rounded literals past the fixnum range.** `shen.compute-integer` falls back to doubles digit by digit, so errors build up. The same arithmetic in Python (2026-11-05), on random integers: 55% of those of 19 digits land on the nearest
  double, the worst 3 units in the last place off; 8% of those of 300 digits, the worst 23. Handing the digits to `strtod` should fix it. Fractions and exponents were not looked at.
- The lowerer computing `(cons (hd X) Acc)` before `(tl X)`, so `tl X` goes straight into X's slot. It needs the
  lowerer to know X is a pair after its `cons?` test.
- Lowering the last operand into the destination, for long `cons` chains: `shen.initialise-environment` uses 830
  slots, and the next largest kernel frame 65.
- A dictionary behind `shen.sysfunc?`, 60% of reading code in a package (2026-11-02). It needs a way to tell that the
  278-symbol list changed.
- The lowerer lowering itself as a gate on every change, after Wirth and Gutknecht's rule that an optimisation must
  speed up the compiler compiling itself; and an audit of special cases against workloads outside the benchmarks.
- Raw slots for 64-bit integers and unboxed doubles, SIMD, and SLJIT operations written from Shen. Declared
  signatures, so typed code can call installed procedures.

## Runtime, threads, platforms and usability

Times are from an Apple M3 Max under macOS unless an entry names another machine. "The Ryzen VM" is a Hyper-V virtual
machine on a Ryzen 5 5600X with Ubuntu 20.04, gcc 9.4 and glibc 2.31. A bare ratio is new time over old time.

### Threads

- **Real threads under one global lock (2026-11-04).** Programs written for Shen/Scheme call `thread`, which is Chez's
  `fork-thread`, as in `(thread (freeze (tk.event-loop)))`, and failed here with an undefined function. We started with
  the simple case: one thread runs at a time, which gives concurrency for work that waits and no speed-up from more
  cores. Join, mutexes and channels are left out, as in Shen/Scheme. `thread` is defined after sealing ends, so that
  programs may define their own.
- **No measurable cost until the first thread.** Each thread's guest stack and handlers are swapped into the VM's fields
  at a switch, so emitted code and hot paths do not change. Against the build before: benchmark campaign 0.997, workloads
  outside the benchmarks 1.00. About 355 lines in all, against an estimate of 120 to 200.
- **Loop checks are needed once threads exist.** A 10 ms ticker asks the way Ctrl-C does, and a thread gives way at a
  frame or loop check, or while it waits on stdin. Without loop checks a spin-wait on a global would hold the lock for
  ever, so the first thread has all code compile again with them. On the Ryzen VM an empty loop then takes 0.54 ns
  against 0.43, and building short lists 1.08 times as long.
- **`exit` could hang:** it flushes every stream, and waits on one that another thread is blocked reading. With threads
  the process flushes what was written and calls `_exit`, so `SHEN_JIT_STATS` prints nothing then.

### x86-64 and Linux (2026-11-03)

Every suite ran in Docker (arm64 with gcc 15, x86-64 through Rosetta with gcc 14, from the release tarball), then natively on
the Ryzen VM, in 214 s. macOS had hidden everything below. Timing is in the JIT and benchmark sections.

- **Found in Docker:**
  - glibc hides `clock_gettime` under `-std=c11`; x86-64 needs `-lm` for `floor`, which arm64 inlines.
  - Two test programs read a value as an argument before another argument's allocation moved it, an order gcc on x86-64
    evaluates in and clang does not. The runtime itself had no such order.
  - `jit_destroy` left the call-site table and perf map allocated, which Linux's AddressSanitizer reports.
- **Found only on the real machine:**
  - The JIT could not start. glibc also hides `MAP_ANON` under `-std=c11`, so SLJIT mapped `/dev/zero` for its code, which
    fails where `/dev` is mounted noexec, as on Ubuntu. Docker's `/dev` is not, so every container had passed. SLJIT is
    now compiled with `_DEFAULT_SOURCE`.
  - The profiler's `dladdr` needs `-ldl` before glibc 2.34.
  - The kernel checks used `tee /dev/stderr`, which on Linux reopens a redirected log and truncates it.
  - `check-generated` depended on a glob's order, which follows the locale where `/bin/sh` is bash, and reported drift
    in unchanged files. It now uses C order.

### Native Windows (2026-11-04)

- **Toolchain:** gcc in MSYS2's UCRT64, which keeps one Makefile and the GNU tools, linked statically to need nothing installed.
- **Rejected: MSVC.** The JIT's code does not depend on the C compiler, so users would see nothing, at the cost of a second
  build system, replacements for GCC builtins and a second compiler to test. Worth reconsidering only to embed Shen/JIT in
  a Visual Studio project.
- **Rejected: WSL as the answer for users.** It means enabling a Windows feature and installing a distribution.
- **No JIT change was needed:** the Win64 convention worked at the first run, and its eight saved registers give loops four
  registers against Linux's two. Threads stay on pthreads through winpthreads.
- **What it found:**
  - `select` works only on sockets, so the read of stdin waits by itself, without the lock.
  - Ctrl-C runs on a thread of its own and ends the main thread's read with `CancelSynchronousIo`, only during a read:
    cancelling a write would lose what was being written.
  - `clock()` and `gettimeofday` tick once a millisecond, too coarse for rows of a few ms. `get-time` uses
    `QueryPerformanceCounter` and `GetSystemTimePreciseAsFileTime`, 0.1 us between two reads. `get-time run` is elapsed
    time there, as `clock()` is: the processor-time counter ticks only every 15.6 ms.
  - `*os*` said "Unix" there until 2026-11-05.
- **Tests:** every suite passes on Windows 10 from the tarball, GC stress included, but MSYS2's `kill` ends a native program, so CLI
  tests that send a signal do not run. A driver through a real console (2026-11-05) saw Ctrl-C end `accept` and `recv` in 92 ms.
- **Timing:** Windows 10 Pro with gcc 16 on a Ryzen 5 5600X, against the Linux VM it hosts: all rows 0.961 open and 0.939 sealed,
  applications 1.10; the kernel test suite 309 ms against 277, startup 7 against 2.
- **Its slower rows are a fixed cost per process.** Long application rows read 0.86 to 1.00; short ones at 1.2 to 1.7 lose 6 to
  10 ms each. Allocating 39 MB per pass takes 10.2, 7.2, then 2.4 ms there and 4.3, 3.8, then 2.4 on Linux: first writes to the
  semispaces, 16,000 small page faults where Linux has huge pages. A process that does nothing takes 2.3 ms against 0.26.
- **Rejected for that cost:** a smaller starting semispace on Windows, which trades one payment for more collections; large
  pages, which need a privilege a user must be granted.

### Release builds, static linking, CI and the standard library

- **Generated files ship only in tarballs (2026-11-03).** The repository stays free of 1.6 MB that changes with every lowerer
  edit. `make dist` writes a 0.95 MB tarball that builds with a C compiler and `make`; `SHEN_SCHEME=false` shows nothing runs
  Shen/Scheme. A manifest of the 51 generated files' hashes makes any other difference drift.
- **SLJIT without its debug checks (2026-11-02):** runtime 307 to 225 KB, executable 1,030 to 948 KB, JIT compilation about 13%
  faster (9,000 lambda forms, 34 to 30 ms). A first try compiled only `sljitLir.c` without them, so `jit.c` read the code size
  at the wrong offset, as the compiler struct changes with those options. The profiler's test caught it.
- **`make release` (2026-11-03)** strips the runtime before appending the image, which `strip` would drop: 0.96 MB against 1.0
  on macOS and 2.07 on Linux, where gcc's debug information takes 1.1 MB. The code is the same.
- **Static Linux, then both kinds (2026-11-04, 2026-11-05).** Linux release jobs were static at first. Static glibc `dlopen` works
  but loads a second libc (`/proc/self/maps` shows it), and a library calling into a static executable gets `undefined symbol`.
  So a static build refuses to load libraries, and says so. Release jobs became dynamic, built on an old glibc to run on newer
  ones, with static ones beside them until they cost more than they give.
- **CI (2026-11-04).** One job makes the tarball, the only one to run Shen/Scheme, and each platform builds it with a C compiler
  alone and runs every suite and GC stress. CI runners are not used for timing.
- **CI was rehearsed** with actionlint, in containers and on the Mac, before any run on GitHub. That found the
  `save-executable` bug below, and stray `\r` in five extensions' strings in the KLambda in use, unlike the 43.2 release and a
  fresh build of its tag.
- **Found later (2026-11-05):** release archives left out `lib/` and `include/`, so a binary could not have loaded `lib/ffi.shen`.
- **A flaky test, not a lost Ctrl-C (2026-11-05).** `thread-survives-interrupt` failed under GC stress on two runners of one CI run, with one `interrupted` in `spin` and another in the expression after it, which could have been the runtime delivering one signal twice. It
  was not: on Linux arm64 in a container of 1 to 3 CPUs, with up to 32 copies at once, all 287 rounds that sent more than one signal failed, and 472 of the 481 that sent one passed. The test's loop sent a second signal when the first had not shown in the output yet, and it reached the next expression. The
  failures with one signal whose output was kept had it land early, once, as the wait for the REPL ran out under that load. The next expression now waits in a FIFO until the interrupt has been seen.
- **Release notes come from the changelog, and releases start as drafts (2026-11-05).** `v0.1` went out at once, with GitHub's generated
  notes, which with one commit are only a link to the tag. A release is now a draft that someone makes public by hand, and carries its
  section of `CHANGELOG.md`, as Shen/Scheme's and the kernel's do. A tag with an empty section makes no release: those two fall back to
  a line pointing at the file.
- **Tag runs leave out the heavy suites (2026-11-05).** In a run on `main`, GC stress took 176 to 312 s per job, the sanitizers 43 to
  59 s and the mutated code objects 69 s, and a tag repeated them on the same commit. A tag's run now builds and runs the fast suites,
  10 to 19 s, on what it publishes, and the release job refuses a commit that has not passed on `main`. From those step times, a
  release should take about 2.5 minutes against 8.
- **bullseye moved to Debian's archive (2026-11-05).** The first run on GitHub failed both dynamic Linux jobs at `apt-get install`:
  `deb.debian.org` still lists bullseye's security updates but answers 404 for their files, which `archive.debian.org` has. The jobs
  use the archive rather than a newer Debian, to keep the executables needing only glibc 2.17, on both architectures.
- **Two faults behind that, found by replaying the job in Docker (2026-11-05).** Without perl there is no `shasum`, so the build id
  compiled in empty and the check that an image matches its build compared nothing: it now uses `sha256sum` where there is one. And
  the test of `[]` looked up `cos`, but Debian's gcc drops an unused `libm`, and the runtime uses nothing from it on either
  architecture: it looks up `strlen` now. The pinned images of `make test-linux` hid both, having perl and keeping `libm`.
- **The guide became Markdown (2026-11-05).** A hand-written page beside a 550-line README said most things twice, each with details
  the other lacked. `docs/guide.md` now holds them, pandoc renders it, and the README only points to it. It is read as GitHub's
  Markdown, so that it reads the same in the repository and its anchors match. The tarball carries the page, so that every release
  archive has it without each platform needing pandoc.
- **The standard library is left out of the default image (2026-11-01), optional since 2026-11-03.** The names it exports become
  system functions, so a program on it cannot define its own `take`. It also defines `min` twice, so it cannot be loaded sealed.
- **`make stlib`** loads the kernel's precompiled `stlib.kl` and saves a binary: a 1.7 MB image, starting in 3.4 ms against 2.8.
- **Found in its tests:** the first "typed code" test checked nothing. `load` decides whether to type check when it starts, so
  `(tc +)` inside a file does not apply to the rest of it.

### The REPL and small decisions

- **End of input ends the process, status 0 (2026-11-01).** The kernel's REPL, and so Shen/Scheme, prints "empty stream" at every
  prompt for ever, so piped input never finished. A read in user code still raises the error.
- **Line editing (2026-11-01):** documented `rlwrap`. `isocline` and `replxx` were rejected as more than this needs.
- **`(shen-jit.exit N)`, no plain `exit` (2026-11-02):** a sealed `exit` would refuse programs that define their own.
- **`track`, `spy` and `step` checked (2026-11-02), nothing to change.** `track` is refused on sealed definitions.

### Ctrl-C and standard input

- **Design (2026-11-02).** The handler only sets a flag and clears `check_limit`, the limit compiled code checks at function entry.
  Lowering `stack_limit` itself was rejected: it is also the dirty mark above which slots are clear.
- **Loops pay only under the REPL.** Self tail calls jump past the entry check, so loops test the flag at the back edge. That cost
  6 to 16% on the tightest loops and 2.6% over the canonical benchmarks, so only code compiled once the REPL catches Ctrl-C has it.
  Under `script` and `eval` SIGINT keeps its default and ends the process.
- **A program's `trap-error` cannot swallow it:** "interrupted" is raised again at every check until the REPL's handler is innermost.
- **Three bugs, each found by a real Ctrl-C through a pty (2026-11-04),** which earlier tests had missed:
  - At the prompt, or in a program reading stdin, it was dropped, so a half-typed expression could not be abandoned.
  - A loop compiled before the REPL started, as `eval -l FILE -r` allows, had no check, and with SIGINT caught nothing could stop
    it. The REPL now has all code compile again: 2.35 to 2.68 ms to start it, nothing for `script` or `eval`.
  - One landing while the REPL printed its prompt or an error, outside its handler, ended the REPL with "uncaught error:
    interrupted". It is now dropped: about 680,000 signals in 2 s, three runs, where before it died within 966.
- **stdin has its own buffer and read (2026-11-04),** which fixes the first bug. stdio's read would restart after a signal under
  `SA_RESTART`, which writes need, and does not say when it is about to wait. The wait is in `select`, which a signal always ends,
  and only the wait is without the lock. Threads block SIGINT, so that it reaches the main thread.

### Backtraces (2026-11-02)

Built from a table of call sites the JIT records when it compiles, so nothing is paid until an error asks.

- **When to capture took two tries.** "No handler is active" cannot work, as the kernel's REPL wraps every evaluation in `trap-error`.
  "The REPL's handler is innermost" is not enough either: with typechecking on, the kernel raises again from its own frames. A trace
  is kept when the innermost handler, if any, belongs to a frame at or below the REPL's, only if the walk reached the expression being
  evaluated, and only the first in each evaluation.
- **Rejected: breakpoints, stepping and inspecting locals.** They need an interpreter or deoptimisation back to bytecode, the machinery
  that made the earlier prototype large.
- **Inlined bodies (2026-11-03)** stay in backtraces, at a cost in the first version: `h_prim` noted its own return address, so it kept
  a frame, about 1 ns on every primitive called through C (`append` 1.21, `trap-error` raising 1.22 to 1.33). Slow paths in inlined
  bodies now store the site themselves.

### Profiler and heap statistics

- **`SHEN_JIT_PROFILE=1` (2026-11-02)** prints a flat profile from a SIGPROF timer, in about 180 lines of C. Not on Windows.
- **Its bias misled us once.** Samples land where system calls return, so it over-counts C. Loading 9,000 definitions it gave 23% to
  SLJIT's executable allocator; timed directly, all JIT compilation took 23 ms of 645. Time a profile's claim before acting on it.
- **`SHEN_JIT_STATS`** prints collections and pauses (2026-11-01), then the live heap by type after a final collection (2026-11-02).
  That showed two thirds of the live heap at startup was kernel bytecode (707 of 1,113 KB); packed bytecode followed the same day,
  699 to 181 KB, and the image 1.22 to 0.70 MB.

### Saving programs

- **`--save IMAGE` and the single-file executable (2026-11-02).** An image saved with `-q` kept its `*hush*` and printed nothing. On
  macOS `codesign --verify` rejects an appended image, which matters only for notarized distribution.
- **`(shen-jit.save-executable Path Entry)` (2026-11-03)** writes a binary from inside Shen with no build directory, about 1.0 MB and 90
  lines of C. It never returns, as an image holds no frames, so it works from any depth.
- **Bug (2026-11-04):** it interned its entry-point symbol and kept only the cell. Nothing else reached that symbol, so a collection
  could free it, and the saved binary ran as the launcher. It reproduced at GC stress 1 and 10, and at 1000 on a release build.
- **Shebang scripts (2026-11-02):** the port's `read-file` drops a first line starting with `#!`; `read-file-as-bytelist` does not.

### Errors and messages (2026-11-02)

- **Errors name their values:** `"A" is not a number` where the message began with nothing, `undefined function foo`, `foo: expected 2
  arguments, got 3`. The printer stops after 60 bytes, which also ends a circular value.
- **Cost:** raising is unchanged, and quiet handlers build nothing. A handler reading the text of a failed `<-address` took 44 ns per
  raise, where the old message without a value took 17. The printer avoids `snprintf`, at 145 ns at first.
- **`SHEN_JIT_MAX_HEAP`** raises a catchable "out of memory". At the limit the last tenth of the heap is a reserve: without one, a heap
  full of live data left no room for the error, and the handler received `[]`.

### Byte buffers and bit operations (2026-11-03)

- **Decision:** checked primitives on tagged values, with buffers as objects in the Shen heap, which the collector frees and saved
  executables keep. Raw slots in the bytecode, the first design, wait for a concrete need.
- **Numbers, per item:** `u8` in a Shen loop 1.36 ns, the same as `<-address`, against 2.02 for `pos` with `string->n`; FNV-1a 2.26; C,
  not vectorised, 0.32. The executable grew 24 KB, to 1.02 MB.
- **Rejected for now: an unchecked mode.** The checks are 0.52 ns of a read in the tightest loop. No real program has shown it matters.
- **Rejected: writing them in Shen.** Only `bit-not`, `rotate32` and `bswap32` could move, freeing about 21 of 230 lines of C. `popcount`,
  `clz` and `ctz` take 9 to 11 ns against 2, and `bytes->string` built with `cn` is quadratic, about 64,000 times slower at 64 KB.

### Not tried yet

- **True parallelism.** `thread` is real threads, one at a time; parallelism is the more advanced case, for later. It needs allocation
  per thread, a stop-the-world handshake and locks around symbols, the JIT and dictionaries.
- **Waiting without the lock on files other than stdin.** A blocking read of a FIFO holds the lock, and Ctrl-C does not end it.
- **Built-in line editing:** vendoring `linenoise` (about 1,200 lines, POSIX only), used only when stdin is a terminal.
- **Backtraces:** a setting that captures at every raise, arguments in the output, and source positions, which means threading locations
  from the reader through the kernel's compiler.
- **A sampling profiler on Windows,** which could attribute about 6% of the kernel test suite that remains unexplained there.
- **Other platforms:** Windows on arm64 (SLJIT supports it; no machine yet), other architectures, and a static musl build.
- **Windows tests:** CLI cases for `\` paths and `PATH`, and non-ASCII text at the console.

## C FFI

Shen calls plain C functions, and C written for Shen takes and returns Shen values and calls back. Built on 2026-11-04 and
2026-11-05. Lines of code: 75 of C for nesting; 460 in `ffi.c`, about 110 elsewhere and 82 of Shen to call C; 333 in `ffi.c`,
about 30 elsewhere and a 140-line header for C written for Shen. Timings are from an Apple M3 Max.

### Who writes the glue (2026-11-04)

- **Both, kept apart.** `define-foreign` declares a plain C function with its conversions, as in Chez, with no C compiler.
  `define-foreign-procedure` declares C written against `shen.h`, as in OCaml, the only form that reaches Shen's values.
  One form joined by a raw `shen` type (Chez's `scheme-object`) was the most to specify.
- **Rejected: parsing C declarations (LuaJIT).** A C parser in Shen, and layouts per platform are still needed.

### The call

- **Chosen, 2026-11-04: one shared SLJIT stub, one C helper, casts.** A foreign function is a procedure type, taking
  the dead `T_PRIM`'s slot, entered through a stub like the arity and compile stubs. It calls `h_foreign`, which
  converts the arguments and calls through a cast that fills every argument register: 6 integers and 8 doubles. No
  code per signature, no new instruction, no dependency. POSIX needs 2 casts, by result type. Win64 fills registers
  by position, so it needs 32: 16 masks of which of the first four arguments are doubles, by 2 result types.
- **Rejected:**
  - An SLJIT stub per signature: `sljit_emit_icall` stops at 4 arguments, and `sqlite3_prepare_v2` takes 5, `mmap` 6.
  - libffi: a dependency to vendor and link statically, and expected to be slower per call. Not measured.
  - Assembly trampolines per platform: three calling conventions to maintain.
  - Only functions shaped `shen_value f(shen_value...)`, as in OCaml: `cos` would need a C wrapper.
  - Building on `prim` instructions: `vm->args` has five slots, so it would stop at four arguments.
- **Casting is not standard C.** GCC turns a call through an incompatible cast into a trap when it can see the
  target, which pointers from `dlsym` and `GetProcAddress` do not show it.
- **Tried before building, 2026-11-04.** 19 checks up to 6 integers and 8 doubles interleaved, plus `cos`, `pow`,
  `strlen`, `htons` and `socket`, on macOS arm64. An earlier form on Linux x86-64 and arm64. The mask table on
  Windows 10 with `ucrtbase` and `ws2_32`. All passed.
- **Variadics need their own casts.** Through the ordinary cast a variadic function returned garbage on Apple arm64.
  `(varargs N)`, integers only, exists for `fcntl`. Doubles and `printf` stay out.
- **No fast paths, by measurement.** A C helper behind `publish` costs about 2 ns a call (2026-11-04), so a foreign call's
  cost is its conversions and the C function: roughly 7 ns with nothing to convert, 10 ns for two integers and an integer
  or a double and a new double, 13 ns with a 16-byte string, at a load of about 3 (2026-11-05). A Shen call costs under 1 ns.

### Types (2026-11-04)

- **Named by width,** with no `int` or `long`. `long` is 32 bits on Windows, and a C `int` result leaves the upper half
  of the register undefined, so it must be declared `int32`. A `bool` result tests the low byte, all C defines.
- **An `int64` result past 62 bits raises.** A real would lose low bits silently, which is worse for handles.
- **NULL is `[]` both ways.** A pointer object with address 0 keeps `pointer?` true, but needs a `null?` of its own.
- **Strings are copied for the call.** A Shen string whose length is a multiple of 8 has no NUL terminator.
- **`T_POINTER` holds a kind and an address.** Rejected: a pointer as a fixnum, unchecked and saved silently in images.

### How C sees values

- **Raw `shen_value`, as in OCaml and Chez,** 2026-11-04. Rejected: JNI's handles (an indirection per access and a
  table), Lua's stack (index juggling in every function), Erlang's environments (Shen has mutable vectors).
- **A function table, tested against exports, 2026-11-04.** Exported symbols work on only one release configuration: static
  glibc gives `undefined symbol` with or without `-rdynamic`, and a stripped macOS executable exports nothing. Rejected:
  extensions linked statically (OCaml's `-custom`), a toolchain and a build per extension.
- **Written for a later collector,** perhaps like OCaml's. The header promises neither that objects move nor that they stay,
  stores go only through `shen_vector_set` and `shen_root_set`, where a barrier would go, and it names no layout beyond the
  fixnum encoding and a few constants. Its one assumption: the heap does not move while a thread holds the lock and makes no API call.
- **Reads never allocate or raise,** 2026-11-04. Raising allocates, so a read that raised could collect and invalidate
  every value in scope. A read of the wrong type gives `SHEN_NONE` or NULL.
- **Misuse ends the process by `_Exit(70)`,** 2026-11-05: `abort` means a crash report on macOS and perhaps a dialog on Windows.
- **Not stable until 1.0,** 2026-11-05. `SHEN_API_VERSION` says when `shen.h` has changed; from 1.0 the table only grows.

### Errors (2026-11-04)

- **By value: `SHEN_ERROR` and `shen_raise`,** as every helper works already. Rejected: `longjmp` (skips C cleanup, hard for
  C++ and Rust) and JNI's pending exception (the same checks, and a call made while one is pending must be defined).
- **A boundary handler, in place of a floor in `h_unwind`.** `shen_call` pushes a handler with no address; `h_unwind` pops
  it and returns NULL unchanged, so an error never jumps across C frames. `jit_call` itself stays without it, as a
  top-level call with no handlers must still count as uncaught.
- **A native stack bound per thread, in place of a depth count.** Nesting without end raises `stack overflow`.

### Roots

- **Locals: `shen_root` over the existing root stack, as `CAMLlocal`.** A procedure's arguments arrive rooted, and
  returning resets the count, so an early `return` is safe. Rejected: Chez's rule alone (nothing checks it) and API
  calls taking rooted references (more verbose).
- **So a rule covers evaluation order:** never nest two allocating calls. `shen_cons(vm, shen_cons(vm, a, b), c)` may
  read `c` before the inner call moves it. The runtime had this bug on 2026-11-04.
- **Long-lived: allocator-owned slots with create, get, set and delete, as in `ocaml-boxroot`,** 2026-11-04. One pointer
  that fits `void *`, in constant time. Rejected: registering a C variable's address (removal searches), generational
  global roots (no gain with this collector, and `shen_root_set` keeps them open), integer references (a lookup per
  access), pinning (a copying collector cannot pin small objects).
- **A root is three words: its table, its value and a link,** 2026-11-05, where a `RootArray` slot was planned.
  `shen_root_delete` takes no `vm`, so its wrapper needs the table from the root. The link cannot share the value's slot,
  as a thread deleting a root may run during another thread's collection, which writes the slot.
- **Why deleting needs no lock.** Delete pushes the root on one process-wide lock-free list by compare-and-swap, through
  its link, and touches nothing else. Whoever holds the lock swaps out the whole list at the next `shen_root_new` or
  collection. Until then the value is scanned as usual and just lives a little longer. So a root can go with no `vm` at
  hand, while the lock is released, from a thread of C's own, and later from a finalizer or a Rust `Drop`.

### Threads and callbacks

- **A foreign call holds the lock by default** (2026-11-04), so buffers stay put; `blocking` and `shen_release`/`shen_acquire`
  give it up. `blocking` copies `bytes` arguments out and back, as another thread's collection may move the buffer. Without
  the copies the test fails under stress on macOS arm64.
- **Callbacks: C trampolines with the closure in a root reached through `userdata`.** Rejected for now: a fixed pool of
  stubs, which LuaJIT limits to 500 to 1000. Generated stubs are under "Not tried yet".

### Images and static builds

- **Resolve lazily by name, at the first call,** 2026-11-04. A saved program finds its functions again, a pointer loads
  dead and raises when passed to C, and `save-executable` refuses nothing new. Rejected: refusing to save.
- **Static glibc `dlopen` works, but loads a second libc** (tried in Docker, 2026-11-04). So nothing `malloc`'d by one
  side is freed by the other, and no `FILE *` crosses, on Linux as on Windows.
- **Linux releases are dynamic on an old glibc; static ones stay beside them without the FFI** while they pay for their
  two archives, 2026-11-05. A call there raises `foreign: this static build cannot load libraries`.

### SQLite and sockets (2026-11-05)

First libraries, to test whether declarations cover real use: 128 and 206 lines of Shen with no C.

- **`shen-jit.pointer-kill` was the one addition.** Closing a database twice would have crashed in C.
- **Sockets are always non-blocking,** in place of a blocking `recv`. The wait is in `poll`, in 100 ms slices with the lock
  given up, so no buffer is copied and Ctrl-C ends it: within 100 ms on macOS and Linux, 92 ms through a Windows console.
- **`bytes` passes a buffer's start, so `socket.send` copies through a 64 KB chunk.** 100 MB on loopback ran at about
  3 GB/s, so the copy is not the limit. An offset type waits for a profile.
- **A SQLite connection belongs to one thread.** Apple's build is in multi-thread mode and `sqlite.step` gives up the lock.

### Bugs found while building it

- **2026-11-04, a leaf's frame not reserved.** Leaves skip the stack check, so a nested call near the end of the stack
  wrote past its block: one bus error in about 6,000 runs. Guard Malloc then named the writer at most alignments.
- **2026-11-04, C roots shared by threads.** The new test crashed in 3 runs of 3 under stress, and passes 3 of 3 per thread.
- **2026-11-05, Apple clang merged a `switch` over three variadic casts** into one call with the last's type:
  `var_one(3, 1, 2, 3)` read 3, 0, 0. Each is now a function of its own, not inlined.
- **2026-11-05, a string result pointing into a byte argument** (`fgets`) could move while the string was made.
- **2026-11-05, stale values show only sometimes:** after an even number of collections an old pointer is back inside the heap.
- **2026-11-05, release archives left out `lib/` and `include/`,** so a binary could not have loaded `lib/ffi.shen`.
- **Whether the tests can fail, 2026-11-05.** Not resetting roots on return, not scanning `shen_root_new`'s roots and not
  rooting arguments each end the run under stress.

### Not tried yet

| Left out | Estimated lines of C | What would bring it back |
| --- | ---: | --- |
| Callback stubs from SLJIT, like `foreign-callable` | 120 to 150 | A wanted library without `userdata`, such as `qsort` or some GUI toolkits |
| Finalizers on pointers, over a weak list | 40 | Leaks in a real program, or Rust's `Drop` |
| Structs by value, `float`, variadics with doubles | 100 each | raylib, for instance; a C wrapper costs ten lines meanwhile |
| `peek`/`poke` beyond `pointer->bytes` | 30 | A library that needs writing through pointers |
| Inlined or `noalloc` calls | 150 | A profile with the 2 ns helper call on top |
| Embedding, a `shen_startup` | 100 | Someone asking for it |
| C threads calling in, like `caml_c_thread_register` | 80 | A library calling back from its own threads |
| Interrupt polling from C | 15 | A long C loop that matters |
| Rust bindings: a crate on the table, as in `ocaml-interop` | - | Wanted eventually; reads and root deletion were kept ready for it |
| Shen streams over sockets, buffered line reading | - | Real use; `T_STREAM` holds a `FILE *`, and Winsock has no `fdopen` |

Not run as of 2026-11-05: static musl, upstream clang's function sanitizer on the casts (Apple clang 17 does not check),
the old-glibc container on GitHub's runners, and sockets beyond loopback.

## Benchmark results

Ratios are geometric means of Shen/JIT's time over the other implementation's, so below 1 means Shen/JIT is faster.
Open is the default, with kernel functions sealed and user definitions not; sealed is `shen-jit --seal`. The campaign
and Prolog comparisons used harnesses and recorded data that are not published: `make bench` and
`make bench-independent` are what a reader can run.

### How the comparisons were done

- **The campaign, from 2026-11-01.** We reran the earlier prototype's last complete campaign, recorded 2026-10-27, on its
  own drivers, beside its recorded medians for Shen/Scheme 0.50 on Chez 10.3.0 and for the prototype, both on kernel 42.2.
- **156 timed rows:** 122 canonical kernel cases in one process, compilation outside the timer; 23 warmed `eval`s including
  their compilation; 11 prepared controls, with preparation out of the means. Each Shen/JIT cell is the median of six fresh processes.
- **Sealed covers 155 rows,** as `kernel-yacc` defines `<as>` twice. The recorded Shen/Scheme ran in its normal mode. Results
  are checked: all match the expected values or Shen/Scheme's, apart from six opaque values printed differently.
- **Machine drift is measured,** since the recording cannot be rerun: a saved binary before and after a campaign, then
  Shen/Scheme 0.52 timed each time. A rerun on a busy machine, every row about 1.05 times as long, was not used (2026-11-03).
- **Single rows move with placement.** `vector create (big)` took 0.24 s to 0.43 s with the heap pointer's parity on an Apple
  M3 Max. Identical code took 0.098 s or 0.151 s on a Ryzen 5 5600X. Slower rows are timed alone before anyone acts on them.
- **Before the campaign, 2026-11-01, Apple M3 Max, against Shen/Scheme 0.52.** `make bench`, 79 benchmarks of 2 ms or more, best of
  3: 1.35 (2.38 for the first build with a kernel image, the same day); the realistic compile pipeline 2.0 (4.4) and bytecode VM
  2.2 (6.4). Startup 3.0 ms (3.4) against 188 ms. Kernel test suite 0.46 s (0.83) against 0.78 s.

### Campaign reruns (Apple M3 Max, against the recording)

"Earlier" is the earlier prototype. Each change is described under its own topic.

| Date | Changes since the row before | Open / Scheme | Open / earlier | Sealed / Scheme | Sealed / earlier |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-11-01 | First full run | 1.24 | 2.33 | - | - |
| 2026-11-01 | Dictionaries, constant operands, sealing, tail-call arguments, registers, quiet handlers | 0.71 | 1.33 | 0.64 | 1.20 |
| 2026-11-02 | First argument and loop slots in registers, collector copies | 0.62 | 1.16 | 0.55 | 1.03 |
| 2026-11-02 | Overrides, Prolog, loading, collector | 0.55 | 1.02 | 0.47 | 0.89 |
| 2026-11-02 | Calls, list literals, patterns, handlers, strings, reals | 0.52 | 0.97 | 0.44 | 0.83 |
| 2026-11-03 | Allocation, open loops, equality, patterns | 0.46 | 0.87 | 0.43 | 0.80 |
| 2026-11-03 | Calls through `fn`, pattern parts, leaves, cons runs | 0.44 | 0.83 | 0.42 | 0.78 |
| 2026-11-03 | Inlining open callees, exact traces, closures, `cn`, `=` | 0.43 | 0.80 | 0.41 | 0.77 |
| 2026-11-03 | List walking; machine about 2% slower | 0.42 | 0.79 | 0.41 | 0.78 |
| 2026-11-03 | Patched branches, loop registers, exit tests; about 3% of it is the machine | 0.39 | 0.74 | 0.38 | 0.72 |
| 2026-11-03 | Type tests leave the value in a register; machine 1.7% slower | 0.40 | 0.75 | 0.39 | 0.73 |
| 2026-11-04 | Prolog variables as immediates, trail unifier, growing in place | 0.38 | 0.70 | 0.37 | 0.69 |
| 2026-11-04 | C function alignment, kernel 43.2, threads, Ctrl-C; machine about 2% faster | 0.37 | 0.70 | 0.37 | 0.69 |

- **Open / Scheme through 2026-11-01, change by change:** 1.24, 1.18, 1.14, 1.00, 0.93, 0.85, 0.79, 0.77, 0.74, 0.72, 0.71.
- **Rows faster than both, open:** 7 on 2026-11-01, 58 and 60 on 2026-11-02, 78, 95, 99 and 105 on 2026-11-03, 127 on 2026-11-04. On
  2026-11-04, 148 against Shen/Scheme and 131 against the earlier prototype open, 147 and 133 sealed.
- **Caught by a rerun, 2026-11-03:** pattern sharing turned a frozen failure continuation into a closure made on every call, so
  the realistic pipelines took 1.15 to 1.22 times as long. Fixed in the lowerer.
- **Threads and Ctrl-C cost nothing the campaign can see, 2026-11-04:** 0.997 open and 1.004 sealed against the rerun before.
- **`kernel-interpreter` is not pinned down, 2026-11-04.** One cold `eval` of about 2 ms read 1.13 and 1.17 on the M3 Max and 1.36
  and 1.38 on a Ryzen 5 5600X VM against the rerun before. Warm, over a million iterations, it reads 1.00 and 1.06.
- **Open / Scheme by group, 2026-11-04:** control flow 0.13, compilation 0.27, Prolog 0.37, equality 0.42, warm calls 0.46, patterns 0.50, data
  0.54, arithmetic 0.61, applications 0.61, prepared applications 0.72.
- **Behind both, open, 2026-11-04:** list patterns with several clauses that match (1.19 and 1.25), a nested list pattern's late mismatch
  (1.21 and 1.08), the recursive list rebuild (1.04 and 1.01), `kernel-interpreter` (1.04 and 1.08).

### x86-64 Linux

A Hyper-V VM with 4 cores of a Ryzen 5 5600X, Ubuntu 20.04, gcc 9.4. Against Shen/Scheme 0.52 run alongside on each machine, six
rounds; on x86-64 both ran in one Debian 13 container, as its Linux binary needs glibc 2.38. Shen/Scheme 0.52 takes 1.05 times
the recorded 0.50's time on the M3 Max. The earlier prototype has no x86-64 numbers.

| Date | M3 Max open, sealed | Ryzen VM open, sealed | Rows ahead on the VM, open, sealed | VM / M3 Max: Shen/Scheme, Shen/JIT |
| --- | ---: | ---: | ---: | ---: |
| 2026-11-03, first | 0.39, - | 0.50, 0.46 | 108, 128 | 1.11, 1.43 |
| 2026-11-03 | 0.38, 0.37 | 0.45, 0.43 | 129, 136 | 1.10, 1.30 |
| 2026-11-03 | 0.38, 0.37 | 0.44, 0.43 | 138, 139 | 1.08, 1.27 |
| 2026-11-04 | 0.36, 0.35 | 0.43, 0.42 | 136, 139 | 1.08, 1.32 |
| 2026-11-04 | 0.36, 0.35 | 0.43, 0.42 | 134, 134 | 1.11, 1.31 |

- **Each change, interleaved on the VM, 2026-11-03, open and sealed:** patched branches 0.931 and 0.999, loop registers 0.988 and
  0.985, exit tests 0.982 and 0.975 (0.954 and 0.972 on the M3 Max, with the realistic pipelines losing 2 to 5%).
- **Behind Shen/Scheme on the VM, open, 2026-11-04:** `tuple create` 1.71, list patterns with several clauses that match 1.48,
  `reverse` 1.41, `closure allocation` 1.31.
- **`trap-error` with an error raised looks 3 to 7 times worse there, from Shen/Scheme's side:** raising takes it 0.65 s on macOS
  against 0.13 s on Linux for the basic row.

### Native Windows (2026-11-04)

Windows 10 Pro on the VM's Hyper-V host, all 12 threads of the Ryzen 5 5600X, gcc 16 in MSYS2's UCRT64, against the VM's last rows above:
the same processor, though one is a guest and one the host. No Shen/Scheme beside it.

- **All rows:** 0.961 open (median 0.989), 0.939 sealed (median 0.981). Canonical 0.93, applications 1.10, prepared execution 1.03.
- **Small loops gain:** eight saved registers against six, so four loop registers against two. Many control loops take 0.67 to 0.75 of their time.
- **The loss is a fixed cost per process.** Long rows are level or better (`realistic-vm-9` 1.00, `kernel-n-queens` 0.86). First writes to
  the semispaces cost about 13 ms against 3, without huge pages; a process that does nothing takes 2.3 ms against 0.26.
- **Left as it is:** large pages need a privilege a user must be granted, and a smaller start would trade the one payment for more collections.

### Prolog, against SWI-Prolog and Shen/Scheme (2026-11-04, Apple M3 Max)

Microseconds of CPU time per iteration, best of the rounds, timed inside each process after a warm-up, collection included. SWI-Prolog
10.0.2 with -O, Shen/Scheme 0.52 on kernel 43.1. Each program in Prolog and as `defprolog`; `zebra`'s `.shen` file is Prolog syntax and
`qsort` has no Prolog file, so both are left out. Last recording:

| Program | SWI -O | Shen/Scheme | Shen/JIT | JIT / SWI -O | JIT / Scheme | Peak MB: SWI -O, Scheme, JIT |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| coloring | 216.8 | 151.0 | 104.8 | 0.48 | 0.69 | 9, 64, 71 |
| einstein | 1871.1 | 3302.9 | 805.3 | 0.43 | 0.24 | 8, 63, 71 |
| hamilton | 72.3 | 194.5 | 62.5 | 0.86 | 0.32 | 8, 62, 71 |
| nreverse | 12.3 | 32.3 | 12.2 | 1.00 | 0.38 | 8, 62, 71 |
| queens-8 | 79.9 | 133.8 | 66.1 | 0.83 | 0.49 | 8, 60, 71 |
| subset | 30.2 | 48.3 | 19.5 | 0.65 | 0.40 | 9, 60, 71 |
| tak | 3360.8 | 6063.2 | 1787.2 | 0.53 | 0.29 | 26, 136, 124 |
| Geometric mean | | | | 0.65 | 0.38 | |

- **Geometric means through the day, against SWI -O and Shen/Scheme:** first recording 0.85 and 0.50, inline `lazyderef` 0.72 and 0.42,
  walking two lists in the unifiers 0.71 and 0.42, inline `deref` 0.68 and 0.40, a later closure 0.66 and 0.39, last 0.65 and 0.38.
- **With the occurs check off,** as SWI-Prolog does none: 0.65 of SWI -O and 0.40 of Shen/Scheme with its check off too.
- **A recording at a load average of about 7 read about 10% slower on every row, a control binary included.** It was thrown away, and
  the driver now refuses to record above a load of 3.
- **`tak` is not evidence for runtime changes.** It needs `(prolog-memory 1000000)` on both Shen engines and allocates that per query,
  needlessly, and a kernel hook could fix that.
- **The campaign's Prolog rows, against the recorded Shen/Scheme:** 1.79 on 2026-11-01, 0.73 on 2026-11-02, 0.37 on 2026-11-04.

### Workloads never used for tuning

`make bench-independent`, added 2026-11-03: the kernel's test suite (38 programs), its extension tests, the standard library install (22 files),
the contract examples and startup. They mostly load, compile and typecheck, which the campaign hardly measures. Median wall time of nine
rounds, in ms. Shen/Scheme cannot install the standard library, which defines a name its port already has.

| Machine, date, build | Startup | Kernel tests | Extensions | Stdlib | Contract |
| --- | ---: | ---: | ---: | ---: | ---: |
| M3 Max, build of 2026-11-01, timed 2026-11-03 | 4 | 468 | 32 | 142 | 24 |
| M3 Max, 2026-11-03, with exit tests | 3 | 268 | 20 | 76 | 12 |
| M3 Max, 2026-11-04, Prolog and heap work | 4 | 215 | 21 | 69 | 13 |
| M3 Max, 2026-11-04, kernel 43.2 | 4 | 190 | 20 | 67 | 13 |
| Shen/Scheme, M3 Max, 2026-11-03 | 185 | 969 | 256 | - | - |
| Ryzen VM, 2026-11-04 | 2 | 277 | 23 | 84 | 13 |
| Shen/Scheme 0.52, Ryzen VM, 2026-11-04 | 241 | 1305 | 342 | - | - |
| Windows 10 on the Ryzen, 2026-11-04 | 7 | 309 | 37 | 111 | 21 |

- **The gains hold outside the benchmarks.** On 2026-11-04 the kernel's test suite takes 0.20 of Shen/Scheme's 964 ms on the M3 Max and 0.21
  on the Ryzen VM, against 0.36 and 0.43 for the campaign.
- **It caught what the campaign could not.** Reserving 1 TiB per semispace on macOS read 1.52 at startup and 1.15 to 1.18 on the short
  workloads, 2026-11-04; the campaign times inside the process. The reservation went to 64 GiB.
- **It shows compile costs.** Open inlining and exact traces (2026-11-03) cost these workloads 3 to 5% of compile time while the benchmarks
  gained: open inlining 1%, the rest most likely the bookkeeping for exact backtraces.
