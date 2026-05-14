# Eco

A native compiler and runtime for the [Elm](https://elm-lang.org/) programming language.

Eco compiles Elm to native x86 binaries via MLIR and LLVM. The compiler is written in Elm.

## Status

**Working today:**

- Elm source code compiles through: Elm → typed AST → LocalOpt → Monomorphization → GlobalOpt → custom MLIR dialect (`eco`) → LLVM (AOT and JIT execution)
- Whole-program monomorphisation and optimisation pipeline (type-directed specialisation, unboxing, erasure, staged currying, ABI cloning)
- Bytes fusion DSL compilation (a dedicated MLIR dialect compiling `Bytes.Encode`/`Bytes.Decode` pipelines into fused loops)
- 144 MLIR operations across the `eco` and `bf` (bytes fusion) dialects, with lowering to LLVM
- C++ implementations of Elm kernel packages: core, json, bytes, time, http, regex, url, parser, file, browser, virtual-dom
- Generational garbage collector exploiting Elm's immutability (no write barrier needed), with LLVM statepoint-based stack root tracing
- Platform.worker event loop, scheduler, and effect managers (Task, Time, HTTP) for long-running programs
- Extensive test coverage: 466 codegen/E2E test programs, 87 compiler test suites (~8,000 fuzz iterations), property-based GC tests, parameterised Elm stress suite

**In progress towards 0.1.0:**

- Bootstrapping (the compiler compiles itself to native code) — ~20 runtime/codegen bugs fixed, bootstrap push ongoing

## 0.1.0 Criteria

The initial release establishing the foundation of the Eco compiler toolchain.

- [x] MLIR `eco` dialect established, compilation via LLVM to x86 binaries
- [x] Standard library scaffolding (core, json, bytes, http, regex, url, parser, time)
- [x] Bytes fusion DSL compilation
- [x] Full program optimisation and monomorphisation pass
- [x] Extensive test suite confirming compiler correctness
- [x] Generational garbage collector
- [x] GC stack root tracing for long-running programs
- [x] Scheduler correctness for effect managers
- [x] Linux only
- [ ] Self-compilation (bootstrapping in progress)

## Architecture

```
  Elm source
      │
      ▼
┌───────────┐    compiler/                   Elm compiler written in Elm
│  Parse &  │                                (forked from Guida)
│ Typecheck │
└─────┬─────┘
      │  Typed AST
      ▼
┌───────────┐    compiler/src/Compiler/LocalOpt/
│  LocalOpt │                                Per-module simplification,
│           │                                inlining, case-of-case, DCE
└─────┬─────┘
      │  Optimised AST
      ▼
┌───────────┐    compiler/src/Compiler/Monomorphize/
│ Monomor-  │                                Type-directed specialisation,
│ phization │                                unboxing, erasure
└─────┬─────┘
      │  Monomorphic AST
      ▼
┌───────────┐    compiler/src/Compiler/GlobalOpt/
│ GlobalOpt │                                Whole-program: staged currying,
│           │                                ABI cloning, call annotation
└─────┬─────┘
      │
      ▼
┌───────────┐    compiler/src/Compiler/Generate/MLIR/
│   MLIR    │                                Lambda lowering, bytes fusion,
│  Codegen  │                                MLIR bytecode emission
└─────┬─────┘
      │  eco dialect MLIR
      ▼
┌───────────┐    runtime/src/codegen/
│   LLVM    │                                EcoToLLVM lowering passes
│  Lowering │
└─────┬─────┘
      │  LLVM IR
      ▼
┌───────────┐
│   Native  │    x86 binary (AOT) or JIT execution
│    Code   │
└───────────┘
      │
      ▼
┌───────────┐    runtime/src/allocator/
│  Runtime  │                                GC, heap, process scheduling
│           │    elm-kernel-cpp/
│           │                                C++ kernel implementations
└───────────┘
```

### Key directories

| Directory | Contents |
|-----------|----------|
| `compiler/` | Elm compiler (written in Elm) with MLIR backend |
| `runtime/` | C++20 runtime: MLIR dialect, LLVM lowering, GC, heap |
| `elm-kernel-cpp/` | C++ implementations of Elm kernel packages |
| `eco-kernel-cpp/` | Eco-specific kernel extensions (console, file, env, process) |
| `test/` | Codegen tests, E2E tests, property-based GC tests |
| `design_docs/` | Invariants, theory documentation, design decisions |

## Building

### Prerequisites

**Docker (recommended):**

```bash
docker build -t eco-build .
docker run --rm -v "$PWD":/work eco-build
```

**Debian/Ubuntu host:**

```bash
sudo apt install clang lld ninja-build cmake ccache
```

### Configure and build

```bash
# Release
cmake --preset ninja-clang-lld-linux
cmake --build build

# Debug
cmake --preset ninja-clang-lld-linux-debug
cmake --build build
```

### Running the functional test suite

The functional suite covers the C++ runtime (GC, allocator, kernel ops),
MLIR codegen, and Elm end-to-end tests (compile Elm → MLIR → JIT).

```bash
# Incremental build + run all tests
cmake --build build --target check

# Full clean rebuild + tests (use after compiler changes)
cmake --build build --target full

# Filter tests by name
TEST_FILTER=elm cmake --build build --target check
TEST_FILTER=String cmake --build build --target run-tests

# Compiler frontend tests (Elm-side unit tests, run via elm-test-rs)
cd compiler && npx elm-test-rs --project ../build/compiler/build-xhr --fuzz 1
```

#### Running the test binary directly

```bash
./build/test/test                             # Run all tests
./build/test/test --filter elm                # Filter by name
./build/test/test -n 1000                     # 1000 property-test iterations
./build/test/test -n 1000 --num-tests 1000    # --num-tests is an alias for -n
./build/test/test --num-test-loops 1000       # Canonical long form
./build/test/test -m 500 --max-size 500       # Secondary size (generator complexity)
./build/test/test --seed 42                   # Reproducible run
./build/test/test --timeout 5m                # Fail if the suite takes > 5m
./build/test/test --list                      # List tests without running
./build/test/test -i                          # Interactive test picker
```

`-n` and `-m` are shared with the stress runner below and control the
rapidcheck `max_success` and `max_size` parameters here.

### Running the stress test suite

The stress suite runs longer-lived Elm programs that exercise the
runtime and GC under sustained load. It lives in a separate binary
(`stress-test`) so its high iteration counts don't slow down the
normal `check` cycle.

```bash
# Build only the stress binary (faster than a full rebuild)
cmake --build build --target stress-test

# Run the full stress suite with default parameters
./build/test/stress-test

# Scale work per-test via the shared -n / -m knobs
./build/test/stress-test -n 500 -m 200

# Filter to a single stress program
./build/test/stress-test --filter ListReverseStressTest -n 1000 -m 100

# List the discovered stress programs
./build/test/stress-test --list

# Other options
./build/test/stress-test --timeout 5m          # Per-suite wall-clock budget
./build/test/stress-test -t 30s                # Run repeatedly for 30 seconds
./build/test/stress-test -r 5                  # Repeat the whole suite 5x
./build/test/stress-test --seed 42             # Seed for reproducible runs
./build/test/stress-test -v                    # Verbose (prints config + flags)
```

Stress programs that opt in to parameterization use the shared
`StressHarness` module (`test/stress-elm/src/StressHarness.elm`): they
receive a `StressFlags` record (`maxSize`, `numLoops`, `seed`,
`startMs`, `timeoutMs`, `verbose`) built from the CLI flags above and
use it to size their input and loop count. `-n` sets `numLoops` (outer
iteration count) and `-m` sets `maxSize` (secondary size knob, e.g.
list/array length). `--timeout` is threaded through as `timeoutMs`, so
a harness-based program can bail from its inner loop once the
wall-clock budget is exhausted instead of relying on the backstop
SIGKILL.

### Build targets

Every target below is invoked as `cmake --build build --target <name>`. For a live listing, run `cmake --build build --target help`.

#### Convenience targets

| Target | Purpose |
|---|---|
| `rebuild` | `ninja clean` + full rebuild |
| `check` | Build everything + run E2E tests (set `TEST_FILTER=` to filter) |
| `run-tests` | Run E2E tests without rebuilding |
| `stress` | Build + run stress-elm suite |
| `full` | `clean` + rebuild + run E2E tests |
| `run-mlir-equivalence` | Build mlir-equivalence + run Stage 2 vs Stage 6 MLIR diff |

#### Bootstrap chain

| Target | Stage | Output |
|---|---|---|
| `guida` | 1 | `build/compiler/build-xhr/bin/guida.js` |
| `eco-boot` | 2 | `build/compiler/build-kernel/bin/eco-boot.js` |
| `eco-boot-2` | 3 | `build/compiler/build-kernel/bin/eco-boot-2.js` |
| `eco-boot-3` | 4a | `build/compiler/build-kernel/bin/eco-boot-3.js` |
| `eco-boot-verify` | 4b | JS fixed-point check stamp |
| `eco-compiler-mlir` | 5 | `build/compiler/build-kernel/bin/eco-compiler.mlir` |
| `eco-compiler` | 6 | Native ELF compiler |
| `eco-compiler-boot` | 7 | Native self-compiled compiler |
| `bootstrap` | aggregate | Full chain through Stage 8 fixed-point |

#### Test executables

| Target | Purpose |
|---|---|
| `test` | Main test binary (`build/test/test`) — unit + E2E + allocator |
| `stress-test` | Stress-elm runner (`build/test/stress-test`) |
| `mlir-equivalence` | MLIR-diff binary (`build/test/mlir-equivalence`) |

#### Runtime executables

| Target | Purpose |
|---|---|
| `ecor` | Allocator + RapidCheck test exe (`build/ecor`) |
| `eco-boot-native` | Native MLIR-lowering tool used by Stages 6–8 |
| `ecoc` | Standalone Eco compiler driver |
| `ecogen` | Code-generation driver |

#### Runtime libraries

| Target | Purpose |
|---|---|
| `EcoRunner` | JIT runner library |
| `EcoPasses` | MLIR passes |
| `EcoDialect` | Eco MLIR dialect |
| `BFDialect` | BF (bytecode / bitfusion) MLIR dialect |
| `EcoEntryStatic` | Entry-point glue |
| `EcoRuntimeStatic` | Runtime archive |

#### Elm kernel libraries

| Target | Purpose |
|---|---|
| `ElmKernel_Basics` | `Basics` kernel |
| `ElmKernel_Bitwise` | `Bitwise` kernel |
| `ElmKernel_Browser` | `Browser` kernel |
| `ElmKernel_Bytes` | `Bytes` kernel |
| `ElmKernel_Char` | `Char` kernel |
| `ElmKernel_Debug` | `Debug` kernel |
| `ElmKernel_EffectRegistry` | Effect manager registry |
| `ElmKernel_File` | `File` kernel |
| `ElmKernel_Http` | `Http` kernel |
| `ElmKernel_JsArray` | `JsArray` kernel |
| `ElmKernel_Json` | `Json` kernel |
| `ElmKernel_List` | `List` kernel |
| `ElmKernel_Parser` | `Parser` kernel |
| `ElmKernel_Platform` | `Platform` kernel |
| `ElmKernel_Process` | `Process` kernel |
| `ElmKernel_Regex` | `Regex` kernel |
| `ElmKernel_Scheduler` | `Scheduler` kernel |
| `ElmKernel_String` | `String` kernel |
| `ElmKernel_Time` | `Time` kernel |
| `ElmKernel_Url` | `Url` kernel |
| `ElmKernel_Utils` | `Utils` kernel |
| `ElmKernel_VirtualDom` | `VirtualDom` kernel |

#### Eco kernel libraries

| Target | Purpose |
|---|---|
| `EcoKernel_Console` | `Eco.Console` IO |
| `EcoKernel_Crash` | `Eco.Crash` (Stage 2+ replacement for `Debug.todo`) |
| `EcoKernel_Env` | `Eco.Env` environment variables |
| `EcoKernel_File` | `Eco.File` IO |
| `EcoKernel_Http` | `Eco.Http` IO |
| `EcoKernel_MVar` | `Eco.MVar` synchronization |
| `EcoKernel_Process` | `Eco.Process` IO |
| `EcoKernel_Runtime` | `Eco.Runtime` glue |

#### Tablegen / generated headers

| Target | Purpose |
|---|---|
| `EcoOpsIncGen` | Generate Eco dialect Op .inc files |
| `BFOpsIncGen` | Generate BF dialect Op .inc files |
| `mlir-headers` | Aggregate MLIR header gen |
| `mlir-tablegen-targets` | Aggregate tablegen rule set |
| `acc_gen` | LLVM OpenACC headers (transitive) |
| `omp_gen` | LLVM OpenMP headers (transitive) |
| `target_parser_gen` | LLVM TargetParser headers (transitive) |
| `vt_gen` | LLVM VTune headers (transitive) |

#### CMake built-ins

| Target | Purpose |
|---|---|
| `clean` | Remove ninja-tracked outputs |
| `help` | List all available targets |
| `install` | Install built artifacts |
| `edit_cache` | Open CMake cache for editing |
| `rebuild_cache` | Reconfigure CMake cache |
| `list_install_components` | List installable components |

## Docker development

```bash
# Build image
docker build -t eco-build .

# Interactive session with persistent home directory
docker volume create eco-dev-home
docker run -it --rm -v "$PWD":/work -v eco-dev-home:/home/dev eco-build bash

# One-shot build + test
docker run --rm -v "$PWD":/work eco-build bash -c \
  "cmake --preset ninja-clang-lld-linux && cmake --build build --target check"
```

## Acknowledgements

The Eco compiler frontend is forked from [Guida](https://github.com/guida-lang/compiler), an Elm compiler port. Guida is itself a port of the original [Elm compiler](https://github.com/elm/compiler) by Evan Czaplicki.
