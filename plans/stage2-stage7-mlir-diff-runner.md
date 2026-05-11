# Stage 2 vs Stage 7 MLIR equivalence test runner

## Goal

A new C++ test runner under `test/` that, for every Elm E2E test source file across all `test/elm*`, `test/eco-kernel/`, and `test/stress-elm/` directories, compiles the source twice — once with the Stage 2 compiler (`eco-boot.js` via Node) and once with the Stage 7 compiler (`eco-compiler` native ELF) — and asserts the two text-MLIR outputs are byte-identical.

This is a **bootstrap equivalence check**: it pins the JS-and-native compilers to producing the same MLIR for the same input.

## Decisions (from /pqn round 1)

- **Naming**: target / binary = `mlir-equivalence`. Source = `test/mlir_equivalence_main.cpp`. Output dir = `build/test/mlir-equivalence/`.
- **CMake integration**: standalone opt-in target. Not part of `full`. User runs `cmake --build build --target mlir-equivalence` explicitly. If `eco-boot.js` or `eco-compiler` are missing, the runner exits with a clear "run bootstrap stages 1–6 first" diagnostic.
- **Cache isolation**: each invocation uses its own `--builddir` so Stage 2's and Stage 7's `.ecot` / `.eci` / `.eco` caches never collide. No shared `eco-stuff/`.
- **Concurrency**: parallel test execution mirroring the existing Elm E2E runner, capped at 4 concurrent tests to start (each test spawns both Stage 2 Node + Stage 7 native, ~2.5 GB each).
- **MLIR comparison**: `--text-mlir` produces byte-canonical output across compilers, so byte-for-byte diff is the comparator.
- **Failure policy**: any side failing to build to MLIR = FAIL. Both sides must produce MLIR. If both fail (even with the same error), the test still FAILS — we have no MLIR to compare.
- **Exit code**: non-zero on any failure (matches existing `test/test`).

## Step-by-step plan

### Phase 1 — discovery

1. Enumerate Elm E2E test directories under `/work/test/`:
   - `test/elm/`
   - `test/elm-core/`
   - `test/elm-bytes/`
   - `test/elm-http/`
   - `test/elm-json/`
   - `test/elm-regex/`
   - `test/elm-time/`
   - `test/elm-url/`
   - `test/eco-kernel/`
   - `test/stress-elm/`
   - Skip `test/elm-parser/` if it contains no `src/*Test.elm` (see open question 1).
   - The C++-only directories (`allocator/`, `bf-codegen/`, `codegen/`) are out of scope.
2. For each test directory, enumerate `src/*Test.elm` files (matches the existing Elm E2E convention).
3. Each test directory has its own `elm.json` defining its package dependencies; both Stage 2 and Stage 7 invocations run with that directory as their working directory so they pick up the right deps.

### Phase 2 — CMake integration

4. Add a new CMake target `mlir-equivalence` in `test/CMakeLists.txt`:
   - Builds a new test binary `mlir-equivalence` from `test/mlir_equivalence_main.cpp` (+ any helper headers).
   - Has no automatic dependency on `eco-boot.js` or `eco-compiler` (those are bootstrap outputs, not CMake outputs).
   - Supports `--filter <pattern>` flag for `TEST_FILTER=…` compatibility.
   - Invocation: `cmake --build build --target mlir-equivalence` builds the binary and runs it once.
5. Runner preflight: at startup, check that `compiler/build-kernel/bin/eco-boot.js`, `compiler/build-kernel/bin/eco-boot-runner.js`, and `compiler/build-kernel/bin/eco-compiler` all exist. If any missing, print a diagnostic pointing at `guides/bootstrap.md` and exit non-zero.

### Phase 3 — runner core

6. New C++ binary `test/mlir_equivalence_main.cpp`:
   - Reuse `IsolatedTestRunner.hpp` / `ElmE2ETestBase.hpp` patterns from the existing Elm E2E runner where they fit; otherwise write minimal scaffolding tailored to this runner.
   - Test case representation: `struct TestCase { std::string package_dir; std::string elm_src; std::string display_name; }`.
   - Discovery: walk the directories listed in Phase 1, build a `std::vector<TestCase>`.
   - Apply `--filter` if present (substring match on `display_name`).

7. For each test case, in a worker thread:
   1. Compute per-stage build directories (under `build/test/mlir-equivalence/<package>/<test>/stage2/` and `stage7/`). The `--builddir` flag is passed to the compiler so all of its `eco-stuff/`, `.eci/.eco/.ecot` etc. land there and cannot collide with the other stage or with concurrent tests. Per-test build dirs also handle within-package concurrency.
   2. Stage 2 invocation: spawn `node --stack-size=65536 <repo>/compiler/build-kernel/bin/eco-boot-runner.js make --optimize --text-mlir --builddir <stage2_dir> --kernel-package eco/compiler --local-package eco/kernel=<repo>/eco-kernel-cpp --output=<stage2_dir>/out.mlir <abs path to test elm file>`, with `cwd = <package_dir>` and env `NODE_OPTIONS=--max-old-space-size=12000`.
   3. Stage 7 invocation: same flags / cwd, but binary = `<repo>/compiler/build-kernel/bin/eco-compiler` (no `node` wrapper), and `--builddir <stage7_dir>`.
   4. If either invocation exits non-zero or its `out.mlir` is missing, mark FAIL with that side's stderr captured (capped to ~80 lines).
   5. If both succeed: byte-compare `stage2/out.mlir` and `stage7/out.mlir`. On mismatch: FAIL + unified diff excerpt (capped to ~80 lines). On match: PASS.

8. Worker thread pool: hard-cap at **4 concurrent tests** (each spawns Stage 2 Node + Stage 7 native, ~2.5 GB resident per side). Configurable via env var `MLIR_EQUIV_JOBS` for future tuning, default 4.

9. Summary at the end:
   - `Tests run: N`, `Tests passed: P`, `Tests failed: F`
   - List of failed tests
   - Exit 0 if `F == 0`, else 1
   - Match the output format of `test/test` so CI parsing is consistent.

### Phase 4 — output and ergonomics

10. Per-test status line as each test completes, mirroring the existing runner's `[N/M] TestName ok / FAILED:` format.
11. On FAIL with mismatch: print test name, paths to the two `.mlir` files (kept for postmortem), and a unified diff excerpt.
12. On FAIL with compile error: print which side failed (Stage 2 or Stage 7) and its stderr tail.
13. Build dirs `build/test/mlir-equivalence/<package>/<test>/stage{2,7}/` persist after the run for inspection; cleaned only by `cmake --build build --target clean`.

### Phase 5 — verification

14. Run the new target after a fresh bootstrap. Expect a baseline pass rate; non-passes are the bootstrap differences to investigate.
15. Add a short note in `guides/bootstrap.md` or a new `guides/mlir-equivalence.md` explaining when to run the target and how to interpret failures.

## Remaining open questions (lower priority, can be resolved during implementation)

1. **`test/elm-parser/`**: I have not yet confirmed whether this directory contains Elm tests or only C++ parsing tests. If it has `src/*Test.elm`, include it; otherwise skip silently.
2. **Test entry-point pattern**: I'll match `src/*Test.elm`. If some packages have non-`Test.elm` Elm files used as shared helpers, those won't be invoked as test entry points — confirm this matches the existing convention.
3. **`stress-elm` / `eco-kernel` peculiarities**: these packages may have non-`Test.elm` shared modules or unusual entry points. If discovery picks up something that fails for both stages with an "unsupported entry" error, the runner will report it as a real FAIL (since both must produce MLIR). I'll handle observed false positives reactively rather than predicting them.
4. **Per-package kernel-package overrides**: I am assuming every test directory uses `eco/compiler` + `eco/kernel=<repo>/eco-kernel-cpp`. If discovery surfaces a package that needs different flags, add a small per-package config table.
5. **`elm-stuff/` collisions**: `--builddir` controls Eco caches but stock `elm-stuff/` may still be shared per package. If we see contention from concurrent tests in the same package, escalate to per-test `--builddir` for both `elm-stuff/` and `eco-stuff/`, or fall back to serializing within a package.

## Out of scope

- Re-running Stage 1, Stage 2, Stage 6 themselves — those are bootstrap.md steps. The runner only consumes their outputs.
- Comparing the bytecode (`.eco`) intermediate files — only the final text MLIR.
- Stress-test runtime execution — this runner stops at MLIR generation; it never lowers to LLVM or runs the program.
- Diff visualization beyond unified diff (no HTML, no side-by-side).
- Inclusion in `full` — opt-in only.
