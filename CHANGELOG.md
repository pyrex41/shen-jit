# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

### Fixed

- An integer literal too big for a fixnum, and one with a large exponent such as `1e300`, now reads as the
  nearest real. They could land slightly off it, as `1e100` read as `1.0000000000000006e100`.

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

[Unreleased]: https://github.com/tizoc/shen-jit/compare/v0.2...HEAD
[0.2]: https://github.com/tizoc/shen-jit/compare/v0.1...v0.2
[0.1]: https://github.com/tizoc/shen-jit/releases/tag/v0.1
