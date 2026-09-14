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

**Comparability across the post-inline prune (Runs 9/10 on).** `inline.pruneDead` removed 9,897
dead specializations that AbiCloning had been walking, so every group-2 figure steps DOWN once as
a correction, not a regression: a stamp or a decline recorded at a call site in a specialization
nothing reaches was never worth anything. **Do not compare a group-2 number from Runs 1-8 with one
from Run 9 onward.** Groups 1, 3 and 4 are unaffected — coverage is measured upstream of the prune
(identical to the digit across Runs 9/10) and dead code does not execute.

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

> **RETRACTED 2026-09-11 — do not cite this row's dispatch figures.** That fixed-point failure was a
> MISCOMPILE (`/work/eta-fixed-point-root-cause.md`): a false-singleton `p|` stamp made `andThen`'s
> `step s` call `succeed`'s evaluator, which returns the INCOMING state, so the solver silently
> skipped demand bindings. The benchmark arm's `sat=784,353,200` is therefore the lowest number in
> this file because the compiler was not doing the work — iterated once more it SIGSEGV'd on every
> program. Run 3 is the same configuration on the fixed tree (`sat=894,855,765`); the +110 M is the
> restored unification traffic, visible per symbol as `readPointCellS` +52.6 M, `UnionFind.reprS`
> +25.6 M, `Store.loadTypeC` +11.8 M — exactly the `connectTypes` work the bug elided. The reference
> arm, which carries no stamps at all, rose +222.0 M (+7.7 %) over the same source change, so the
> extra work is a property of the fixed SOURCE, not of the stamping.

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

### Run 3 — shipping defaults, post-fix tree (2026-09-11)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, defaults | 641.1 | 14,638,208 | 2,303 | 11 | 22,870 | 15,668,282 |
| benchmark | solver+LSS, defaults | solver+LSS, defaults | 512.0 | 14,407,272 | 2,230 | 11 | 22,825 | 15,668,282 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 148,338 | 101,232 (68.24 %) | 34,625 (23.34 %) | 11,341 (7.65 %) | 1,083 (0.73 %) | 57 (0.04 %) | 91.59 % |
| benchmark | 148,338 | 101,232 (68.24 %) | 34,625 (23.34 %) | 11,341 (7.65 %) | 1,083 (0.73 %) | 57 (0.04 %) | 91.59 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,276 | 3,206 | 205 | 15 | 14,505 | 5,078 | 1,258 | 669 | 365 | 108/307/0/14 | 3,652 |
| benchmark | 18,276 | 3,206 | 205 | 15 | 14,505 | 5,078 | 1,258 | 669 | 365 | 108/307/0/14 | 3,652 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,108,682,227 | 3,020,193,143 | 88,489,084 | 0 | 3,108,682,227 | 0.00 | 97.15 | 2.85 | 7,284 |
| benchmark | 894,855,765 | 813,195,885 | 81,659,880 | 953,039,064 | 1,847,894,829 | 51.57 | 44.01 | 4.42 | 6,960 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,070,159,698 | 15,899,918,154 | 1,316,582,057 | 2,752,643,350 | 477,508,914 | 0 | 0 | 426,234 | 82.70 |
| benchmark | 12,423,189,340 | 10,804,779,989 | 1,316,288,129 | 724,424,466 | 646,967,851 | 0 | 0 | 448,556 | 94.14 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,664,154,269 | 84,439,050 | 4,050,031 | 88,489,081 vs typed 88,489,084 — 3 events |
| benchmark | 642,764,589 | 77,939,788 | 3,720,089 | 81,659,877 vs typed 81,659,880 — 3 events |

Shipping defaults on the post-fix tree (η DEFAULT-ON, `Translate`'s `Let`/`Destruct` body connect,
constructor aliases refused). This is the baseline for everything that follows: Runs 1–2 predate the
fix and no longer describe the shipped compiler. Both arms agree exactly in groups 1–2 and emit a
byte-identical 15,668,282 B artifact, which is `defA.mlir`, the verified bootstrap fixed point.
Against Run 1 (η on but miscompiling — different source, so attribute with care) the connect fix puts
real sets in front of the stamper: `blocked` 1,371 → 5,078, `stampedPapGlobal` 2,577 → 3,206, coverage
91.74 → 91.59 %.

### Run 4 — defaults + `preMono=1` (2026-09-11)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `preMono=1` | 632.7 | 12,623,584 | 2,308 | 11 | 22,923 | 15,588,695 |
| benchmark | solver+LSS, `preMono=1` | solver+LSS, `preMono=1` | 523.3 | 14,493,316 | 2,235 | 11 | 22,912 | 15,588,695 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,634 | 100,724 (68.23 %) | 34,436 (23.33 %) | 11,340 (7.68 %) | 1,077 (0.73 %) | 57 (0.04 %) | 91.55 % |
| benchmark | 147,634 | 100,724 (68.23 %) | 34,436 (23.33 %) | 11,340 (7.68 %) | 1,077 (0.73 %) | 57 (0.04 %) | 91.55 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,280 | 3,228 | 205 | 15 | 14,431 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |
| benchmark | 18,280 | 3,228 | 205 | 15 | 14,431 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,117,965,995 | 3,029,714,582 | 88,251,413 | 0 | 3,117,965,995 | 0.00 | 97.17 | 2.83 | 7,334 |
| benchmark | 896,811,962 | 815,407,211 | 81,404,751 | 955,824,012 | 1,852,635,974 | 51.59 | 44.01 | 4.39 | 7,005 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,099,210,170 | 15,928,379,445 | 1,322,876,210 | 2,760,877,307 | 478,605,371 | 0 | 0 | 426,234 | 82.70 |
| benchmark | 12,449,914,433 | 10,815,384,911 | 1,322,546,371 | 725,784,409 | 648,278,889 | 0 | 0 | 449,691 | 94.15 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,672,625,897 | 84,242,745 | 4,008,665 | 88,251,410 vs typed 88,251,413 — 3 events |
| benchmark | 644,379,661 | 77,726,024 | 3,678,724 | 81,404,748 vs typed 81,404,751 — 3 events |

Defaults plus `ECO_INLINE_PRE_MONO=1`, same tree as Run 3, so the two runs are same-source and the A/B
is clean. `preMono=1` is a bootstrap fixed point of its own (`cs4-bench-out.mlir` == `preA.mlir`) and
both arms emit 15,588,695 B — 79,587 B (−0.51 %) smaller than Run 3, with 704 fewer arrow positions,
74 fewer `noInstance` and 34 fewer `blocked` declines. Priced separately under `ECO_INLINE_REPORT=1`
(a report flag perturbs groups 3–4, so it is not a row here): 13,150 pre-mono inlines take the
post-mono inliner from 67,407 to 48,819, so one pre-mono inline retires ~1.4 post-mono ones. It buys
NO dispatch: the benchmark population rises +0.26 % and generic +0.27 %, while the reference arm —
same binary, only the workload flag moved — rises +0.30 %, so the preMono-BUILT binary is
dispatch-neutral. Wall +2.2 % (benchmark) against −1.3 % (reference) — opposite signs at N=1, no wall
claim; the Run 4 reference row's lower peak RSS is the known bimodal artefact, not a preMono effect.

### Run 5 — shipping defaults spelled out: `eta=1 preMono=1` (2026-09-12)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `eta=1 preMono=1` | 642.5 | 14,678,840 | 2,308 | 11 | 22,923 | 15,588,695 |
| benchmark | solver+LSS, `eta=1 preMono=1` | solver+LSS, `eta=1 preMono=1` | 515.0 | 14,501,920 | 2,235 | 11 | 22,912 | 15,588,695 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,634 | 100,724 (68.23 %) | 34,436 (23.33 %) | 11,340 (7.68 %) | 1,077 (0.73 %) | 57 (0.04 %) | 91.55 % |
| benchmark | 147,634 | 100,724 (68.23 %) | 34,436 (23.33 %) | 11,340 (7.68 %) | 1,077 (0.73 %) | 57 (0.04 %) | 91.55 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,280 | 3,228 | 205 | 15 | 14,431 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |
| benchmark | 18,280 | 3,228 | 205 | 15 | 14,431 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,117,966,009 | 3,029,714,591 | 88,251,418 | 0 | 3,117,966,009 | 0.00 | 97.17 | 2.83 | 7,334 |
| benchmark | 896,812,039 | 815,407,282 | 81,404,757 | 955,824,021 | 1,852,636,060 | 51.59 | 44.01 | 4.39 | 7,034 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,099,212,121 | 15,928,379,652 | 1,322,878,000 | 2,760,877,321 | 478,605,373 | 0 | 0 | 426,234 | 82.70 |
| benchmark | 12,449,916,439 | 10,815,385,263 | 1,322,548,198 | 725,784,461 | 648,278,926 | 0 | 0 | 449,691 | 94.15 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,672,625,906 | 84,242,747 | 4,008,668 | 88,251,415 vs typed 88,251,418 — 3 events |
| benchmark | 644,379,707 | 77,726,030 | 3,678,724 | 81,404,754 vs typed 81,404,757 — 3 events |

The SHIPPING configuration on the current tree, spelled out: solver + LSS + η + preMono, both flags
now default-on. Read this row as the baseline, and Run 6 as its η A/B. Everything agrees: the arms
emit a byte-identical 15,588,695 B, that artifact is the `.mlir` the benchmark compiler was itself
built from (bootstrap fixed point), and the older subst reference binary — built before the preMono
flip — reproduces it exactly once the flags are passed explicitly, which is the workload-invariance
check at its strongest.

### Run 6 — same tree, `eta=0` — the honest η A/B (2026-09-12)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `eta=0 preMono=1` | 643.7 | 14,433,848 | 2,315 | 11 | 22,751 | 15,790,230 |
| benchmark | solver+LSS, `eta=0 preMono=1` | solver+LSS, `eta=0 preMono=1` | 548.5 | 14,267,528 | 2,306 | 11 | 22,649 | 15,790,230 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,662 | 100,726 (68.21 %) | 33,674 (22.80 %) | 11,942 (8.09 %) | 1,179 (0.80 %) | 141 (0.10 %) | 91.02 % |
| benchmark | 147,662 | 100,726 (68.21 %) | 33,674 (22.80 %) | 11,942 (8.09 %) | 1,179 (0.80 %) | 141 (0.10 %) | 91.02 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,870 | 2,225 | 685 | 3 | 14,266 | 6,598 | 1,263 | 697 | 365 | 7/305/0/75 | 3,754 |
| benchmark | 17,870 | 2,225 | 685 | 3 | 14,266 | 6,598 | 1,263 | 697 | 365 | 7/305/0/75 | 3,754 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,143,530,580 | 3,056,240,803 | 87,289,777 | 0 | 3,143,530,580 | 0.00 | 97.22 | 2.78 | 7,267 |
| benchmark | 1,123,071,873 | 1,040,201,434 | 82,870,439 | 1,044,982,029 | 2,168,053,902 | 48.20 | 47.98 | 3.82 | 7,598 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,140,898,722 | 16,017,763,415 | 1,340,439,058 | 2,784,996,210 | 479,221,066 | 0 | 0 | 426,234 | 82.64 |
| benchmark | 12,540,817,438 | 11,482,322,170 | 1,340,109,115 | 910,244,127 | 774,296,037 | 0 | 0 | 457,172 | 92.88 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,697,706,436 | 83,233,865 | 4,055,909 | 87,289,774 vs typed 87,289,777 — 3 events |
| benchmark | 827,373,691 | 79,144,772 | 3,725,664 | 82,870,436 vs typed 82,870,439 — 3 events |

The same tree with `ECO_INLINE_ETA_EXPAND=0` — the honest η A/B, and the row Runs 1–2 could not
provide (both predate the LSS connect fix, and Run 1's compiler was miscompiling). η is worth
**−226,259,834 dispatches (−20.15 %) and −224,794,152 generic (−21.61 %)** on the benchmark arm,
−201,535 B (−1.28 %) of artifact and 548.5 → 515.0 s of wall. The reference arm — same binary, only
the workload flag moved — falls just −0.81 %, so ~19.3 of those 20.15 points are the η-BUILT binary
dispatching better rather than η making the compile cheaper. Run 1's retracted −21.4 % was therefore
a real η win sitting on a floor that the miscompile had pushed ~112 M too low.

### Run 7 — defaults, `preserveSets` OFF (2026-09-12)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, defaults (`psets=0`) | 606.4 | 14,534,004 | 2,250 | 11 | 22,856 | 15,594,595 |
| benchmark | solver+LSS, defaults (`psets=0`) | solver+LSS, defaults (`psets=0`) | 517.3 | 14,543,236 | 2,245 | 10 | 22,926 | 15,594,595 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,938 | 100,763 (68.11 %) | 34,457 (23.29 %) | 11,582 (7.83 %) | 1,079 (0.73 %) | 57 (0.04 %) | 91.40 % |
| benchmark | 147,938 | 100,763 (68.11 %) | 34,457 (23.29 %) | 11,582 (7.83 %) | 1,079 (0.73 %) | 57 (0.04 %) | 91.40 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,284 | 3,228 | 205 | 15 | 14,434 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |
| benchmark | 18,284 | 3,228 | 205 | 15 | 14,434 | 5,044 | 1,257 | 669 | 365 | 108/307/0/14 | 3,652 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,812,561,920 | 2,726,486,373 | 86,075,547 | 0 | 2,812,561,920 | 0.00 | 96.94 | 3.06 | 6,798 |
| benchmark | 898,228,272 | 816,650,903 | 81,577,369 | 958,086,598 | 1,856,314,870 | 51.61 | 43.99 | 4.39 | 7,037 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,076,022,902 | 15,437,680,949 | 1,324,213,675 | 2,595,630,545 | 400,044,492 | 0 | 0 | 424,272 | 84.03 |
| benchmark | 12,473,820,288 | 10,834,406,102 | 1,323,919,705 | 726,984,387 | 649,467,023 | 0 | 0 | 449,969 | 94.15 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,509,555,001 | 82,060,465 | 4,015,079 | 86,075,544 vs typed 86,075,547 — 3 events |
| benchmark | 645,407,021 | 77,892,235 | 3,685,131 | 81,577,366 vs typed 81,577,369 — 3 events |

The `preserveSets` A/B's OFF arm, and the first row measured on a tree where η, the pre-mono
inliner and the LSS connect fix have all shipped. Note the reference compiler is rebuilt from this
tree: the older `eco-std4-census` predates both the `preMono` flip and the flag itself, so under
bare defaults it silently ran a different workload and ignored `ECO_INLINE_PRESERVE_SETS`
entirely — a reference binary must be able to honour every flag the run names.

### Run 8 — defaults + `preserveSets=1` (2026-09-12)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `psets=1` | 613.8 | 14,539,644 | 2,250 | 11 | 22,860 | 15,449,374 |
| benchmark | solver+LSS, `psets=1` | solver+LSS, `psets=1` | 521.6 | 14,648,732 | 2,245 | 11 | 22,940 | 15,449,374 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 147,938 | 100,763 (68.11 %) | 34,457 (23.29 %) | 11,582 (7.83 %) | 1,079 (0.73 %) | 57 (0.04 %) | 91.40 % |
| benchmark | 147,938 | 100,763 (68.11 %) | 34,457 (23.29 %) | 11,582 (7.83 %) | 1,079 (0.73 %) | 57 (0.04 %) | 91.40 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,088 | 3,719 | 204 | 15 | 14,609 | 4,084 | 1,257 | 695 | 365 | 108/307/0/14 | 3,652 |
| benchmark | 18,088 | 3,719 | 204 | 15 | 14,609 | 4,084 | 1,257 | 695 | 365 | 108/307/0/14 | 3,652 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,812,911,613 | 2,726,912,200 | 85,999,413 | 0 | 2,812,911,613 | 0.00 | 96.94 | 3.06 | 6,770 |
| benchmark | 835,397,548 | 783,918,852 | 51,478,696 | 1,021,066,066 | 1,856,463,614 | 55.00 | 42.23 | 2.77 | 6,936 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,074,418,750 | 15,433,974,877 | 1,323,838,950 | 2,596,015,314 | 400,013,385 | 0 | 0 | 424,272 | 84.03 |
| benchmark | 12,508,076,570 | 10,704,738,157 | 1,323,544,986 | 664,188,739 | 634,597,780 | 0 | 0 | 449,696 | 94.54 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,510,015,904 | 81,997,549 | 4,001,861 | 85,999,410 vs typed 85,999,413 — 3 events |
| benchmark | 612,710,046 | 47,806,780 | 3,671,913 | 51,478,693 vs typed 51,478,696 — 3 events |

`ECO_INLINE_PRESERVE_SETS=1`: the post-mono inliner declines the one reshape that clears an LSS
member, leaving the callee's PAP in place
(plans/pre-mono-lss-transforms-02-inline-preserve-sets.md §10). NOT flat, and the mechanism is
visible end to end: `stampedPapGlobal` +491 (+15.21 %) because the surviving PAPs are stampable
`p|` members, `blocked` declines −960, and **62,830,724 dispatches (−6.99 %) move out of the
generic/typed bucket into `fast` (+62,979,468)** at a population that is flat to 0.01 % — a
conversion, not an elimination. The reference arm, same binary with only the workload flag moved,
shifts +0.01 %, so essentially ALL of it is the preserveSets-BUILT binary. `out.mlir` falls
145,221 B (−0.93 %) because each declined partial inline is one callee body not copied
(`inlined` 48,836 → 46,737), and the self-compile reshape census reads `cleared=0 bySite=`.
Coverage and positions are identical to the digit — the flag moves the inliner, not the analysis.

### Run 9 — defaults + the post-inline dead-spec prune (2026-09-13)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `prune=1` | 620.9 | 14,360,268 | 2249 | 11 | 22,990 | 13,367,419 |
| benchmark | solver+LSS, `prune=1` | solver+LSS, `prune=1` | 525.7 | 14,589,388 | 2237 | 12 | 22,841 | 13,367,419 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 148,838 | 101,254 (68.03 %) | 34,597 (23.24 %) | 11,843 (7.96 %) | 1,087 (0.73 %) | 57 (0.04 %) | 91.27 % |
| benchmark | 148,838 | 101,254 (68.03 %) | 34,597 (23.24 %) | 11,843 (7.96 %) | 1,087 (0.73 %) | 57 (0.04 %) | 91.27 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,673 | 3,251 | 204 | 12 | 10,917 | 2,418 | 1,263 | 650 | 353 | 67/310/0/9 | 1,783 |
| benchmark | 16,673 | 3,251 | 204 | 12 | 10,917 | 2,418 | 1,263 | 650 | 353 | 67/310/0/9 | 1,783 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,836,638,231 | 2,779,296,562 | 57,341,669 | 0 | 2,836,638,231 | 0.00 | 97.98 | 2.02 | 6,779 |
| benchmark | 841,170,945 | 788,053,933 | 53,117,012 | 1,020,914,791 | 1,862,085,736 | 54.83 | 42.32 | 2.85 | 7,084 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,126,848,867 | 15,451,973,964 | 1,342,247,775 | 2,619,897,819 | 389,891,836 | 0 | 0 | 425,999 | 83.97 |
| benchmark | 12,519,807,433 | 10,668,746,638 | 1,341,951,729 | 670,280,160 | 639,482,456 | 0 | 0 | 452,342 | 94.52 |

`ECO_INLINE_PRUNE_DEAD=1`, default since this run: `Prune.pruneAfterInline` runs straight after
`MonoInlineSimplify` and removes every specialization the inliner orphaned when it inlined the only
reference to one (plans/post-inline-dead-spec-prune.md §8). **`pruned=9,897 kept=33,930` — 22.6 % of
the graph was dead** — and `out.mlir` falls 15,532,506 → 13,367,419 B, **−13.94 %**.
Read group 2 against Run 10 only. Every AbiCloning figure there was counting sites in dead specs
before this pass existed, so each steps DOWN once as a correction: a stamp or a decline at a call
site nothing reaches was never worth anything. Group 1 is unmoved to the digit — coverage is
measured during monomorphization, upstream of the prune. Bootstrap fixed point B == C; E2E
1,725/1,725 with the flag on and off; flag-off emission byte-identical to the pre-change binary.

### Run 10 — the same tree with the prune OFF (2026-09-13)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `prune=0` | 618.1 | 14,619,872 | 2257 | 11 | 23,114 | 15,532,506 |
| benchmark | solver+LSS, `prune=0` | solver+LSS, `prune=0` | 529.4 | 14,682,456 | 2244 | 12 | 22,935 | 15,532,506 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 148,838 | 101,254 (68.03 %) | 34,597 (23.24 %) | 11,843 (7.96 %) | 1,087 (0.73 %) | 57 (0.04 %) | 91.27 % |
| benchmark | 148,838 | 101,254 (68.03 %) | 34,597 (23.24 %) | 11,843 (7.96 %) | 1,087 (0.73 %) | 57 (0.04 %) | 91.27 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 18,139 | 3,722 | 204 | 15 | 14,662 | 4,084 | 1,280 | 696 | 364 | 108/307/0/14 | 3,667 |
| benchmark | 18,139 | 3,722 | 204 | 15 | 14,662 | 4,084 | 1,280 | 696 | 364 | 108/307/0/14 | 3,667 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,849,654,112 | 2,791,361,696 | 58,292,416 | 0 | 2,849,654,112 | 0.00 | 97.95 | 2.05 | 6,769 |
| benchmark | 846,220,006 | 792,398,093 | 53,821,913 | 1,025,515,992 | 1,871,735,998 | 54.79 | 42.33 | 2.88 | 7,042 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,172,761,634 | 15,571,592,867 | 1,346,858,413 | 2,632,402,101 | 392,193,141 | 0 | 0 | 425,999 | 83.96 |
| benchmark | 12,566,436,246 | 10,769,869,809 | 1,346,562,330 | 674,817,647 | 642,717,495 | 0 | 0 | 452,342 | 94.51 |

`ECO_INLINE_PRUNE_DEAD=0`, the control for Run 9. The SAME two binaries do both runs, so every
difference is the workload flag.
**Dispatch is neutral.** `sat` falls 846,220,006 → 841,170,945 (−0.60 %) in the benchmark arm, but
the reference arm — same binary, only the flag moved — falls 2,849,654,112 → 2,836,638,231
(−0.46 %), so all but ≈0.14 % of it is the pass's own saved work rather than a property of the
pruned binary. `fast %` 54.79 → 54.83 and wall 529.4 → 525.7 s are noise at N=1.
**The census corrections**, every one a site in dead code: `dispatchUpgraded` 18,139 → 16,673,
`stampedPapGlobal` 3,722 → 3,251, `noInstance` 14,662 → 10,917, `blocked` 4,084 → 2,418,
`multiInstanceGroups` 3,667 → 1,783, `devirtPost.fn` 108 → 67.

---

### Run 11 — defaults, `aliasForward=0` (2026-09-14; control for Run 12)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `afwd=0` | 615.4 | 14,488,332 | 2245 | 11 | 22,844 | 13,400,752 |
| benchmark | solver+LSS, `afwd=0` | solver+LSS, `afwd=0` | 526.7 | 14,571,516 | 2252 | 11 | 22,936 | 13,400,752 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 149,391 | 101,457 (67.91 %) | 34,677 (23.21 %) | 12,111 (8.11 %) | 1,089 (0.73 %) | 57 (0.04 %) | 91.13 % |
| benchmark | 149,391 | 101,457 (67.91 %) | 34,677 (23.21 %) | 12,111 (8.11 %) | 1,089 (0.73 %) | 57 (0.04 %) | 91.13 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,723 | 3,251 | 204 | 12 | 10,922 | 2,418 | 1,267 | 650 | 353 | 67/310/0/9 | 1,784 |
| benchmark | 16,723 | 3,251 | 204 | 12 | 10,922 | 2,418 | 1,267 | 650 | 353 | 67/310/0/9 | 1,784 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,846,000,950 | 2,788,516,387 | 57,484,563 | 0 | 2,846,000,950 | 0.00 | 97.98 | 2.02 | 6,825 |
| benchmark | 843,527,677 | 790,275,486 | 53,252,191 | 1,024,559,506 | 1,868,087,183 | 54.85 | 42.30 | 2.85 | 7,076 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,157,883,332 | 15,494,472,948 | 1,346,735,886 | 2,628,698,072 | 390,971,563 | 0 | 0 | 427,290 | 83.96 |
| benchmark | 12,548,622,690 | 10,694,441,176 | 1,346,438,461 | 672,224,167 | 641,423,893 | 0 | 0 | 453,685 | 94.52 |

Control for Run 12: the tree with `PreMono.AliasForward` present (default-off) and every other flag at
its default. **Both Runs 11 and 12 additionally carry `ECO_INLINE_REPORT=1`** (the pass's census
line is what §7 of its plan needed), uniformly across all four rows, so their walls are comparable
with each other and not with Runs 1-10. Against Run 9 (same defaults, a day-older tree): coverage
91.27 → 91.13 % and `positions` 148,838 → 149,391 are the corpus growing (this tree adds
`PreMono/AliasForward.elm` and its test), not a change in the analysis; group 2 identical to the digit
except `bodyMismatch` 1,263 → 1,267 and `multiInstanceGroups` 1,783 → 1,784.
Native seed for the reference: `bin/eco-pruneB` (Run 9's benchmark binary) emitted `afwd-std-subst.mlir`
from this tree — the JS-hosted subst self-compile hits V8's heap limit on this 15 GB box.

### Run 12 — defaults + `aliasForward=1` (2026-09-14)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `afwd=1` | 621.0 | 14,472,576 | 2242 | 11 | 22,841 | 13,342,049 |
| benchmark | solver+LSS, `afwd=1` | solver+LSS, `afwd=1` | 521.0 | 14,489,028 | 2250 | 11 | 22,883 | 13,342,049 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 148,401 | 100,600 (67.79 %) | 34,608 (23.32 %) | 12,074 (8.14 %) | 1,088 (0.73 %) | 31 (0.02 %) | 91.11 % |
| benchmark | 148,401 | 100,600 (67.79 %) | 34,608 (23.32 %) | 12,074 (8.14 %) | 1,088 (0.73 %) | 31 (0.02 %) | 91.11 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,765 | 3,356 | 206 | 12 | 9,579 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |
| benchmark | 16,765 | 3,356 | 206 | 12 | 9,579 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,847,026,669 | 2,789,843,180 | 57,183,489 | 0 | 2,847,026,669 | 0.00 | 97.99 | 2.01 | 6,799 |
| benchmark | 869,837,286 | 788,985,697 | 80,851,589 | 1,003,485,083 | 1,873,322,369 | 53.57 | 42.12 | 4.32 | 7,155 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,150,816,972 | 15,490,832,657 | 1,344,138,476 | 2,630,975,144 | 392,614,627 | 0 | 0 | 427,290 | 83.95 |
| benchmark | 12,502,695,131 | 10,744,722,205 | 1,343,840,927 | 699,576,492 | 640,962,474 | 0 | 0 | 450,194 | 94.34 |

`ECO_INLINE_ALIAS_FORWARD=1` — pre-mono alias forwarding
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md`, v1): a reference to a parameter-less alias
definition is rewritten to the same reference to its target before η-expansion. On this corpus it
forwards 15,343 calls and 1,539 values (`pre-afwd:` — `aliases=351`, of which 189 are kernel
aliases; 6,050 kernel-alias calls are KEPT because their kernel's ABI is per-occurrence, 57 because
they are under-applied). Same-source, and the reference rows are the SAME binary as Run 11's, so
every difference is the workload flag; the benchmark rows are different binaries. **Bootstrap fixed
point in both arms** (each benchmark emission byte-identical to its reference emission).
**Emission.** `out.mlir` 13,400,752 → 13,342,049 B (−0.44 %). The pre-mono inliner does 13,175 →
5,485 inlines and the post-mono one 47,127 → 28,974 (−18,153: the alias wrappers it no longer needs
to copy); post-inline prune keeps 33,988 → 32,911 specs (−1,077 retired wrappers).
**Static (group 2).** `declinedBlocked` 2,418 → 7 and `declinedNoInstance` 10,922 → 9,579: a call
through an alias CAF is an indirect site whose member's only instance is the synthetic wrapper
(blocked); forwarding makes it a direct call, so the site ceases to exist — consulted sites
35,800 → 32,212. `stampedPapGlobal` 3,251 → 3,356, `dispatchUpgraded` +42. Coverage 91.13 → 91.11 %
(`positions` −990 with the retired specs), not a precision change.
**Dispatch (group 3) — NEUTRAL on `gen`, a tier shift against on the rest.** `gen` 790,275,486 →
788,985,697 (−0.16 %); but `fast` −21,074,423 (−2.06 %) and `typed` +27,599,398 (+51.8 %), i.e.
≈1.2 % of the population moved from a stamped direct call to `eco_closure_call_saturated`
(+22,227,029 in group 4's helper row, with +27,356,864 `eco_gc_push_stack_range` — one per typed
call). The callee census names the shape: direct calls into `List_map` specs fall 49,493,259 →
13,007,767 while post-mono `partialMerges` rise 419 → 1,050 — `List.map` is being inlined at the
forwarded sites and the callback inside the inlined loop is invoked as a typed closure call rather
than the `fast` stamp it had in the `List_map` spec. Attribution to a site needs the per-`fp`
dispatch rows symbolized, which this run did not anchor. The reference arm (same binary, flag
only) moves `sat` +0.04 %: the pass's own work is free.
**Wall FLAT:** benchmark 526.7 → 521.0 s (−1.1 %), reference 615.4 → 621.0 s (+0.9 %), N=1, under
the 3 % bar. **Verdict:** not a dispatch win on the arc's counter — the static declines it removes
were not dynamic weight (the site-count-vs-weight trap, again) and the `fast → typed` shift is
small but real. The flag stays DEFAULT-OFF pending that shift's attribution.

---

### Run 12a — `aliasForward=1` with post-mono inlining of `List.map`/`List.foldr` blacklisted (2026-09-14; the attribution arm for Run 12's `fast → typed` shift)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` (Run 11/12's binary) | solver+LSS, `afwd=1`, `bl=List.map,List.foldr` | 617.2 | — | — | — | — | 13,450,845 |
| benchmark | solver+LSS, `afwd=1`, `bl=…` | same | 517.9 | — | — | — | — | 13,450,845 |

**3. dispatch-stats** (the only group this arm exists for; groups 1/2/4 in `call-stats.tsv` rows `cs12a-*`)

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,846,709,395 | 2,789,669,307 | 57,040,088 | 0 | 2,846,709,395 | 0.00 | 98.00 | 2.00 | — |
| benchmark | 849,847,497 | 791,926,755 | 57,920,742 | 1,023,107,372 | 1,872,954,869 | 54.63 | 42.28 | 3.09 | — |

Same binaries and flags as Run 12 plus `--config` with `inline.blacklist = ["List.map", "List.foldr"]`
(post-mono inliner only; the `bl=` hash token keeps it cache-disjoint). Bootstrap fixed point holds.
**It recovers the shift:** against Run 12, `fast` 1,003,485,083 → **1,023,107,372** (+19.6 M of the
21.1 M lost; Run 11: 1,024,559,506), `typed` 80,851,589 → **57,920,742** (Run 11: 53,252,191),
`eco_closure_call_saturated` 70.7 M → 48.2 M (Run 11: 48.5 M), `gen` +0.37 % (791.9 M — the
un-inlined `List_map` specs cost a few million generic calls of their own). `List_map` specs in the
emission: 895 (Run 11) / 230 (Run 12) / **892** (this arm); the `Canonical.typeEncoderS` site's map
lambda is `singleton_fast` again with `_pap_prefix = 1`. So ≈93 % of Run 12's `fast → typed` shift
is the post-mono inliner inlining `List.map`/`foldr` at sites whose callback was stamped inside the
keyed spec; the residual ≈4.7 M `typed` is the same effect at other HOFs that crossed the budget
(`Tuple.mapSecond`, `Basics.composeL`, `Dict.foldr`, …) and were not blacklisted. The blacklist is
the attribution instrument, not the fix: it also blocks the `map`/`foldr` inlines Run 11 performed
(`out.mlir` +0.37 % vs Run 11), which a stamp-aware guard would keep. Mechanism and evidence:
`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §7.1.

---

### Run 13 — defaults on the CGEN_080-fixed compiler, `aliasForward=0` (2026-09-14)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` (this tree, CGEN_080 fix) | solver+LSS, `afwd=0` | 611.2 | 14,521,632 | 2245 | 11 | 22,865 | 13,427,210 |
| benchmark | solver+LSS, `afwd=0` | solver+LSS, `afwd=0` | 525.9 | 14,552,240 | 2252 | 11 | 22,917 | 13,427,210 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 149,391 | 101,457 (67.91 %) | 34,677 (23.21 %) | 12,111 (8.11 %) | 1,089 (0.73 %) | 57 (0.04 %) | 91.13 % |
| benchmark | 149,391 | 101,457 (67.91 %) | 34,677 (23.21 %) | 12,111 (8.11 %) | 1,089 (0.73 %) | 57 (0.04 %) | 91.13 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,726 | 3,251 | 204 | 12 | 10,922 | 2,418 | 1,267 | 650 | 353 | 67/310/0/9 | 1,784 |
| benchmark | 16,726 | 3,251 | 204 | 12 | 10,922 | 2,418 | 1,267 | 650 | 353 | 67/310/0/9 | 1,784 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,846,785,989 | 2,789,300,512 | 57,485,477 | 0 | 2,846,785,989 | 0.00 | 97.98 | 2.02 | 6,799 |
| benchmark | 827,268,339 | 790,554,966 | 36,713,373 | 1,041,434,851 | 1,868,703,190 | 55.73 | 42.31 | 1.96 | 7,105 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,161,647,325 | 15,489,926,657 | 1,347,022,677 | 2,629,400,585 | 391,098,558 | 0 | 0 | 427,301 | 83.96 |
| benchmark | 12,552,368,296 | 10,655,701,814 | 1,346,725,326 | 655,896,982 | 647,149,917 | 0 | 0 | 452,934 | 94.62 |

The CGEN_080 emission fix (`Expr.generateCall` consults the AbiCloning stamp on the
`CallDirectKnownSegmentation` single-stage-saturated branch for closure-valued callees;
`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §7.2) at the DEFAULT flags — the control
for Run 14 and the fix's own A/B against Run 11 (same source apart from the fix's own arm, same
flags, same seed). Static groups 1/2 are identical to Run 11 to the digit (`dispatchUpgraded` +3 =
the fix's code in the corpus): the fix is emission-only. Emission: `singleton_fast` 12,559 →
15,225 (+2,666), `direct_known_segmentation` 8,461 → 5,795 (−2,666), `eco.call` and `papCreate`
unchanged — zero direct calls diverted (the first cut of the fix diverted 4,691 and was narrowed
before this run). **Dispatch:** `typed` 53,252,191 → **36,713,373 (−31 %)**, `fast` +16,875,345,
`gen` +0.04 % (noise), `eco_closure_call_saturated` −14.8 M, runtime calls −38.7 M (one GC
stack-range push per typed call). Wall 526.7 → 525.9 s, flat. Bootstrap fixed point holds. Both
arms carry `ECO_INLINE_REPORT=1` as Runs 11/12 do.

### Run 14 — CGEN_080-fixed compiler + `aliasForward=1` (2026-09-14)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` (this tree, CGEN_080 fix) | solver+LSS, `afwd=1` | 617.6 | 14,504,896 | 2242 | 11 | 22,865 | 13,379,444 |
| benchmark | solver+LSS, `afwd=1` | solver+LSS, `afwd=1` | 520.7 | 14,551,076 | 2251 | 11 | 22,955 | 13,379,444 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 148,401 | 100,600 (67.79 %) | 34,608 (23.32 %) | 12,074 (8.14 %) | 1,088 (0.73 %) | 31 (0.02 %) | 91.11 % |
| benchmark | 148,401 | 100,600 (67.79 %) | 34,608 (23.32 %) | 12,074 (8.14 %) | 1,088 (0.73 %) | 31 (0.02 %) | 91.11 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,768 | 3,356 | 206 | 12 | 9,579 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |
| benchmark | 16,768 | 3,356 | 206 | 12 | 9,579 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,847,844,768 | 2,790,660,359 | 57,184,409 | 0 | 2,847,844,768 | 0.00 | 97.99 | 2.01 | 6,799 |
| benchmark | 827,582,838 | 789,273,265 | 38,309,573 | 1,046,384,077 | 1,873,966,915 | 55.84 | 42.12 | 2.04 | 7,126 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,154,673,488 | 15,487,413,337 | 1,344,436,624 | 2,631,707,619 | 392,744,035 | 0 | 0 | 427,301 | 83.95 |
| benchmark | 12,506,586,893 | 10,655,051,892 | 1,344,139,038 | 657,251,158 | 648,504,715 | 0 | 0 | 449,172 | 94.60 |

`ECO_INLINE_ALIAS_FORWARD=1` on the fixed compiler — the flip decision for pre-mono alias
forwarding, re-measured now that the emission gap it exposed is closed. Same binaries' seed and
flags as Run 13; static groups identical to Run 12 to the digit (`dispatchUpgraded` +3).
**Against Run 13 (the only comparison that decides the flip):** `gen` 790,554,966 → **789,273,265
(−0.16 %)**, `fast` +4,949,226, `typed` +1,596,200 (the residual of what was +27.6 M in Run 12 vs
11), `elm` direct calls −45.8 M (the inlined `List.map`/`foldr` specs), wall 525.9 → 520.7 s
(−1.0 %, noise), `out.mlir` −47,766 B (−0.36 %), specs kept 33,988 → 32,911, post-mono inlines
47,127 → 28,974. **Against Run 12 (the fix under forwarding):** `typed` −42,542,016, `fast`
+42,898,994, runtime calls −89.7 M — the forwarding arm had MORE stamped-but-typed sites than the
default arm, which is why it surfaced the gap. **Against Run 11 (both changes vs the pre-change
default):** `fast` +21.8 M, `typed` −14.9 M, `gen` −1.0 M, `out.mlir` −21,308 B. Verdict: with
CGEN_080 in place, forwarding is neutral-to-positive on every dispatch counter and negative on
nothing measured; the flip is the user's call. Bootstrap fixed point holds in both arms.
**FLIPPED DEFAULT-ON 2026-09-14** after the full `guides/bootstrap.md` chain at the new default: Gate A
1727/1727, Stage 4b JS fixed point, Gate B 893/895 (the two are AOT-harness gaps — FLAGS directive
and port echo unimplemented in `aot_e2e_main.cpp` — and reproduce with the flag off), Stage 8c
`eco-compiler-boot == eco-compiler-boot-2` byte-identical, Stage 9b self-compile OK. The bootstrapped
artifact is this row's emission plus the flipped `Config.default` literal (a 4-line diff).

---

## Summary

Run 1's rows come from a MISCOMPILING benchmark binary (see the retraction under that run) and
are kept only so the arc is auditable. Run 3 is the shipping configuration.

| Run | State | Compiler | Wall (s) | Minor GC | Major GC | Promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 598.2 | 2131 | 11 | 22472 | 15654810 |
| 1 | eta=1 | benchmark | 496.1 | 2062 | 11 | 22518 | 15665163 |
| 2 | eta=0 | reference | 607.7 | 2147 | 11 | 22269 | 15816680 |
| 2 | eta=0 | benchmark | 520.7 | 2136 | 11 | 22284 | 15816680 |
| 3 | defaults | reference | 641.1 | 2303 | 11 | 22870 | 15668282 |
| 3 | defaults | benchmark | 512.0 | 2230 | 11 | 22825 | 15668282 |
| 4 | preMono=1 | reference | 632.7 | 2308 | 11 | 22923 | 15588695 |
| 4 | preMono=1 | benchmark | 523.3 | 2235 | 11 | 22912 | 15588695 |
| 5 | eta=1 preMono=1 | reference | 642.5 | 2308 | 11 | 22923 | 15588695 |
| 5 | eta=1 preMono=1 | benchmark | 515.0 | 2235 | 11 | 22912 | 15588695 |
| 6 | eta=0 preMono=1 | reference | 643.7 | 2315 | 11 | 22751 | 15790230 |
| 6 | eta=0 preMono=1 | benchmark | 548.5 | 2306 | 11 | 22649 | 15790230 |
| 7 | psets=0 | reference | 606.4 | 2250 | 11 | 22856 | 15594595 |
| 7 | psets=0 | benchmark | 517.3 | 2245 | 10 | 22926 | 15594595 |
| 8 | psets=1 | reference | 613.8 | 2250 | 11 | 22860 | 15449374 |
| 8 | psets=1 | benchmark | 521.6 | 2245 | 11 | 22940 | 15449374 |
| 9 | prune=1 | reference | 620.9 | 2249 | 11 | 22990 | 13367419 |
| 9 | prune=1 | benchmark | 525.7 | 2237 | 12 | 22841 | 13367419 |
| 10 | prune=0 | reference | 618.1 | 2257 | 11 | 23114 | 15532506 |
| 10 | prune=0 | benchmark | 529.4 | 2244 | 12 | 22935 | 15532506 |

### 1. lss-coverage

| Run | State | Compiler | positions | k1 | kN | var | top | part | coverage % |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 147818 | 101099 | 34501 | 11107 | 1071 | 40 | 91.73 |
| 1 | eta=1 | benchmark | 147871 | 101132 | 34521 | 11107 | 1071 | 40 | 91.74 |
| 2 | eta=0 | reference | 147858 | 101215 | 33714 | 11625 | 1161 | 143 | 91.26 |
| 2 | eta=0 | benchmark | 147858 | 101215 | 33714 | 11625 | 1161 | 143 | 91.26 |
| 3 | defaults | reference | 148338 | 101232 | 34625 | 11341 | 1083 | 57 | 91.59 |
| 3 | defaults | benchmark | 148338 | 101232 | 34625 | 11341 | 1083 | 57 | 91.59 |
| 4 | preMono=1 | reference | 147634 | 100724 | 34436 | 11340 | 1077 | 57 | 91.55 |
| 4 | preMono=1 | benchmark | 147634 | 100724 | 34436 | 11340 | 1077 | 57 | 91.55 |
| 5 | eta=1 preMono=1 | reference | 147634 | 100724 | 34436 | 11340 | 1077 | 57 | 91.55 |
| 5 | eta=1 preMono=1 | benchmark | 147634 | 100724 | 34436 | 11340 | 1077 | 57 | 91.55 |
| 6 | eta=0 preMono=1 | reference | 147662 | 100726 | 33674 | 11942 | 1179 | 141 | 91.02 |
| 6 | eta=0 preMono=1 | benchmark | 147662 | 100726 | 33674 | 11942 | 1179 | 141 | 91.02 |
| 7 | psets=0 | reference | 147938 | 100763 | 34457 | 11582 | 1079 | 57 | 91.40 |
| 7 | psets=0 | benchmark | 147938 | 100763 | 34457 | 11582 | 1079 | 57 | 91.40 |
| 8 | psets=1 | reference | 147938 | 100763 | 34457 | 11582 | 1079 | 57 | 91.40 |
| 8 | psets=1 | benchmark | 147938 | 100763 | 34457 | 11582 | 1079 | 57 | 91.40 |
| 9 | prune=1 | reference | 148838 | 101254 | 34597 | 11843 | 1087 | 57 | 91.27 |
| 9 | prune=1 | benchmark | 148838 | 101254 | 34597 | 11843 | 1087 | 57 | 91.27 |
| 10 | prune=0 | reference | 148838 | 101254 | 34597 | 11843 | 1087 | 57 | 91.27 |
| 10 | prune=0 | benchmark | 148838 | 101254 | 34597 | 11843 | 1087 | 57 | 91.27 |
| 11 | afwd=0 | reference | 149391 | 101457 | 34677 | 12111 | 1089 | 57 | 91.13 |
| 11 | afwd=0 | benchmark | 149391 | 101457 | 34677 | 12111 | 1089 | 57 | 91.13 |
| 12 | afwd=1 | reference | 148401 | 100600 | 34608 | 12074 | 1088 | 31 | 91.11 |
| 12 | afwd=1 | benchmark | 148401 | 100600 | 34608 | 12074 | 1088 | 31 | 91.11 |
| 13 | fix afwd=0 | reference | 149391 | 101457 | 34677 | 12111 | 1089 | 57 | 91.13 |
| 13 | fix afwd=0 | benchmark | 149391 | 101457 | 34677 | 12111 | 1089 | 57 | 91.13 |
| 14 | fix afwd=1 | reference | 148401 | 100600 | 34608 | 12074 | 1088 | 31 | 91.11 |
| 14 | fix afwd=1 | benchmark | 148401 | 100600 | 34608 | 12074 | 1088 | 31 | 91.11 |

### 2. lss-stamping

| Run | State | Compiler | upgraded | papGlobal | staged | papPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | dp fn | dp ctor | dp noSpec | dp ambiguous | multiInst |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 18226 | 2577 | 201 | 15 | 14553 | 1371 | 1262 | 667 | 365 | 103 | 305 | 0 | 14 | 3617 |
| 1 | eta=1 | benchmark | 18225 | 2577 | 201 | 15 | 14553 | 1371 | 1262 | 668 | 365 | 103 | 305 | 0 | 14 | 3618 |
| 2 | eta=0 | reference | 17820 | 2202 | 678 | 3 | 14327 | 6633 | 1268 | 692 | 365 | 7 | 307 | 0 | 77 | 3732 |
| 2 | eta=0 | benchmark | 17820 | 2202 | 678 | 3 | 14327 | 6633 | 1268 | 692 | 365 | 7 | 307 | 0 | 77 | 3732 |
| 3 | defaults | reference | 18276 | 3206 | 205 | 15 | 14505 | 5078 | 1258 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 3 | defaults | benchmark | 18276 | 3206 | 205 | 15 | 14505 | 5078 | 1258 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 4 | preMono=1 | reference | 18280 | 3228 | 205 | 15 | 14431 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 4 | preMono=1 | benchmark | 18280 | 3228 | 205 | 15 | 14431 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 5 | eta=1 preMono=1 | reference | 18280 | 3228 | 205 | 15 | 14431 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 5 | eta=1 preMono=1 | benchmark | 18280 | 3228 | 205 | 15 | 14431 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 6 | eta=0 preMono=1 | reference | 17870 | 2225 | 685 | 3 | 14266 | 6598 | 1263 | 697 | 365 | 7 | 305 | 0 | 75 | 3754 |
| 6 | eta=0 preMono=1 | benchmark | 17870 | 2225 | 685 | 3 | 14266 | 6598 | 1263 | 697 | 365 | 7 | 305 | 0 | 75 | 3754 |
| 7 | psets=0 | reference | 18284 | 3228 | 205 | 15 | 14434 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 7 | psets=0 | benchmark | 18284 | 3228 | 205 | 15 | 14434 | 5044 | 1257 | 669 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 8 | psets=1 | reference | 18088 | 3719 | 204 | 15 | 14609 | 4084 | 1257 | 695 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 8 | psets=1 | benchmark | 18088 | 3719 | 204 | 15 | 14609 | 4084 | 1257 | 695 | 365 | 108 | 307 | 0 | 14 | 3652 |
| 9 | prune=1 | reference | 16673 | 3251 | 204 | 12 | 10917 | 2418 | 1263 | 650 | 353 | 67 | 310 | 0 | 9 | 1783 |
| 9 | prune=1 | benchmark | 16673 | 3251 | 204 | 12 | 10917 | 2418 | 1263 | 650 | 353 | 67 | 310 | 0 | 9 | 1783 |
| 10 | prune=0 | reference | 18139 | 3722 | 204 | 15 | 14662 | 4084 | 1280 | 696 | 364 | 108 | 307 | 0 | 14 | 3667 |
| 10 | prune=0 | benchmark | 18139 | 3722 | 204 | 15 | 14662 | 4084 | 1280 | 696 | 364 | 108 | 307 | 0 | 14 | 3667 |
| 11 | afwd=0 | reference | 16723 | 3251 | 204 | 12 | 10922 | 2418 | 1267 | 650 | 353 | 67 | 310 | 0 | 9 | 1784 |
| 11 | afwd=0 | benchmark | 16723 | 3251 | 204 | 12 | 10922 | 2418 | 1267 | 650 | 353 | 67 | 310 | 0 | 9 | 1784 |
| 12 | afwd=1 | reference | 16765 | 3356 | 206 | 12 | 9579 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 12 | afwd=1 | benchmark | 16765 | 3356 | 206 | 12 | 9579 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 13 | fix afwd=0 | reference | 16726 | 3251 | 204 | 12 | 10922 | 2418 | 1267 | 650 | 353 | 67 | 310 | 0 | 9 | 1784 |
| 13 | fix afwd=0 | benchmark | 16726 | 3251 | 204 | 12 | 10922 | 2418 | 1267 | 650 | 353 | 67 | 310 | 0 | 9 | 1784 |
| 14 | fix afwd=1 | reference | 16768 | 3356 | 206 | 12 | 9579 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 14 | fix afwd=1 | benchmark | 16768 | 3356 | 206 | 12 | 9579 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |

### 3. dispatch-stats

| Run | State | Compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 2886671569 | 2797263407 | 89408162 | 0 | 2886671569 | 0.00 | 96.90 | 3.10 | 7250 |
| 1 | eta=1 | benchmark | 784353200 | 701772872 | 82580328 | 881785787 | 1666138987 | 52.92 | 42.12 | 4.96 | 6943 |
| 2 | eta=0 | reference | 2926959206 | 2839835575 | 87123631 | 0 | 2926959206 | 0.00 | 97.02 | 2.98 | 7188 |
| 2 | eta=0 | benchmark | 997989868 | 915281751 | 82708117 | 968555804 | 1966545672 | 49.25 | 46.54 | 4.21 | 7520 |
| 3 | defaults | reference | 3108682227 | 3020193143 | 88489084 | 0 | 3108682227 | 0.00 | 97.15 | 2.85 | 7284 |
| 3 | defaults | benchmark | 894855765 | 813195885 | 81659880 | 953039064 | 1847894829 | 51.57 | 44.01 | 4.42 | 6960 |
| 4 | preMono=1 | reference | 3117965995 | 3029714582 | 88251413 | 0 | 3117965995 | 0.00 | 97.17 | 2.83 | 7334 |
| 4 | preMono=1 | benchmark | 896811962 | 815407211 | 81404751 | 955824012 | 1852635974 | 51.59 | 44.01 | 4.39 | 7005 |
| 5 | eta=1 preMono=1 | reference | 3117966009 | 3029714591 | 88251418 | 0 | 3117966009 | 0.00 | 97.17 | 2.83 | 7334 |
| 5 | eta=1 preMono=1 | benchmark | 896812039 | 815407282 | 81404757 | 955824021 | 1852636060 | 51.59 | 44.01 | 4.39 | 7034 |
| 6 | eta=0 preMono=1 | reference | 3143530580 | 3056240803 | 87289777 | 0 | 3143530580 | 0.00 | 97.22 | 2.78 | 7267 |
| 6 | eta=0 preMono=1 | benchmark | 1123071873 | 1040201434 | 82870439 | 1044982029 | 2168053902 | 48.20 | 47.98 | 3.82 | 7598 |
| 7 | psets=0 | reference | 2812561920 | 2726486373 | 86075547 | 0 | 2812561920 | 0.00 | 96.94 | 3.06 | 6798 |
| 7 | psets=0 | benchmark | 898228272 | 816650903 | 81577369 | 958086598 | 1856314870 | 51.61 | 43.99 | 4.39 | 7037 |
| 8 | psets=1 | reference | 2812911613 | 2726912200 | 85999413 | 0 | 2812911613 | 0.00 | 96.94 | 3.06 | 6770 |
| 8 | psets=1 | benchmark | 835397548 | 783918852 | 51478696 | 1021066066 | 1856463614 | 55.00 | 42.23 | 2.77 | 6936 |
| 9 | prune=1 | reference | 2836638231 | 2779296562 | 57341669 | 0 | 2836638231 | 0.00 | 97.98 | 2.02 | 6779 |
| 9 | prune=1 | benchmark | 841170945 | 788053933 | 53117012 | 1020914791 | 1862085736 | 54.83 | 42.32 | 2.85 | 7084 |
| 10 | prune=0 | reference | 2849654112 | 2791361696 | 58292416 | 0 | 2849654112 | 0.00 | 97.95 | 2.05 | 6769 |
| 10 | prune=0 | benchmark | 846220006 | 792398093 | 53821913 | 1025515992 | 1871735998 | 54.79 | 42.33 | 2.88 | 7042 |
| 11 | afwd=0 | reference | 2846000950 | 2788516387 | 57484563 | 0 | 2846000950 | 0.00 | 97.98 | 2.02 | 6825 |
| 11 | afwd=0 | benchmark | 843527677 | 790275486 | 53252191 | 1024559506 | 1868087183 | 54.85 | 42.30 | 2.85 | 7076 |
| 12 | afwd=1 | reference | 2847026669 | 2789843180 | 57183489 | 0 | 2847026669 | 0.00 | 97.99 | 2.01 | 6799 |
| 12 | afwd=1 | benchmark | 869837286 | 788985697 | 80851589 | 1003485083 | 1873322369 | 53.57 | 42.12 | 4.32 | 7155 |
| 12a | afwd=1 bl=map,foldr | reference | 2846709395 | 2789669307 | 57040088 | 0 | 2846709395 | 0.00 | 98.00 | 2.00 | — |
| 12a | afwd=1 bl=map,foldr | benchmark | 849847497 | 791926755 | 57920742 | 1023107372 | 1872954869 | 54.63 | 42.28 | 3.09 | — |
| 13 | fix afwd=0 | reference | 2846785989 | 2789300512 | 57485477 | 0 | 2846785989 | 0.00 | 97.98 | 2.02 | 6799 |
| 13 | fix afwd=0 | benchmark | 827268339 | 790554966 | 36713373 | 1041434851 | 1868703190 | 55.73 | 42.31 | 1.96 | 7105 |
| 14 | fix afwd=1 | reference | 2847844768 | 2790660359 | 57184409 | 0 | 2847844768 | 0.00 | 97.99 | 2.01 | 6799 |
| 14 | fix afwd=1 | benchmark | 827582838 | 789273265 | 38309573 | 1046384077 | 1873966915 | 55.84 | 42.12 | 2.04 | 7126 |

### 4. call-census

| Run | State | Compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | eta=1 | reference | 12397337886 | 15115035870 | 1249117272 | 2567397553 | 424983636 | 0 | 0 | 425554 | 82.98 |
| 1 | eta=1 | benchmark | 11761180689 | 10244739002 | 1257847614 | 635332155 | 569760396 | 0 | 0 | 447605 | 94.54 |
| 2 | eta=0 | reference | 12484949134 | 15253474174 | 1274938486 | 2604088288 | 427063311 | 0 | 0 | 425554 | 82.90 |
| 2 | eta=0 | benchmark | 11879805582 | 10889624388 | 1274643126 | 812303959 | 690703643 | 0 | 0 | 455137 | 93.28 |
| 3 | defaults | reference | 13070159698 | 15899918154 | 1316582057 | 2752643350 | 477508914 | 0 | 0 | 426234 | 82.70 |
| 3 | defaults | benchmark | 12423189340 | 10804779989 | 1316288129 | 724424466 | 646967851 | 0 | 0 | 448556 | 94.14 |
| 4 | preMono=1 | reference | 13099210170 | 15928379445 | 1322876210 | 2760877307 | 478605371 | 0 | 0 | 426234 | 82.70 |
| 4 | preMono=1 | benchmark | 12449914433 | 10815384911 | 1322546371 | 725784409 | 648278889 | 0 | 0 | 449691 | 94.15 |
| 5 | eta=1 preMono=1 | reference | 13099212121 | 15928379652 | 1322878000 | 2760877321 | 478605373 | 0 | 0 | 426234 | 82.70 |
| 5 | eta=1 preMono=1 | benchmark | 12449916439 | 10815385263 | 1322548198 | 725784461 | 648278926 | 0 | 0 | 449691 | 94.15 |
| 6 | eta=0 preMono=1 | reference | 13140898722 | 16017763415 | 1340439058 | 2784996210 | 479221066 | 0 | 0 | 426234 | 82.64 |
| 6 | eta=0 preMono=1 | benchmark | 12540817438 | 11482322170 | 1340109115 | 910244127 | 774296037 | 0 | 0 | 457172 | 92.88 |
| 7 | psets=0 | reference | 13076022902 | 15437680949 | 1324213675 | 2595630545 | 400044492 | 0 | 0 | 424272 | 84.03 |
| 7 | psets=0 | benchmark | 12473820288 | 10834406102 | 1323919705 | 726984387 | 649467023 | 0 | 0 | 449969 | 94.15 |
| 8 | psets=1 | reference | 13074418750 | 15433974877 | 1323838950 | 2596015314 | 400013385 | 0 | 0 | 424272 | 84.03 |
| 8 | psets=1 | benchmark | 12508076570 | 10704738157 | 1323544986 | 664188739 | 634597780 | 0 | 0 | 449696 | 94.54 |
| 9 | prune=1 | reference | 13126848867 | 15451973964 | 1342247775 | 2619897819 | 389891836 | 0 | 0 | 425999 | 83.97 |
| 9 | prune=1 | benchmark | 12519807433 | 10668746638 | 1341951729 | 670280160 | 639482456 | 0 | 0 | 452342 | 94.52 |
| 10 | prune=0 | reference | 13172761634 | 15571592867 | 1346858413 | 2632402101 | 392193141 | 0 | 0 | 425999 | 83.96 |
| 10 | prune=0 | benchmark | 12566436246 | 10769869809 | 1346562330 | 674817647 | 642717495 | 0 | 0 | 452342 | 94.51 |
| 11 | afwd=0 | reference | 13157883332 | 15494472948 | 1346735886 | 2628698072 | 390971563 | 0 | 0 | 427290 | 83.96 |
| 11 | afwd=0 | benchmark | 12548622690 | 10694441176 | 1346438461 | 672224167 | 641423893 | 0 | 0 | 453685 | 94.52 |
| 12 | afwd=1 | reference | 13150816972 | 15490832657 | 1344138476 | 2630975144 | 392614627 | 0 | 0 | 427290 | 83.95 |
| 12 | afwd=1 | benchmark | 12502695131 | 10744722205 | 1343840927 | 699576492 | 640962474 | 0 | 0 | 450194 | 94.34 |
| 13 | fix afwd=0 | reference | 13161647325 | 15489926657 | 1347022677 | 2629400585 | 391098558 | 0 | 0 | 427301 | 83.96 |
| 13 | fix afwd=0 | benchmark | 12552368296 | 10655701814 | 1346725326 | 655896982 | 647149917 | 0 | 0 | 452934 | 94.62 |
| 14 | fix afwd=1 | reference | 13154673488 | 15487413337 | 1344436624 | 2631707619 | 392744035 | 0 | 0 | 427301 | 83.95 |
| 14 | fix afwd=1 | benchmark | 12506586893 | 10655051892 | 1344139038 | 657251158 | 648504715 | 0 | 0 | 449172 | 94.60 |
