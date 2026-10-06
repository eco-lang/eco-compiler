# Wide heap objects, Phase 0: baselines and pins

**Parent:** [`wide-object-tail-kind-words.md`](wide-object-tail-kind-words.md) (phase map §4, test mechanics §6, shared definitions §S).
**Status:** DONE (2026-10-05): baselines recorded, harness fixed, all pins added and red for their listed reasons.

Phase 0 changes no production code. It does three things:
- records the baselines every later gate compares against;
- adds one harness fix that the big pins need (Step 0.5; the rule is overview §6.5);
- adds every pin that can be written against today's APIs. Each pin fails today for a reason
  recorded here, and is listed with the phase that turns it green. **This file's pin list is
  authoritative**; every later phase's expected-failure list is this list minus the pins already
  green.

Pins that need APIs or attributes introduced later are written in the phase that introduces them:
- Phase 2: the closure-boundary unit tests (`WideClosureTest.cpp`), the bytecode-encoder elm-test,
  the `eval_desc_sat_*` fixtures;
- Phase 3A: `WideObjectTest.cpp`;
- Phase 3B: the wide construct fixtures;
- Phase 3D: the 2040/2041 and 2047/2048 cap fixtures, the `TooLarge` field-variant elm-tests (`LimitErrorsTest`) and the
  String-at-24 elm-test variant.

**Verified against the tree on 2026-10-05.** Every pin below was compiled with
`node compiler/bin/index.js`, lowered with `eco-boot-native` and run in the session scratchpad;
the "Today" column is the observed result. Expected values were computed by the generator script
(Appendix P0-A), which mirrors each program's arithmetic. Where a program partly runs correctly
today (`.f27`, `f0024`, `f0028`), the run confirmed the generator's formula.

---

## Step 0.1: preconditions and snapshot

1. **Clean tree.** Use the git tree, or `benchmarks/lss-loop-snap.sh snap base-wide "wide-object
   plan: Phase 0 base"`.
2. **Build trees:** configure and build `build` with `cmake --preset build`, then
   `cmake --build build`.
3. **Validate tree.** Recreate `build-validate` if it is absent (§S.7), needing about 20 GB free.
   Use `ulimit -c 0` for every run (§6.1): negative controls dump cores.
4. **Test binaries are not in ALL:** run `cmake --build build --target test`, then check the mtime
   of `build/test/test`.

**Rollback:** nothing to roll back.

## Step 0.2: functional baselines (run each ONCE, tee'd, §6.1 / §S.7)

| # | Command | Record | Value on 2026-10-05 (fill in the empty cells at Step 0.2) |
|---|---|---|---|
| B-1 | `cmake --build build --target elm-tests 2>&1 \| tee /tmp/p0_elmtests.txt` | pass/fail counts; the **names** of failures (`grep '✗'`) | 14,059 pass / 4 fail: `MonoCaseBranchResultTypeTest` × 2 (GOPT_003); `CallAbiConsistencyTest` "constructor with a field past the unboxed slot cap is called with matching operand types"; `DestructorTypeProjectionTest` "Int field past the unboxed slot cap is projected boxed, then unboxed" |
| B-2 | cache wipe (§6.3), then `ulimit -c 0; cmake --build build --target full 2>&1 \| tee /tmp/p0_full.txt` | counts; failure lines `grep -E 'FAIL:' /tmp/p0_full.txt` | 2,040 pass / 1 fail: `elm/WideCtorField24Test.elm` |
| B-3 | move `build/test/aot-e2e/*/eco-stuff` aside; `cmake --build build --target run-aot-e2e 2>&1 \| tee /tmp/p0_aot.txt` | pass/fail list | 913 run, 910 pass / 3 fail: `elm/FlagsRecordTest` (ELF crashed, signal 6) and `elm/PortEchoTest` (CHECK miss; the AOT runner has no flags/port echo, a known harness gap), `elm/WideCtorField24Test` (MLIR→ELF failed) |
| B-4 | `cmake --build build --target bootstrap 2>&1 \| tee /tmp/p0_boot.txt && cmake --build build --target eco-verify 2>&1 \| tee -a /tmp/p0_boot.txt` | A==B, B==C verdicts | **green** (2026-10-05): Stage 4b JS fixed point and Stage 8c native fixed point hold; `eco-verify` rc 0. First bootstrap after the Oct 5 fixes |
| B-5 | `register-guards` (§S.7) | green / red list | green (validate-only arms skipped in `build`, as designed) |
| B-6 | `tla-canary`, configured with `-DECO_TLA_CANARY_STRICT=ON` | clean / not clean | clean (strict, rc 0) |

**Elm-test failure lines:** elm-test-rs prints `✗ <test name>`; the gate compares the set of `✗`
names.

**E2E failure lines:** `build/test/test` prints `  FAIL: <name>: <reason>`. ANSI colour codes
appear when stdout is a TTY; strip them with `sed 's/\x1b\[[0-9;]*m//g'` before comparing. E2E
names are `elm/<File>.elm` and `eco-kernel/<File>.elm`; codegen fixture names are
`codegen/<file>.mlir`.

**Rollback:** nothing to roll back.

## Step 0.3: performance baseline (one timed triple)

Follow `benchmarks/fe-opt-loop.md` §2 "Phase 2 — the candidate builds itself" with
`ARM=eco-opt-prev`, i.e. the current compiler; that "Phase 2" is fe-opt-loop's naming, not this
plan's. Two adjustments:
- `REG=~/.eco/0.1.3/packages/registry.dat` (the version moved past 0.1.1);
- `ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"`.

Record the median and spread of these stats in the table below:
- wall;
- minor and major GC count;
- promoted MiB;
- max RSS;
- GC time (`Minor GC time` / `Major GC time` lines of `$ARM-rR.stdout`);
- objects allocated (`Objects allocated:`).

**Name the binary** (`eco-opt-prev` and its sha256): later counter comparisons are only valid
against the same lowering (counters are not bit-exact across lowerings).

**Recorded 2026-10-05.** `build/compiler/build-kernel/bin/eco-optP0`, sha256
`44e3b9b593b29438af760736b48ca58d398bcabef51a31c72c891c366bfe6db3`. `eco-opt-prev` no longer
existed (the `full` target's clean removes it), and it predated the Oct 5 fixes anyway, so the
baseline binary was built from the Phase 0 tree with fe-opt-loop's Phase 1.3/1.4: the bootstrap's
`eco-compiler-boot-2` compiled `ecoP0.mlir` with `--optimize`, lowered by `eco-boot-native`. The
three runs are byte-identical to each other and to `ecoP0.mlir` (deterministic + fixed point).
GC time is the `Total GC/Alloc time` line (the `Minor/Major GC time` lines do not exist).

| stat | r1 | r2 | r3 | median | spread |
|---|---|---|---|---|---|
| wall (s) | 68.22 | 67.46 | 68.12 | 68.12 | 0.76 (1.1 %) |
| minor GCs | 1333 | 1333 | 1333 | 1333 | 0 |
| major GCs | 7 | 7 | 7 | 7 | 0 |
| promoted MiB | 6361 | 6361 | 6361 | 6361 | 0 |
| objects allocated | 304,190,251 | 304,190,260 | 304,190,286 | 304,190,260 | 35 |
| GC time (s) | 2.98 | 2.98 | 2.99 | 2.98 | 0.01 |
| max RSS (kB) | 6,419,148 | 6,422,956 | 6,412,952 | 6,419,148 | 10,004 |

**Rollback:** nothing to roll back.

## Step 0.4: censuses

### 0.4a Self-compile wide-object census (MLIR census script)

**No source patch is needed.** The census reads the self-compile's MLIR. Convert the r1 output
of Step 0.3 to text (ecoc writes the dump to **stderr**):

```bash
BK=build/compiler/build-kernel
ulimit -c 0
build/runtime/src/codegen/ecoc --emit=mlir "$BK/bin/eco-opt-prev-r1-out.mlir" > /tmp/p0_self.txt 2>&1
python3 plans/wide-object-tail-kind-words-census.py /tmp/p0_self.txt | tee /tmp/p0_census.txt
```

The script is Appendix P0-B. Commit it as `plans/wide-object-tail-kind-words-census.py`, a plan
artefact rather than source, so the Phase 2 and Phase 3C gates can re-run it. It is the only census
mechanism of this plan; no lowering instrumentation is added.

**Result** on the Step 0.3 output (`eco-optP0-r1-out.mlir`, 2026-10-05):

| census row | count |
|---|---|
| papCreate total | 25,362 |
| papCreate arity ≤ 20 | 25,359 |
| papCreate arity 21..25 (gain one ext word in P2) | 2 |
| papCreate arity 26..63 | **1**: `@Compiler_Eco_Config_InlineConfig_$_28135`, arity 27, num_captured 0 |
| papCreate arity > 63 / num_captured > 25 | 0 / 0 |
| papExtend total / with > 25 operands | 33,687 / 0 |
| construct.custom size > 24 | 0 |
| construct.record field_count > 26 | 432 |
| construct.record with an `eco.box`-defined operand at index ≥ 26 (a primitive boxed by the 26 cap; this is what P3C changes) | 4 |

**E10 (overview §1): an E8 instance inside the compiler.** The arity-27 papCreate is the record-alias constructor
`InlineConfig` used by `Compiler.Eco.Config.inlineDecoder`
(`compiler/src/Compiler/Eco/Config.elm:649-676`, `D.pure InlineConfig |> D.apply …`).
- Its parameter 25 is `kernelCostHof : Int`, whose kind the closure header truncates (B5).
- The decoder runs only when an `eco-config.json` with an `"inline"` key is read
  (`Compiler/Eco/Config.elm:583`). No such file exists in the tree, so today's self-compile is
  unaffected; a user config would silently get a pointer-sized `kernelCostHof`.
- Phase 2 fixes it, and the census must then show it with ext words, no change otherwise. The
  Phase 2 gate also runs one self-compile with an `eco-config.json` containing an `"inline"` object.

### 0.4b Kernel census (`closureCapture` / closure and aggregate builders), run now

```bash
cd /work
grep -rn -E "allocClosureK\(|allocClosure\(|eco_alloc_closure_k\(|eco_alloc_closure\(" \
  elm-kernel-cpp/src eco-kernel-cpp/src runtime/src/platform runtime/src/allocator \
  --include=*.cpp --include=*.hpp | grep -v -E "inline HPointer|extern \"C\""
grep -rn -E "\b(alloc::)?(custom|record)\(" elm-kernel-cpp/src eco-kernel-cpp/src runtime/src/platform --include=*.cpp
grep -rn "eco_alloc_with_roots(Tag_Custom\|eco_alloc_with_roots(Tag_Record" elm-kernel-cpp/src eco-kernel-cpp/src
```

| builder | sites | maximum size |
|---|---|---|
| kernel closures (`allocClosure` / `allocClosureK`) | 38 call lines: Http, Task, Time, Platform, Port, Scheduler, MVar, TaskBinding | **max_values 5** (`runtime/src/platform/PortRuntime.cpp:211`) |
| `alloc::custom` / `custom(…)` | Browser, Bytes, Http, Task, Time, Platform, Json, `eco-kernel/Http.cpp` | ≤ 5 fields (largest `std::vector<Unboxable> fields(5)`) |
| `alloc::record` / `record(…)` | Http (`HttpExports.cpp:223`, `:314`, `:331`), `eco-kernel/Process.cpp:160`, `:259` | ≤ 5 fields |
| Json decoder Customs (`eco_alloc_with_roots(Tag_Custom…)`) | `elm-kernel-cpp/src/json/JsonExports.cpp`; `buildMapDecoder` at `:1539` | **9 fields** (`DEC_MAP8`, `:1597`) |

**Conclusions** (inputs to P1 1c/1d and HEAP_077):
- No kernel closure reaches slot 20.
- No kernel aggregate reaches 24 fields.
- The P1 `closureCapture` abort, at idx ≥ 25 and later ≥ 20, cannot fire from kernels.
- The P1 tail loops are dead for kernel-built objects.

**Rollback:** nothing to roll back.

## Step 0.5: harness change: big-stack compilation (needed by four pins)

**Observed.** With the E2E harness's plain `node <index.js> make …`
(`test/ElmE2ETestBase.hpp:479-480`, inside `compileElmFile`), the Stage-1 JS compiler overflows its
stack on four pins:
- `WideClosureArity300Test`: writes a **truncated** `.mlir` (only `main`) and exits 0. The lowering
  then fails with `expected operation name in quotes`.
- `WideCtor1100Test`: no output file, exit 0.
- `WideRecordDecoder300Test`: `eco-io handler error: RangeError: Maximum call stack size exceeded`,
  exit 0.
- `WideClosureArity2047Test`: segfault.

With `ulimit -s unlimited` plus `node --stack-size=500000` all four compile completely (arity
2047: 32 s; the others ≤ 11 s). The AOT runner already passes `--stack-size=65536`
(`test/aot_e2e_main.cpp:367`), which is not enough for arity 2047.

**Change.** In `test/ElmE2ETestBase.hpp`, inside `compileElmFile`, build the command as:

```cpp
// was: std::string compileCmd = "cd \"" + testDir + "\" && node \"" + guidaPath + "\" make ...
std::string compileCmd = "cd \"" + testDir + "\" && { ulimit -s unlimited 2>/dev/null || true; } && "
                         "node --stack-size=500000 \"" + guidaPath +
                         "\" make \"" + elmPath + "\" --output=\"" + result.mlirPath + "\"" + getTextMlirFlag();
```

The `ulimit` must run in the same shell as `node`: an earlier draft used a `( … )` subshell, which
leaves node's limit unchanged, and the arity-2047 pin then segfaulted (exit 139).

In `test/aot_e2e_main.cpp:367`, raise `--stack-size=65536` to `500000` and run the child under the
same `ulimit -s unlimited` (wrap the argv in `sh -c 'ulimit -s unlimited; exec "$@"' sh …`).

**Invariant:** no test outcome changes except that these four pins reach their verifier error. B-2
must still be exactly 2,040 / 1.

**Related: B21** (overview §3). `compiler/bin/index.js:22-24` catches the handler exception,
logs it and responds 500, but the process exit code stays 0, so a broken `.mlir` reaches the
backend. That is why a stack overflow above looks like a later lowering error. The fix
(`process.exitCode = 1` there and in `compiler/bin/eco-boot-runner.js:84`) is a Phase 1 step. It
has no pin: a portable non-zero-exit test would need a crash that stays reproducible after this
step's stack fix.

**Rollback:** revert the two harness lines.

## Step 0.6: add the pins

All E2E pin sources are produced by the generator (Appendix P0-A, committed as
`plans/wide-object-tail-kind-words-pins.py` so they can be regenerated):

```bash
python3 plans/wide-object-tail-kind-words-pins.py test/elm/src test/eco-kernel/src
```

It writes 19 files into `test/elm/src/` (the 20th Elm pin, `WideCtorField24Test.elm`, already exists) and 2 into `test/eco-kernel/src/`. The generated files
**are** the pins and are committed. Do not hand-edit them; regenerate them.

### 0.6a E2E pins (expected output = their `-- CHECK:` lines)

| File | Covers | CHECK lines (all must match) | Today, verified | Green at |
|---|---|---|---|---|
| `elm/WideCtorField24Test.elm` (exists) | E1 | existing | verifier: `size (27) exceeds Custom's 24-slot limit` | P3D |
| `elm/WideRecordPatternTest.elm` | E3, B3 | `access f27: 1027`, `access f25: 1025`, `pattern: 1028025`, `update f27: 1028`, `update f26: 7`, `update pattern: 1029025` | CHECK miss: `pattern: 1120986464801025`, `update pattern: 1120986465697025` | P1 |
| `elm/WideClosureGroupTest.elm` | B15 | `group: 849` | runtime abort: `eco_gc_push_stack_range: Assertion 'count <= 64 && "stack root range exceeds 64-slot limit"'` | P1 |
| `elm/WideClosurePap27bTest.elm` | E4 | `res: [23702, 40502]` | CHECK miss: `res: [90799903730678, 90799903725370]` | P2 |
| `elm/WideClosureSat26Test.elm` | E5 | `res: [6208, 6215]` | verifier: `'eco.papExtend' op newargs_unboxed_bitmap exceeds 50-bit capacity` | P2 |
| `elm/WideClosureBoxed27Test.elm` | E6 | `res: [385, 392]` | verifier: `newargs count (27) exceeds 25-slot limit` | P2 |
| `elm/WideClosureCapture27Test.elm` | E7 (String and Int captures) | `strings: [1378, 2378]`, `ints: [7930, 8930]` | verifier: `'eco.papCreate' op num_captured (27) exceeds 25-slot limit` | P2 |
| `elm/WideRecordDecoder26Test.elm` | E8 | `f0000: Just 1000`, `f0024: Just 1024`, `f0025: Just 1025` | CHECK miss: `f0025: Just 1120986469856` | P2 |
| `elm/WideRecordDecoder30Test.elm` | E8 (mixed kinds at positions ≥ 25) | `f0000: Just 1000`, `f0024: Just 1024`, `f0025: Just 25.5`, `f0026: Just 'a'`, `f0027: Just 1027`, `f0028: Just "28s"`, `f0029: Just 1029` | CHECK miss on f0025/26/27/29 (`5.53840904272e-312`, `'ឈ'`, …) | P2 |
| `elm/WideClosureArity63Test.elm` | arity 63; steps 1/7/20/20/15; Float/Char at 19/20/24/25/51/52/62; String 33; Bool 40 | `res: [72873]` | runtime abort: `eco_pap_extend: cannot un-box null/embedded HPointer` (`RuntimeExports.cpp:2579`) | P2 |
| `elm/WideClosureArity300Test.elm` | arity 300; steps 1/7/20/63/64/65/80 (root chunks > 64) | `res: [1882518]` | verifier: `'eco.papCreate' op arity (300) exceeds 6-bit max_values limit (63)` (after Step 0.5) | P2 |
| `elm/WideClosureArity2047Test.elm` | arity 2047, steps up to 1527 | `res: [577952886]` | verifier: `arity (2047) exceeds 6-bit max_values limit (63)` (after Step 0.5; compile 32 s) | P2 |
| `eco-kernel/WideClosureGcTest.elm` | 200 arity-28 closures across `GC.minorGC` and `GC.majorGC` | `WideClosureGcTest minor: 1`, `… major: 1`, `… value: 8956201` | verifier: `'eco.papExtend' op newargs_unboxed_bitmap exceeds 50-bit capacity` (the eco-kernel suite fuses the 20 + 7 extends into one 27-newarg extend; a scratch run without that fusion gave the CHECK miss `value: 18161410731484301`) | P2 |
| `elm/WideRecordDecoder70Test.elm` | E9 | 12 lines `f00NN: Just …` (in file) | verifier: `'eco.papCreate' op arity (70) exceeds 6-bit max_values limit (63)` | P3D (record cap; the arity part is fixed in P2) |
| `elm/WideRecordDecoder300Test.elm` | 300-field decoder | 12 lines (in file) | verifier: `papCreate … arity (300) …` (after Step 0.5) | P3D |
| `elm/WideRecord33Test.elm` | 33 mixed fields: access/pattern/update/`==`/`Debug.toString` | in file (incl. full `show: { f0000 = 1000, … }`) | verifier: `'eco.construct.record' op field_count (33) exceeds Record's 32-slot GC scan limit` | P3D |
| `elm/WideRecord40Test.elm` | 40 mixed fields | in file | `field_count (40) exceeds …` | P3D |
| `elm/WideRecord600Test.elm` | call-path allocation (> 4096 B) | in file | `field_count (600) exceeds …` | P3D |
| `elm/WideRecord1100Test.elm` | large object (> 8 KiB) | in file | `field_count (1100) exceeds …` (front end 11 s) | P3D |
| `elm/WideCtorMixedTest.elm` | 60 mixed fields; case on 23/24/55/59; `==`; `show: W …` | in file | `'eco.construct.custom' op size (60) exceeds Custom's 24-slot limit` | P3D |
| `elm/WideCtor1100Test.elm` | 1100 mixed fields | in file | `size (1100) exceeds …` (after Step 0.5) | P3D |
| `eco-kernel/WideHeapGcTest.elm` | 200 × (40-field record, 60-field ctor) across minor + major GC | `… minor: 1`, `… major: 1`, `… value: 842495` | `field_count (40) exceeds …` | P3D |

The arity-2048 limit is pinned by **elm-tests** (`LimitErrorsTest`, 0.6b item 5), not an E2E
file: the Elm E2E harness has no expected-compile-error directive (`test/ElmE2ETestBase.hpp`
compile step: a non-zero exit is a test failure). Phase 2 step 2.8.6 adds a one-off CLI check of
the rendered, located error.

### 0.6b elm-test pins (`compiler/tests/TestLogic/…`)

1. **Existing:**
   - `CallAbiConsistencyTest.elm:77` "constructor with a field past the unboxed slot cap is
     called with matching operand types": red today, green P1 (B1).
   - `DestructorTypeProjectionTest.elm:157` "Int field past the unboxed slot cap is projected
     boxed, then unboxed": red today, green P1 (B2). Phase 3C rewrites it to expect
     `project.custom[24] -> i64` (field 24 becomes unboxed), and Phase 3D adds a String-at-24
     variant that keeps the boxed projection path covered.
2. **B3, new test in `TestLogic/Generate/CodeGen/DestructorTypeProjectionTest.elm`:**
   "record pattern of a field past the record slot cap is projected boxed, then unboxed".
   - **Program** (SourceBuilder):
     - `fields = f00..f27 : Int` (28);
     - `viaPat : { f00 : Int, …, f27 : Int } -> Int` with argument pattern `pRecord ["f27", "f25"]`
       and body `f27 * 1000 + f25` (`binopsExpr`, or `callExpr (varExpr "add")` per the existing
       helpers);
     - `testValue = viaPat (recordExpr [ ("f00", intExpr 0), … ])`.
   - **Check:** add `checkRecordFieldProjection : Types.RecordLayout -> MlirModule -> List
     Violation` to `TestLogic/Generate/CodeGen/DestructorTypeProjection.elm`. Compute the layout
     with `Compiler.Generate.MLIR.Types.computeRecordLayout` (`Types.elm:465`) over the 28 `MInt`
     fields. Then every `eco.project.record` whose `_operand_types` is `[!eco.value]`, whose
     `field_index` has `isUnboxed = False`, and whose result is unboxable is a violation:
     `"raw read of boxed record field <i> as <type>"`.
   - **Guard:** the test first requires at least one `eco.project.record` in the output
     (`countRecordProjections`), so it cannot pass by the pattern being optimised away.
   - **Today:** fails with that message for field 27 (and 25 if boxed: it is not, index 25 < 26).
     **Green P1.** Because it reads the layout from `Types`, it stays valid when Phase 3C drops the
     record cap. Phase 3C rewrites only the fixed-index rules that Phase 1 adds to the checker.
3. **B9, rewrite test 9 in `TestLogic/Monomorphize/AbiCloningPapFastPassTest.elm:296-319`.**
   - Rename it "9. §11.1 a constructor wider than 24 fields STAMPS (B1: the ctor function takes
     every field at its ABI)".
   - Replace the assertions with `Expect.equal 1 st.stampedPapGlobal` and
     `Expect.equal 0 st.declinedNoInstance`.
   - **Today:** fails, because `stampedPapGlobal` is 0 (the guard at `AbiCloning.elm:2988`).
     **Green P1** (B9).
4. **B4, new test in `TestLogic/Generate/CodeGen/UnboxedBitmapTest.elm`:** "closure kind
   attributes stay within the backend's slot limits".
   - **Program:** `mk : Int -> … (26 Ints) -> (Int -> Int)`, `mk a0 … a25 = \x -> x * 7 + a0 * 1 +
     … + a25 * 26`, `testValue = List.map (mk 1 2 … 26) [1, 2]`. This is the `CloP26I` shape.
   - **Check** (new `checkClosureKindLimits` in `UnboxedBitmap.elm`):
     - every `eco.papExtend` has `newargs_unboxed_bitmap < 2^50` and ≤ 25 real newargs;
     - every `eco.papCreate` has `unboxed_bitmap < 2^50` and `num_captured ≤ 25`;
     - **from P2**, these become "`slot_kinds` length ≤ 2047, no u64 bitmap present".
   - **Today:** fails with `papExtend newargs_unboxed_bitmap 1501199875790165 needs 52 bits (limit
     50)`. **Green P2.**
   - **Resolved (implemented 2026-10-05):** `runToMlir` does not produce a 26-newarg papExtend for
     `mk`; it produces an `eco.papCreate` with `num_captured = 26` and `unboxed_bitmap =
     1501199875790165`. That closure breaks both limits, so the program was kept. Today's failure:
     `papCreate unboxed_bitmap 1501199875790165 needs 52 bits (limit 50)` and `papCreate
     num_captured 26 exceeds 25`. ("Needs N bits" counts whole 2-bit slots.)
5. **Limit diagnostics (B18, D5): new test module `compiler/tests/TestLogic/Canonicalize/LimitErrors.elm`
   and `LimitErrorsTest.elm`**, modelled on `TestLogic/Canonicalize/DuplicateDecls.elm`. That module
   runs `Compiler.Canonicalize.Module.canonicalize` on a built `Src.Module` and inspects the
   `CanError.Error` list.
   - **Expectation helper**, in two forms:
     - **Phase 0 form** (the constructor doesn't exist yet):
       `expectTooLarge : String -> Int -> Int -> Src.Module -> Expectation`. It passes when
       canonicalization fails with exactly one error whose `Debug.toString` starts with
       `"TooLarge"`, contains the variant tag given as the `String` (e.g. `"TooManyParams"`), and
       ends with the `actual` and `limit` numbers.
     - **Phase 2 form** (step 2.8.6 switches to it):
       `expectTooLarge : (CanError.TooLargeWhat -> Bool) -> Int -> Int -> Src.Module -> Expectation`,
       matching the real constructor.
     - `expectCanonicalizes : Src.Module -> Expectation` is for the boundary case.
   - **Cases** (build every parameter list with `List.range`, never literally):
     - "a top-level function with 2048 parameters is TooLarge TooManyParams": `big a0 … a2047 = a0`,
       expecting 2048 and 2047, `TooManyParams "big"`;
     - "a let-defined function with 2048 parameters is TooLarge TooManyParams": the same `big`
       inside a `let`;
     - "a lambda with 2048 parameters is TooLarge TooManyLambdaParams": `f = \a0 … a2047 -> a0`;
     - "a lambda with 2000 parameters capturing 48 locals is TooLarge TooManyClosureSlots":
       `mk c0 … c47 = \a0 … a1999 -> c0 + … + c47 + a0`, expecting 2048 and 2047,
       `TooManyClosureSlots Nothing`;
     - "a function with 2047 parameters is accepted": `expectCanonicalizes`;
     - "the TooLarge report names the function and the limit": render the first error of the
       2048-parameter case with `CanError.toReport` to its title plus
       `Compiler.Reporting.Doc.toString` of its message (there is no `Report.toDoc`; the source
       text comes from `Compiler.Reporting.Render.Code.toSource ""`); it contains
       `TOO MANY PARAMETERS`, `big` and `2047`. The module also exposes a third helper,
       `expectFirstReportContains`, for this case.
   - **Today:** no `TooLarge` error exists, so canonicalization succeeds. The five non-boundary
     cases fail; the boundary case passes.
   - **Green P2.** Phase 3D (step 3D.2) adds the field cases to the same module.

### 0.6c Codegen fixtures (`test/codegen/`; full text in Appendix P0-C)

| File | RUN | Today | Green at |
|---|---|---|---|
| `make_closure_packed_word.mlir` (B13) | `%ecoc %s -emit=mlir-llvm 2>&1 \| %FileCheck %s` | FileCheck miss: expected `llvm.mlir.constant(16578 : i64)`, emitted `4290` | P1. **P2 must update the CHECK** to the new packed word `2 \| 3<<11 \| 1<<24 = 16783362` |
| `construct_custom_i1_operand_rejected.mlir` (B14) | `not %ecoc %s -emit=mlir 2>&1 \| %FileCheck %s` | ecoc **accepts** it (exit 0), so `not` fails | P1 (verifier text must contain `has i1 type`) |
| `construct_record_i1_operand_rejected.mlir` (B14) | same | accepts | P1 |
| `pap_simplify_fusion_slot_cap.mlir` (B16) | `%ecoc %s -emit=mlir-eco 2>&1 \| %FileCheck %s` | error after fusion: `'eco.papExtend' op newargs_unboxed_bitmap exceeds 50-bit capacity` | P1 (fusion declines: two extends). **P2 rewrites the CHECKs** to one fused 30-newarg extend |

### 0.6d Unit pins: new file `test/allocator/WideObjectPinsTest.cpp` (+ `.hpp`)

**Registration:**
- `void registerWideObjectPinsTests(Testing::TestSuite& suite);`
- add `#include "allocator/WideObjectPinsTest.hpp"` next to `test/main.cpp:46`;
- a suite `Testing::TestSuite wideObjectPinsTests("Wide object pins");` with
  `registerWideObjectPinsTests(wideObjectPinsTests);` next to `test/main.cpp:995`, added to the
  runner like `genericApplyBoxingTests`;
- add the `.cpp` to `test/CMakeLists.txt` beside `allocator/GenericApplyBoxingTest.cpp`
  (`test/CMakeLists.txt:104`).

**Every pin that can crash today runs in a `fork()` child** (pattern
`test/allocator/ParallelMinorTest.cpp:434-454`), so a red pin fails one test instead of killing
the binary. Shared helper:

```cpp
// child returns normally => exit 0; abort => signalled
template <class F> static int runInChild(F f) {
    pid_t pid = fork();
    if (pid == 0) { f(); _exit(0); }
    int st = 0; waitpid(pid, &st, 0);
    return WIFSIGNALED(st) ? -WTERMSIG(st) : WEXITSTATUS(st);
}
static HPtr stubEval(void**) { return HPtr::fromBits(0); }
```

| Test name | Body (sketch) | Expect | Today | Green |
|---|---|---|---|---|
| `wide B6: closureCapture of a typed kind at slot >= 25 aborts` | child: `initAllocator(); HPointer c = alloc::allocClosureK(stubEval, 30, PK_Boxed); void* p = Allocator::instance().resolve(c);` 25 × `closureCapture(p, boxedInt(i), PK_Boxed)`; then `closureCapture(p, Unboxable{.i = 7}, PK_Int)` | `runInChild(...) == -SIGABRT` | child exits 0 (raw Int stored under a boxed kind, `HeapHelpers.hpp:2054-2058`) | P1 |
| `wide B7: pointerMaskFromKindBitmap treats slots >= 32 as boxed` | `volatile u64 bm = 1; volatile unsigned n = 40;` `u64 m = pointerMaskFromKindBitmap(bm, n);` | `m == ((1ULL<<40) - 2)` | bit 32 clear (UB shift reads slot 0's kind, `Heap.hpp:281-287`) | P1 |
| `wide B7: equality of 40-field records compares slots >= 32 as boxed` | `std::vector<Unboxable> v(40)`; `v[0].i = 5`; slots 1..39 `= boxed allocInt(1000+i)`, built **twice** (distinct pointers); `alloc::record(v, 1)` × 2; `Elm_Kernel_Utils_equal(a, b)` | result is True (`Export::encodeBoxedBool(true)` bits) | False (slot 32 compared as a raw Int pointer, `elm-kernel-cpp/src/core/Utils.cpp:666-674`) | P1 |
| `wide B7: boxed captures 32..39 of a 40-slot closure survive minor GCs` | child: `allocClosureK(stubEval, 40, 0)`; capture slot 0 `PK_Int` 5, slots 1..39 boxed `allocInt(1000+i)`; root the closure (`getRootSet().addRoot`); 2 × (churn 1e5 ints; `minorGC()`); read slots 32..39, deref and check `ElmInt.value == 1000+i` | child exit 0, run in **build-validate** (poisoned from-space makes it deterministic) | slot 32 untraced (closure walker `fieldKind(cl->unboxed, 32)` = slot 0's kind) → wrong value or validate abort | P1 |
| `wide B8: custom() with 70 boxed fields roots every slot on the slow path` | child: `initAllocator(cfg)` with small nursery; fill until `Allocator::instance().allocateFast(16) == nullptr` (probe; nothing allocated on failure); `std::vector<Unboxable> v(70)` boxed `allocInt(1000+i)` rooted; `HPointer h = alloc::custom(0, v, 0);` then check each slot's `ElmInt.value == 1000+i` immediately | child exit 0 | abort: `eco_gc_push_stack_range` `assert(count <= 64)` (`RuntimeExports.cpp:4317`) on 70 roots | P1 |
| `wide B8b: slots 24..69 of a 70-field Custom survive a later minor GC` | as above, then root `h`, churn, `minorGC()`, check slots 24..69 | child exit 0 (validate tree) | Custom walker stops at `i < 24` (`HeapChildWalk.hpp:70`) | P1 (1d) |
| `wide B11: eco_set_unboxed on a Record aborts` | child: `HPointer r = alloc::record({boxed, boxed}, 0); eco_set_unboxed(HPtr::fromBits(…r…), 3);` | `-SIGABRT` | child exits 0 (writes `header.unboxed = 3`, `RuntimeExports.cpp:294-298`) | P1 |

The closure-boundary unit tests (`eco_pap_extend_l`, arities 20/21/52/53/2047, `EvaluatorDesc` /
`EvalParamLayout` `static_assert`s, all-boxed apply at 100) use Phase 2 APIs, so they are written in
Phase 2 (`WideClosureTest.cpp`).

**Rollback for 0.6:** delete the generated pins, the fixtures, `WideObjectPinsTest.*` and the
two-line registration; revert the test edits.

## Step 0.7: Phase 0 gate (expected-failure lists)

Run each command once (§6.1, §S.7), after the cache wipe (§6.3).

**elm-tests: exactly these 12 `✗` names**
- `MonoCaseBranchResultTypeTest` × 2 (GOPT_003, unrelated);
- `CallAbiConsistencyTest` "constructor with a field past the unboxed slot cap is called with
  matching operand types";
- `DestructorTypeProjectionTest` "Int field past the unboxed slot cap is projected boxed, then
  unboxed";
- `DestructorTypeProjectionTest` "record pattern of a field past the record slot cap is projected
  boxed, then unboxed";
- `AbiCloningPapFastPassTest` "9. §11.1 a constructor wider than 24 fields STAMPS …";
- `UnboxedBitmapTest` "closure kind attributes stay within the backend's slot limits";
- `LimitErrorsTest`: the five non-boundary cases of 0.6b item 5 (the 2047 boundary case passes).

**`full` (build/test/test): exactly these failures, each with its reason substring**

| Name | Reason substring |
|---|---|
| `elm/WideCtorField24Test.elm` | `exceeds Custom's 24-slot limit` |
| `elm/WideRecordPatternTest.elm` | CHECK `pattern: 1028025` missing |
| `elm/WideClosureGroupTest.elm` | `stack root range exceeds 64-slot limit` / crash |
| `elm/WideClosurePap27bTest.elm` | CHECK `res: [23702, 40502]` missing |
| `elm/WideClosureSat26Test.elm` | `newargs_unboxed_bitmap exceeds 50-bit capacity` |
| `elm/WideClosureBoxed27Test.elm` | `newargs count (27) exceeds 25-slot limit` |
| `elm/WideClosureCapture27Test.elm` | `num_captured (27) exceeds 25-slot limit` |
| `elm/WideRecordDecoder26Test.elm` | CHECK `f0025: Just 1025` missing |
| `elm/WideRecordDecoder30Test.elm` | CHECK `f0025: Just 25.5` missing |
| `elm/WideClosureArity63Test.elm` | `cannot un-box null/embedded HPointer` / crash |
| `elm/WideClosureArity300Test.elm` | `arity (300) exceeds 6-bit max_values limit (63)` |
| `elm/WideClosureArity2047Test.elm` | `arity (2047) exceeds 6-bit max_values limit (63)` |
| `elm/WideRecordDecoder70Test.elm` | `arity (70) exceeds 6-bit max_values limit (63)` |
| `elm/WideRecordDecoder300Test.elm` | `arity (300) exceeds 6-bit max_values limit (63)` |
| `elm/WideRecord33Test.elm`, `…40…`, `…600…`, `…1100…` | `field_count (N) exceeds Record's 32-slot GC scan limit` |
| `elm/WideCtorMixedTest.elm`, `elm/WideCtor1100Test.elm` | `exceeds Custom's 24-slot limit` |
| `eco-kernel/WideClosureGcTest.elm` | `newargs_unboxed_bitmap exceeds 50-bit capacity` |
| `eco-kernel/WideHeapGcTest.elm` | `field_count (40) exceeds Record's 32-slot GC scan limit` |
| `codegen/make_closure_packed_word.mlir` | FileCheck: `16578` not found |
| `codegen/construct_custom_i1_operand_rejected.mlir`, `codegen/construct_record_i1_operand_rejected.mlir` | `not` failed (ecoc exit 0) |
| `codegen/pap_simplify_fusion_slot_cap.mlir` | `newargs_unboxed_bitmap exceeds 50-bit capacity` |
| `wide B6 …`, `wide B7: pointerMask…`, `wide B7: equality…`, `wide B8 …`, `wide B11 …` | assertion text in the test |

`wide B7: boxed captures…` and `wide B8b` must be red in **build-validate**; in the default tree
they may pass by luck. List them in the validate run, not the default one. Everything else in
`full` passes. The run count is B-2's 2,041 + 21 new E2E pins (19 `elm/` + 2 `eco-kernel/`) +
4 fixtures + 7 unit pins = 2,073.

**Recorded 2026-10-05** (after the §6.3 cache wipe, then `full` and `elm-tests` once each):
- `full`: 2,073 run, 2,042 pass, 31 fail. The 31 are exactly the list above: 20 `elm/` E2E pins
  (19 new + `WideCtorField24Test`), 2 `eco-kernel/` pins, 4 fixtures, 5 unit pins. Each failed for
  its listed reason. The two remaining unit pins (`wide B7: boxed captures…`, `wide B8b`) passed
  by luck in the default tree, as expected; every previously passing test still passes.
- `WideClosureArity2047Test` first segfaulted in the compiler (the subshell `ulimit` bug fixed in
  Step 0.5); re-run alone after the fix, it compiles in 49 s and fails with `arity (2047) exceeds
  6-bit max_values limit (63)`.
- build-validate, `--filter "wide B"`: 7 run, 7 fail. Both GC pins fail on a stale from-space
  pointer (`debugAssertValidNurseryPointer`: the untraced slot), B8 on `count <= 64`.
- `elm-tests`: 14,059 pass / 12 fail, exactly the 12 names above.

**Other gates:**
- `register-guards`, `tla-canary`, bootstrap and AOT equal their baselines B-3..B-6. AOT also
  gains the new pins, with the same reasons, or skips the eco-kernel ones per its own harness.
- No production code changed, so the perf triple is not re-run.

## Phase 0 checklist

- [x] 0.1 snapshot, trees built, validate tree recreated
- [x] 0.2 B-1..B-6 recorded (bootstrap re-run done; attribute any failure first)
- [x] 0.3 perf triple recorded, binary named
- [x] 0.4a census script committed and run on the 0.3 output; table replaced
- [x] 0.4b kernel census confirmed (max closure 5, max aggregate 9)
- [x] 0.5 harness stack change; B-2 still 2,040 / 1
- [x] 0.6 generator committed; 21 new E2E pins (+ the existing `WideCtorField24Test`), 5 elm-test pins (2 existing + 3 new + test 9 rewrite),
      4 fixtures, 7 unit pins added
- [x] 0.7 every pin red for exactly its listed reason; nothing else changed

## Open questions (with the defaults used above)

1. **Arity-2047 E2E compile time** (32 s plus lowering). Default: keep it in `full`. If the gate
   budget objects, move it to the eco-kernel suite's opt-in tier.
2. **`WideClosureArity63Test` today aborts** in a dev-asserting build. In a build without asserts
   it would print a wrong value. Default: the gate reason is "crash or CHECK miss".

## Appendix P0-A: pin generator (`plans/wide-object-tail-kind-words-pins.py`)

Deterministic. Usage: `python3 plans/wide-object-tail-kind-words-pins.py test/elm/src test/eco-kernel/src`.

```python
#!/usr/bin/env python3
"""Generate the wide-object E2E pins of plans/wide-object-tail-kind-words-phase-0.md.

Usage: gen_wide_pins.py OUT_ELM_DIR OUT_ECO_KERNEL_DIR
Writes one <Name>.elm per pin; each file carries its own `-- CHECK:` lines,
computed here from the same formulas the program evaluates.
Deterministic: re-running produces byte-identical files.
"""
import sys, os

def kind(i):            # mixed-kind pattern: Int, Float, Char, String, Bool
    return ["Int", "Float", "Char", "String", "Bool"][i % 5]

def elm_val(i, k, base="base"):
    # source expression for field i of kind k; base is a runtime 1
    return {"Int": f"({base} + {1000 + i - 1})",
            "Float": f"(toFloat {base} + {i}.5 - 1)",
            "Char": f"(Char.fromCode ({base} + {96 + (i % 26)}))",
            "String": f"(String.fromInt ({base} + {i - 1}) ++ \"s\")",
            "Bool": f"(modBy 2 ({base} + {i - 1}) == 0)"}[k]

def py_show(i, k):      # Debug.toString of that value with base = 1
    return {"Int": str(1000 + i),
            "Float": f"{i}.5",
            "Char": "'" + chr(97 + (i % 26)) + "'",
            "String": f"\"{i}s\"",
            "Bool": "True" if i % 2 == 0 else "False"}[k]

HDR = "import Html exposing (text)\n\n"
BASE = "        base =\n            1 + List.length [ () ] - 1\n\n"

def module(name, doc, checks, body):
    s = f"module {name} exposing (main)\n\n{{-| {doc}\n-}}\n\n"
    s += "".join(f"-- CHECK: {c}\n" for c in checks) + "\n" + HDR + body
    return s

def fields_decl(n, kinds):
    return "\n    , ".join(f"f{i:04d} : {kinds[i]}" for i in range(n))

def logs(pairs):        # pairs: (label, expr)
    return "".join(f"        _ =\n            Debug.log \"{l}\" ({e})\n\n" for l, e in pairs)

out = {}

# ---- WideRecordPatternTest (E3, B3; green P1) --------------------------------
n = 28
decl = "\n    , ".join(f"f{i:02d} : Int" for i in range(n))
vals = "\n        , ".join(f"f{i:02d} = base + {1000 + i - 1}" for i in range(n))
body = f"""type alias R =
    {{ {decl}
    }}


make : Int -> R
make base =
    {{ {vals}
    }}


viaPat : R -> Int
viaPat {{ f27, f25 }} =
    f27 * 1000 + f25


upd : R -> R
upd r =
    {{ r | f27 = r.f27 + 1, f26 = 7 }}


main =
    let
{BASE}        r =
            make base

{logs([("access f27", "r.f27"), ("access f25", "r.f25"), ("pattern", "viaPat r"),
       ("update f27", "(upd r).f27"), ("update f26", "(upd r).f26"), ("update pattern", "viaPat (upd r)")])}    in
    text "done"
"""
out["WideRecordPatternTest"] = module("WideRecordPatternTest",
    "E3/B3: a 28-Int record read through a record PATTERN projects slots 26/27\n(stored boxed under the 26-slot cap) as raw i64. `.f27` and update are correct.",
    ["access f27: 1027", "access f25: 1025", "pattern: 1028025", "update f27: 1028",
     "update f26: 7", "update pattern: 1029025"], body)

# ---- WideClosurePap27bTest (E4; green P2) ------------------------------------
n = 28
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * (n + 1))
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
first = " ".join(f"(base + {i})" for i in range(20))
step = " ".join(f"(b + {i})" for i in range(20, 27))
exp = [sum((1 + k) * (k + 1) for k in range(20)) + sum((b + k) * (k + 1) for k in range(20, 27)) + 5 * 28
       for b in (100, 200)]
L_PAP27B = logs([("res", "List.map (\\g -> g 5) gs")])
body = f"""big : {sig}
big {params} =
    {summ}


step7 : (Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int) -> Int -> (Int -> Int)
step7 h b =
    h {step}


main =
    let
{BASE}        h =
            big {first}

        gs =
            List.map (step7 h) [ 100, 200 ]

{L_PAP27B}    in
    text "done"
"""
out["WideClosurePap27bTest"] = module("WideClosurePap27bTest",
    "E4: an arity-28 closure extended 20 + 7 + 1 through eco_pap_extend; the param\nkinds at slots 25/26 are truncated to boxed, so the typed consumer reads HPointers.",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureSat26Test (E5; green P2) -------------------------------------
n = 26
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * n + ["(Int -> Int)"])
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
args = " ".join(f"(base + {i})" for i in range(n))
exp = [x * 7 + sum((1 + i) * (i + 1) for i in range(n)) for x in (1, 2)]
body = f"""mk : {sig}
mk {params} =
    \\x -> x * 7 + {summ}


main =
    let
{BASE}        f =
            mk {args}

{logs([("res", "List.map f [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureSat26Test"] = module("WideClosureSat26Test",
    "E5: 26 typed newargs at once to an arity-27 function (eta-flattened mk).",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureBoxed27Test (E6; green P2) -----------------------------------
n = 27
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["String"] * n + ["(Int -> Int)"])
summ = " + ".join(f"String.length a{i}" for i in range(n))
args = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
exp = [x * 7 + sum(1 + i for i in range(n)) for x in (1, 2)]
body = f"""mk : {sig}
mk {params} =
    \\x -> x * 7 + {summ}


main =
    let
{BASE}        f =
            mk {args}

{logs([("res", "List.map f [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureBoxed27Test"] = module("WideClosureBoxed27Test",
    "E6: 27 boxed (String) newargs at once: rejected by the 25-newarg count cap.",
    [f"res: [{exp[0]}, {exp[1]}]"], body)

# ---- WideClosureCapture27Test (E7 + typed variant; green P2) -----------------
n = 27
sp = " ".join(f"a{i}" for i in range(n))
ssig = " -> ".join(["String"] * n + ["List Int", "List Int"])
ssum = " + ".join(f"String.length a{i}" for i in range(n))
sargs = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
isig = " -> ".join(["Int"] * n + ["List Int", "List Int"])
isum = " + ".join(f"a{i} * {i + 1}" for i in range(n))
iargs = " ".join(f"(base + {i})" for i in range(n))
es = [x * 1000 + sum(1 + i for i in range(n)) for x in (1, 2)]
ei = [x * 1000 + sum((1 + i) * (i + 1) for i in range(n)) for x in (1, 2)]
body = f"""mkS : {ssig}
mkS {sp} xs =
    List.map (\\x -> x * 1000 + {ssum}) xs


mkI : {isig}
mkI {sp} xs =
    List.map (\\x -> x * 1000 + {isum}) xs


main =
    let
{BASE}{logs([("strings", f"mkS {sargs} [ 1, 2 ]"), ("ints", f"mkI {iargs} [ 1, 2 ]")])}    in
    text "done"
"""
out["WideClosureCapture27Test"] = module("WideClosureCapture27Test",
    "E7: a lambda capturing 27 params (boxed and typed variants) passed to List.map:\npapCreate num_captured = 27.",
    [f"strings: [{es[0]}, {es[1]}]", f"ints: [{ei[0]}, {ei[1]}]"], body)

# ---- decoder-pattern records (E8 / E9) ----------------------------------------
def decoder(name, n, kinds, doc, show):
    decl = fields_decl(n, kinds)
    chain = "\n".join(f"        |> andMap (Just {elm_val(i, kinds[i], 'b')})" for i in range(n))
    pairs = [(f"f{i:04d}", f"Maybe.map .f{i:04d} r") for i in show]
    checks = [f"f{i:04d}: Just {py_show(i, kinds[i])}" for i in show]
    body = f"""type alias R =
    {{ {decl}
    }}


andMap : Maybe a -> Maybe (a -> b) -> Maybe b
andMap ma mf =
    case ( mf, ma ) of
        ( Just f, Just a ) ->
            Just (f a)

        _ ->
            Nothing


build : Int -> Maybe R
build b =
    Just R
{chain}


main =
    let
{BASE}        r =
            build base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

decoder("WideRecordDecoder26Test", 26, ["Int"] * 26,
        "E8: a 26-Int record alias built with the decoder (andMap) pattern; the\nconstructor closure has arity 26 and loses param kind 25.",
        [0, 24, 25])
k30 = ["Int"] * 25 + ["Float", "Char", "Int", "String", "Int"]
decoder("WideRecordDecoder30Test", 30, k30,
        "E8, mixed kinds at declaration positions >= 25 (30 fields).", [0, 24, 25, 26, 27, 28, 29])
k70 = [kind(i) for i in range(70)]
decoder("WideRecordDecoder70Test", 70, k70,
        "E9: a 70-field mixed record built with andMap: papCreate arity 70 (> 63) and\nfield_count 70 (> 32).", [0, 19, 20, 24, 25, 31, 32, 33, 62, 63, 64, 69])
k300 = [kind(i) for i in range(300)]
decoder("WideRecordDecoder300Test", 300, k300,
        "A 300-field mixed record built with andMap (closure arity 300, record > 2 KiB).",
        [0, 19, 20, 31, 32, 63, 64, 95, 96, 255, 256, 299])

# ---- staged closures of arity 63 / 300 / 2047 (green P2) ---------------------
def staged(name, n, kinds, steps, doc, timing_note=""):
    params = " ".join(f"a{i}" for i in range(n))
    sig = " -> ".join(kinds + ["Int"])
    def term(i):
        k = kinds[i]
        return {"Int": f"a{i} * {i + 1}", "Float": f"round (a{i} * 10)",
                "Char": f"Char.toCode a{i}", "String": f"String.length a{i}",
                "Bool": f"(if a{i} then {i} else 0)"}[k]
    summ = "\n    + ".join(term(i) for i in range(n))
    def pval(i):
        k = kinds[i]
        return {"Int": (1 + i) * (i + 1), "Float": round((i + 0.5) * 10),
                "Char": 96 + (i % 26) + 1, "String": i + 1,
                "Bool": i if (i % 2 == 0) else 0}[k]
    # slot values: Int base+i, Float base+i-0.5 (=i+0.5), Char code base+96+i%26, String len base+i, Bool even
    def arg(i):
        k = kinds[i]
        return {"Int": f"(b + {i})", "Float": f"(toFloat b + {i}.5 - 1)",
                "Char": f"(Char.fromCode (b + {96 + (i % 26)}))",
                "String": f"(String.repeat (b + {i}) \"a\")",
                "Bool": f"(modBy 2 (b + {i - 1}) == 0)"}[k]
    fns, pos = [], 0
    pipeline = "big"
    for si, cnt in enumerate(steps):
        a = " ".join(arg(j) for j in range(pos, pos + cnt))
        fns.append(f"step{si} h b =\n    h {a}\n")
        pos += cnt
    assert pos == n
    app = "List.map (\\b -> big) [ base ]"
    expr = "big"
    lets = ""
    cur = "fs0"
    lets += f"        fs0 =\n            [ big ]\n\n"
    for si in range(len(steps)):
        lets += f"        fs{si + 1} =\n            List.map (\\h -> step{si} h base) fs{si}\n\n"
    exp = sum(pval(i) for i in range(n))
    body = f"""big : {sig}
big {params} =
    {summ}


{chr(10).join(fns)}

main =
    let
{BASE}{lets}{logs([("res", f"fs{len(steps)}")])}    in
    text "done"
"""
    out[name] = module(name, doc + timing_note, [f"res: [{exp}]"], body)

def ckind(i, special):
    return special.get(i, "Int")

sp63 = {19: "Float", 20: "Char", 24: "Float", 25: "Char", 51: "Float", 52: "Char", 62: "Float", 33: "String", 40: "Bool"}
staged("WideClosureArity63Test", 63, [ckind(i, sp63) for i in range(63)], [1, 7, 20, 20, 15],
       "Arity-63 closure extended 1 + 7 + 20 + 20 + 15 through eco_pap_extend, with\nFloat/Char params on both sides of slots 20, 25 and 52.")
sp300 = {i: k for i, k in zip(range(300), [kind(i) for i in range(300)])}
staged("WideClosureArity300Test", 300, [kind(i) for i in range(300)], [1, 7, 20, 63, 64, 65, 80],
       "Arity-300 mixed closure extended in steps 1/7/20/63/64/65/80 (root chunks over 64).")
staged("WideClosureArity2047Test", 2047, [kind(i) for i in range(2047)], [1, 7, 20, 63, 64, 65, 300, 1527],
       "Arity-2047 mixed closure (the stage-arity limit), extended in steps up to 1527.")

# ---- saturated wide records / ctors (green P3D) ------------------------------
def wide_record(name, n, kinds, show, doc, full=False):
    decl = fields_decl(n, kinds)
    vals = "\n        , ".join(f"f{i:04d} = {elm_val(i, kinds[i])}" for i in range(n))
    pairs = [(f"f{i:04d}", f"r.f{i:04d}") for i in show]
    checks = [f"f{i:04d}: {py_show(i, kinds[i])}" for i in show]
    last = n - 1
    pairs += [("pattern", f"viaPat r"), ("update", f"(upd r).f{last:04d}"),
              ("eq self", "r == make base"), ("eq updated", "r == upd r")]
    lk = kinds[last]
    upd_val = {"Int": "r.f%04d + 1" % last, "Float": "r.f%04d + 1" % last,
               "Char": "'!'", "String": "\"u\"", "Bool": "not r.f%04d" % last}[lk]
    upd_show = {"Int": str(1000 + last + 1), "Float": f"{last + 1}.5", "Char": "'!'",
                "String": "\"u\"", "Bool": "False" if last % 2 == 0 else "True"}[lk]
    checks += [f"pattern: ({py_show(0, kinds[0])}, {py_show(last, lk)})", f"update: {upd_show}",
               "eq self: True", "eq updated: False"]
    if full:
        pairs.append(("show", "r"))
        # Eco's typed record printer prints fields in heap-layout order (Types.computeRecordLayout:
        # unboxed Int/Float/Char fields first, then boxed ones, each group by name), not Elm's
        # alphabetical order (existing behaviour, e.g. TypeAliasCtorTest's { count = 42, bold = True }).
        order = [i for i in range(n) if kinds[i] in ("Int", "Float", "Char")] + \
                [i for i in range(n) if kinds[i] not in ("Int", "Float", "Char")]
        checks.append("show: { " + ", ".join(f"f{i:04d} = {py_show(i, kinds[i])}" for i in order) + " }")
    body = f"""type alias R =
    {{ {decl}
    }}


make : Int -> R
make base =
    {{ {vals}
    }}


viaPat : R -> ( {kinds[0]}, {kinds[last]} )
viaPat {{ f0000, f{last:04d} }} =
    ( f0000, f{last:04d} )


upd : R -> R
upd r =
    {{ r | f{last:04d} = {upd_val} }}


main =
    let
{BASE}        r =
            make base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

wide_record("WideRecord33Test", 33, [kind(i) for i in range(33)], [0, 31, 32],
            "33-field mixed record: access, pattern, update, ==, Debug.toString.", full=True)
wide_record("WideRecord40Test", 40, [kind(i) for i in range(40)], [0, 31, 32, 39],
            "40-field mixed record (second ext word boundary not reached; header + 1 ext word).", full=True)
wide_record("WideRecord600Test", 600, [kind(i) for i in range(600)], [0, 31, 32, 63, 64, 599],
            "600-field mixed record: inline-alloc bound (4096 B) exceeded -> eco_alloc_record call path.")
wide_record("WideRecord1100Test", 1100, [kind(i) for i in range(1100)], [0, 31, 32, 1023, 1024, 1099],
            "1100-field mixed record: > 8 KiB large object (nursery-large / YLOS).")

def wide_ctor(name, n, kinds, show, doc):
    tys = " ".join(kinds[i] if kinds[i] in ("Int", "Float", "Char", "String", "Bool") else kinds[i] for i in range(n))
    vals = " ".join(elm_val(i, kinds[i]) for i in range(n))
    pat = " ".join(f"x{i}" for i in range(n))
    fns = ""
    pairs, checks = [], []
    for i in show:
        fns += f"get{i} : W -> {kinds[i]}\nget{i} w =\n    case w of\n        W {pat} ->\n            x{i}\n\n\n"
        pairs.append((f"field{i}", f"get{i} w"))
        checks.append(f"field{i}: {py_show(i, kinds[i])}")
    pairs += [("eq self", "w == make base"), ("eq other", "w == make (base + 1)")]
    checks += ["eq self: True", "eq other: False"]
    if n <= 60:
        pairs.append(("show", "w"))
        checks.append("show: W " + " ".join(py_show(i, kinds[i]) for i in range(n)))
    body = f"""type W
    = W {tys}


make : Int -> W
make base =
    W {vals}


{fns}main =
    let
{BASE}        w =
            make base

{logs(pairs)}    in
    text "done"
"""
    out[name] = module(name, doc, checks, body)

wide_ctor("WideCtorMixedTest", 60, [kind(i) for i in range(60)], [23, 24, 55, 59],
          "60-field mixed constructor: case match on fields 23/24/55/59, ==, Debug.toString.")
wide_ctor("WideCtor1100Test", 1100, [kind(i) for i in range(1100)], [0, 23, 24, 56, 1099],
          "1100-field mixed constructor: large object.")


# ---- WideClosureGroupTest (B15; green P1) -------------------------------------
n, per = 66, 22
ps = " ".join(f"s{i}" for i in range(n))
sig = " -> ".join(["String"] * n + ["Int", "Int"])
def lens(j): return " + ".join(f"String.length s{i}" for i in range(per * j, per * j + per))
args = " ".join(f"(String.repeat (base + {i}) \"a\")" for i in range(n))
L1 = sum(1 + i for i in range(per, 2 * per))
body = f"""run : {sig}
run {ps} k =
    let
        f0 n =
            if n <= 0 then
                {lens(0)}

            else
                f1 (n - 1) + 1

        f1 n =
            if n <= 0 then
                {lens(1)}

            else
                f2 (n - 1) + 10

        f2 n =
            if n <= 0 then
                {lens(2)}

            else
                f0 (n - 1) + 100
    in
    f0 k


main =
    let
{BASE}{logs([("group", f"run {args} 4")])}    in
    text "done"
"""
out["WideClosureGroupTest"] = module("WideClosureGroupTest",
    "B15: three mutually recursive let-bound closures (one papCreateGroup), each\ncapturing 22 boxed Strings: 66 flat captures, more than one 64-slot root range.",
    [f"group: {L1 + 112}"], body)

elm_dir = sys.argv[1]
os.makedirs(elm_dir, exist_ok=True)
for name, src in out.items():
    with open(os.path.join(elm_dir, name + ".elm"), "w") as f:
        f.write(src)
print("\n".join(sorted(out)))

# ---- GC-stress pins for test/eco-kernel/src (Eco.GC.minorGC / majorGC) ------
def gc_pin(name, doc, decls, build_expr, read_expr, expected, green):
    body = f"""import Eco.GC as GC
import Platform
import Task


{decls}

type Msg
    = Done Int Int Int


churn : Int -> Int
churn k =
    List.range 1 (20000 + k) |> List.map String.fromInt |> List.length


init : () -> ( (), Cmd Msg )
init _ =
    let
        base =
            1 + List.length [ () ] - 1

        objs =
            {build_expr}

        task =
            GC.minorGC
                |> Task.andThen (\\mi -> GC.majorGC |> Task.map (\\ma -> ( mi.collected, ma.collected )))
                |> Task.map (\\( mi, ma ) -> Done mi ma (churn mi + {read_expr}))
    in
    ( (), Task.perform identity task )


update : Msg -> () -> ( (), Cmd Msg )
update msg _ =
    case msg of
        Done mi ma v ->
            let
                _ =
                    Debug.log "{name} minor" mi

                _ =
                    Debug.log "{name} major" ma

                _ =
                    Debug.log "{name} value" v
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker {{ init = init, update = update, subscriptions = \\_ -> Sub.none }}
"""
    s = f"module {name} exposing (main)\n\n{{-| {doc} Green at {green}.\n-}}\n\n"
    s += f"-- CHECK: {name} minor: 1\n-- CHECK: {name} major: 1\n-- CHECK: {name} value: {expected}\n\n" + body
    gc_out[name] = s

gc_out = {}
# 200 arity-28 closures, each extended 20 then 7 (live across both GCs), then saturated.
n = 28
params = " ".join(f"a{i}" for i in range(n))
sig = " -> ".join(["Int"] * (n + 1))
summ = " + ".join(f"a{i} * {i + 1}" for i in range(n))
first = " ".join(f"(k + {i})" for i in range(20))
step = " ".join(f"(k + {i})" for i in range(20, 27))
decls = f"""big : {sig}
big {params} =
    {summ}


mk : Int -> (Int -> Int)
mk k =
    let
        h =
            big {first}
    in
    h {step}
"""
def bigval(k, last): return sum((k + i) * (i + 1) for i in range(27)) + last * 28
exp = sum(bigval(k, 5) for k in range(1, 201)) + 20001
gc_pin("WideClosureGcTest", "200 arity-28 closures (typed kinds at slots 20..27) live across a minor and a\nmajor GC, then saturated.", decls,
       "List.map mk (List.range base 200)", "List.sum (List.map (\\g -> g 5) objs)", exp, "P2")

# 200 40-field mixed records + 200 60-field mixed ctors across GCs (green P3D).
kr = [kind(i) for i in range(40)]
kc = [kind(i) for i in range(60)]
def num(i, k, var):    # an Int contribution of field i read from var
    return {"Int": f"{var}", "Float": f"round ({var} * 2)", "Char": f"Char.toCode {var}",
            "String": f"String.length {var}", "Bool": f"(if {var} then 1 else 0)"}[k]
def pnum(i, k, b):
    return {"Int": b + 999 + i, "Float": round((b - 1 + i + 0.5) * 2), "Char": b + 96 + (i % 26),
            "String": len(f"{b - 1 + i}s"), "Bool": 1 if (b + i - 1) % 2 == 0 else 0}[k]
rdecl = fields_decl(40, kr)
rvals = "\n        , ".join(f"f{i:04d} = {elm_val(i, kr[i])}" for i in range(40))
rsum = "\n        + ".join(num(i, kr[i], f"r.f{i:04d}") for i in (0, 31, 32, 33, 38, 39))
ctys = " ".join(kc)
cvals = " ".join(elm_val(i, kc[i]) for i in range(60))
cpat = " ".join(f"x{i}" for i in range(60))
csum = "\n                + ".join(num(i, kc[i], f"x{i}") for i in (0, 23, 24, 25, 56, 59))
decls = f"""type alias R =
    {{ {rdecl}
    }}


type W
    = W {ctys}


mkR : Int -> R
mkR base =
    {{ {rvals}
    }}


mkW : Int -> W
mkW base =
    W {cvals}


readR : R -> Int
readR r =
    {rsum}


readW : W -> Int
readW w =
    case w of
        W {cpat} ->
            {csum}
"""
exp = sum(sum(pnum(i, kr[i], b) for i in (0, 31, 32, 33, 38, 39)) +
          sum(pnum(i, kc[i], b) for i in (0, 23, 24, 25, 56, 59)) for b in range(1, 201)) + 20001
gc_pin("WideHeapGcTest", "200 40-field records and 200 60-field constructors (mixed kinds) live across a\nminor and a major GC.", decls,
       "List.map (\\b -> ( mkR b, mkW b )) (List.range base 200)",
       "List.sum (List.map (\\( r, w ) -> readR r + readW w) objs)", exp, "P3D")

kdir = sys.argv[2] if len(sys.argv) > 2 else None
if kdir:
    os.makedirs(kdir, exist_ok=True)
    for name, src in gc_out.items():
        with open(os.path.join(kdir, name + ".elm"), "w") as f:
            f.write(src)
    print("\n".join(sorted(gc_out)))
```

## Appendix P0-B: census script (`plans/wide-object-tail-kind-words-census.py`)

```python
#!/usr/bin/env python3
"""Wide-object census over TEXT MLIR (ecoc --emit=mlir FILE > out.txt 2>&1).

Reports (plans/wide-object-tail-kind-words-phase-0.md, step 0.4):
  papCreate  : arity histogram buckets <=20, 21..25, 26..63, >63; num_captured > 25
  papExtend  : newarg count > 25
  construct.custom : size > 24
  construct.record : field_count > 26 with an eco.box-defined operand at index >= 26
                     (a primitive boxed by the 26-slot record cap)
"""
import re, sys, collections
text = open(sys.argv[1]).read()
c = collections.Counter()
for m in re.finditer(r'"eco\.papCreate"\(([^)]*)\)[^{<]*[{<]+([^}>]*)', text):
    attrs = m.group(2)
    a = re.search(r'\barity = (\d+)', attrs); n = re.search(r'num_captured = (\d+)', attrs)
    if not a: continue
    ar = int(a.group(1)); nc = int(n.group(1)) if n else 0
    c['papCreate total'] += 1
    c['papCreate arity <=20' if ar <= 20 else 'papCreate arity 21..25' if ar <= 25 else
      'papCreate arity 26..63' if ar <= 63 else 'papCreate arity >63'] += 1
    if nc > 25: c['papCreate num_captured >25'] += 1
    if ar > 25:
        f = re.search(r'function = (@[\w$#.]+)', attrs)
        print(f"  wide papCreate: arity={ar} num_captured={nc} {f.group(1) if f else '?'}")
for m in re.finditer(r'"eco\.papExtend"\(([^)]*)\)', text):
    ops = [o for o in m.group(1).split(',') if o.strip()]
    c['papExtend total'] += 1
    if len(ops) - 1 > 25: c['papExtend operands >25 (incl. gc roots)'] += 1
for m in re.finditer(r'"?eco\.construct\.custom"?\(([^)]*)\)[^{]*\{([^}]*)\}', text):
    s = re.search(r'\bsize = (\d+)', m.group(2))
    if s and int(s.group(1)) > 24: c['construct.custom size >24'] += 1
for fn in re.split(r'\n\s*func\.func ', text):          # SSA names are per function
    box_defs = set(re.findall(r'(%[\w#]+) = "?eco\.box"?', fn))
    for m in re.finditer(r'"?eco\.construct\.record"?\(([^)]*)\)[^{]*\{([^}]*)\}', fn):
        fc = re.search(r'field_count = (\d+)', m.group(2))
        if not fc: continue
        n = int(fc.group(1)); ops = [o.strip() for o in m.group(1).split(',')]
        if n > 26:
            c['construct.record field_count >26'] += 1
            if any(o in box_defs for o in ops[26:n]): c['construct.record boxed primitive at >=26'] += 1
for k in sorted(c): print(f"{k}: {c[k]}")
```

## Appendix P0-C: codegen fixtures

### `test/codegen/make_closure_packed_word.mlir`

```mlir
// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// B13 (plans/wide-object-tail-kind-words-phase-0.md): eco.make.closure must pack the
// closure word exactly like papCreate: n_values | max_values<<6 | result_kind<<12 |
// kinds<<14 (Phase 1 layout). Captures (i64, !eco.value), arity 3, legacy (untyped)
// evaluator, so the kinds are the capture kinds: slot 0 = Int (1), slot 1 = boxed.
// Expected word: 2 | 3<<6 | 0<<12 | 1<<14 = 16578.

module {
  llvm.func @stub_evaluator(%args: !llvm.ptr) -> !llvm.ptr {
    %r = llvm.mlir.zero : !llvm.ptr
    llvm.return %r : !llvm.ptr
  }

  func.func @make_closure_packed(%cap0: i64, %cap1: !eco.value) -> !eco.value {
    %env = eco.make.closure_env(%cap0, %cap1)
         : (i64, !eco.value) -> !eco.closure_env<i64, !eco.value>
    %clo = eco.make.closure @stub_evaluator, %env {arity = 3 : i64}
         : (!eco.closure_env<i64, !eco.value>) -> !eco.value
    return %clo : !eco.value
  }
}

// CHECK-LABEL: llvm.func @make_closure_packed
// CHECK: llvm.mlir.constant(16578 : i64)
```

### `test/codegen/construct_custom_i1_operand_rejected.mlir`

```mlir
// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// B14 (plans/wide-object-tail-kind-words-phase-0.md): construct ops must reject i1
// operands. Today an i1 is stored as zext 0/1 into a kind-0 (boxed) slot, which the GC
// would trace as a pointer; the front end always boxes Bool first.

module {
  func.func @bad_construct_i1(%b: i1, %x: !eco.value) -> !eco.value {
    %c = "eco.construct.custom"(%b, %x) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (i1, !eco.value) -> !eco.value
    return %c : !eco.value
  }
}

// CHECK: has i1 type
```

### `test/codegen/construct_record_i1_operand_rejected.mlir`

```mlir
// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// B14: eco.construct.record must reject i1 operands (see construct_i1_operand_rejected.mlir).

module {
  func.func @bad_record_i1(%b: i1, %x: !eco.value) -> !eco.value {
    %r = "eco.construct.record"(%b, %x) {field_count = 2 : i64, unboxed_bitmap = 0 : i64} : (i1, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: has i1 type
```

### `test/codegen/pap_simplify_fusion_slot_cap.mlir`

Header and CHECK lines below; the 32-parameter `@sum32` body and the `%c0..%c31` constants are mechanical. The full file is reproduced exactly by this snippet, so commit its output:

```mlir
// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// B16 (plans/wide-object-tail-kind-words-phase-0.md): EcoPAPSimplify's chain fusion
// (P2) must not build a papExtend with more newargs than the verifier allows. Two
// typed extends of 15 Int args each (arity 32, 1 capture, result escapes) would fuse
// into one 30-newarg extend whose 60-bit bitmap exceeds the 50-bit / 25-slot cap.
// Phase 1: fusion declines (both extends survive). Phase 2: the cap becomes 2047 and
// this fixture's CHECKs are rewritten to expect ONE fused 30-newarg extend.

  ... (generated: func @sum32 with 32 i64 params summed; func @partial: 32 constants,
       papCreate(@sum32, arity 32, 1 i64 capture), papExtend 15 i64 (remaining 31), papExtend 15 i64 (remaining 16), return) ...
}

// CHECK-LABEL: func.func @partial
// CHECK: eco.papExtend
// CHECK: eco.papExtend
// CHECK-NOT: error
```

Generator for the full fixture (writes `test/codegen/pap_simplify_fusion_slot_cap.mlir`):

```python
n = 32
params = ", ".join(f"%a{i}: i64" for i in range(n))
body = "    %s0 = eco.int.add %a0, %a1 : i64\n" + "".join(
    f"    %s{i-1} = eco.int.add %s{i-2}, %a{i} : i64\n" for i in range(2, n))
def ext(name, src, start, cnt, rem):
    ops = ", ".join(f"%c{i}" for i in range(start, start + cnt))
    tys = ", ".join(["i64"] * cnt)
    bm = sum(1 << (2 * i) for i in range(cnt))
    return (f'    {name} = "eco.papExtend"({src}, {ops}) {{\n'
            f'      remaining_arity = {rem} : i64,\n      newargs_unboxed_bitmap = {bm} : i64\n'
            f'    }} : (!eco.value, {tys}) -> !eco.value\n')
consts = "".join(f"    %c{i} = arith.constant {i} : i64\n" for i in range(32))
hdr = "// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s\n//\n// B16 (plans/wide-object-tail-kind-words-phase-0.md): EcoPAPSimplify's chain fusion\n// (P2) must not build a papExtend with more newargs than the verifier allows. Two\n// typed extends of 15 Int args each (arity 32, 1 capture, result escapes) would fuse\n// into one 30-newarg extend whose 60-bit bitmap exceeds the 50-bit / 25-slot cap.\n// Phase 1: fusion declines (both extends survive). Phase 2: the cap becomes 2047 and\n// this fixture's CHECKs are rewritten to expect ONE fused 30-newarg extend.\n\n"
src = (hdr + "module {\n  func.func @sum32(" + params + ") -> i64 {\n" + body +
       f"    eco.return %s{n-2} : i64\n  }}\n\n  func.func @partial() -> !eco.value {{\n" + consts +
       '    %pap = "eco.papCreate"(%c0) {\n      function = @sum32,\n      arity = 32 : i64,\n'
       '      num_captured = 1 : i64,\n      unboxed_bitmap = 1 : i64\n    } : (i64) -> !eco.value\n' +
       ext("%p1", "%pap", 1, 15, 31) + ext("%p2", "%p1", 16, 15, 16) +
       "    return %p2 : !eco.value\n  }\n}\n\n// CHECK-LABEL: func.func @partial\n"
       "// CHECK: eco.papExtend\n// CHECK: eco.papExtend\n// CHECK-NOT: error\n")
open("test/codegen/pap_simplify_fusion_slot_cap.mlir", "w").write(src)
```

The "today" result (`error: 'eco.papExtend' op newargs_unboxed_bitmap exceeds 50-bit capacity`
at the second extend's location) was observed with `build/runtime/src/codegen/ecoc <file>
-emit=mlir-eco`. Both input extends are individually valid (15 newargs, 30-bit bitmaps), so the
error comes from the fused op.
