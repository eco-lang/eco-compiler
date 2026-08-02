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
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 \
    cmake --build build --target eco-compiler          # + track-opt env vars as they land
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
