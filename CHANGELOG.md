# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Memory outside the heap: `shen-jit.pointer-sized` makes a C pointer readable and writable in place, with
  the same functions as a byte buffer, each access checked against the length stated. `lib/memory.shen`
  allocates and frees such memory.
- `shen-jit.s32`, `s64`, `f32` and `f64` and their stores, on byte buffers too, and `shen-jit.pointer!`.

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
