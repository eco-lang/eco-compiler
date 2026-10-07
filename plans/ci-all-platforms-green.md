# Plan: All three platforms green with hard test gates

## Goal

`linux-aot`, `mac-aot` and `win-aot` on `ci/v0.2-github-build` each complete the whole pipeline
(build, every test gate, stage 9, distribution bundle, isolated smoke test) with **every test
gate hard again**: the `TEMP(soft-gates)` changes removed and nothing failing underneath them.
After that the branch can go to `master` (a maintainer decision, not part of this plan).

## Starting point (verified 2026-10-06)

All three workflows complete their builds; only test results are hidden by the soft gates.
Runs: Linux `37445152661` and Mac `37445152664` (commit `3fda845`), Windows `37431329096`
(`35acd3f`; `3fda845`'s Windows run stopped at a test-binary compile fixed in `40cca8a`).

| Platform | Pipeline | Failing under the soft gates |
|---|---|---|
| Linux | green | elm-tests: the 2 GOPT_003 pins (JIT 2128/2128, stress 101/101, AOT 932/932) |
| Mac | green | elm-tests: the 2 GOPT_003 pins; JIT: `WideClosureArity2047Test` + 5 threaded-GC determinism tests |
| Windows | green | elm-tests: the 2 GOPT_003 pins; JIT: `test.exe` dies with heap corruption, so most of the suite never runs |

Not failures, left alone: the codegen MLIR suites, which `test/main.cpp` gates off on Windows
(E-W5, `plans/build-on-windows.md`). Since `f290b6f980` (the `SKIP-AOT` directive) AOT E2E no
longer runs `FlagsRecordTest` and `PortEchoTest`, so Linux AOT is 932/932 (Linux run
`37478972971`, commit `40cca8a`).

## Assumptions

- The `eco-kernel-cpp/src/eco` vs `src/Eco` case collision (canary warnings on Mac/Windows) is
  fixed: the C++ directory is now `eco-kernel-cpp/src/eco-kernel` (merged 2026-10-06, with the
  `F.externalRoots` and `F.fork` canary pins re-audited in M1 and M6).
- Claude can commit and push from the dev container (git works in `/work`; `gh` is authenticated
  as a user with push rights to `eco-lang/eco-compiler`).
- Work happens on `ci/v0.2-github-build`; CI builds `ci/**` on push (path-filtered: a push must
  touch `compiler/`, `runtime/`, `test/`, `cmake/`, a workflow file, or the other listed paths).

## Open issues, in the order to work them

Each issue lists the evidence, what is known, then hypotheses or fixes **in the order to try
them**. Work one issue at a time through the fix loop below. If an issue's options are
exhausted without a fix, stop and ask.

### 1. GOPT_003 bug pins (elm-tests, all platforms)

**Evidence.** Two tests fail identically everywhere:
`JoinpointABI case branch types match after GlobalOpt` ("2.1 majority2Flat: SpecId 3 inline-leaf:
MONO_018 violation", result type `MFunction [MInt] (MFunction [MInt] MInt)` vs inline leaf
`MFunction [MInt,MInt] MInt`) and `Higher-order function tests case branch types match after
GlobalOpt` ("Case returns differently staged lambdas", same shapes).

**Known** (from `compiler/tests/TestLogic/Monomorphize/MonoCaseBranchResultTypeTest.elm`, which
pins it): a `case` whose branches return differently staged lambdas keeps its monomorphized
(curried) result type, while the flat branches are retyped `[Int, Int] -> Int` and the curried
branch is not wrapped. `Compiler.GlobalOpt.Staging.Rewriter`'s `MonoCase` arm never retypes the
case; the GOPT_003 enforcer named in `design_docs/invariants.csv` (`normalizeCaseIfAbi` /
`rewriteCaseForAbi` / `buildAbiWrapperGO` in `Compiler.GlobalOpt.MonoGlobalOptimize`,
around lines 295-345 and 939) is unreachable, and `Staging.validateClosureStaging` is a no-op.
Codegen copes by treating such values as `segmentation_unknown`, so no wrong output is known.
The test's notes point at `/work/gopt003-issue.md`, which is not in the tree.

**Fixes to try.**
1. Make the existing enforcer reachable: after staging, run the case normalization
   (`chooseCanonicalSegmentation` + `buildAbiWrapperGO`) on every `MonoCase` whose branches
   disagree, so the branches are wrapped to one canonical segmentation and the case's result
   type is that canonical type. Read invariants GOPT_003, MONO_018 and the staging invariants
   first.
2. Fix it in `Staging.Rewriter`'s `MonoCase` arm instead: retype the case to the staging chosen
   for its result, and wrap each branch whose staging differs (an ABI wrapper, as
   `buildAbiWrapperGO` builds).
3. Give `Staging.validateClosureStaging` a real body so the condition is caught where it
   arises (this diagnoses; it does not fix).
4. **Only with maintainer sign-off:** turn the two pins into expected failures (for example
   `Test.skip`, which elm-test-rs reports as INCOMPLETE and the CI gate accepts when `Failed: 0`).

**Verify locally** (Linux, this container): `cmake --build build --target elm-tests 2>&1 | tee
/tmp/elm-tests.txt` (once), then the affected E2E programs with
`TEST_FILTER=JoinpointABI cmake --build build --target full` and `TEST_FILTER=HigherOrder ...`.
Codegen should no longer need `segmentation_unknown` for these programs.

**Done when** both tests pass on all three platforms and no other elm-test or E2E test regresses.

### 2. Mac: `WideClosureArity2047Test` segfaults the JS compiler

**Evidence** (Mac run `37445152664`): `Guida compilation failed (exit code 139)`: a SIGSEGV in
`node --stack-size=500000 compiler/bin/index.js make .../WideClosureArity2047Test.elm`. Passes on
Linux.

**Known.** `test/ElmE2ETestBase.hpp:482-485` runs `{ ulimit -s unlimited 2>/dev/null || true; }`
before `node --stack-size=500000` (about 488 MiB). macOS refuses an unlimited stack (the hard
limit is typically 64 MiB), the `|| true` hides that, and V8, told it may use 488 MiB, recurses
past the real stack. `test/mlir_equivalence_main.cpp:286` has the same pattern (Linux-only
today).

**Fixes to try.**
1. Size Node's stack from the real limit: raise the soft limit to the hard limit
   (`ulimit -s hard`), then use `--stack-size` = 90 % of `ulimit -s` when it prints a number,
   and keep 500000 when it prints `unlimited`. Apply to both call sites.
2. If 2047 parameters need more than macOS's 64 MiB, find the deep recursion in the JS
   compiler for this program (reproduce on Linux with `ulimit -s 65520` and a matching
   `--stack-size`, then `--stack-trace-limit=200`) and make it iterative or shallower.
3. Run the compile in a Node worker thread with an explicit stack size
   (`resourceLimits.stackSizeMb`), if (1) and (2) fall short.
4. **Only with maintainer sign-off:** skip this test on macOS (`f290b6f980` added a `SKIP-AOT`
   directive; an analogous directive would be the mechanism).

**Verify locally:** reproduce the segfault on Linux under `ulimit -s 65520`, confirm the fix
there, then confirm on Mac CI.

### 3. Mac: threaded-GC determinism tests

**Evidence** (Mac runs `37431329118`, `37445152664` and earlier; all pass on Linux):
- `threaded-gc-06: promotion through worker 0 of a context reproduces allocate() exactly`:
  `PB_ASSERT(a.layout == b.layout)` at `test/allocator/PromoBufferTest.cpp:115`.
- `threaded-gc-07: a job stopped after k items and finished in the pause places every copy as
  mode 1`, `threaded-gc-07: E2 in a unit test: modes 1 and 2 agree on every counter and placement
  (1 worker)`, `threaded-gc-07: breadth-first (FIFO) tenure order keeps objects, and stop/resume
  placement is exact` (intermittent), `threaded-gc-07b: at k = 2, 3 mode 2 (with forced stops)
  reproduces mode 1: every counter and placement`.
  Every counter matches; only the placement ("layout") differs.

**Known.**
- `threaded-gc-06` runs both arms in one process and compares `OldGenSpace` `layoutHash`
  (`runtime/src/allocator/OldGenSpace.hpp:2175`), which hashes offsets, size classes, alloc
  state, `live_bytes` and mark bitmaps, not absolute addresses.
- The 07/07b tests run each arm in its own forked child (`runInChild` in
  `test/allocator/TenureAgeingTest.cpp` and `ConcurrentTenureTest.cpp`) and compare
  `NurserySpace::test_layout_`, which records **absolute** destination addresses
  (`runtime/src/allocator/NurseryTenure.cpp:106`).
- `ConcurrentTenureTest.cpp` states its assumption: every child forks from the same parent state,
  so the root set (an `unordered_set` of slot addresses, iterated in hash order) "sees identical
  malloc placement in every arm". macOS's allocator may not honour that across forks.
- On macOS `MADV_POPULATE_WRITE` does not exist, so `populate_supported` is false and the
  commit-ahead path (U2) is disabled in mode 2; pages are 16 KiB on arm64.

**Hypotheses to test, in order.**
1. **Root iteration order differs between the forked arms** (macOS malloc placement differs, so
   the address-keyed root set iterates differently and tenure visits objects in another order).
   Instrument: in each arm, log the first N root-slot addresses in iteration order and the first
   N tenure destinations. If the root orders differ, decide with the maintainer whether the fix
   is in the runtime (iterate roots in a deterministic order, if GC_DET_001 is meant to hold
   across platforms) or in the test (register roots in a stable order).
2. **Heap or region bases differ between the arms**, so equal relative placements hash
   differently. Instrument: log the heap base and each region's base per arm. If only the bases
   differ, record placements relative to the base in the test.
3. **16 KiB pages or the missing populate path change mode 2's behaviour.** Instrument: log the
   page size, `populate_supported`, and committed bytes and block count after each minor GC in
   both modes; diff the two arms.
4. **Helper-thread timing leaks into placement** (the FIFO test is intermittent). Instrument: log
   each job's stop point and which thread finished which chunk; rerun the failing tests several
   times in one CI run to separate deterministic from timing-dependent failures.
5. For `threaded-gc-06` specifically: dump both arms' block lists (position, size class,
   `live_bytes`, bitmap) and report the first block that differs.

**Instrumentation mechanism:** a test-only environment variable (for example
`ECO_TEST_LAYOUT_DUMP=<dir>`) that makes these tests write per-arm dumps; add the directory to
`mac-aot.yml`'s artifact upload (marked `TEMP(diag)`), download it with `gh run download`, and
diff the dumps locally.

**Done when** the five tests pass on Mac in two consecutive runs, and still pass on Linux.

### 4. Windows: heap corruption in `test.exe`

**Evidence** (Windows runs `37368741971`, `37431329096`): `test.exe exit code: -1073740940
(0xC0000374)`, which is `STATUS_HEAP_CORRUPTION`, about 2 s into the run. The last test name on
stdout varies between runs (inside the `threaded-gc-05a`/`05b` suites); stderr holds only
RapidCheck lines. An earlier run exited 1 at `gc_mark_threads JSON, env and validation`, most
likely the same fault.

**First lead.** In three of four runs (`37363862386`, `37431329096`, `37478973111`; the fourth,
`37368741971`, stopped earlier in `threaded-gc-05a`) the last test name printed is
`threaded-gc-05b: gc_mark_threads JSON, env and validation`
(`test/allocator/ParallelMarkTest.cpp:317`), which only parses strings and catches the
exceptions it expects. The test before it, `a forked child can run the gang`, is a no-op on
Windows, so the last real work is `threaded-gc-05b: GCMarkGang runs every member exactly once per
run`: `GCMarkGang::configure(8, 0)`, 8000 `run()`s with a stack `Ctx`, then
`shutdownForTesting()` (`runtime/src/allocator/GCHelperPool.cpp`, `memberLoop` around line 411,
`run` around 468, `shutdownForTesting` around 498). Heap corruption usually surfaces at the next
allocation, so examine the gang's Windows thread lifecycle first: thread start in
`startThreadsLocked`, the `threads_` vector, `tl_member_run_`, and whether a member can still
touch `fn_`/`ctx_` or gang state after `run()` returns or after `shutdownForTesting()`.

**Already ruled out.** On Linux the full test binary under glibc's checking allocator
(`LD_PRELOAD=libc_malloc_debug.so.0`, `GLIBC_TUNABLES=glibc.malloc.check=3`, `MALLOC_PERTURB_`)
found no corruption in 2224 tests. The `MarkWork.hpp` deque buffers (`new`/`delete`) and
`RootSet.cpp`'s `malloc`/`free` pairs are matched.

**Steps, in order.**
1. **Localize by suite.** Add a `TEMP(diag)` step to `win-aot.yml` that runs after a failed
   JIT step: run `test.exe --filter <suite>` for each top-level suite in turn and print each
   exit code (hex), so the suite that corrupts the heap shows up on its own. Each run takes
   seconds.
2. **Catch the corrupting write.** Probe the runner for the Debugging Tools
   (`C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\{gflags,cdb}.exe`). If present, enable
   full page heap (`gflags /p /enable test.exe /full`) and run the culprit suite under
   `cdb -g -G -o -c "g; .ecxr; kb 50; q" build\test\test.exe --filter <suite>`; RelWithDebInfo
   builds have PDBs (`/Zi`), so the stack is symbolized. If the tools are missing, try
   installing them in the step, or use Application Verifier.
3. **AddressSanitizer on Windows.** If (1) and (2) do not pin it down, add a diagnostic job that
   builds `test.exe` with clang-cl `/fsanitize=address` and runs the culprit suite.
4. **Code review of Windows-only paths**, guided by (1): `PlatformVirtualMemory_win32.cpp`
   (64 KiB allocation granularity vs 4 KiB pages; `MEM_RELEASE` only at a reservation's base),
   `StackUnwind.cpp`'s Windows unwinder, the Windows branches of `GCHelperPool`, `ReservedArray`
   and the mark-bitmap arena; 32-bit `long` on Windows (LLP64) in size arithmetic; the
   `alignas(64)` types (`MarkWork.hpp:217-219`, `OldGenSpace.hpp` `SharedWord`/`ClaimWord`)
   allocated or freed through a path that is not alignment-aware; and C runtime mixing (a
   library such as rapidcheck built with a different `/MT`/`/MD` runtime frees memory from
   another heap).

**Done when** `test.exe` runs to its summary on Windows in two consecutive runs.

### 5. Windows: the rest of JIT E2E, run for the first time

Once issue 4 is fixed, everything after the crash point runs on Windows for the first time,
including the Elm end-to-end suites. Expect a new failure list. Triage each failure:
- a real bug: fix it through the loop;
- a feature Windows does not support: guard it with a stated reason, **with sign-off**;
- a harness problem: fix the harness.

Add each new item to this plan as issue 5a, 5b, … before working it.

### 6. Upstream churn: new fork()-based tests

New `test/allocator` files keep arriving with `sys/wait.h` and `fork()` (`WideClosureTest.cpp`,
`WideObjectTest.cpp`). When the Windows test binary fails on one, guard it the way the existing
files do: POSIX includes and fork helpers under `#if !defined(_WIN32)`, the tests that need a
child as no-ops on Windows, newly unused helpers `[[maybe_unused]]`. Check with the MinGW
syntax check (see the loop) before pushing.

### 7. Restore the hard gates (last)

When issues 1-5 are fixed, remove every `TEMP(soft-gates)` change (`grep -rn
'TEMP(soft-gates)' .github/`): the `continue-on-error: true` lines in `mac-aot.yml` and
`win-aot.yml`, and the `SOFT_GATES` switch and `gate_fail` helper in `linux-aot.yml`, which goes
back to exiting on a failed gate. Remove the `TEMP(diag)` steps too. Keep the improved Windows
JIT diagnostics (exit code in hex, stdout and stderr apart, `test_output.txt.err` uploaded).
Then run the loop until all three platforms are green with the gates hard.

### Optional, if time allows

- `linux-aot.yml`'s "Verify fully-static eco binary" step rebuilds the `eco-static` target
  (about 40 minutes) instead of reusing the image the previous step built.
- `actions/checkout@v4`, `actions/cache@v4` and `actions/upload-artifact@v4` trigger Node 20
  deprecation warnings.
- `mac-aot.yml` tries `brew install rapidcheck`, which always fails before the source-build
  fallback and leaves a red annotation on every run.

## The fix loop

Repeat until the exit criteria hold.

1. **Pick** the first open issue above. Write the hypothesis or fix being tried in the
   iteration log at the end of this file.
2. **Read** the code, and before touching codegen, runtime or representation code, the relevant
   rows of `design_docs/invariants.csv` (CLAUDE.md). Before touching `runtime/src/allocator/`,
   read `test/tla/README.md`.
3. **Instrument** when the cause is not yet known: minimal, behaviour-neutral, gated by a
   test-only environment variable or confined to test code, and marked with a `TEMP(diag)`
   comment so it is easy to find and remove. Instrumentation is its own commit.
4. **Fix** once the evidence points at a cause: the smallest change that addresses it, one
   concern per commit.
5. **Check locally** before every push:
   - build the touched targets on Linux (`ninja -C build <objects>` or
     `cmake --build build --target test`);
   - for Windows-only code, a MinGW syntax check: `x86_64-w64-mingw32-g++-posix -fsyntax-only`
     with the test target's `-I`/`-D` flags (from `ninja -C build -t commands`); it catches
     missing POSIX headers and calls, though it is not MSVC;
   - the kernel-license canary when `elm-kernel-cpp/` changes:
     `sh test/scripts/check-kernel-license-manifest.sh .` (it runs in the full build, not in
     `--target test`). If it fires, re-audit per `plans/kernel-parametricity-license.md` §2,
     advance each affected row's `audited:` date with the verdict, then `--update`;
   - the canary: `sh test/scripts/check-tla-manifest.sh .` (strict). If a pin fires, follow
     GC_MODEL_001: check the named models' MAPPING.md, add a dated AUDIT.md entry with a
     verdict and the new hash prefix to each named model, then `--update`. Never just repair
     the hash;
   - compiler changes: elm-tests locally (`cmake --build build --target elm-tests`), run once
     with output to a file per CLAUDE.md;
   - workflow changes: parse the YAML (`python3 -c "import yaml; yaml.safe_load(open(...))"`).
6. **Commit** following `GITSTYLE.md`:
   - one imperative, capitalized subject of about 50-70 characters, no trailing period, no
     scope prefix, naming the concrete thing changed;
   - a blank line, then a body hard-wrapped at 100 columns, in the present tense, one paragraph
     per concern, stating the why (the failure fixed, the evidence, the constraint);
   - **no tool or assistant attribution trailers** (no `Co-Authored-By:` naming an AI, no
     session links, no "Generated with" lines);
   - write the message to a file under `/tmp` and use `git commit -F`.
7. **Push** to `origin ci/v0.2-github-build`. Never push to `master`. Do not force-push unless
   a rebase onto the maintainer's branch was agreed. Cancel superseded runs on the branch
   (`gh run cancel <id>`) to save runner time.
8. **Monitor** with `gh run list -R eco-lang/eco-compiler -b ci/v0.2-github-build`, a polling
   watcher on the run IDs, or `gh run watch`. Typical durations: Windows about 60 minutes to the
   smoke test (JIT E2E about 25 minutes in); Mac 80-90 minutes; Linux `test` about 2 h 40 min,
   then `bundle` about 1 h 20 min (40 minutes of that is the fully-static check).
9. **Read the logs.** A job's log is available once that job finishes:
   `gh api --allow-escape-sequences repos/eco-lang/eco-compiler/actions/jobs/<job-id>/logs`.
   Use `gh run view <run> --log` once the run finishes, and `gh run download <run> -n <name>`
   for artifacts. While soft gates are on, the API reports a failed `continue-on-error` step as
   success: read its log for the test summary (`Tests failed:`, `✗` lines, `Failed:`), and on
   Linux the `::error title=Soft gate failed::` annotations.
10. **Decide** from the evidence and record it in the iteration log: fixed (go to 1 for the next
    issue, and remove the instrumentation in its own commit), new evidence (refine the
    hypothesis and go to 3), or hypothesis refuted (take the next one). After three iterations
    on one hypothesis without progress, move to the next; when an issue's options are
    exhausted, stop and ask.

## Guardrails

Without asking: code and harness fixes, test-only instrumentation, guarding POSIX-only tests on
Windows, `TEMP(diag)` diagnostic steps in `mac-aot.yml` and `win-aot.yml`, and removing the soft
gates at the end, all on `ci/v0.2-github-build`.

Ask first:
- skipping, deleting or weakening a test, or changing a test's expectation to match new
  behaviour;
- renaming directories or other large refactors;
- any change to `publish-nightly.yml` or `release.yml`;
- merging to `master`.

Never: put the TLA+ model checks, trace validation or GenMC into CI (local gates only), or
repair a canary hash without the GC_MODEL_001 audit.

## Exit criteria

- No `TEMP(soft-gates)` or `TEMP(diag)` change left in the tree.
- On one commit, `linux-aot` (`test` and `bundle`), `mac-aot` and `win-aot` all succeed, and in
  every run each test gate reports zero unexpected failures: elm-tests `Failed: 0`, JIT E2E
  `Tests failed: 0`, stress `Tests failed: 0`, and AOT E2E failing only on its two tolerated
  tests.
- The macOS determinism fix holds for two consecutive Mac runs, and the Windows `test.exe`
  reaches its summary in two consecutive Windows runs.

## Iteration log

| # | Date | Issue | Hypothesis / change | Commit | Runs | Result |
|---|---|---|---|---|---|---|
| 0 | 2026-10-06 | 1 | Deferred by the maintainer: GOPT_003 is fixed on another branch and merged across when ready. The loop works issues 2-7 meanwhile. | | | deferred |
| 1 | 2026-10-06 | 2 | Fix 1: `NodeBigStack.hpp` raises the soft stack limit to unlimited or the hard limit and passes `--stack-size` = 90 % of it (max 500000) at all three node sites. Reproduced on Linux first: 8 MiB soft + `--stack-size=500000` exits 139; the compile needs 7-16 MiB; under 64 MiB hard / 8 MiB soft the fixed script compiles it with byte-identical output, and `test --filter WideClosureArity2047` passes. | `afb6b85b` | mac `37494848356` | **fixed**: `[659/659] WideClosureArity2047Test ok`; JIT failures down to the determinism tests |
| 2 | 2026-10-06 | 4 | Step 1, sharpened: `ECO_TEST_HEAPCHECK` makes the runner `_heapchk()` after every test (Windows) and exit 97 at the first corrupting test; a `TEMP(diag)` win-aot step reruns test.exe that way, probes for gflags/cdb and, if present, runs it under full page heap in cdb. Test names are flushed (`std::endl`), so the last name printed is reliable. | `79554ce4` | win `37494848413` (cache miss), `37510505595` | culprit found: the heap check passes after every 05b test up to `gc_mark_threads JSON, env and validation`; page heap + cdb (both present on the runner) stop with VERIFIER STOP 0x10 "corrupted start stamp" while `__std_exception_destroy` frees a block inside test.exe's image (the literal "ECO_GC_MARK_THREADS ..."), from the catch at `ParallelMarkTest.cpp:326` |
| 3 | 2026-10-06 | infra | Runs for `79554ce4` (linux `37494848337`, win `37494848413`) failed at the LLVM cache restore (`fail-on-cache-miss`): per-commit ccache saves (~1.6 GB a push) pushed the repo past its 10 GB cache allowance and the Windows LLVM and debian LLVM caches were evicted. Deleted six superseded ccache entries; dispatched `win-llvm-build` (`37496511230`) and `linux-llvm-build-debian` (`37496515268`) on this branch to re-warm, then re-run. | | | in progress |
| 4 | 2026-10-06 | 3 | Hypotheses 3 (16 KiB pages, no populate) refuted locally: a Linux build with `OS_PAGE_SIZE = 16384` and `populate_supported = false` passes all five tests. Hypothesis 1 confirmed on Linux: `RootSet` iterates an `unordered_set` of slot addresses, so scan order (hence placement) depends on where `Workload`'s heap-allocated `slots` vector lands; shifting it in one arm of threaded-gc-06 (a 768-byte malloc before the workload) fails `a.layout == b.layout` with every other figure equal, with libstdc++'s identity hash and with a libc++-style mixing hash. glibc reuses the freed chunk so the arms match; macOS's allocator does not. Not a GC_DET_001 breach (that invariant is about helper-thread progress). Maintainer chose the test fix: `MinorWorkload` keeps its slots and `tmp` in static storage (heap fallback when taken). Verified on Linux with the shifted heap plus the mixing hash: all five pass; `threaded-gc-06` (18) and `threaded-gc-07` (40) groups pass as on clean HEAD. Aside, pre-existing on clean HEAD too: `test --filter threaded-gc-0` aborts in "parallel minors under a running concurrent mark cycle" (old-gen allocation fails in `evacuate`); it passes alone and in the unfiltered CI order. | `ad6b0898` | mac `37510505777`, `37518982508` | **fixed**: JIT 2128/2128 on two consecutive Mac runs |
| 5 | 2026-10-06 | 4 | Cause: `llvm_update_compile_flags` (via `add_mlir_library`/`add_llvm_executable`) defines `_HAS_EXCEPTIONS=0` on MSVC targets without `LLVM_REQUIRES_EH`; `obj.EcoRunner`, `ecoc`, `eco-boot-native` re-enable EH with `/EHsc` but kept it, so the runtime's `std::exception` had the STL's no-exceptions layout while the test's catch used the vcruntime one and freed the literal message. Fix: `eco_drop_no_exceptions_define` strips it from those targets; `HeapConfigJson.cpp` `#error`s if it returns. TEMP(diag) stays until test.exe reaches its summary twice. | `a9bc4638` | win `37518982415`, `37527286767` | **fixed**: test.exe reaches its summary on both runs (717/719, then 718/719). TEMP(diag) removed in its own commit. |
| 6 | 2026-10-06 | 7 (optional) | `mac-aot.yml`: build rapidcheck from source directly (Homebrew has no formula; the failed `brew install` left an error annotation on every run). | `59e1426b` | mac `37518982508` | **fixed**: no annotation |
| 7 | 2026-10-06 | 5a | Windows: `threaded-gc-05c: conc_mark_* and Part B JSON keys and validation` writes its config to `/tmp/...`, absent on Windows ("cannot open"). Harness fix: `std::filesystem::temp_directory_path()`. | `3ffcc976` | win `37527286767` | **fixed** |
| 8 | 2026-10-06 | 5b | Windows: `K8b decoder read_string goldens` fails `units[i] == g.units[i]`; passes on Linux/macOS, the decoder is deterministic on the zero-padded input. The assert now names the golden (`bfed936e`): `overlong_4: code unit at 1: got 0061, want 0000`. Cause: the legacy decode reserves two units per 4-byte lead but an overlong one writes one, so the last unit is stale nursery memory (0061 = the earlier ascii_31's 'a'). Reproduced on Linux with a minor GC before each decode (stale DFFF). Fix: zero the leftover units. | `695ae9e3` | win `37535443873` | build failed: the change tripped `check-kernel-license-manifest` (25 Bytes rows pin BytesExports.cpp); re-audited in the next commit |
| 9 | 2026-10-06 | 5b | Kernel-license re-audit for the 25 TypeFaithful Bytes rows (§2 of the license plan): only `read_string` changed, u16 stores into its own result; no application/retention/fabrication/type change. Evidence dates advanced, line citations shifted, manifest regenerated; elm-tests 14099 passed, 2 failed (the GOPT_003 pins only). Local loop step 5 now runs this canary. | `d6cc63cc` | win `37538768652` | **fixed**: test.exe 719/719, exit 0; bundle smoke test OK. Windows JIT is clean; only the GOPT_003 elm-tests pins remain (soft). |
| 10 | 2026-10-07 | 7 | Maintainer decision: keep every `TEMP(soft-gates)` change until the GOPT_003 branch merges, then restore the hard gates (issue 7 as written) and run the loop to the exit criteria. Until then the soft gates hide only the 2 GOPT_003 elm-tests pins. | | | deferred |
| 11 | 2026-10-07 | 2-5 | All three platforms on one commit (`aab6d3c7`): Linux `37538768557` (test + bundle) JIT 2128/2128, stress 101/101, AOT E2E 932/932, only soft-gate annotation = elm-tests; Mac `37538768576` JIT 2128/2128 (4th clean run); Windows `37538768652` test.exe 719/719, bundle smoke OK. Under the soft gates only the 2 GOPT_003 elm-tests pins fail, everywhere. Remaining: issue 1 (other branch), then issue 7. | `aab6d3c7` | as listed | **green except GOPT_003** |
