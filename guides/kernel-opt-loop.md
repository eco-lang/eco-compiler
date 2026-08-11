# Kernel-Opt Implement / Gate / Benchmark Loop

Work the fourteen `plans/kernel-opt-NN-*.md` items **one at a time**. For each item:

1. **Implement** the optimization exactly as its plan specifies (phases, flags, gates included).
2. **Prove it breaks nothing** — the plan's gate list, run once each, teed and grepped.
3. **Benchmark it** into `@benchmarks/kernel-opt.md` following the recording instructions and
   methodology in that file (it is the authority; this guide only adds the loop mechanics).

Then decide the item's disposition and move on. Every plan is already
IMPLEMENTATION-READY with a `## Approach` phase list, a `## Flag & rollback` section, a
`## Gates` list and an `## Expected impact` statement — **this loop does not re-plan; it
executes.** When the tree contradicts a plan, the tree wins: correct the plan file in place
and say so in the status entry.

---

## What "accept" means here — read this before the first item

**This is not a win-hunt.** A measured wall improvement is welcome but is *not* the bar.
Most of these items predict FLAT wall in their own `## Expected impact` (07, 08, 09, 11, 12
say so in bold; 05, 06 too). A flat result on those is a **pass**, not a failure.

The bar is: **keep it unless it makes things badly worse.**

- The measured run-to-run spread of an unchanged binary on this workload is **≈6 s on ≈213 s
  (≈2.8%)**. Anything inside that band is **FLAT** — write "no regression detected", never
  "a −1% gain" and never "a +1% regression".
- **Reject only a reproduced wall regression of ≥3%** (see "The decision rule" below).
- The GC counters are **exact at n=1** and carry more information than the wall. An
  *unexplained* counter move is a stop-and-explain even when the wall is flat.
- Do not add benchmark rounds chasing a sub-3% number. Establishing a genuine small gain is a
  separately budgeted exercise, not part of this loop.

### Dispositions

| disposition | meaning |
|---|---|
| **KEPT-ON** | Gates green, no regression → flag default flipped to on, env escape retained. |
| **LANDED** | Item has no default to flip (07's inert table; census-only phases). Gates green. |
| **KEPT-DARK** | Code + tests + flag land, default stays **off**. Used for a reproduced ≥3% regression, or when the plan's own census/go-no-go gate says NO-GO. |
| **PARTIAL** | Multi-phase plan where some phases are KEPT-ON and others are KEPT-DARK / not executed (expected for 02, 09, 13, 14). Record per phase. |
| **REVERTED** | Broke a correctness gate and cannot be hidden behind a default-off flag. |
| **BLOCKED** | Three consecutive gate failures with no root cause, or an unmet external precondition. Stop, write down what is known, move to the next item. |

---

## Worklist and order

Numeric order is **not** executable — 03/08/09/11/12/13 are blocked on 07, and 09 on 08.
This order satisfies every `## Dependencies` section, matches the design doc's own sequencing
(`design_docs/kernel-boundary-reduction.md:1610` — table first, then its first backend
consumer), and puts each item's Phase-0 census after the siblings that would perturb it.

| # | item | why here | flag(s) | change surface |
|---|---|---|---|---|
| 1 | **07** kernel-facts-table | spine: unblocks 03/08/11/12/13; landing it before 05/14 saves a `KernelSigs`→`KernelFacts` row migration | none (inert table) | Elm (+**new .elm ⇒ reconfigure**), one C++ deletion |
| 2 | **01** list-cons → construct.list | independent; highest-confidence wall bet; must precede 14 (chunk-counter parity) and 10 (census population) | `ECO_LIST_CONS_INTRINSIC` | Elm front-end |
| 3 | **02** array-push churn | independent; census-first, then a compiler-source rewrite with a byte-identity gate | `ECO_ARRAY_PUSH_CENSUS` (P0 only) | C++ census, then Elm compiler source |
| 4 | **04** string.length / code_unit_at | independent; hard blocker for 14 Phase 6 | `ECO_STRING_LENGTH_OP`, `ECO_STRING_LEN_INLINE` | Elm + backend + kernel C++ |
| 5 | **05** Utils_append type split | independent; 07 already shipped ⇒ borrow axes go straight into `KernelFacts`; enables 14's `String_cons` rider | `ECO_APPEND_SPLIT`, `ECO_APPEND_CENSUS` | Elm + backend + kernel C++ |
| 6 | **06** string ordering cmp3 | must precede 03 (03's Phase 5 is gated on 06's residue numbers) and lands first in the shared `Intrinsics.elm` region | `ECO_STRING_ORDER_INTRINSIC` | Elm front-end only |
| 7 | **03** value.eq fast path | needs 07 Phase 5 (the fprintf deletion) and 06's residue numbers; merges on top of 06 in `Intrinsics.elm`/`Config.elm` | `ECO_VALUE_EQ`, `_STRCASE`, `_INLINE`, `_GCLEAF` | Elm + backend + kernel C++ |
| 8 | **08** kernel gc-leaf stamp | needs 07's facts rows; carries `KERNEL_FACTS_001` | `ECO_KERNEL_GCLEAF_EMIT`, `ECO_KERNEL_GCLEAF` | Elm + backend + new C++ test |
| 9 | **09** GCPrepare barrier relaxation | consumes 08's `eco.gc_leaf`; census (Phase 1) before any transform | `ECO_GCPREPARE_{CENSUS,MERGE,GROUP_INLINE,LEAF_SAFEPOINT}` | backend only |
| 10 | **11** mono DCE + cost model | needs 07; authors `debug-log-ordering-policy.md` that 13 waits on (13's census ride-along has a stated fallback) | `ECO_KERNEL_FACTS_DCE`, `ECO_KERNEL_COST_*` | Elm front-end |
| 11 | **13** mono CSE | needs 07 + 11's policy doc; census-gated at every step | `ECO_CSE*` | Elm (+**new .elm ⇒ reconfigure**) |
| 12 | **10** MLIR CSE + folders | its Phase-0 census must reflect 13's residual; lands second vs 09 ⇒ keeps the order fold → CSE → mark → GCPrepare | `ECO_MLIR_CSE`, `ECO_MLIR_FOLD` | backend only |
| 13 | **12** eco.call purity attr | needs 07; lands second vs 09 ⇒ owes the `eco.cse_safe` strip move above the `isCallSafepoint` guard; 10 is already in so fixture F5 ships with it | `ECO_CALL_PURITY` | Elm + backend |
| 14 | **14** Elm-source List HOFs | Phase 6 needs 04 + 05; parity baseline needs 01; row deletions need 07 | `ECO_LIST_SHUNT_REVERSE`, CMake `ECO_CORE_OVERLAY` | Elm + elm/core overlay + kernel deletions |

Track state in `@kernel-opt-status.md` — one row per item, one sub-row per benchmarked phase.

---

## Environment facts that change how you work

- **There is no git in this container.** `/work` is a worktree whose parent `.git` lives at an
  unmounted path; every `git` command fails. Consequences:
  - **Snapshot before editing**: `cp -a` each file you are about to touch into
    `$SCRATCH/snap-<NN>/`. Revert = copy back. There is no `git checkout --`.
  - There is no `git stash`, no branch, no commit. Do not write "commit the change" into the
    status file; write "landed in the working tree".
  - Gates that call for a pristine checkout (kernel-opt-02's **G2** semantic byte-identity)
    must use a scratch copy of `compiler/src` taken **before** the edit, not `git worktree add`.
- **Every `file:line` anchor in the plans drifts as items land.** Re-verify each anchor by
  reading the file before you edit it. Do not trust a line number that a sibling item has
  already moved.
- **`Compiler/Eco/Config.elm`'s decoder is positional.** Items 01/03/04/05/06/08/11/12/13 all
  append a LAST alias field. The second and later landers must re-check lockstep across the
  four sites — record alias, `default`, `decoder` (`D.apply` order), `hash` token — or the
  config silently decodes into the wrong field.
- **A new `.elm` file under `compiler/src` needs `cmake --preset build`** before
  `cmake --build build` (`ELM_SOURCES` is a configure-time `GLOB_RECURSE`,
  `compiler/CMakeLists.txt:126`). Applies to **07** and **13** only.

---

## Setup (run once, before the first item)

```bash
export NODE_OPTIONS="--max-old-space-size=12000"
export BK=/work/build/compiler/build-kernel
export SCRATCH=/tmp/claude-1000/-work/<session>/scratchpad/kernel-opt   # per the session scratchpad
mkdir -p "$SCRATCH"

# 1. Loop-entry baseline binary, built with the standard track env (benchmarks/kernel-opt.md §Methodology).
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"        # ninja is env-blind; force Stage 5
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-kopt-base"
cp -p "$BK/bin/eco-compiler.mlir" "$SCRATCH/base-eco-compiler.mlir"   # flag-off byte-identity reference

# 2. Two cold Stage-7a rounds of eco-kopt-base -> record as "Run D - loop entry baseline"
#    in benchmarks/kernel-opt.md (wall, RSS, objects/bytes allocated, minor, promoted,
#    major, GC time, out.mlir size).

# 3. Record the CURRENT green counts for the two gates you re-run every item:
#    - `cmake --build build --target full`        -> N/N   (measured 2026-08-10: 1632/1632)
#    - `cmake --build build --target elm-tests`   -> passed/failed. MEASURE it: the suite is
#      NOT green on the pristine tree (2026-08-10: 13066 passed / 12 failed, all TYPE_007
#      constraint-generation suites + one golden fingerprint). "Green" means *still exactly
#      those failures*, so the count is the gate, not the word PASSED.
```

Write `baseline_wall`, `baseline_counters` and the two gate counts into
`@kernel-opt-status.md`. After every **KEPT-ON** item, `eco-kopt-base` and these numbers are
re-pointed at the new state — the baseline is cumulative.

### Measured gate costs (2026-08-10, 24 cores, ccache at 81% hits)

| step | cost |
|---|---|
| `cmake --preset build` reconfigure | ~10 s |
| `--target elm-tests` | **~13 min** (776–786 s) — the most expensive routine gate |
| `--target full` (clean + rebuild ALL + 1632 JIT E2E) | **~4 min** |
| `--target eco-compiler` (Stage 5 self-compile 7.7 min + Stage 6 lowering ~4 min) | **~12 min/arm** |
| re-link only, Shape B (backend-only items) | **~4 min/arm** |
| one cold Stage-7a leg | **~3.5 min** (a 2×2 A/B is ~14 min) |

Budget ≈ **55 min per item**. `ninja clean` is cheap here because ccache serves the C++;
do not assume `--target full` is expensive.

---

## Building the arms — three shapes, pick by change surface

The build recipe depends on **what** changed, and getting it wrong silently measures the old
code.

**Shape A — Elm compiler source changed** (`compiler/src/**.elm`). Stage 5 must re-run:

```bash
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"        # ninja env-blindness
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    <TRACK_FLAG>=1 cmake --build build --target eco-compiler
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-kopt<NN>-on"
```

**Shape B — backend / runtime / kernel C++ changed** (`runtime/src/**`, `elm-kernel-cpp/**`).
`--target eco-compiler` will **NOT** pick this up: Stage 6 depends on the Stage-5 `.mlir` and
on `eco-boot-native`, and `KERNEL_SOURCES` globs only `eco-kernel-cpp/src/Eco/*.elm|*.js`, so
a C++ edit leaves the Stage-6 command "up to date" and the ELF keeps the **old** kernel
archive (kernel-opt-02 §P0.4, verified). Correct recipe — and it is also the *better* A/B,
because both arms are lowered from one Stage-5 `.mlir`:

```bash
cmake --build build --target eco-boot-native                    # refreshes ElmKernel_*/EcoRuntimeStatic
/work/build/runtime/src/codegen/eco-boot-native "$BK/bin/eco-compiler.mlir" \
    -o "$BK/bin/eco-kopt<NN>-on"                                # + env flags for backend-gated lowering
```

**Shape C — both sides changed** (04, 05, 03, 08, 12, 14). Do not conflate them: run Shape A
for the emission half and Shape B for the lowering half, and say in the run entry which half
each arm carries. If you must measure them together, state it explicitly and expect the
`-out.mlir` to move.

---

## The benchmark

`@benchmarks/kernel-opt.md` §Methodology and §Recording instructions are normative — follow
them verbatim (cold `rm -rf $BK/eco-stuff` before **every** run, `ECO_MONO_ENGINE=subst` as
the workload engine, 2 rounds × 2 arms with the arm order reversed in round 2, one cold run
per leg and no warmup leg). The loop adds only these three rules:

1. **Arm naming**: `eco-kopt<NN>-on` / `eco-kopt<NN>-off`. **Both arms are built from the
   SAME post-change tree**, differing only by the track flag in the build env — *not*
   "new binary vs the old `eco-kopt-base` binary". This matters because **the Stage-7a
   workload IS `/work/compiler/src`**: an item that edits compiler source changes the job
   itself, so an arm pair straddling the edit would compare two different workloads. With
   both arms cut from the post-change tree the workload is identical by construction and
   `eco-kopt-base` serves only as the cross-item trend line, never as the A/B partner.
   For an item with **no flag** (07) there is no pair; run one arm, compare to
   `eco-kopt-base`, and state the workload delta (new/changed modules) explicitly rather
   than claiming a clean wall comparison.
2. **The track flag belongs in the BUILD env, never in the workload env.** The two engine
   knobs the file warns about generalise: setting an emission flag on the `make` run changes
   *what the binary compiles*, so `-out.mlir` moves and the walls stop being comparable. Build
   the ON arm with the flag; run both arms with `ECO_MONO_ENGINE=subst` and nothing else. Then
   `cmp` the two `-out.mlir` files — they must be byte-identical, and that identity is what
   makes the wall delta mean "the optimized binary is faster/slower", which is the question.
3. Where the plan's own gate list specifies extra arms (03 wants three, 09 wants per-phase,
   14 wants one entry per phase), run the plan's arms and label the run entry accordingly.

Then append one labelled section to `benchmarks/kernel-opt.md` — **Run E onward**, continuing
the letters (A/B/C are taken; Run D is the loop-entry baseline). Multi-phase items use
`Run K.1`, `Run K.2`, …. Max 10 lines of prose, the full stats table, and never a wall without
its major-GC count.

---

## The decision rule

Compute `Δwall` on the **r1/r2 mean** of the ON arm vs the OFF arm.

```
Δwall ≤ +3.0%   ->  NOT a regression.  Keep.  (A win is a bonus; a flat is a pass.)
Δwall >  +3.0%  ->  suspect.  Run one more round pair (r3, arms reversed).
                    Mean of 3 still > +3.0%  ->  REGRESSION -> KEPT-DARK (or REVERTED).
                    Mean falls inside the band -> FLAT -> keep, and say the first pair was noise.
```

Independently of the wall, **stop and explain before assigning a disposition** if any of these
moved in a way the plan did not predict (they are exact at n=1, so a move is real):
`Objects allocated`, `Bytes allocated`, `Objects promoted`, `Minor GC cycles`,
`Major GC cycles`. `Objects promoted` is the retention channel and the one that has actually
tracked wall in this repo — an unexplained rise there is a stronger reason to reject than a
few seconds of wall. A predicted move in the predicted direction is a *confirmation*, not a
problem (01, 02, 10, 13, 14 all expect allocation to move).

Also record, without gating on them: max RSS (flag a >3% rise for investigation), `.text` vs
`.llvm_stackmaps` split for the metadata-class items (08, 09 — that split *is* their
deliverable), and the `-out.mlir` byte size as the workload-constancy check.

---

## LOOP

### 1. Check `/usage`
If over 90%, `sleep <seconds until reset + 60>`, then continue — do **not** stop or report out.

### 2. Pick the next item
The first row of the worklist table not yet marked with a terminal disposition in
`@kernel-opt-status.md`. If none remain, go to **DONE**.

### 3. Read and snapshot
Read the plan end to end — `Approach`, `Traps & risks`, `Gates`, and the go/no-go tables
inside the phases. Re-verify its `file:line` anchors against the tree (siblings have moved
them). Read the relevant `REP_*` / `CGEN_*` / `HEAP_*` / `FORBID_*` rows of
`@design_docs/invariants.csv`. `cp -a` every file listed in `## Files touched` into
`$SCRATCH/snap-<NN>/`.

### 4. Implement, phase by phase
Follow the plan's phase order. Honour its internal gates: several plans **stop themselves** —
02's Phase 0 census picks the lane, 09's Phase 1 census is a hard precondition to any
transform, 10's Phase 0.1 purity audit licenses CSE, 13's C1/D-C gate decides whether C2 is
built at all. A plan that gates itself to NO-GO is a **successful execution** with disposition
KEPT-DARK/PARTIAL — record the census numbers in the plan file's own results section and in
the status file; do not force the transform in anyway.

Land the flag **default-off** exactly as the plan specifies. The default flip is step 7.

### 5. Gates — each run ONCE, teed to a file, then grepped
Never re-run a suite to "see more"; grep the tee'd file (`@CLAUDE.md`). Running the *same*
suite twice in two different flag states is two legs, not a re-run — that is required and
expected.

```bash
cmake --preset build                                          # only if the item added a compiler/src/*.elm
cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt
cmake --build build --target full     2>&1 | tee /tmp/test_output.txt        # flag OFF
<FLAG>=1 cmake --build build --target full 2>&1 | tee /tmp/test_output_on.txt # flag ON
```

Never `--target check` when anything that regenerates `.mlir` changed. Then:

- **Plan-specific gates** — run every numbered item in the plan's `## Gates` list (fixtures,
  op-count reconciliation, `EcoListTemplate` counter parity, emission deltas, census archives,
  audit harnesses). These are where a wrong item actually gets caught; the generic suites
  mostly do not see it. **Skip the plan's own heap-validate and bootstrap steps** — see below.

A gate failure → fix forward while you understand the failure. Three consecutive failures with
no root cause → revert from the snapshot, mark **BLOCKED** with everything learned, next item.

### Gates this loop deliberately does NOT run

Every plan's `## Gates` list asks for two more that this loop **skips by decision** (user
call, 2026-08-10 — the loop is being kept short):

- **The heap-validate tree** (`-DECO_HEAP_VALIDATE=ON` in a second build dir): ~30 min for the
  first build (the option changes every compile line, so ccache cannot serve it) and ~5 min
  incrementally after.
- **`--target bootstrap`** (the 9-stage self-host ladder to the Stage-8c fixed point): ~60–90
  min; `.ninja_log` puts single stages at 7.0–7.7 min and the ladder runs twice.

**State the cost honestly rather than pretending it is covered.** Dropping these gives up:

1. *Under-rooting detection.* heap-validate is the only gate that walks the heap and catches a
   GC root that a new op or a rewritten kernel forgot. The 1632-test E2E corpus catches it
   only when it happens to crash. Items 01/03/04/05/09/10/14 are exactly the ones that can
   introduce it. **This is the real loss.**
2. *Self-host convergence.* Nothing else proves the compiler still reaches a fixed point.

What partially carries the weight instead, at no extra cost:

- The benchmark's **`cmp` of the two arms' `-out.mlir`** is a genuine self-consistency check,
  not just a workload-constancy check: both arms compile the identical frozen input, so a byte
  difference means the change altered emitted code when it claimed not to. Treat a `cmp`
  mismatch as a stop-the-line correctness failure, not a benchmarking annoyance.
- Each benchmark leg is a full ~243-module self-compile under the real GC — the heaviest
  allocation workload available. A rooting bug severe enough to matter usually crashes it.

If a later item reports an unexplained `Objects promoted` / `Major GC` move, or a benchmark leg
segfaults, **that is the signal to spend the 30 min on a heap-validate tree** for that item
specifically. And run one `--target bootstrap` at DONE before declaring the series finished.

### 6. Benchmark
Build the arms (Shape A/B/C), run the A/B per `@benchmarks/kernel-opt.md`, append the labelled
run entry with the full stats table, and apply **The decision rule**.

`--target full` runs `ninja clean` first, so it deletes `bin/eco-compiler` and
`bin/eco-compiler.mlir` — always **gate first, then build the arms and benchmark**, or you
will benchmark a binary the gate then destroys. Your `cp`'d `eco-kopt*` arms are not ninja
outputs and survive the clean.

### 7. Disposition
- **Keep (Δwall ≤ +3%, gates green)** → flip the plan's flag default to on, keeping the env
  escape (`ECO_X=0`), exactly as Run B/C did for `ECO_CMPCASE` / `ECO_ORDER_FROM_SIGN`. Both
  flag states are already proven by step 5, so the flip itself needs only
  `cmake --build build --target elm-tests` plus the plan's own fixture filter. Note that the
  hash token now appears for default builds — that is the designed behaviour and it
  invalidates stale caches for you. Promote the arm:
  `cp -p "$BK/bin/eco-kopt<NN>-on" "$BK/bin/eco-kopt-base"`, and re-point `baseline_wall` /
  `baseline_counters` at this run.
- **Reproduced ≥3% regression** → **KEPT-DARK**: leave the code, tests and flag in the tree at
  default-off, record the measured regression and the suspected mechanism. Revert from the
  snapshot only if the item cannot be made inert at default-off.
- **Plan self-gated NO-GO** → KEPT-DARK / PARTIAL with the census numbers.
- **Item has no default to flip** (07) → **LANDED**.

### 8. Record and continue
Update `@kernel-opt-status.md` (disposition, Δwall, counter deltas, gate counts, run label,
notes) and the plan file's own results section where it has one (02, 11, 13 ask for it
explicitly; 08, 09, 10 ask for their census/size numbers). Go to **1**.

---

## DONE

Only when all fourteen have a terminal disposition. Produce a report with:

- One line per item: disposition, Δwall (with its run label), the counter deltas that moved,
  and for KEPT-DARK/BLOCKED the reason.
- **Cumulative** Stage-7a wall and counters: final `eco-kopt-base` vs the Run D loop-entry
  baseline, measured as a fresh 2×2 A/B, not summed from the per-item deltas.
- Confirmation that the final tree passes `--target full` and `--target elm-tests` at their
  recorded counts, plus **one** `--target bootstrap` run here at the end (the only one in the
  series) confirming the compiler still reaches its Stage-8c fixed point. If it fails, say so
  and note that attribution across 14 landed items is a manual bisect — there is no git here.
- An explicit statement of what was NOT gated: no heap-validate tree was built during the
  loop, so under-rooting introduced by any item is unproven except insofar as the E2E corpus
  and the self-compile benchmark legs exercised it.
- The list of flags now default-on and their escape hatches, plus the summary table at the
  bottom of `benchmarks/kernel-opt.md` updated with every run.

---

## Gotchas

- **No git** (see above): snapshot with `cp -a`, revert by copying back — then **`touch`
  every restored file**. `cp -a` preserves the original mtime, which is *older* than the
  object built from the edited version, so ninja considers the stale object up to date and
  the revert silently does not take. (Hit once: reverted census instrumentation still linked
  in, surfacing as `undefined reference to eco_array_census_tally` against source lines that
  no longer existed.)
- **FREEZE `/work/compiler/src` while any build or timed run is in flight.** Stage 5 reads
  it to build the binary and Stage 7a compiles it *as the workload*, so an edit landing
  mid-run silently changes either the artefact or the job. (Hit once: a source edit landed
  39 s after Stage 5 wrote its `.mlir`. Provenance was recoverable only by grepping the
  emitted `.mlir` for the new module's symbols — do that check whenever the timing is
  close, and otherwise just don't edit until the run reports done.)
- **`--target full` cleans first** — it deletes `bin/eco-compiler{,.mlir}` and `eco-boot.js`
  (Stage 1 rebuilds the latter). `cp`'d arm binaries survive. Gate before you benchmark.
- **Ninja is env-blind**: an env-only flavour change does not re-run Stage 5. `rm -f` the
  Stage-5 outputs to force it — this is how a "flag-on" build silently measures flag-off code.
- **After a default flip, the promoted baseline binary is stale as an A/B partner.** It was
  built with the flag forced via env while its *compiled-in* default was still off, so when
  it later runs a workload with no env var it emits the OLD encoding — the next item's A/B
  then differs in two ways at once and its byte-identity gate fails for the wrong reason.
  Either rebuild the baseline after the flip, or force the flag in the workload env for
  **both** arms so the emission matches. (Hit once: item 02's G2 "failure" was 7,300 lines
  of `eco.call @Elm_Kernel_List_cons` → `eco.construct.list`, i.e. entirely item 01.)
- **Cold wipe**: `rm -rf "$BK/eco-stuff"` immediately before every timed run; never touch
  source mtimes; **never delete `~/.eco`** (warm package cache).
- **Kernel `.elm`/`.js` edits need the `~/.eco` seed cache nuked** for that package
  (`rm -rf ~/.eco/0.1.0/packages/eco/kernel`) or stage 2 fails with the old signature.
- **A kernel/runtime C++ edit does not reach `--target eco-compiler`** — Shape B above.
- **Run test suites serially.** Concurrent E2E/unit suites corrupt
  `~/.eco/.../typed-artifacts.dat` and produce flaky mono crashes.
- **Gate counts must be measured, not assumed.** `elm-tests` is already red on the pristine
  tree (13066/12), and the heap-validate figure is quoted as both 1623 and 1632 in different
  places — which is why the recorded number, not the word PASSED, is the gate.
- **Do not poll with `pgrep -f "target full"`** — the pattern matches the polling command's own
  command line, so the loop never exits and you conclude a 4-minute build took 10+ minutes.
  Poll on the artefact or on the log's terminal line instead.
- **`rc::check` failures do not fail the suite** — also grep for `Falsifiable`.
- **Kernel symbol deletions (item 14) land as a separate step after all gates pass**, never in
  the same step as the migration that made them dead.
- **Attribute honestly**: inside ±2.8% is FLAT. Not "a small win", not "a slight regression".
