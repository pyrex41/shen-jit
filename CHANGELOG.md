# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Bounded streaming HTTP responses with explicit lengths or chunked output, pull-based backpressure,
  total write budgets and deterministic producer cleanup. Persistent connections retain one reader under
  request-count, idle and total-lifetime limits; the SQLite example streams NDJSON exports.
- Optional JSON decoding and encoding over byte views, with typed values, strict UTF-8, lossless number
  tokens, exact integer conversion and bounded output builders. The SQLite example accepts JSON PUT bodies.
- Bounded chunked HTTP requests, validated extensions and separate trailers, with decoded/metadata limits,
  total body deadlines and preserved following bytes. Readers can peek an available span under a copy limit.
- A bounded HTTP listener with connection limits, cooperative socket cancellation, controlled shutdown
  and completion snapshots. A runnable SQLite counter API in `example-apps/sqlite-http/` demonstrates
  per-request database ownership, atomic increments, JSON responses and an explicit shutdown command.
- Optional HTTP/1.1 request parsing, bounded Content-Length bodies, response encoding and a one-request
  socket driver with per-phase deadlines, typed APIs and a small echo/health example. Ambiguous framing
  is rejected; HEAD/bodyless responses, partial output failure and owned body bytes have explicit rules.
- `lib/native.shen` writes loops and branches without labels: `if`, `when`, `unless`, `while`, `for`, `block`, `exit`
  and `next`, which become the same instructions. `shen-jit.expand-native` shows what they become.
- `lib/datalog.shen`: relations, facts, recursive rules, stratified negation, arithmetic on 32-bit integers and
  aggregates (`count`, `sum`, `min` and `max`), evaluated bottom up to a fixed point, with each rule compiled to
  native code with `lib/native.shen`, facts added to a database incrementally, and facts removed. See the guide.
- Optional HTTP head framing preserves unread body bytes under an explicit byte limit. Monotonic
  operation deadlines cover socket transfers across short progress and retries, with typed results,
  injected clocks and transient reader timeout recovery.
- Optional `lib/frame.shen` reads bounded binary frames across I/O chunks; `lib/io-socket.shen` adds
  owned TCP endpoints and flushing write shutdown over existing sockets. `tools/frame-echo.shen`
  demonstrates framed sessions with bounded payloads and one flushed reply per message.
- Optional `lib/io.shen` and `lib/io-file.shen`: bounded chunk readers/writers, memory endpoints and
  native binary files, independent of kernel streams. Short transfers retain progress; explicit close
  flushes pending output, and scoped helpers preserve primary and cleanup errors.
- Optional `lib/buffer.shen` and `lib/cursor.shen`: checked views over managed bytes or sized foreign
  memory, overlapping copies, owned captures, logical equality and typed cursor operations.
  `tools/buffer-parsers.shen` demonstrates complete JSON and length-prefixed binary parsing over them.

### Changed

- The JIT reuses scratch buffers across liveness checks while compiling each code object.
  Reported by @pyrex41 in [#17](https://github.com/tizoc/shen-jit/pull/17).
- Converting strings to byte lists for `read-from-string` takes time linear in the string's length.
  Reported by @pyrex41 in [#16](https://github.com/tizoc/shen-jit/pull/16).
- Compiling code with many distinct constants no longer searches all of them for each new one: a list of 32000
  numbers takes about a thirtieth of what it did.
- Lowering is faster: looking up a fixed name no longer scans them all, and a long definition with many inlined calls
  no longer takes time that grows with the square of its size.
- Many threads waiting on sockets use far less CPU: giving up the runtime lock wakes the next thread, not every
  waiting one, so 1000 such threads no longer take over the machine.

### Fixed

- Closing a guarded handle invalidates it even if its release function raises, so a retained view cannot
  keep using storage that the release function freed.
- Under `SHEN_JIT_MAX_HEAP`, a vector or string of 256 KB or more no longer raises `out of memory` with the heap nearly
  empty, as it did for good once the heap had grown past half the limit. The process can use more memory at the limit
  as a result, up to about three times it.
- Writing to a closed pipe raises an error that a program can catch, instead of ending the process. So
  `shen-jit script f | head` can now print `write-byte: Broken pipe` to stderr and exit with status 1.
- A `c#N;` escape past 255 in a string, such as `c#955;`, no longer fails to load: `n->string` gives a Unicode scalar
  value's UTF-8 bytes.
- File read errors raise instead of looking like end of file: whole-file reads no longer return empty or
  partial data on failure, and `read-byte` reports failed file reads.
- Loading code with more than 255 parameters or call arguments, or a capture index above 255, reports which limit
  was exceeded. Reported by @pyrex41 in [#18](https://github.com/tizoc/shen-jit/pull/18).
- The error for defining a function with a system function's name ends its line, as the kernel's does.

## [0.4] - 2026-11-06

### Added

- `make test-differential` runs each primitive over generated values, however it is compiled and through C, and
  `make differential-scheme` lists what differs from Shen/Scheme.

### Changed

- Moved to the Shen kernel 43.4, from 43.2.
- Moved to Shen/Scheme 0.54, from 0.53, as the other host that can build a checkout, and what `make bench` compares
  against.
- Compiled code keeps more values in registers between instructions, which speeds up small interpreters and other code
  that works on values it has just taken apart.
- Compiling a long literal list takes far less, and with constant elements the list uses one frame slot instead of one
  per element.

### Fixed

- `define` no longer fails on a `cond` with no true clause. The definition compiles, and raises an error when no
  clause applies.
- `absvector` too large for `SHEN_JIT_MAX_HEAP` gave a handler `[]`, on which `error-to-string` failed, instead of
  an "out of memory" error.
- `absvector` with a length of 2^56 or more crashed. It now raises an error from 2^48 up, as `shen-jit.bytes` does.
- `shen-jit.pvar` and `shen-jit.pvar-offset` raised past a `trap-error` in the same function whose handler ignores
  the error.
- `write-byte` and `close` raise an error when the write fails, as on a full disk, instead of losing the data silently.

## [0.3] - 2026-11-06

### Added

- Memory outside the heap: `shen-jit.pointer-sized` makes a C pointer readable and writable in place, with
  the same functions as a byte buffer, each access checked against the length stated. `lib/memory.shen`
  allocates and frees such memory.
- `shen-jit.s32`, `s64`, `f32` and `f64` and their stores, on byte buffers too, and `shen-jit.pointer!`.
- `lib/mmap.shen`: all of a file as memory, on each system, with `mmap.read`, `mmap.read-write`, `mmap.create`
  and `mmap.close`.
- `lib/handle.shen`: memory that releases itself once nothing reaches it, with `handle.wrap`, `handle.close` and
  `handle.sweep`, over `shen-jit.pointer-guard`, `shen-jit.pointer-owner` and `shen-jit.pointers-dead`.
- `shen-jit.collect` collects now.
- `shen-jit.pointer-read-only` makes a pointer that raises when stored to, which is what `mmap.read` gives.
- Real registers in native code written by hand: `real`, `f64!`, `jump-unless` and `return-real` keep doubles
  unboxed in loops that call nothing, and `loop` and `again` make those loops, which can nest.
- Word registers there too: `word`, `jump-unless-word`, `return-word`, `word-box`, and `u8!` to `u64!` keep 64-bit
  integers that wrap, for hashes and random numbers, and as indices with no tag to check.
- `make bench-numeric` runs numeric programs and a path tracer in C and in Shen.
- The rendered guide now has how Shen/JIT works, its semantics, its instructions and calling C as pages of
  their own.

### Changed

- Arithmetic and comparisons on reals, and division, compile inline.
- A loop that calls nothing works out the memory it reads and stores through once, on the way in.
- In native code, machine registers go to what the deepest loops use most, whatever the order of the names, and
  an access to memory reached at one width takes one comparison.
- New objects now always go in the same memory, so a program that allocates uses much less of it, and allocates
  faster where two semispaces taking turns outgrew the cache. A process that only starts takes about 2 MB more.
- On x86-64 outside Windows, a loop that calls nothing keeps up to four values in registers, where it was two.
- The heap grows with what is live, not by doubling, so a program holding a lot of data no longer slows down as it
  nears the next doubling. Such a program can use more memory than before, at most about 1.7 times.

### Fixed

- `=`, `<`, `>`, `<=` and `>=` now compare an integer with a real exactly. From 2^53 up the integer was rounded to a
  double first, so `=` was not transitive, unification could depend on the order of its arguments, and two keys that
  were `=` could have different hashes.
- `=` no longer crashes on terms nested deeper than the C stack, in the head of a pair or in an absvector. A cyclic
  term still ends the process, now with a message.
- An integer literal too big for a fixnum, and one with a large exponent such as `1e300`, now reads as the
  nearest real. They could land slightly off it, as `1e100` read as `1.0000000000000006e100`.
- A burst of new symbols, such as from `gensym` in a loop, no longer slows every later collection for as long as
  the process runs.

## [0.2] - 2026-11-05

### Added

- A checkout now builds on Linux arm64, from `make deps`.

### Changed

- A checkout now builds with the previous release of Shen/JIT, which `make deps` fetches. Shen/Scheme can
  still build it, with `make BOOTSTRAP=...`, and makes the same generated files.
- The guide is centered on wide screens.

## [0.1] - 2026-11-05

### Added

- Initial release

[Unreleased]: https://github.com/tizoc/shen-jit/compare/v0.4...HEAD
[0.4]: https://github.com/tizoc/shen-jit/compare/v0.3...v0.4
[0.3]: https://github.com/tizoc/shen-jit/compare/v0.2...v0.3
[0.2]: https://github.com/tizoc/shen-jit/compare/v0.1...v0.2
[0.1]: https://github.com/tizoc/shen-jit/releases/tag/v0.1
