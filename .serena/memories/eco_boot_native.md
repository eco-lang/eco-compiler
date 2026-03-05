# eco-boot-native (AOT Compiler)

## What It Is
`eco-boot-native` is the CMake target for the AOT native compiler binary. It compiles Elm/MLIR to standalone x86-64 Linux ELF executables.

## Key Files
- `runtime/src/codegen/eco-boot.cpp` — Main driver (MLIR parse, pipeline, obj emit, link)
- `runtime/src/codegen/eco_entry.cpp` — Entry wrapper providing main() for output binaries
- Generated: `build/runtime/src/codegen/include/eco/EcoBootConfig.h` — Library paths baked in by CMake

## CMake Targets
- `eco-boot-native` — The compiler binary (named differently from JS `eco-boot` target in compiler/)
- `EcoRuntimeStatic` — Static library of runtime/GC for linking into output binaries
- `EcoEntryStatic` — Static library with main() wrapper

## Build
```bash
cmake --build build --target eco-boot-native
```

## Usage
```bash
# From .mlir:
build/runtime/src/codegen/eco-boot-native input.mlir -o output_binary
build/runtime/src/codegen/eco-boot-native input.mlir --emit=obj -o output.o
build/runtime/src/codegen/eco-boot-native input.mlir --emit=llvm -o output.ll

# From .elm (requires --frontend):
build/runtime/src/codegen/eco-boot-native input.elm --frontend=path/to/runner.js -o output
```

## Key Design Decisions
- main→eco_main rename in LLVM IR to avoid C main() clash
- __eco_init_globals declared weak in eco_entry.cpp
- Library paths generated into EcoBootConfig.h via CMake file(GENERATE)
- Uses -Wl,--start-group/--end-group for circular static lib deps
- Fully static linking with -static flag
- Default optimization O0

## Test Results (2026-03-05)
194/209 codegen MLIR tests pass (identical output to JIT). Remaining:
- 9 tests intentionally crash/abort (crash.mlir, expect_fail.mlir, etc.)
- 6 tests differ only in heap pointer debug values (expected, not a bug)
