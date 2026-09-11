# Call statistics — LSS coverage, stamping, dispatch and surviving calls

Four censuses, recorded together for every run, under fixed names. Use these
names everywhere — plans, memories, other benchmark files — so numbers from
different sessions can be joined.

| # | Name | What it counts | Source |
|---|---|---|---|
| 1 | **lss-coverage** | LSS set at each arrow POSITION in the emitted artifact: singleton (`k1`), multi (`kN`), `var`, `⊤`, partial | `coverage:` line, `ECO_MONO_LSS_REPORT=1` |
| 2 | **lss-stamping** | AbiCloning verdict at each consulted site: `dispatchUpgraded`, `stampedPapGlobal`, `stampedStaged`, `stampedPapPrefix`, declines (`noInstance`, `blocked`, `bodyMismatch`, `shape`, `abiMismatch`), post-settle devirt `fn`/`ctor`/`noSpec`/`ambiguous` | `lss globalopt:` line, `ECO_MONO_LSS_REPORT=1` |
| 3 | **dispatch-stats** | LOGICAL dispatches the runtime performed: `fast`, `generic`, `typed` | `[dispatch-stats]`, binary lowered `ECO_LSS_DISPATCH_SITE_COUNTERS=1`, run `ECO_DISPATCH_STATS=1` |
| 4 | **call-census** | SURVIVING calls in the emitted object code by target: direct Elm, direct runtime, direct kernel, dispatch trampolines (`helper`), direct stamped fast clones (`cap`), `extern`, `indirect` | `[call-census]`, binary lowered `ECO_CALL_CENSUS=1` |

Groups 1–2 are properties of the WORKLOAD (what the compiler is asked to
compile, under which flags). Groups 3–4 are properties of the BINARY (what the
compiler itself executes). That is why every run measures two compilers.

## Methodology

Same shape as `benchmarks/flag-off-lss-loop.md`, and native throughout — never
measure on the JS build.

- **Reference compiler** — built with `ECO_MONO_ENGINE=subst`, i.e. none of the
  LSS optimizations applied *to it*. Emitted from the current tree by any
  working native seed (output is a function of source + config, not of the
  compiling binary), then lowered.
- **Benchmark compiler** — built with solver + LSS + the run's flags.
- **Both compilers then do the SAME self-compile**, under
  `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1` plus the run's flags. The workload is
  identical; only the binary doing the work differs. The reference row prices
  the LSS analysis, the benchmark row prices what the analysis bought.

Both binaries are lowered with `ECO_CALL_CENSUS=1 ECO_LSS_DISPATCH_SITE_COUNTERS=1`
so groups 3 and 4 come out of the same run as groups 1 and 2.

```bash
BK=/work/build/compiler/build-kernel; BOOT=/work/build/runtime/src/codegen/eco-boot-native
SRC=/work/compiler/src/Terminal/Main.elm; cd $BK

# reference .mlir, current tree, subst engine
rm -rf eco-stuff
ECO_MONO_ENGINE=subst ./bin/<seed> make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/std-subst.mlir $SRC

# census-lower both compilers
ECO_CALL_CENSUS=1 ECO_LSS_DISPATCH_SITE_COUNTERS=1 $BOOT bin/std-subst.mlir  -o bin/eco-std-census
ECO_CALL_CENSUS=1 ECO_LSS_DISPATCH_SITE_COUNTERS=1 $BOOT bin/<bench>.mlir    -o bin/<bench>-census

# one run per compiler, same workload flags
rm -rf eco-stuff
ECO_DISPATCH_STATS=1 ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 <FLAGS> \
  /usr/bin/time -v -o <tag>.time ./bin/<compiler>-census make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/<tag>-out.mlir $SRC > <tag>.stdout 2> <tag>.stderr
```

**Hygiene.** `rm -rf eco-stuff` before every measured run; strictly serial (peak
RSS ~14 GB on a 15 GB box); never touch `ECO_HEAP_CONFIG`; compare only
same-source arms — the workload is the compiler's own source, so any item that
adds source shifts every figure. Record `out.mlir` bytes with every row and
quote both sizes before making any cross-row claim.

**Census-on walls.** Every run here carries all four censuses, so the wall and
GC figures are ~2 % above the plain protocol in `benchmarks/lss-opt.md` and are
NOT comparable to that file's. They are comparable across rows of this file.
`ECO_MONO_LSS_REPORT=1` also contributes its own dispatch events to groups 3–4,
uniformly in every row here — which is why `benchmarks/runtime-calls.md` rows
measured report-off are not comparable to these either.

**Artefacts.** `benchmarks/call-stats.tsv` is the raw extraction, one line per
compiler run, and `benchmarks/call-stats-extract.py <tag>...` regenerates it from
the `<tag>.time` / `.stdout` / `.stderr` triple in `build/compiler/build-kernel`.
Add rows only by running the protocol, never by hand.

**Reading.** Group 1's denominator is arrow positions, one tally per arrow per
specialization; a `kN` set counts as covered exactly as much as a `k1` set
(analysis coverage = `(k1+kN)/positions`). Group 3's `fast %` is over the
dispatch population `sat+fast`. Group 4's static-target share is
`(elm+kernel+cap)/(elm+kernel+cap+sat)`.

---

## Runs

### Run 1 — default flags, `eta=1` (2026-09-11)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `eta=1` | 598.2 | 14,130,180 | 2,131 | 11 | 22,472 | 15,654,810 |
| benchmark | solver+LSS, `eta=1` | solver+LSS, `eta=1` | 496.1 | 13,970,512 | 2,062 | 11 | 22,518 | 15,665,163 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,818 | 101,099 (68.39 %) | 34,501 (23.34 %) | 11,107 (7.51 %) | 1,071 (0.72 %) | 40 (0.03 %) | 91.73 % |
| benchmark | 147,871 | 101,132 (68.39 %) | 34,521 (23.35 %) | 11,107 (7.51 %) | 1,071 (0.72 %) | 40 (0.03 %) | 91.74 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,226 | 2,577 | 201 | 15 | 14,553 | 1,371 | 1,262 | 667 | 365 | 103/305/0/14 | 3,617 |
| benchmark | 18,225 | 2,577 | 201 | 15 | 14,553 | 1,371 | 1,262 | 668 | 365 | 103/305/0/14 | 3,618 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,886,671,569 | 2,797,263,407 | 89,408,162 | 0 | 2,886,671,569 | 0.00 | 96.90 | 3.10 | 7,250 |
| benchmark | 784,353,200 | 701,772,872 | 82,580,328 | 881,785,787 | 1,666,138,987 | 52.92 | 42.12 | 4.96 | 6,943 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 12,397,337,886 | 15,115,035,870 | 1,249,117,272 | 2,567,397,553 | 424,983,636 | 0 | 0 | 425,554 | 82.98 |
| benchmark | 11,761,180,689 | 10,244,739,002 | 1,257,847,614 | 635,332,155 | 569,760,396 | 0 | 0 | 447,605 | 94.54 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,477,989,394 | 85,356,493 | 4,051,666 | 89,408,159 vs typed 89,408,162 — 3 events |
| benchmark | 552,751,830 | 78,858,126 | 3,722,199 | 82,580,325 vs typed 82,580,328 — 3 events |

Default flags plus `ECO_INLINE_ETA_EXPAND=1`; tree carries the E9.5 `matchSpec` uniqueness
fix. The reference's `fast=0` is the arm working as designed — a subst-built binary carries
no LSS stamps — while its `cap`=425 M shows Channel A is not LSS-driven. Groups 1–2 agree
between the arms to within 53 positions and one stamp, the workload-invariance check.
**The two arms' `out.mlir` differ (15,654,810 vs 15,665,163): the eta-BUILT compiler is not
at a bootstrap fixed point for `eta=1`, so that gate is owed before the flag can ship on.**

### Run 2 — default flags, `eta=0` (2026-09-11)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `eta=0` | 607.7 | 13,846,244 | 2,147 | 11 | 22,269 | 15,816,680 |
| benchmark | solver+LSS, `eta=0` | solver+LSS, `eta=0` | 520.7 | 13,823,092 | 2,136 | 11 | 22,284 | 15,816,680 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,858 | 101,215 (68.45 %) | 33,714 (22.80 %) | 11,625 (7.86 %) | 1,161 (0.79 %) | 143 (0.10 %) | 91.26 % |
| benchmark | 147,858 | 101,215 (68.45 %) | 33,714 (22.80 %) | 11,625 (7.86 %) | 1,161 (0.79 %) | 143 (0.10 %) | 91.26 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,820 | 2,202 | 678 | 3 | 14,327 | 6,633 | 1,268 | 692 | 365 | 7/307/0/77 | 3,732 |
| benchmark | 17,820 | 2,202 | 678 | 3 | 14,327 | 6,633 | 1,268 | 692 | 365 | 7/307/0/77 | 3,732 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,926,959,206 | 2,839,835,575 | 87,123,631 | 0 | 2,926,959,206 | 0.00 | 97.02 | 2.98 | 7,188 |
| benchmark | 997,989,868 | 915,281,751 | 82,708,117 | 968,555,804 | 1,966,545,672 | 49.25 | 46.54 | 4.21 | 7,520 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 12,484,949,134 | 15,253,474,174 | 1,274,938,486 | 2,604,088,288 | 427,063,311 | 0 | 0 | 425,554 | 82.90 |
| benchmark | 11,879,805,582 | 10,889,624,388 | 1,274,643,126 | 812,303,959 | 690,703,643 | 0 | 0 | 455,137 | 93.28 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,516,964,660 | 83,066,209 | 4,057,419 | 87,123,628 vs typed 87,123,631 — 3 events |
| benchmark | 729,595,845 | 78,980,947 | 3,727,167 | 82,708,114 vs typed 82,708,117 — 3 events |

Shipping defaults. Both arms produce a byte-identical 15,816,680 B output and identical
groups 1–2 — the workload-invariance check passing exactly. Against Run 1's benchmark
(different binary AND different workload flags, `out.mlir` 1.0 % apart, so attribute with
care): η cuts generic dispatch 915.3 M → 701.8 M (−23.3 %) and the whole dispatch population
−15.3 %, of which the reference arms show only −1.4 % is the workload; `blocked` declines
fall 6,633 → 1,371 and `devirtPost ambiguous` 77 → 14.

---

## Summary

| Run | State | Compiler | Wall (s) | Minor GC | Major GC | Promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 598.2 | 2131 | 11 | 22472 | 15654810 |
| 1 | eta=1 | benchmark | 496.1 | 2062 | 11 | 22518 | 15665163 |
| 2 | eta=0 | reference | 607.7 | 2147 | 11 | 22269 | 15816680 |
| 2 | eta=0 | benchmark | 520.7 | 2136 | 11 | 22284 | 15816680 |

### 1. lss-coverage

| Run | State | Compiler | positions | k1 | kN | var | top | part | coverage % |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 147818 | 101099 | 34501 | 11107 | 1071 | 40 | 91.73 |
| 1 | eta=1 | benchmark | 147871 | 101132 | 34521 | 11107 | 1071 | 40 | 91.74 |
| 2 | eta=0 | reference | 147858 | 101215 | 33714 | 11625 | 1161 | 143 | 91.26 |
| 2 | eta=0 | benchmark | 147858 | 101215 | 33714 | 11625 | 1161 | 143 | 91.26 |

### 2. lss-stamping

| Run | State | Compiler | upgraded | papGlobal | staged | papPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | dp fn | dp ctor | dp noSpec | dp ambiguous | multiInst |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 18226 | 2577 | 201 | 15 | 14553 | 1371 | 1262 | 667 | 365 | 103 | 305 | 0 | 14 | 3617 |
| 1 | eta=1 | benchmark | 18225 | 2577 | 201 | 15 | 14553 | 1371 | 1262 | 668 | 365 | 103 | 305 | 0 | 14 | 3618 |
| 2 | eta=0 | reference | 17820 | 2202 | 678 | 3 | 14327 | 6633 | 1268 | 692 | 365 | 7 | 307 | 0 | 77 | 3732 |
| 2 | eta=0 | benchmark | 17820 | 2202 | 678 | 3 | 14327 | 6633 | 1268 | 692 | 365 | 7 | 307 | 0 | 77 | 3732 |

### 3. dispatch-stats

| Run | State | Compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 2886671569 | 2797263407 | 89408162 | 0 | 2886671569 | 0.00 | 96.90 | 3.10 | 7250 |
| 1 | eta=1 | benchmark | 784353200 | 701772872 | 82580328 | 881785787 | 1666138987 | 52.92 | 42.12 | 4.96 | 6943 |
| 2 | eta=0 | reference | 2926959206 | 2839835575 | 87123631 | 0 | 2926959206 | 0.00 | 97.02 | 2.98 | 7188 |
| 2 | eta=0 | benchmark | 997989868 | 915281751 | 82708117 | 968555804 | 1966545672 | 49.25 | 46.54 | 4.21 | 7520 |

### 4. call-census

| Run | State | Compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 12397337886 | 15115035870 | 1249117272 | 2567397553 | 424983636 | 0 | 0 | 425554 | 82.98 |
| 1 | eta=1 | benchmark | 11761180689 | 10244739002 | 1257847614 | 635332155 | 569760396 | 0 | 0 | 447605 | 94.54 |
| 2 | eta=0 | reference | 12484949134 | 15253474174 | 1274938486 | 2604088288 | 427063311 | 0 | 0 | 425554 | 82.90 |
| 2 | eta=0 | benchmark | 11879805582 | 10889624388 | 1274643126 | 812303959 | 690703643 | 0 | 0 | 455137 | 93.28 |
