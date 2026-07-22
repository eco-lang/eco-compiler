# Performance-Tuning Apply / Benchmark / Validate Loop

Apply the candidate performance wins in `@perf-investigation-report.md` one at a time,
**benchmark each against the cold Stage-7a self-compile**, keep only the measured wins,
and validate every kept win with the E2E suite. Repeat until every item in the report
is either **WIN** (kept) or **NO-WIN / SKIPPED** (reverted).

The improvements are edits to the compiler's own Elm source, so a benchmarked binary
must be **rebuilt to embed the change**. We do this the fast Stage-7 way (the current
native compiler lowers the changed source), not the full JS bootstrap.

## The benchmark: cold Stage 7a

**Stage 7a** = the native solver-built `eco-compiler` binary compiling the whole compiler
source (`Terminal/Main.elm` + deps) to MLIR, with the `eco-stuff/` typed-artifact cache
wiped first so the *entire* program recompiles every run (not just the one changed module).
`~/.eco` (the global package/registry cache) stays warm.

Canonical command (from `compiler/CMakeLists.txt`, the `eco-compiler-boot.mlir` target):

```bash
cd /work/build/compiler/build-kernel
/usr/bin/time -v -o /work/bench/timing.txt \
  <BINARY> make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=/work/bench/out.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Primary metric = **Elapsed (wall clock)** from `/usr/bin/time -v`; secondary = **Maximum
resident set size** (these are GC/allocation-churn wins, so watch RSS too). The self-compile
runs several minutes; do NOT bound it with `timeout` (that would truncate the workload).

**Deterministic corroborators (use these to resolve sub-noise wall changes):** the lowered
`eco-compiler` binaries emit an exit-time `=== GC Statistics ===` banner (captured if you
redirect stdout to a log). Grep it for `Bytes allocated:` (total mutator alloc — often
INSENSITIVE, dominated by transient nursery churn), the Old-Gen Allocation histogram `total`
(retained alloc — the real signal for retained-memory wins), and `Minor/Major GC cycles:`
(deterministic counts). For retained-memory/record-copy wins, **old-gen alloc + RSS +
major-GC count move together and are deterministic run-to-run**, while total-bytes-allocated
barely moves — decide on wall, corroborated by these.

## Setup (run once, before the loop)

```bash
# 0. Node heap for any JS-hosted rebuild (E2E gate uses it).
export NODE_OPTIONS="--max-old-space-size=12000"

# 1. Scratch/harness dir OUTSIDE the build tree (survives `ninja clean`, which the
#    E2E `--target full` gate performs and which would otherwise delete our binaries).
mkdir -p /work/bench

# 2. Ensure a fresh, canonical baseline native compiler exists (full bootstrap to Stage 6/7).
cmake --build build --target eco-compiler-boot 2>&1 | tee /work/bench/setup-build.log

# 3. Copy the harness binaries into scratch so the loop never depends on build-tree state.
cp build/compiler/build-kernel/bin/eco-compiler        /work/bench/eco-current     # current-best (baseline)
cp build/runtime/src/codegen/eco-boot-native           /work/bench/eco-boot-native # MLIR -> ELF lowerer

# 4. Determine the safe cold-wipe (see "Cold wipe" gotcha) and record it in the log.

# 5. Establish the BASELINE: 3 cold Stage-7a runs of /work/bench/eco-current, record the
#    MINIMUM wall as baseline_wall, and the run-to-run spread as the noise floor.
```

Record `baseline_wall`, `baseline_rss`, and the noise floor in `@perf-tune-status.md`
(the loop's status/log file — one row per report item: PENDING / WIN / NO-WIN / BROKE-TESTS
/ SKIPPED, with measured deltas and notes).

### Cold wipe

Force a full recompile before every timed run. Prefer the proven-safe wipe that mirrors
what CMake's Stage 5 does (delete typed artifacts, keep the dependency solve so no re-solve
is triggered):

```bash
find /work/build/compiler/build-kernel/eco-stuff -name '*.ecot' -delete
find /work/build/compiler/build-kernel/eco-stuff -name '*.eci'  -delete
```

At setup, verify this yields a full cold compile (~minutes, not seconds). Only if you must
also invalidate the dependency solve, use `rm -rf .../eco-stuff` — but this can hit the
`INCOMPATIBLE DEPENDENCIES` re-solve trap (the `--local-package` flag usually avoids it);
if `rm -rf` fails, fall back to the `*.ecot`/`*.eci` delete above. Use the SAME wipe for
baseline and every candidate so measurements are comparable.

## Building a candidate binary (Stage-7 fast path — no JS bootstrap)

After editing the compiler source for one improvement:

```bash
cd /work/build/compiler/build-kernel

# (a) current-best compiles the CHANGED source to MLIR (this proves the edit compiles).
find eco-stuff -name '*.ecot' -delete; find eco-stuff -name '*.eci' -delete
/work/bench/eco-current make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=/work/bench/cand.mlir /work/compiler/src/Terminal/Main.elm   # rc must be 0

# (b) lower the changed MLIR to a native binary that EMBEDS the change.
/work/bench/eco-boot-native /work/bench/cand.mlir -o /work/bench/eco-cand
```

`/work/bench/eco-cand` is the compiler WITH the change. The current-best binary is correct,
so it compiles the changed source faithfully; lowering yields the same binary the full
bootstrap would (fixed-point property). If step (a) fails to compile, the edit is broken —
fix or revert.

### Fast correctness screen (self-consistency)

Because every change here must be **output-preserving**, screen for miscompiles cheaply
before spending an E2E run: have the candidate reproduce itself and diff the MLIR.

```bash
find eco-stuff -name '*.ecot' -delete; find eco-stuff -name '*.eci' -delete
/work/bench/eco-cand make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=/work/bench/cand2.mlir /work/compiler/src/Terminal/Main.elm
cmp /work/bench/cand.mlir /work/bench/cand2.mlir   # native fixed point: must be identical
```

`cand.mlir` (current-best on changed source) and `cand2.mlir` (candidate on changed source)
must be byte-identical — that is the Stage-8 fixed-point invariant and a strong signal the
change is self-consistent and output-preserving. A mismatch or a crash ⇒ treat as broken
(revert), regardless of speed. Note: the self-compiled MLIR is *not* expected to equal the
pre-change baseline MLIR (we changed the compiler's own source, so its own emitted code
changes); only the fixed-point / E2E-corpus byte-identity gates apply.

## Win criterion

Run the candidate's cold Stage-7a **3 times**, take the **minimum** wall (least
interference). It is a **win** iff:

```
cand_min_wall  ≤  baseline_min_wall × (1 − 0.010)      # ≥ 1.0% faster
AND the improvement exceeds the setup noise floor.
```

Borderline (0.5–1.5%, or within noise): re-measure with more runs before deciding; if still
ambiguous, treat as NO-WIN (do not keep a change we cannot show helps). Record RSS too — a
wall-neutral change that meaningfully cuts RSS may still be worth keeping (note it, but the
default bar is wall).

## LOOP

Drive the worklist in the report's **§5 suggested sequencing** order (asymptotic first,
then dead-code, then the S-copy batch, then data-structure swaps). Track state in
`@perf-tune-status.md`.

### 1. Check /usage
If over 90%, run `sleep <seconds until reset + 60>`, then continue — do NOT stop or report.

### 2. Pick the next item
Next report item not marked WIN / NO-WIN / SKIPPED. If none remain, go to DONE.

### 3. Apply the improvement
Read the cited code and the report's detail. Make the minimal, output-preserving edit.
Respect `@design_docs/invariants.csv`. Keep the diff focused to one item.

### 4. Benchmark
- Build the candidate binary (fast path, step a+b above). If it fails to compile → this
  attempt is broken; go to step 7 (NO with a "did not compile" note).
- Run the fast correctness screen (self fixed point). Mismatch/crash → broken; step 7.
- Run 3 cold Stage-7a timings of `/work/bench/eco-cand`; take the min.
- Apply the win criterion vs `baseline_min_wall`.

### 5. Win?
- **NO** → Revert the edit (`git checkout -- <files>`), delete `/work/bench/eco-cand*`.
  Record the measured delta and "NO-WIN" in `@perf-tune-status.md`.
  Tried < 3 distinct approaches for this item AND you have a plausible alternative
  (the report often suggests one) → go back to step 3 with the new approach.
  Otherwise mark NO-WIN (or SKIPPED with reason) and go to LOOP.
- **YES** → go to step 6.

### 6. Validate (E2E)
Run the E2E suite ONCE, capturing output (per `@CLAUDE.md`'s test discipline):

```bash
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```

Inspect `/tmp/test_output.txt` with grep/head/tail — do NOT re-run. (`--target full`
performs a clean rebuild from the changed source through Stage 1 + runs the JIT E2E suite;
the `/work/bench` harness binaries survive its `ninja clean`.) For a stronger gate on
mono/codegen changes, also run `cmake --build build --target run-aot-e2e` once.

- **PASS** → Keep the win. Promote the candidate to the new baseline:
  `cp /work/bench/eco-cand /work/bench/eco-current`; set `baseline_min_wall = cand_min_wall`;
  optionally `git commit` the edit (branch + Co-Authored-By trailer). Mark **WIN** with the
  delta in `@perf-tune-status.md`. Go to LOOP.
- **FAIL** → The change breaks correctness despite being faster. Revert
  (`git checkout -- <files>`), keep the old baseline. Record the failure; mark **BROKE-TESTS**
  (retry with a safer approach if one is obvious and attempts < 3, else SKIPPED). Go to LOOP.

## DONE

Produce a report: for each report item — WIN (with %Δ wall and ΔRSS), NO-WIN (with the
measured non-improvement), BROKE-TESTS, or SKIPPED (with reason). Give the **cumulative**
Stage-7a wall improvement (final baseline vs the setup baseline) and confirm the final
compiler still passes the E2E suite and reaches its native self-compile fixed point.
Do NOT go to DONE while any report item is still PENDING.

## Gotchas

- **`ninja clean` (via `--target full`) deletes build-tree binaries** — that is why the
  harness (`eco-current`, `eco-boot-native`) lives in `/work/bench`. build-kernel's
  `elm.json` / `src` symlink / `node_modules` are configure inputs and survive clean;
  `eco-stuff` is recreated on the next compile.
- **Node 12 GB**: `export NODE_OPTIONS="--max-old-space-size=12000"` for any JS-hosted
  rebuild (the E2E gate). The native benchmark path does not need it.
- **Cold-wipe re-solve trap**: prefer the `*.ecot`/`*.eci` delete; `rm -rf eco-stuff` can
  trip `INCOMPATIBLE DEPENDENCIES` (mitigated by `--local-package`).
- **Output-preserving means byte-identical for other programs**: the self-compiled MLIR
  changes (we edited the compiler's own source), but the E2E corpus MLIR and behavior must
  not. The self fixed-point diff + E2E are the real correctness gates.
- **Measurement noise**: use min-of-N, keep the machine otherwise idle, use the identical
  cold wipe for baseline and candidate, and re-measure borderline results.
- **Run tests once**: `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`,
  then grep the file — never re-run to "see more."
- **Already-done / rejected items** (report §6): skip `Step` de-monadification, the
  MVarId-keyed-Dict→Array, `LambdaSet1`→BitSet, and `charAt`-as-asymptotic — do not spend
  loop iterations re-litigating them.
- **Attribute wins honestly**: a change that is within noise is NO-WIN, not a "small win."
```
