# SLJIT provenance

- Upstream: https://github.com/zherczeg/sljit
- Commit: `a0020dd49a21020434ff838fc308626c48cd8f05`
- License: Simplified BSD (`LICENSE`)
- Copied on 2026-11-01.

The tree carries one patch that came with the copy: `sljitSerialize.c` zeroes its output
allocation before writing fields. Shen/JIT never calls SLJIT's serialization,
so the patch has no effect here; it is kept rather than reverted by hand. Keep
Shen/JIT code outside `sljit_src/` so SLJIT can be updated independently.

Shen/JIT adds one patch of its own (2026-11-02): `SLJIT_LABEL_ALIGN_32` in
`sljitLir.h`, and the argument check in `sljitLir.c` accepting it. The code
that aligns labels already handles any power of two; only the check stopped
at 16. Shen/JIT aligns loop heads to 32 bytes (`src/runtime/jit.c`).
