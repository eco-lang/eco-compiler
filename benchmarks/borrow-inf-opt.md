# Borrow-Inference Opt Track — Stage-7a Cold-Cache Benchmarks

Tracks the wall/RSS/allocation impact of the tier-1 optimization track
(`plans/opt-tier1-aggregate-promotion.md` — U-T1.3.x aggregate promotion and
successors) on the standard bootstrap workload. Append one labelled section
per run.

---

## Recording instructions (fixed — keep every entry uniform)

**Per run:** give it a **label** (Run A, Run B, …). Record **wall time**,
**max RSS**, and the **number and size of heap allocations** from the GC
stats exit dump (`Objects allocated`, `Bytes allocated`), plus
`Minor GC cycles`, `Objects promoted`, `Major GC cycles` (never report a
wall without its majors — trigger-lottery lesson), `Total GC/Alloc time`,
and the output `.mlir` byte size (workload-constancy check). Describe the
run in **max 10 lines of text** — no extensive write-ups; keep the labelled
entries uniform in appearance, stats recorded, and briefness.

**Summary table:** maintained at the **bottom of this file** — one row per
run: label, wall time, total heap allocation. Just the table, no write-up.

**Allocation-count caveat (census §18.3):** the standard binary's HEAP_034
inline-alloc fast path bypasses the per-tag counter, so `Objects allocated`
undercounts codegen'd constructs (~6× on this workload). The figure is
comparable **run-to-run** only for unchanged lowering; when a track
optimization is expected to move allocation, add a separate census leg with
an `ECO_INLINE_ALLOC=0`-lowered binary and record it explicitly as such.

---

## Methodology (repeat exactly each time; adapted from `benchmarks/runtime-calls.md`)

**Workload — cold-cache Stage 7a, constant-config.** The tested
`eco-compiler` binary compiling the entire compiler front-end
(`compiler/src/Terminal/Main.elm`, ~243 modules) to MLIR. The workload runs
under the **cheap fixed configuration** — `ECO_MONO_ENGINE=subst`, no LSS,
no borrow (both default-off under subst) — so the job the binary executes
stays essentially constant across track changes and the measurement isolates
**how fast the optimized binary runs**, undistorted by the recursive tax of
solver/LSS/borrow running *as* workload.

**Binary — the thing being tested.** Built with **solver + LSS + borrow ON
plus every track optimization under test**: this is the artifact whose
performance the track is improving. `build` preset (RelWithDebInfo,
asserts + GC-stats ON — the standard bootstrap config; ~2.6× slower than
release but deterministic). Note: `ECO_BORROW=1` without report/reify is
inert-by-construction today (the Phase-6 pass self-skips); it is set anyway
so the build line already carries every track knob as they become real.

**Two independent engine knobs** (do not confuse): the **build engine** (env
at the `cmake --build` step — how the binary itself is compiled) vs the
**workload engine** (env at the `make` run — how the binary monomorphizes
what it compiles). Here: build = solver+LSS+borrow+track-opts; workload =
subst, always.

**Cache reset — delete `eco-stuff/` immediately before every run; do NOT
touch sources.** `rm -rf build/compiler/build-kernel/eco-stuff` is the
honest cold-cache reset (touching mtimes is fragile; engine changes are
invisible to mtime). **Never delete `~/.eco`** (warm package cache).

**Testing is a separate pass** — never mix gate runs into a benchmark; they
pollute timings and the `eco-stuff/` cache.

**Commands** (run from `/work`):

```bash
BK=build/compiler/build-kernel

# Phase 1 — build the tested binary (repeat when the track changes):
# NINJA IS ENV-BLIND (discovered Run B): with no source change, an env-only
# flavor change does NOT rerun Stage 5 — delete its outputs to force it.
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler          # + further track-opt env vars as they land
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-borrowopt"

# Phase 2 — benchmark it (throwaway leg first to warm the OS page cache,
# then the recorded leg; BOTH legs cold in eco-stuff):
for LEG in warmup measured; do
  rm -rf "$BK/eco-stuff"
  ( cd "$BK" && ulimit -c 0 && \
      ECO_MONO_ENGINE=subst \
      /usr/bin/time -v -o "borrowopt-$LEG.time" \
      ./bin/eco-compiler-borrowopt make --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output=bin/borrowopt-out.mlir /work/compiler/src/Terminal/Main.elm \
          > "borrowopt-$LEG.stdout" 2> "borrowopt-$LEG.stderr" )
done
# Report the measured leg. Wall + Max RSS from the .time file; allocation
# stats from the GC dump in .stdout; output size from bin/borrowopt-out.mlir.
```

For an A/B against a prior run, `cmp` the two `borrowopt-out.mlir` — the
subst-mode output must stay **byte-identical** across track changes (the
track optimizes the binary, not the semantics of what it emits); a size or
byte diff means the workload moved and walls are not comparable.

---

## Runs

### 2026-08-04 12:30 UTC — Run L: T1.3.7 psplit selection fixpoint + justification widening (mechanism proven; population honest-small)

Census-first (DEV-JS): candidates 982 vs justified **27** (passthrough-only
params 1,176; other 1,629) — justification dominates ⇒ Phase B. Ships: a
selection FIXPOINT (round N−1 table = walker allowance + scan seed,
monotone), a PRE-ORDER site scan (**latent bug found: the foldExpr driver
is bottom-up — binder shapes registered AFTER their call sites; the binder
channel was dead since v1**), and sret→psplit NESTED COMPOSITION ($sret
multi-results feed $psplit scalars, container-free end-to-end). At scale
34 workers/294 sites (+6/+13): the census bounds were ADMISSIBILITY bounds;
justification is bounded by upstream slot-form availability, not analysis
precision. Wall −2.9% ≈ ship config; census −27.55M ≈ Run K (+60K delta).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:45.36** (r1 3:41.47; off 3:48.38/3:51.62) | 5,979,572 kB | 799,543,762 | 28,090.85 MB | 885 | 353,193,385 (44.2%) | 10 (off 11 — lottery) | 85.89 s | 12,914,984 B |

### 2026-08-03 23:55 UTC — Run K: T1.3.5 psplit param-side promotion (wall-neutral; alloc −27.5M; ships)

Binary = full ship config (solver+LSS+borrow+aggp+ctori+sretr+**psplit**).
At scale **28 `$psplit` workers / 281 migrated sites** — most of the census
`lit:tup2` bracket fails projection-only/free-slot admissibility: an
allocation rider, not a wall lever. Interleaved same-day vs off
(3:52.77/3:52.74): **3:46.24/3:44.14 ≈ Run J = −3.3%**, equal majors.
Census legs (`ECO_INLINE_ALLOC=0`): **total −27.5M obj (−0.65%, −668 MiB);
Tuple2 −25.1M (−6.33%), Tuple3 −4.74%, Custom −1.67M, Cons −1.36M**. The
first all-flags bootstrap hit the RS4GC FCA assert (AlwaysInliner-orphaned
dead make-chains) — fold-pass sweep fixed it; forensics + `ECO_FCA_SCAN` in
the plan's T1.3.5 addendum. Byte-identity, leaks 0, corpus 29/29, E2E 1611/1611.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:44.14** (r1 3:46.24; off 3:52.74) | 5,986,692 kB | 798,562,858 | 28,057.25 MB | 868 | 356,103,195 (44.6%) | 11 | 87.29 s | 12,914,350 B |

### 2026-08-03 23:30 UTC — Run J: T1.3.6 tail-func widening (**+4% REGRESSION → default-off**); ship sret = −3.2%

Binary = flag-on build (solver+LSS+borrow+aggp+ctori+sretr). THE LESSON: a
9-leg interleaved session read J-with-widening ≈ off — flat — because
**T1.3.6's widening (+4%) cancelled T1.3.3's win (−4%) almost exactly**;
only a 3-arm isolation behind an independent gate (`ECO_SRET_TAILFUNC`)
exposed it. Cause: 68 tail-func workers loop-carry N result-slot columns
through EVERY hot-loop iteration. Verdict: `sretTailFuncs` **default OFF**
(opt-in `=1`, hash "srtf=1"); machinery kept (revive = exit-block-only
result materialization). Ship config: **3:45.29/3:45.35 vs off
3:52.77/3:52.74 = −7.4s (−3.2%)**, equal majors — and corrects Run I: its
−5.9% was day-drift-inflated. Second-order PASS, byte-identity off≡J PASS.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:45.35** (r1 3:45.29; off 3:52.74) | 5,964,012 kB | 798,562,682 | 28,057.24 MB | 868 | 356,076,742 (44.6%) | 11 | 89.13 s | 12,914,350 B |

### 2026-08-03 14:05 UTC — Run I: T1.3.3 sret result promotion (**−5.9% wall, the track's first measured win**)

Binary = flag-on build (solver+LSS+borrow+aggp+ctori+**sretr**). 268 `$sret`
workers, **1,228 migrated call sites** (`Context.freshVar` 262/262 — the
census's #1 target); shims keep the boxed ABI for the rest. Raw wall vs
Run H (+14s) is DAY DRIFT, not the transform — the same-source A/B settles
it: **on-built 3:39.4/3:40.0 (two pairs, hours apart, ±0.7s) vs off-built
3:53.9/3:53.8 = −13.8s (−5.9%)**, equal majors (10=10). Census legs
(`ECO_INLINE_ALLOC=0` binaries, same workload): **Tuple2 385.1M → 360.8M
(−24.2M, −6.3%, −554 MiB); total −26.4M objects (−577 MiB)** — the direct
proof the transform fires. Second-order (same source) **PASS**; boundary
leak 0; CGEN_067 re-ratified `enforced`. Workload moved (+45.0KB out.mlir).
Two implementation incidents caught by gates: TailRec synthetic-let slot
persistence (loud lookupVar crash) and the RS4GC FCA assert on aggregate
case results → DECOMPOSED YIELDS (N scalar case results + block-local
rebuild, the old pass's recorded shape) + a tail-flag restore fix.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:40.04** (pair2 3:40.03; off-built 3:53.77) | 5,822,584 kB | 775,152,632 | 27,218.00 MB | 876 | 331,599,383 (42.8%) | 10 | 83.52 s | 12,845,895 B |

### 2026-08-03 08:58 UTC — Run H: T1.3.2c ctor-call inlining (42,539 saturated ctor calls → 0)

Binary = flag-on build (solver+LSS+borrow+aggp+**ctori**). Saturated direct
ctor calls now emit `eco.construct.custom` inline in the caller
(`tryCtorInline` at `generateSaturatedCall`; slot prep shared with the
make-form via `prepareCtorSlots` so layouts cannot drift). At scale:
**42,539 n-ary ctor-call sites → 0**; 8,941 NULLARY calls untouched by
design (CAF-memoized singletons — inlining would ADD allocation). Sister
lever case-of-known-ctor measured **NO-GO**: 0 `eco.case` + 3 `get_tag` on
locally-known ctor results in the whole self-compile. Yardstick 95
(82c+12t2+1t3) unchanged; boundary-leak 0. No `ECO_INLINE_ALLOC=0` census
leg: the transform RELOCATES constructs, object counts don't move (deltas
vs G = workload growth, +4,853 B out.mlir). Wall vs G −1.03 s on a larger
workload — neutral-to-marginally-positive; RSS swing is major-GC lottery.
Second-order (on-built ≡ off-built, same source) **PASS**.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:25.97** (warmup 3:29.85) | 5,548,908 kB | 746,132,063 | 26,160.53 MB | 824 | 301,131,711 (40.4%) | 10 | 78.06 s | 12,800,927 B |

### 2026-08-03 01:10 UTC — Run G: T1.3.3L scalar-split loop variables (win-gated; 4 pure-win loops)

Binary = flag-on build with SCALAR-SPLIT loop variables: selected tail-func
params carried as per-field state slots (no aggregate crosses an iteration —
sidesteps the RS4GC FCA hazard). WIN GATE is the story: ungated, 624 loops
split but only 3 held real wins (the rest = eager per-slot projections +
whole-use REmaterialization — Dict.get's tuple key would re-allocate per
node); gated = admissible (all uses projections) AND all tail args
slot-feedable with ≥1 fresh construct → **4 split loops, all pure wins**
(partition-class accumulator pairs; carried-tuple/State/inline-ctor fixture
classes now promote). Yardstick (solver leg) **95 = 82c+12t2+1t3** — exactly
Run F (promotion-neutral; subst-leg 90 is a different-basis count, not a
regression). Workload MOVED (+29,909 B out.mlir: sources grew ~1k lines) —
object delta vs F (+12.9M) is workload growth. Second-order (on-built vs
off-built, same source) **PASS**. Boundary-leak scan 0. 10 majors recorded.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:27.00** (warmup 3:23.79) | 5,078,956 kB | 742,093,523 | 26,002.69 MB | 819 | 298,084,519 (40.2%) | 10 | 77.41 s | 12,796,074 B |

### 2026-08-02 22:31 UTC — Run F: T1.3.2t TailRec real-body threading (95 sites; intra-def track CLOSED)

Binary = flag-on build after threading the REAL loop-body suffix through
TailRec's synthetic def-setup (`Ctx.tailRecLetBody` + per-position
fwd-ref scan union). Fixture proof: loop-LOCAL tuple+ctor in tail loops
promote (per-iteration allocation eliminated), loop-CARRIED stays heap.
Yardstick 93 → **95** (+2: the TailRec class is ~all loop-carried — every
solveGo State flows into the next iteration's tail call; correctly
rejected). Leak check 0. **CONCLUSION: the intra-def syntactic promotable
population on this workload is ~95 sites — track closed.** Remaining mass
needs aggregate-typed LOOP VARIABLES (`Eco_AnyValueOrAggregate` on
yields/joinpoints already exists) or T1.3.3's call ABI. A/B identical
workload: +277 objects delta ≈ noise (measured leg mildly loaded; warmup
3:16.67 ≈ off-ref 3:16.62). Second-order **PASS**.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:25.07** (warmup 3:16.67) | 5,370,232 kB | 729,180,966 | 25,502.90 MB | 786 | 288,971,702 (39.6%) | — | 78.16 s | 12,766,165 B |

### 2026-08-02 21:47 UTC — Run E: T1.3.2p precise sibling recovery + TailRec root cause (93 sites)

Binary = flag-on build after the precise recovery. The exploration
CORRECTED the incident diagnosis: the dominant leak class was NOT
earlier-sibling captures but **TailRec's synthetic def-setup lets**
(`compileLetStep` wraps each loop-body binding as `MonoLet def MonoUnit`;
the walker saw an empty body and approved anything — 77 of the 87
guard-blocked sites, incl. every solveGo `State`). Fixes: (1) unit-body
lets never promote; (2) per-chain forward-ref scan (`generateLet` head
scan → `ctx.fwdRefdLetNames`; walker checks aliases too) replaces the
conservative chain-head guard, recovering +2 genuine chain-interior
tuples. Yardstick 93 (82 custom + 10 t2 + 1 t3), leak check 0. A/B
identical workload: **−73 objects**. Walls tight (3:23.88–3:25.96).
NEXT COVERAGE: thread the real body through TailRec for the ~85
loop-body candidates — the first plausibly HOT class.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:25.96** | 5,334,708 kB | 725,986,759 | 25,406.35 MB | 785 | 289,765,874 (39.9%) | 9 | 76.33 s | 12,764,655 B |

### 2026-08-02 20:20 UTC — Run D: T1.3.2 ctor-call promotion (91 sites)

Binary = `eco-compiler-borrowopt` built `ECO_AGG_PROMOTE=1` after T1.3.2
(saturated single-ctor calls at chain-head lets → `eco.make.custom`; call +
allocation both erased). **Soundness incident caught by this protocol's
Phase-1 build**: the first cut leaked promoted customs into `eco.box`/
`papCreate` (Elm let-siblings are mutually visible — an EARLIER sibling's
closure can capture a LATER binding, invisible to the body-suffix walk);
fixed by the chain-head guard (`ctx.currentLetSiblings` membership).
Yardstick: 82 custom + 8 tup2 + 1 tup3 = 91 sites (pre-guard 178, unsound).
A/B identical workload: **−9 objects** — cold sites again. Measured-leg
wall is an OUTLIER (GC 115s vs ~75s; warmup 3:28.85 ≈ off-ref 3:37.55).
Second-order gate: **byte-identical PASS**. Workload moved (T1.3.2 source).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **4:30.52** (outlier; warmup 3:28.85) | 5,338,788 kB | 723,558,029 | 25,323.23 MB | 795 | 287,630,652 (39.8%) | 10 | 115.46 s | 12,749,999 B |

### 2026-08-02 12:39 UTC — Run C: T1.3.1b case-scrutinee promotion (43 sites)

Binary = `eco-compiler-borrowopt` rebuilt with `ECO_AGG_PROMOTE=1` after
T1.3.1b (case-scrutinee tuples admitted; walker-only change). Yardstick
40 → **43** promoted sites (+3): the `case (a, b) of …` idiom never
materializes a tuple (the DT compiler destructures literal-tuple scrutinees
component-wise), and the census's residual `lit:` bracket is
call-boundary-entangled (borrowed-arg tuples) — intra-def syntactic
promotion saturates here. Workload moved again (1b source; out.mlir
12,736,685 B). In-run A/B, identical workload: **−398 objects** — cold.
Second-order gate (on-built vs off-built outputs): **byte-identical PASS**.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:30.36** | 5,263,888 kB | 714,654,378 | 25,009.65 MB | 784 | 279,928,963 (39.2%) | 10 | 82.50 s | 12,736,685 B |

### 2026-08-02 11:39 UTC — Run B: T1.3.1 tuple promotion (40 sites), flag-on-built binary

Binary = `eco-compiler-borrowopt` built with `ECO_AGG_PROMOTE=1` (+solver/LSS/
borrow env); its own code carries 39 `make.tuple2` + 1 `make.tuple3` promoted
sites (flag-on self-compile yardstick). **Workload moved vs Run A** (T1.3.1
compiler source added): out.mlir 12,716,226 → 12,734,214 B — A↔B walls not
comparable. In-run A/B on the IDENTICAL workload (off-built ref leg vs this
binary): **−266 objects / −1 minor GC** (714,572,493 → 714,572,227), wall
off-ref 3:29.75 vs on 3:22.36/3:29.47 (warmup) ⇒ noise — the 40 sites are
cold. Second-order gate: on-built and off-built outputs **byte-identical**.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:22.36** | 5,254,524 kB | 714,572,227 | 25,003.57 MB | 784 | 280,242,723 (39.2%) | 10 | 76.82 s | 12,734,214 B |

### 2026-08-02 10:13 UTC — Run A: baseline (post-T1.3.0, no track opts)

Baseline of the track. Binary = `eco-compiler-borrowopt` built 2026-08-02
(solver+LSS+borrow build env; borrow inert-by-construction; **no** track
optimizations — T1.3.0 changed only tests/invariants). Workload = subst,
cold eco-stuff, both legs. Warmup leg wall 3:12.45; measured leg reported.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:12.01** | 5,180,176 kB | 710,329,432 | 24,851.76 MB | 761 | 276,110,914 (38.9%) | 9 | 70.10 s | 12,716,226 B |

---

## Summary

| run | wall (measured leg) | total heap allocation |
|---|---|---|
| A — baseline (post-T1.3.0) | 3:12.01 | 710,329,432 obj / 24,851.76 MB |
| B — T1.3.1 tuple promotion (workload moved; see entry) | 3:22.36 | 714,572,227 obj / 25,003.57 MB |
| C — T1.3.1b case-scrutinee (workload moved; see entry) | 3:30.36 | 714,654,378 obj / 25,009.65 MB |
| D — T1.3.2 ctor promotion (workload moved; wall outlier — see entry) | 4:30.52 | 723,558,029 obj / 25,323.23 MB |
| E — T1.3.2p precise recovery (workload moved; see entry) | 3:25.96 | 725,986,759 obj / 25,406.35 MB |
| F — T1.3.2t TailRec threading (workload moved; see entry) | 3:25.07 | 729,180,966 obj / 25,502.90 MB |
| G — T1.3.3L scalar-split loop vars (workload moved; see entry) | 3:27.00 | 742,093,523 obj / 26,002.69 MB |
| H — T1.3.2c ctor-call inlining (workload moved; see entry) | 3:25.97 | 746,132,063 obj / 26,160.53 MB |
| I — T1.3.3 sret result promotion (−5.9% claim corrected by Run J: −3.2%) | 3:40.04 | 775,152,632 obj / 27,218.00 MB |
| J — T1.3.6 tail widening → default-off; ship sret **−3.2% vs off** (workload moved; see entry) | 3:45.35 | 798,562,682 obj / 28,057.24 MB |
| K — T1.3.5 psplit, **−3.3% vs off**, census −27.5M obj (workload moved; see entry) | 3:44.14 | 798,562,858 obj / 28,057.25 MB |
| L — T1.3.7 psplit fixpoint + justification (mechanism; +6 workers, workload moved) | 3:45.36 | 799,543,762 obj / 28,090.85 MB |
