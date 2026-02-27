# Eco Kernel Implementation Notes

## Record Field Ordering (CRITICAL)
Records in C++ must use **unboxed-first** ordering, NOT pure alphabetical:
1. Unboxable fields (Int, Float, Char only) sorted alphabetically
2. Boxable fields (everything else) sorted alphabetically
3. Bitmap: contiguous low bits `(2^unboxedCount) - 1`

Source: `compiler/src/Compiler/Generate/MLIR/Types.elm:423-466` (`computeRecordLayout`)

**Bug in elm-kernel-cpp**: HttpExports.cpp and RegexExports.cpp use WRONG ordering (pure alphabetical).

## Key Headers
- `KernelHelpers.hpp` - shared helpers (toString, fromString, taskSucceed*, listToStringVector, etc.)
- `ExportHelpers.hpp` - HPointer ↔ uint64_t conversion (uses fully-qualified Elm:: names)
- `allocator/HeapHelpers.hpp` - alloc::record, alloc::just, alloc::nothing, alloc::ok, alloc::err, etc.
- `platform/Scheduler.hpp` - Scheduler::instance().taskSucceed()/taskFail()

## Task Wrapping
C++ kernel functions MUST wrap results in Task themselves. The compiler does NOT wrap.

## Thread Safety
Single-threaded for now. No mutexes needed.

## Env Init
`Eco::Kernel::Env::init(argc, argv)` must be called from main() before rawArgs() works.
