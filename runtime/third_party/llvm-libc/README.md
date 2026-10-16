# Vendored LLVM libc memory functions

The static musl build replaces musl's `memcpy`, `memmove`, `memset`, `bcmp` and `memcmp` with
LLVM libc's in `eco` and in every program it builds (plans/bundle-runtime-performance.md, D).
musl's x86_64 `memcpy` is a `rep movsq` loop; fannkuch-redux spent about 10 % of its time in
it, on copies of 0 to 64 bytes.

- `libc/`: verbatim copies of the five entry points (`src/string/memcpy.cpp`, `memmove.cpp`,
  `memset.cpp`, `memcmp.cpp`, `src/strings/bcmp.cpp`) and the 106 headers they include, at
  their upstream paths. Nothing else from LLVM libc is vendored.
- `eco_memfuncs.cpp`: eco's file; includes the five entry points so they build as one object.
- `update.sh`: refreshes `libc/` from a release tarball.

## Provenance

- Origin: llvm-project, `libc/` (https://github.com/llvm/llvm-project)
- Release: **21.1.8** (`llvmorg-21.1.8`), the same release as eco's LLVM
- Copied from `llvm-project-21.1.8.src.tar.xz`, SHA-256
  `4633a23617fa31a3ea51242586ea7fb1da7140e426bd62fc164261fe036aa142`
- License: **Apache-2.0 WITH LLVM-exception** (`LICENSE.TXT`), the same as LLVM itself

## Usage in eco

The `eco-memfuncs-obj` target in the top-level `CMakeLists.txt` (`ECO_STATIC_MUSL` only)
compiles `eco_memfuncs.cpp` with `-march=x86-64-v3` (the AOT target, `kEcoTargetCPU`;
musl has no IFUNC, so there is no runtime CPU dispatch), `-ffreestanding -fno-builtin` (so
clang does not turn the copy loops back into calls to `memcpy`), and
`LIBC_COPT_PUBLIC_PACKAGING` (so the functions get their C names).
`LIBC_COPT_MEMCPY_X86_USE_REPMOVSB_FROM_SIZE=2048` makes `memcpy` use `rep movsb` from
2 KiB: LLVM's default never does, and its AVX loop was slower than musl's from 64 KiB up.
