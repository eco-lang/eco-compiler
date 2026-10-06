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

### Runs 15/16 — `inline.skipRefMetas` A/B (pre-mono `determines` ignores reference-node metas; 2026-09-14)

| run | compiler | workload | wall (s) | max RSS (kB) | minor | major | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 15 | reference | `srm=0` | 621.4 | 14,360,716 | 2255 | 11 | 22,981 | 13,384,421 |
| 15 | benchmark | `srm=0` | 516.8 | 14,602,936 | 2254 | 11 | 23,074 | 13,384,421 |
| 16 | reference | `srm=1` | 617.1 | 14,589,368 | 2255 | 11 | 22,980 | 13,384,418 |
| 16 | benchmark | `srm=1` | 521.7 | 14,585,708 | 2254 | 11 | 23,067 | 13,384,418 |

**1. lss-coverage**

| run | compiler | positions | `k1` | `kN` | `var` | `⊤` | partial | coverage |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 15 | benchmark | 148,753 | 100,646 (67.66 %) | 34,631 (23.28 %) | 12,355 | 1,090 | 31 | 90.94 % |
| 16 | benchmark | 148,748 | 100,641 (67.66 %) | 34,631 (23.28 %) | 12,355 | 1,090 | 31 | 90.94 % |

**3. dispatch-stats**

| run | compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 15 | reference | 2,851,302,516 | 2,794,054,238 | 57,248,278 | 0 | 2,851,302,516 | 0.00 | 97.99 | 2.01 | 6,802 |
| 15 | benchmark | 828,577,140 | 790,211,433 | 38,365,707 | 1,048,428,907 | 1,877,006,047 | 55.86 | 42.10 | 2.04 | 7,158 |
| 16 | reference | 2,851,355,963 | 2,794,109,428 | 57,246,535 | 0 | 2,851,355,963 | 0.00 | 97.99 | 2.01 | 6,803 |
| 16 | benchmark | 828,593,102 | 790,227,831 | 38,365,271 | 1,048,446,105 | 1,877,039,207 | 55.86 | 42.10 | 2.04 | 7,129 |

`plans/pre-mono-lss-transforms-05-determines-caller-binders.md` §2.5, built on its own flag. The
pre-mono inliner's `determines` stops counting the metas of reference nodes — a
`VarGlobal`/`VarKernel`/`VarCycle`/`VarEnum`/`VarBox` carries the REFERENCED global's scheme
instantiated generically, which `callSiteSubst` can never bind. Group 2 is IDENTICAL in every field
across the two arms; group 1 moves by 5 positions (`k1` 100,646 → 100,641, coverage unchanged at
90.94 %) — the retired specs of the 34 extra inlines.

**MEASURED-OUT, and the code was REMOVED on 2026-09-15** — the flag, its collector and its test are
gone; these rows are the record. Pre-mono `inlined` 5,487 → 5,521 (**+34**), `undetermined`
1,877 → 1,741, and `out.mlir` moves **3 bytes**. Dispatch: `gen` +16,398 (+0.002 %), `fast` +17,198, `typed` −436 —
noise at N=1, as an emission differing by 3 bytes must be. Bootstrap fixed point holds in both arms.

**Why the ceiling is 136 and not the 997 `undBodyOnly` sites.** The flag recovers exactly the
`undLeak` subset (`annBinders = 0` — callees whose own signature is monomorphic while their body
nodes carry variables): 136 → 0. The other 861 sit in POLYMORPHIC callees where the offending
variable is on a non-reference node, which this change does not touch. The plan's original estimate
("≈150 = 148 `undLeak` + part of body-only") was right; the 2026-09-14 recalibration to "up to 997"
was wrong.

**And the residual is cold.** The 861 survivors are `Pretty.softlines` (803), `Pretty.words` (39)
and `Pretty.a` (19) — `Pretty_*` executes **26 times in 12.5 e9 elm calls** per self-compile
(`Pretty_softline`: 1). The same holds for the sibling class this plan's §2.1 targets: the top 18
`undCallerPoly` hosts are 528 of its 664 sites and account for **17,180 of 15.19 e9 calls
(0.0001 %)** — most read zero because `MonoInlineSimplify` already eliminates them, which is also
why +34 pre-mono inlines moved 3 bytes. Site count inversely ranked to weight, for the sixth time
in this arc.

---

### Runs 17/18 — `inline.preMonoThreshold` 10 vs 25 (the pre-mono size budget, alone; 2026-09-15)

| run | compiler | workload | wall (s) | max RSS (kB) | minor | major | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 17 | reference | `preThr=10` | 623.6 | 14,307,028 | 2270 | 11 | 23,130 | 13,397,582 |
| 17 | benchmark | `preThr=10` | 524.2 | 14,715,968 | 2264 | 11 | 23,087 | 13,397,582 |
| 18 | reference | `preThr=25` | 624.7 | 14,660,724 | 2290 | 11 | 23,197 | 13,544,817 |
| 18 | benchmark | `preThr=25` | 529.5 | 14,823,340 | 2290 | 11 | 23,193 | 13,544,817 |

**1. lss-coverage**

| run | positions | `k1` | `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| 17 | 149,873 | 100,772 (67.24 %) | 34,698 (23.15 %) | 13,276 | 1,096 | 31 | 90.39 % |
| 18 | 149,685 | 99,082 (66.19 %) | 34,314 (22.92 %) | 15,111 | 1,147 | 31 | 89.12 % |

**2. lss-stamping** (upgraded / papGlobal / staged / noInstance / blocked / bodyMismatch / shape / multiInst)

| run | values |
|---|---|
| 17 | 16,780 | 3,356 | 206 | 9,589 | 7 | 1,280 | 649 | 1,736 |
| 18 | 16,919 | 3,365 | 206 | 10,033 | 7 | 1,302 | 651 | 1,730 |

**3. dispatch-stats**

| run | compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 17 | reference | 2,862,448,062 | 2,804,990,105 | 57,457,957 | 0 | 2,862,448,062 | 0.00 | 97.99 | 2.01 | 6,817 |
| 17 | benchmark | 831,798,846 | 793,246,304 | 38,552,542 | 1,055,000,137 | 1,886,798,983 | 55.91 | 42.04 | 2.04 | 7,173 |
| 18 | reference | 2,878,820,098 | 2,820,387,541 | 58,432,557 | 0 | 2,878,820,098 | 0.00 | 97.97 | 2.03 | 6,825 |
| 18 | benchmark | 838,011,871 | 799,540,041 | 38,471,830 | 1,061,749,307 | 1,899,761,178 | 55.89 | 42.09 | 2.03 | 7,207 |

The first clean A/B of a single pass's inlining budget: until the 2026-09-15 split, one `threshold`
field drove `InlineSimplify`, `MonoInlineSimplify` AND `EtaExpand`'s cheapness gate, so this
measurement was not expressible. Both arms at a bootstrap fixed point.

**The pre-mono inliner's candidate admission nearly doubles**: `overBudget` 4,811 → 3,411 (−1,400,
exactly the `11-15` + `16-25` histogram buckets), `candidates` 819 → 1,783, pre-mono `inlined`
5,497 → **10,423 (+90 %)**. Only 964 of the 1,400 newly size-eligible definitions become candidates;
the rest are caught by guards the budget had been masking — `polyKernel` 17 → **186**, `hofParam`
54 → 227, `superVar` 25 → 119. (That `polyKernel` jump is the kernel-ABI miscompile class: at the
wider budget the guard carries real weight, and `InlineSimplifyRefMetasTest` pins its input set.)

**It is a LOSS on every axis measured.** `out.mlir` 13,397,582 → **13,544,817 (+1.10 %)** for only
331 fewer specs (32,940 → 32,609) — bigger bodies copied at more sites, which is what a size budget
exists to prevent. Post-mono `inlined` 29,036 → 27,998, so the extra pre-mono work mostly REPLACES
post-mono work rather than adding to it. Dispatch: **`gen` +6,293,737 (+0.79 %)**, `sat` +0.75 %,
`fast` +0.64 % with `fast %` flat at 55.9 — i.e. the whole dispatch population grew; nothing was
converted to a better tier. Wall 524.2 → 529.5 s (+1.0 %). LSS coverage FALLS: `k1` 100,772 →
99,082 and `var` 13,276 → **15,111**, because copying a body into more call sites multiplies arrow
positions the analysis cannot pin.

**Verdict: `preMonoThreshold = 10` is not leaving anything on the table.** The 4,804 over-budget
definitions were the last unpriced population in this area, and raising the budget to admit a third
of them costs 1.1 % code size, 0.8 % more generic dispatch, 1 % wall and 1,690 singleton positions.
Keep the default. The remaining `>50` bucket (2,106 definitions) is further out of reach still.

---

### Run 19 — `inline.preMonoThreshold = 0`: the pre-mono inliner admits NOTHING (2026-09-15)

| run | compiler | workload | wall (s) | max RSS (kB) | minor | major | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 19 | reference | `preThr=0` | 616.7 | 14,612,296 | 2266 | 11 | 23,106 | 13,398,066 |
| 19 | benchmark | `preThr=0` | 530.7 | 14,746,192 | 2261 | 11 | 23,113 | 13,398,066 |

**3. dispatch-stats**

| run | compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 19 | reference | 2,855,267,188 | 2,797,647,055 | 57,620,133 | 0 | 2,855,267,188 | 0.00 | 97.98 | 2.02 | 6,794 |
| 19 | benchmark | 829,936,522 | 791,198,567 | 38,737,955 | 1,053,192,393 | 1,883,128,915 | 55.93 | 42.02 | 2.06 | 7,094 |

Third point on the `preMonoThreshold` curve, on Runs 17/18's REFERENCE COMPILER — same source, same
seed, same day, so the three are directly comparable. `0` makes every body over budget (`cost` ≥ 1
for any node), so `InlineSimplify` still walks the graph and reports its census but admits no
candidates. It is NOT `ECO_INLINE_PRE_MONO=0`, which skips the pass outright.

**The curve, benchmark arms:**

| | `preThr=0` | `preThr=10` (default) | `preThr=25` |
|---|---:|---:|---:|
| pre-mono `inlined` | **0** | 5,497 | 10,423 |
| post-mono `inlined` | **34,908** | 29,036 | 27,998 |
| specs kept | 32,947 | 32,940 | 32,609 |
| `out.mlir` | 13,398,066 | 13,397,582 | 13,544,817 |
| dispatch `gen` | **791,198,567** | 793,246,304 | 799,540,041 |
| `fast %` | 55.93 | 55.91 | 55.89 |
| wall (s) | 530.7 | 524.2 | 529.5 |
| LSS `k1` / `var` | 101,246 / 13,277 | 100,772 / 13,276 | 99,082 / 15,111 |

**The default is not a peak — it is indistinguishable from OFF, and both beat 25.** Turning the
pre-mono inliner's 5,497 inlines off costs **484 bytes** of `out.mlir` (+0.0036 %) and *lowers*
generic dispatch by 2,047,737 (−0.26 %), with `fast %` and specs kept flat. Post-mono absorbs the
work almost exactly (+5,872 inlines), which is the mechanism: at today's defaults the two inliners
are near-perfect substitutes, so moving work between them changes little except LSS coverage
(`k1` 101,246 → 100,772 — slightly BETTER with pre-mono off).

**This re-opens the evidence that shipped `preMono` default-on.** `benchmarks/call-stats.md` Run 4
justified the flip with `out.mlir −0.51 %` and NEUTRAL dispatch, measured 2026-09-11 — before item 4
existed. Alias forwarding then retired the wrapper population the pre-mono inliner was mostly
serving (its inlines fell 13,175 → 5,485 when `aliasForward` went default-on, Runs 13/14), so most
of what Run 4 measured has since been taken over by a cheaper pass that needs no copying. What
remains is worth 484 bytes and costs 0.26 % dispatch. **A `preMono` default-off re-measurement is
the obvious follow-up** — not done here, because `preMono=0` also skips the pass's graph rebuild and
so is not the same experiment as `preThr=0`.

Wall is not readable at N=1 across these three (530.7 / 524.2 / 529.5 s spans 1.2 % with no monotone
trend; the variance study in `benchmarks/lss-opt.md` Run R puts cold-run noise at about that size).

---

### Run 20 — `ECO_INLINE_PRE_MONO=0`: the pre-mono inliner SKIPPED (2026-09-15)

| run | compiler | workload | wall (s) | max RSS (kB) | minor | major | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 20 | reference | `preMono=0` | 621.7 | 14,621,512 | 2265 | 11 | 23,116 | 13,398,066 |
| 20 | benchmark | `preMono=0` | 526.2 | 14,736,704 | 2260 | 11 | 23,098 | 13,398,066 |

**3. dispatch-stats**

| run | compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20 | reference | 2,854,163,494 | 2,796,555,379 | 57,608,115 | 0 | 2,854,163,494 | 0.00 | 97.98 | 2.02 | 6,765 |
| 20 | benchmark | 829,709,242 | 790,971,287 | 38,737,955 | 1,052,614,199 | 1,882,323,441 | 55.92 | 42.02 | 2.06 | 7,059 |

Fourth and last point, on Runs 17/18's reference compiler. `ECO_INLINE_PRE_MONO=0` gates ONLY
`InlineSimplify` — `AliasForward` (slot 2) and `EtaExpand` (slot 3) are separately flagged and still
run, so this isolates the INLINER, not pre-mono optimisation.

**The whole curve, benchmark arms, one source and one seed:**

| | `preMono=0` | `preThr=0` | `preThr=10` (shipping) | `preThr=25` |
|---|---:|---:|---:|---:|
| pre-mono `inlined` | — (skipped) | 0 | 5,497 | 10,423 |
| post-mono `inlined` | 34,908 | 34,908 | 29,036 | 27,998 |
| specs kept | 32,947 | 32,947 | 32,940 | 32,609 |
| `out.mlir` | 13,398,066 | 13,398,066 | 13,397,582 | 13,544,817 |
| dispatch `gen` | **790,971,287** | 791,198,567 | 793,246,304 | 799,540,041 |
| `fast %` | 55.92 | 55.93 | 55.91 | 55.89 |
| LSS `k1` / `var` | 101,246 / 13,277 | 101,246 / 13,277 | 100,772 / 13,276 | 99,082 / 15,111 |
| wall (s) | 526.2 | 530.7 | 524.2 | 529.5 |

**`preMono=0` and `preThr=0` emit BYTE-IDENTICAL artifacts** (13,398,066 B), so the pass is a true
no-op when it admits nothing and the only difference between those two arms is its graph traversal —
worth 227,280 dispatches (0.03 %) and inside wall noise.

**The pre-mono inliner is not earning its place at today's defaults.** Against `preMono=0`, the
shipping configuration's 5,497 inlines buy **484 bytes** of artifact (−0.0036 %) and 7 fewer specs,
and cost **+2,275,017 generic dispatches (+0.29 %)**, +0.25 % `sat`, and 474 singleton positions
(`k1` 101,246 → 100,772). `fast %` is flat to two decimals across all four arms — nothing moves
between tiers anywhere on this curve. Post-mono absorbs the work one-for-one (34,908 → 29,036).

**Why Run 4's evidence no longer holds.** `preMono` was flipped default-on 2026-09-11 on `out.mlir`
−0.51 % with neutral dispatch. That measurement predates item 4: `aliasForward` (default-on
2026-09-14) retired the parameter-less alias wrappers that were this pass's main population — its
inlines fell 13,175 → 5,485 the moment forwarding shipped (Runs 13/14) — and forwarding achieves the
same end by substituting a reference instead of copying a body, so it neither grows the artifact nor
multiplies arrow positions. The inliner is now doing the residue, at a small net loss.

**FLIPPED DEFAULT-OFF 2026-09-15** after the full `guides/bootstrap.md` chain at the new default:
Gate A 1727/1727, Stage 4b JS fixed point (`eco-boot-2.js == eco-boot-3.js`, 8,570,725 B), Gate B
893/895 (the two AOT-harness gaps — `FlagsRecordTest`, `PortEchoTest` — unchanged by the flip),
Stage 5 under subst, **Stage 8c `eco-compiler-boot.mlir == eco-compiler-boot-2.mlir` BYTE-IDENTICAL**
(13,398,066 B), Stage 9b `eco → eco-2` OK. The bootstrapped artifact is this run's emission plus the
flipped `Config.default` literal alone (`arith.constant true → false`, a 4-line diff), and its size
is exactly Run 20's 13,398,066 B — so the shipped compiler IS the `preMono=0` arm measured here.
`postMono` stays default-on; `aliasForward` and `etaExpand` are unaffected (separate passes, separate
flags, both still default-on).

### Run 21 — defaults, `flowAll=0` (2026-09-15; control for Run 22)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `flowAll=0` | 622.6 | 14,725,476 | 2276 | 11 | 23,270 | 13,403,612 |
| benchmark | solver+LSS, `flowAll=0` | solver+LSS, `flowAll=0` | 530.7 | 14,785,424 | 2265 | 11 | 23,310 | 13,403,612 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 150,259 | 101,296 (67.41 %) | 34,873 (23.21 %) | 12,958 (8.62 %) | 1,101 (0.73 %) | 31 (0.02 %) | 90.62 % |
| benchmark | 150,259 | 101,296 (67.41 %) | 34,873 (23.21 %) | 12,958 (8.62 %) | 1,101 (0.73 %) | 31 (0.02 %) | 90.62 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,790 | 3,356 | 206 | 12 | 9,610 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |
| benchmark | 16,790 | 3,356 | 206 | 12 | 9,610 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,857,933,287 | 2,759,672,237 | 98,261,050 | 0 | 2,857,933,287 | 0.00 | 96.56 | 3.44 | 7,013 |
| benchmark | 827,779,417 | 788,905,892 | 38,873,525 | 1,055,314,131 | 1,883,093,548 | 56.04 | 41.89 | 2.06 | 7,006 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,202,787,029 | 15,564,125,728 | 1,343,064,242 | 2,639,663,752 | 391,103,741 | 0 | 0 | 429,285 | 83.94 |
| benchmark | 12,611,421,751 | 10,713,743,952 | 1,342,796,540 | 656,242,898 | 648,893,968 | 0 | 0 | 448,921 | 94.64 |

Control for Run 22: the tree with the `flow` sub-record (`flowConnect` moved into `lss.flow.connect`,
unchanged in meaning, JSON key, env var and `lssFC` token) and F1 (`lss.flow.all`, DEFAULT-OFF) present,
every other flag at its default. Exactly the protocol's environment
(`ECO_DISPATCH_STATS=1 ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1`, no
`ECO_INLINE_REPORT`) plus `ECO_MONO_LSS_FLOW_ALL=0`. Against Run 20: the tree moved at 10:56 the same
day (`Config.elm`, `InlineSimplify.elm` — the `preMono` default flip) and now carries the F1 code, so
`positions` 150,533 → 150,259 and `var` 13,277 → 12,958 are source drift, not analysis; group 2 moves
`dispatchUpgraded` 16,779 → 16,790 and `noInstance` 9,602 → 9,610 for the same reason. Native seed for
the reference: `bin/pmo-bench-off-census` (Run 20's benchmark binary) emitted `f1-std-subst.mlir`
(12,274,732 B) from this tree. **Bootstrap fixed point:** the benchmark emission is byte-identical to the
reference emission.

### Run 22 — defaults, `flowAll=1` (2026-09-15; F1: universal argument write-back)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `flowAll=1` | 630.9 | 14,819,268 | 2296 | 11 | 23,355 | 13,403,612 |
| benchmark | solver+LSS, `flowAll=1` | solver+LSS, `flowAll=1` | 531.0 | 14,843,368 | 2284 | 11 | 23,352 | 13,403,612 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 150,259 | 101,296 (67.41 %) | 34,873 (23.21 %) | 12,958 (8.62 %) | 1,101 (0.73 %) | 31 (0.02 %) | 90.62 % |
| benchmark | 150,259 | 101,296 (67.41 %) | 34,873 (23.21 %) | 12,958 (8.62 %) | 1,101 (0.73 %) | 31 (0.02 %) | 90.62 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 16,790 | 3,356 | 206 | 12 | 9,610 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |
| benchmark | 16,790 | 3,356 | 206 | 12 | 9,610 | 7 | 1,280 | 649 | 358 | 67/310/0/9 | 1,736 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,897,198,112 | 2,798,506,391 | 98,691,721 | 0 | 2,897,198,112 | 0.00 | 96.59 | 3.41 | 7,013 |
| benchmark | 842,487,492 | 803,613,967 | 38,873,525 | 1,067,891,481 | 1,910,378,973 | 55.90 | 42.07 | 2.03 | 6,977 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,303,632,836 | 15,699,241,647 | 1,354,566,129 | 2,676,248,139 | 397,152,696 | 0 | 0 | 429,285 | 83.86 |
| benchmark | 12,704,330,133 | 10,790,168,783 | 1,354,298,390 | 669,049,842 | 659,409,249 | 0 | 0 | 448,921 | 94.59 |

`ECO_MONO_LSS_FLOW_ALL=1` — F1, the universal argument write-back
(`plans/lss-container-payload-transport.md` §10.5/§11): `flowConnect`'s store-level write-back of a
translated argument's type into the callee's param variable, extended from lambda literals to EVERY
argument whose type carries an arrow at any depth (call results, if/case/let/field-access
expressions, containers of functions), with the consumer's `MFunction`-only guard dropped. Same
source, and the reference rows are the SAME binary as Run 21's, so every difference is the workload
flag.
**It fires and changes nothing.** `flow|connLam` 8,970 → 29,289 and `flow|connAll` 788 (30,077
write-backs vs 8,970), `flow|topCarried` 10 → 2,001, `flow|callTopFallback` 32 in both arms — and the
emission is **byte-identical to Run 21's** (all four `out.mlir` files are 13,403,612 B and `cmp`-equal),
so the two benchmark binaries are identical and both arms' bootstrap fixed points hold. Groups 1 and 2
are identical to the digit: coverage 90.62 %, `var` 12,958, `dispatchUpgraded` 16,790.
**Mechanism (verified in code, plan §11.2):** the edge F1 re-ties has been connected since
`arrowIdentity` shipped on 2026-08-25. `translate (TOpt.Call … meta)` passes the call node's own
`meta.tipe` as the inner call's `callCanType`; `unifyResultWithExpected` loads that same stamped
`Can.Type` object; `Store.loadTypeC` memoises set slots by `ArrowId` in the item-scoped
`itemAux.arrowMemo` — so the outer argument's load and the inner call's result already share every
arrow slot, and `connectParamArg` unifies a class with a zonk of itself. The GAP-2 plan's "call result
→ argument" hole was real on 2026-08-24 and closed the next day by identity, not by transport; the
`prodform|` instrument that motivated F1 read the slot BEFORE the inner call was translated.
**Dispatch (groups 3–4) — the write-back's own cost on an identical binary.** Benchmark `sat`
827,779,417 → 842,487,492 (+1.78 %), `gen` +1.86 %, `fast` +1.19 %, `typed` IDENTICAL (38,873,525 —
the extra work is entirely in the analysis's own calls); reference `sat` +1.37 %. Group 4 `helper`
+12,806,944 and `cap` +10,515,281 on the benchmark row, `sites` unchanged at 448,921 (same binary).
**Wall:** reference 622.6 → 630.9 s (+1.3 %), benchmark 530.7 → 531.0 s (flat); RSS +0.4 %/+0.6 %;
minor GC +20/+19. **Verdict: NULL under the completeness metric** — zero positions move — at a
measurable analysis cost. The flag stays DEFAULT-OFF as the measured record; F2/F3 in the plan must
be re-sized from a post-translation read before either is built (plan §11.5).

### Run 23 — defaults with the §12.10 series forced OFF (2026-09-16; control for Run 24)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, §12.10 series OFF | 664.7 | 14,848,000 | 2408 | 10 | 25,463 | 13,562,125 |
| benchmark | solver+LSS, §12.10 series OFF | solver+LSS, §12.10 series OFF | 596.7 | 14,817,020 | 2402 | 11 | 25,457 | 13,562,125 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 151,642 | 115,949 (76.46 %) | 34,068 (22.47 %) | 893 (0.59 %) | 700 (0.46 %) | 32 (0.02 %) | 98.93 % |
| benchmark | 151,642 | 115,949 (76.46 %) | 34,068 (22.47 %) | 893 (0.59 %) | 700 (0.46 %) | 32 (0.02 %) | 98.93 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,505 | 3,361 | 209 | 12 | 9,799 | 7 | 1,481 | 529 | 356 | 65/319/0/0 | 1,757 |
| benchmark | 17,505 | 3,361 | 209 | 12 | 9,799 | 7 | 1,481 | 529 | 356 | 65/319/0/0 | 1,757 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,998,396,130 | 2,895,987,713 | 102,408,417 | 0 | 2,998,396,130 | 0.00 | 96.58 | 3.42 | 7,048 |
| benchmark | 911,061,173 | 870,177,392 | 40,883,781 | 1,079,644,889 | 1,990,706,062 | 54.23 | 43.71 | 2.05 | 7,058 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 14,005,724,983 | 16,360,128,850 | 1,401,893,788 | 2,765,450,253 | 410,705,011 | 0 | 0 | 434,152 | 84.07 |
| benchmark | 13,400,589,939 | 11,370,916,757 | 1,401,623,224 | 726,724,648 | 661,445,024 | 0 | 0 | 455,215 | 94.44 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,663,041,839 | 92,629,750 | 9,778,664 | 2,765,450,253 vs typed 102,408,417 |
| benchmark | 685,840,870 | 37,823,917 | 3,059,861 | 726,724,648 vs typed 40,883,781 |

Control for Run 24: the tree carrying the plans/lss-container-payload-transport.md §12.10 series (F2.c `stamp.useInjectPap`, E15 `flow.accessFlow`, F4-sig `flow.litFacts`, F3-b `flow.letOverlay` — all DEFAULT-ON as of this tree) with the four forced OFF via env (`ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT_PAP=0 ECO_MONO_LSS_FLOW_ACCESS_FLOW=0 ECO_MONO_LSS_FLOW_LIT_FACTS=0 ECO_MONO_LSS_FLOW_LET_OVERLAY=0`); F2 (`stamp.useInject`), F3-a (`flow.rowDefer`, off) and the papSuccWrite fix are as shipped. Exactly the protocol's environment otherwise. Against Run 21: the tree moved (F2 shipped, the §12.9/§12.10 code, the F3-a machinery and the census instruments), so `positions` 150,259 → 151,642, `var` 12,958 → 893 and `dispatchUpgraded` 16,790 → 17,505 are F2 + source drift — see §12.9.4's own A/B for F2's share. Native seed for the reference: `bin/pmo-bench-off-census` emitted `f6-std-subst.mlir` (12,388,807 B). **Bootstrap fixed point:** the benchmark emission is byte-identical to the reference emission (13,562,125 B).

### Run 24 — the §12.10 series ON — F2.c + E15 + F4-sig + F3-b together (2026-09-16)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, §12.10 series ON | 692.9 | 14,865,884 | 2429 | 10 | 25,655 | 13,597,442 |
| benchmark | solver+LSS, §12.10 series ON | solver+LSS, §12.10 series ON | 587.3 | 14,814,408 | 2422 | 11 | 25,671 | 13,597,442 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 151,858 | 116,147 (76.48 %) | 34,160 (22.49 %) | 851 (0.56 %) | 668 (0.44 %) | 32 (0.02 %) | 98.98 % |
| benchmark | 151,858 | 116,147 (76.48 %) | 34,160 (22.49 %) | 851 (0.56 %) | 668 (0.44 %) | 32 (0.02 %) | 98.98 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,522 | 3,370 | 209 | 12 | 9,846 | 7 | 1,536 | 517 | 356 | 65/323/0/0 | 1,778 |
| benchmark | 17,522 | 3,370 | 209 | 12 | 9,846 | 7 | 1,536 | 517 | 356 | 65/323/0/0 | 1,778 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,056,786,821 | 2,954,022,558 | 102,764,263 | 0 | 3,056,786,821 | 0.00 | 96.64 | 3.36 | 7,058 |
| benchmark | 921,082,926 | 880,097,535 | 40,985,391 | 1,101,830,413 | 2,022,913,339 | 54.47 | 43.51 | 2.03 | 7,037 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 14,155,026,289 | 16,561,633,498 | 1,429,151,071 | 2,819,314,329 | 421,478,010 | 0 | 0 | 434,152 | 83.96 |
| benchmark | 13,532,730,486 | 11,450,324,305 | 1,428,880,493 | 732,451,153 | 675,446,910 | 0 | 0 | 456,892 | 94.44 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,716,550,069 | 92,950,898 | 9,813,362 | 2,819,314,329 vs typed 102,764,263 |
| benchmark | 691,465,765 | 37,925,427 | 3,059,961 | 732,451,153 vs typed 40,985,391 |

The four §12.10 flags ON together (the new defaults): F2.c use-site `p|` members for PAP-RHS local-multis, E15 record-field access flow (+ the access-node overlay and the list-literal join), F4-sig literal points in the signature walk, F3-b let/tail-def overlay. Same source and the SAME reference binary as Run 23 (`f6-eco-std-census`), so every difference is the workload flags. **Bootstrap fixed point holds** (benchmark emission byte-identical to the reference emission, 13,597,442 B; +35,317 B / +0.26 % over Run 23 — stored demands gained members, `sites` 455,215 → 456,892).
**Completeness (group 1):** coverage 98.93 % → 98.98 % (+0.05 pp), `var` 893 → 851, `⊤` 700 → 668, k1 +198, kN +92 — the five-arm series of plan §12.10.3 to the digit (that series ran on a census-lowered binary of the same tree). **Stamping (group 2):** `dispatchUpgraded` 17,505 → 17,522 (+17), `stampedPapGlobal` 3,361 → 3,370, `noInstance` 9,799 → 9,846, `bodyMismatch` 1,481 → 1,536, `shape` 529 → 517, `multiInstanceGroups` 1,757 → 1,778 — the extra members mostly land at sites AbiCloning declines (no instance / body mismatch), not at stampable ones.
**Dispatch (group 3):** benchmark `sat` 911,061,173 → 921,082,926 (+1.10 %), `gen` +1.14 %, `fast` +2.05 %, `typed` +0.25 %; fast share 54.23 % → 54.47 % (+0.24 pp); reference `sat` +1.95 % (the analysis's own calls — 5,785 access joins, 13,443 literal points, the overlays). Group 4: `helper` +0.79 %, `cap` +2.12 %, static-target 94.44 % both. **E15's callee-form sites (`state.compileExpr expr ctx`) do not show as a dispatch move** — the +17 upgraded stamps are the whole visible effect.
**Wall:** reference 664.7 → 692.9 s (+4.2 % — the analysis cost on the unoptimized binary), benchmark 596.7 → 587.3 s (−1.6 %, within the ±2 % noise band); RSS flat (14.85 → 14.87 / 14.82 → 14.81 GB); promoted flat. **Verdict: a completeness change (+0.05 pp, var −42, ⊤ −32) that is dispatch-neutral and wall-neutral on the optimized binary, at ~4 % analysis cost on the reference. The flags stay DEFAULT-ON as shipped; the 5-arm attribution is in plan §12.10.3 (F4-sig carries the completeness gain, E15 the analysis cost).**

### Run 25 — defaults on the post-instrument-removal tree (2026-09-16; control for Run 26)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, defaults | 685.2 | 14,692,944 | 2398 | 10 | 25,284 | 13,569,895 |
| benchmark | solver+LSS, defaults | solver+LSS, defaults | 578.6 | 14,833,696 | 2392 | 10 | 25,304 | 13,569,895 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 151,650 | 116,010 (76.50 %) | 34,089 (22.48 %) | 851 (0.56 %) | 668 (0.44 %) | 32 (0.02 %) | 98.98 % |
| benchmark | 151,650 | 116,010 (76.50 %) | 34,089 (22.48 %) | 851 (0.56 %) | 668 (0.44 %) | 32 (0.02 %) | 98.98 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,495 | 3,360 | 209 | 12 | 9,839 | 7 | 1,525 | 518 | 356 | 65/323/0/0 | 1,776 |
| benchmark | 17,495 | 3,360 | 209 | 12 | 9,839 | 7 | 1,525 | 518 | 356 | 65/323/0/0 | 1,776 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,023,062,047 | 2,921,110,413 | 101,951,634 | 0 | 3,023,062,047 | 0.00 | 96.63 | 3.37 | 7,045 |
| benchmark | 908,737,616 | 868,198,925 | 40,538,691 | 1,089,868,621 | 1,998,606,237 | 54.53 | 43.44 | 2.03 | 7,054 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,962,550,641 | 16,385,040,518 | 1,414,449,520 | 2,789,833,065 | 415,381,381 | 0 | 0 | 433,084 | 83.93 |
| benchmark | 13,345,309,894 | 11,323,638,013 | 1,414,179,866 | 723,777,246 | 666,603,836 | 0 | 0 | 455,762 | 94.44 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,687,881,434 | 92,190,992 | 9,760,639 | 2,789,833,065 vs typed 101,951,634 |
| benchmark | 683,238,558 | 37,509,294 | 3,029,394 | 723,777,246 vs typed 40,538,691 |

Control for Run 26, and the first row on the tree after the §12.9/§12.10 census instruments (v3/v4 and
the F4 ones) were removed and the four §12.10 flags went default-on: exactly the protocol's environment,
`ECO_MONO_LSS_ARROW_ROOTS=0` spelled explicitly (its default). Against Run 24 the SOURCE moved (the
instruments were compiler code, so the workload shrank): `positions` 151,858 → 151,650, `out.mlir`
13,597,442 → 13,569,895 B, while `var`/`⊤`/`partial` (851/668/32) and the coverage (98.98 %) are
identical to the digit — the removal is inert on the analysis, as the recovery check measured.
Native seed for the reference: `bin/pmo-bench-off-census` emitted `f7-std-subst.mlir` (12,363,985 B).
**Bootstrap fixed point:** the benchmark emission is byte-identical to the reference emission
(13,569,895 B). Dispatch is Run 24 within noise (benchmark `sat` −1.3 %, fast share 54.47 → 54.53 %).

### Run 26 — `arrowSolverRoots = 1` (`lssAR=1`, `ECO_MONO_LSS_ARROW_ROOTS=1`) (2026-09-16)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `lssAR=1` | 669.7 | 14,824,880 | 2402 | 10 | 25,292 | 13,741,944 |
| benchmark | solver+LSS, `lssAR=1` | solver+LSS, `lssAR=1` | 584.8 | 14,853,996 | 2398 | 10 | 25,293 | 13,741,944 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 151,904 | 115,504 (76.04 %) | 34,954 (23.01 %) | 593 (0.39 %) | 820 (0.54 %) | 33 (0.02 %) | 99.05 % |
| benchmark | 151,904 | 115,504 (76.04 %) | 34,954 (23.01 %) | 593 (0.39 %) | 820 (0.54 %) | 33 (0.02 %) | 99.05 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,868 | 3,251 | 209 | 9 | 9,842 | 7 | 1,688 | 711 | 354 | 65/323/0/0 | 1,952 |
| benchmark | 17,868 | 3,251 | 209 | 9 | 9,842 | 7 | 1,688 | 711 | 354 | 65/323/0/0 | 1,952 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,034,544,032 | 2,933,399,965 | 101,144,067 | 0 | 3,034,544,032 | 0.00 | 96.67 | 3.33 | 7,047 |
| benchmark | 993,826,340 | 886,579,039 | 107,247,301 | 1,068,020,945 | 2,061,847,285 | 51.80 | 43.00 | 5.20 | 7,136 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,983,145,613 | 16,449,171,386 | 1,423,548,328 | 2,800,085,162 | 417,197,980 | 0 | 0 | 433,084 | 83.91 |
| benchmark | 13,297,299,168 | 11,584,285,123 | 1,423,279,077 | 807,838,813 | 719,623,515 | 0 | 0 | 463,376 | 93.95 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,698,941,098 | 91,422,516 | 9,721,548 | 2,800,085,162 vs typed 101,144,067 |
| benchmark | 700,591,515 | 46,493,893 | 60,753,405 | 807,838,813 vs typed 107,247,301 |

Phase 2b solver-root arrow ids (`Compiler.Eco.Config` `lss.arrowSolverRoots`, default-off since
plans/lss-unknown-elimination.md §10.9): every arrow the type checker UNIFIED shares one lambda-set slot
instead of one slot per syntactic occurrence. Same source and the SAME reference binary as Run 25
(`f7-eco-std-census`), so every difference is the flag. Both arms of Run 26 carry the flag (the benchmark
compiler is built from the reference arm's emission, then self-compiles under the same flag).
**Bootstrap fixed point holds** (13,741,944 B both arms; +172,049 B / +1.27 % over Run 25 — slot sharing
widens keyed spec keys, `sites` 455,762 → 463,376). The lowered binary runs the full workload
(`Success!` both arms), so the 2026-08-26 identity-map miscompile does not recur with `papMembers` on.
**Completeness (group 1):** coverage 98.98 % → 99.05 % (+0.07 pp) — but it is the coverage-hollow
shape: `var` 851 → 593 (−258) is bought with `⊤` 668 → 820 (+152, more conflicts once contexts share a
slot) and `k1` −506 / `kN` +865: singleton positions become multi-member sets because distinct call
contexts now pool their members. **Stamping (group 2):** `dispatchUpgraded` 17,495 → 17,868 (+373),
`stampedPapGlobal` 3,360 → 3,251 (−109), `shape` 518 → 711 (+193, `arity over` 219 → 318), `bodyMismatch`
1,525 → 1,688, `multiInstanceGroups` 1,776 → 1,952. **Dispatch (group 3):** benchmark `sat` 908.7 M →
993.8 M (+9.36 %), `typed` 40.5 M → 107.2 M (×2.65), `gen` +2.1 %, `fast` 1,089.9 M → 1,068.0 M
(−2.0 %); fast share 54.53 % → 51.80 % (−2.73 pp), population +3.2 %. The reference arm prices the
workload at `sat` +0.38 %, so the benchmark's +85 M `sat` is the BINARY losing stamps: +373 upgraded
sites are cold and the ~109 de-stamped PAP-global sites are hot — the site-count/weight inversion again.
Group 4 agrees: `helper` 723.8 M → 807.8 M (+11.6 %), `closure_call_saturated_eval` 3.0 M → 60.8 M,
`cap` +8.0 %, static-target 94.44 % → 93.95 %. **Wall:** benchmark 578.6 → 584.8 s (+1.1 %), reference
685.2 → 669.7 s (−2.3 %), both inside the ±2 % band; RSS and promoted flat. **Verdict: §10.9's
prediction confirmed and enlarged — slot sharing without a per-use set variable trades the context
sensitivity that manufactures usable singletons (−0.50 pp fast then, −2.73 pp now, on a tree whose
stamps depend on singletons far more). +0.07 pp coverage is hollow (k1 −506, ⊤ +152). The flag stays
DEFAULT-OFF; it is not a completeness lever, it is a precision-for-sharing trade.**

### Run 27 — `arrowSolverRoots = 1` + `sigRootIdentity = 0` (`lssAR=1 lssSR=0`) (2026-09-16)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, `lssAR=1 lssSR=0` | 667.5 | 14,727,508 | 2402 | 10 | 25,292 | 13,741,944 |
| benchmark | solver+LSS, `lssAR=1 lssSR=0` | solver+LSS, `lssAR=1 lssSR=0` | 574.9 | 14,820,968 | 2398 | 10 | 25,293 | 13,741,944 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 151,904 | 115,504 (76.04 %) | 34,954 (23.01 %) | 593 (0.39 %) | 820 (0.54 %) | 33 (0.02 %) | 99.05 % |
| benchmark | 151,904 | 115,504 (76.04 %) | 34,954 (23.01 %) | 593 (0.39 %) | 820 (0.54 %) | 33 (0.02 %) | 99.05 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,868 | 3,251 | 209 | 9 | 9,842 | 7 | 1,688 | 711 | 354 | 65/323/0/0 | 1,952 |
| benchmark | 17,868 | 3,251 | 209 | 9 | 9,842 | 7 | 1,688 | 711 | 354 | 65/323/0/0 | 1,952 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 3,034,544,109 | 2,933,400,036 | 101,144,073 | 0 | 3,034,544,109 | 0.00 | 96.67 | 3.33 | 7,073 |
| benchmark | 993,826,340 | 886,579,039 | 107,247,301 | 1,068,020,945 | 2,061,847,285 | 51.80 | 43.00 | 5.20 | 7,136 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,982,893,810 | 16,449,171,582 | 1,423,548,371 | 2,800,085,214 | 417,198,017 | 0 | 0 | 433,084 | 83.91 |
| benchmark | 13,297,047,310 | 11,584,285,134 | 1,423,279,083 | 807,838,813 | 719,623,517 | 0 | 0 | 463,376 | 93.95 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,698,941,144 | 91,422,522 | 9,721,548 | 2,800,085,214 vs typed 101,144,073 |
| benchmark | 700,591,515 | 46,493,893 | 60,753,405 | 807,838,813 vs typed 107,247,301 |

Run 26 with ONE change: `ECO_MONO_LSS_SIG_ROOT_ID=0` (solver-root signature identity OFF; `papMembers`
stays on — the REQUIRES note in `Compiler.Eco.Config` forbids only the other direction). Single arm, same
source and the same reference binary as Runs 25/26 (`f7-eco-std-census`). The override took: the stored
config hash of every build in the run carries `lssSR=0` alongside `lssAR=1`.
**The emission is byte-identical to Run 26's** (13,741,944 B, `cmp` clean against `f7-bench-on-out.mlir`),
so groups 1 and 2 are Run 26 to the digit and the benchmark binary is the same program: group 3 matches
Run 26 exactly (`sat` 993,826,340, `fast` 1,068,020,945, `typed` 107,247,301) and group 4 differs only by
the run-to-run noise of the workload (`sat` on the reference +77 events). **Bootstrap fixed point holds.**
**Reading:** `sigRootIdentity` is INERT under `arrowSolverRoots`. Roots (2b) make `AssignMVarIds` resolve
every solver-root slot to one shared arrow id before mono starts, so the occurrence → root memo
translation that `sigRootIdentity` applies inside the inference scratch (`Store.loadTypeC` via
`arrowRootOf`) has nothing left to merge: 2b's identification subsumes SR's. It follows that Run 26's
whole cost (fast share −2.73 pp, `k1` −506, `⊤` +152) is 2b's sharing OUTSIDE the inference scratch —
the per-occurrence, per-call-site identity that specialization needs — and cannot be recovered by
switching SR off. **Wall:** benchmark 574.9 s vs 584.8 s (Run 26) vs 578.6 s (Run 25): the three are one
population within the ±2 % band. Verdict: no separate decision; Run 26's stands, and a Run 26 arm with
SR off is not a distinct configuration.

**SHIPPED AS THE DEFAULTS 2026-09-16 (later the same day):** `arrowSolverRoots = True`,
`sigRootIdentity = False`, on the completeness-first directive. Gates on the flipped tree: elm-tests
13,568 pass / the standing 12 (LssSigFlowTest and MuTieTest pin `arrowSolverRoots = False` — the
differential-overlap rule), E2E `full` 1727/1727, `bootstrap` exit 0 with Stage 8c byte-identical
(`eco-compiler-boot` == `eco-compiler-boot-2`, 75,749,432 B; self-compile emission 13,741,944 B = this
run's), Stage 9b clean. Hash tokens now ride the other arms: `lssAR=0` / `lssSR=1`.

---

### Run 28 — the seven default-OFF LSS flags REMOVED from the compiler (2026-09-17)

| compiler | build | workload | wall (s) | max RSS (kB) | minor GC | major GC | promoted (MB) | out.mlir (B) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| reference | `ECO_MONO_ENGINE=subst` | solver+LSS, defaults | 642.1 | 14,948,864 | 2,297 | 10 | 24,026 | 13,458,106 |
| benchmark | solver+LSS, defaults | solver+LSS, defaults | 546.3 | 15,048,684 | 2,290 | 10 | 23,974 | 13,458,106 |

**1. lss-coverage**

| compiler | positions | singleton `k1` | multi `kN` | `var` | `⊤` | partial | coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| reference | 149,057 | 145,053 (97.31 %) | 2,586 (1.73 %) | 572 (0.38 %) | 813 (0.55 %) | 33 (0.02 %) | 99.05 % |
| benchmark | 149,057 | 145,053 (97.31 %) | 2,586 (1.73 %) | 572 (0.38 %) | 813 (0.55 %) | 33 (0.02 %) | 99.05 % |

**2. lss-stamping**

| compiler | dispatchUpgraded | stampedPapGlobal | stampedStaged | stampedPapPrefix | noInstance | blocked | bodyMismatch | shape | abiMismatch | devirtPost fn/ctor/noSpec/ambiguous | multiInstanceGroups |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 17,318 | 3,331 | 208 | 9 | 9,810 | 7 | 1,415 | 524 | 351 | 65/323/0/0 | 1,762 |
| benchmark | 17,318 | 3,331 | 208 | 9 | 9,810 | 7 | 1,415 | 524 | 351 | 65/323/0/0 | 1,762 |

**3. dispatch-stats**

| compiler | sat | gen | typed | fast | population | fast % | gen % | typed % | distinct |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 2,907,671,876 | 2,810,413,630 | 97,258,246 | 0 | 2,907,671,876 | 0.00 | 96.66 | 3.34 | 7,016 |
| benchmark | 929,988,224 | 836,492,291 | 93,495,933 | 1,035,778,145 | 1,965,766,369 | 52.69 | 42.55 | 4.76 | 7,006 |

**4. call-census**

| compiler | elm | runtime | kernel | helper | cap | extern | indirect | sites | static-target % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| reference | 13,359,566,318 | 15,718,765,828 | 1,374,064,809 | 2,682,996,484 | 398,696,190 | 0 | 0 | 427,610 | 83.88 |
| benchmark | 12,693,545,022 | 11,002,605,289 | 1,373,769,177 | 751,568,605 | 693,275,654 | 0 | 0 | 451,085 | 94.07 |

| compiler | helper `apply_closure_eval` | `closure_call_saturated` | `..._saturated_eval` | typed cross-check |
|---|---:|---:|---:|---|
| reference | 2,585,738,241 | 87,861,408 | 9,396,835 | 2,682,996,484 vs typed 97,258,246 |
| benchmark | 658,072,675 | 36,145,752 | 57,350,178 | 751,568,605 vs typed 93,495,933 |

**What this run is.** The tree with `spineArity`, `qSolve`, `sigRootIdentity`,
`argPoints`, `stageAnchor.rowFill`, `stageAnchor.demandFill` and
`flow.rowDefer` DELETED, along with the code they gated
(`plans/remove-default-off-lss-flags.md`). All seven shipped default-off, so no
default behaviour is intended to change — and none did: eleven fixed workloads
compile byte-identically before vs after (that plan's §6.5), E2E is 1,727/1,727,
and both bootstrap fixed points hold.

**This is a NEW BASELINE, not a comparison against Run 27.** Two independent
reasons, and they compound:

1. **The workload shrank.** The call-stats workload IS the compiler's own
   source, and this change deletes ~2 % of it — `out.mlir` 13,741,944 →
   13,458,106 B. `positions` 151,904 → 149,057 follows directly. Every absolute
   count in groups 1–4 moves for that reason alone.
2. **Run 27 predates `stamp.rootFoldDepth`** (shipped 2026-09-17, after that
   run). The `k1` 115,504 → 145,053 / `kN` 34,954 → 2,586 swing is THAT flag's
   recorded effect (`plans/lss-root-fold-depth-qualified-spine.md` §13.2: kN
   −92.6 %, k1 +32,151), not this removal's. Reading it as a flag-removal
   result would be wrong.

The ratios are the only figures that travel, and they are flat-to-slightly-up:
analysis coverage **99.05 %** (Run 27: 99.05 %), fast-dispatch share **52.69 %**
(51.80 %), static-target share **94.07 %** (93.95 %) — the last two carrying
`rootFoldDepth`, not this change.

**The internal check the protocol exists for passes exactly.** Groups 1 and 2
are identical between the two arms **to the digit** — every coverage cell, every
stamping verdict, `multiInstanceGroups` included — and both arms emit the same
`out.mlir` byte count. The workload is invariant to which binary compiles it,
which is what makes the group-3/4 difference attributable to the binary alone.

### 2026-10-06 — generic-call census (plans/staging-honesty-and-production-test-pipeline.md P0.3/P0.4)

**Not a protocol run.** The protocol above needs `ECO_MONO_LSS_REPORT=1`, which currently ABORTS
the self-compile on every binary (`FATAL: GC shadow root stack overflow`: `listFromUnboxables`
pushes one root range per boxed element, reached from `List.sortBy` on a 142,895-element list in
`renderLssReport`; ECO_MONO_LSS_CENSUS=1 the same). So this run is the benchmark arm only, with
the new `ECO_STAGING_REPORT=1` flag instead of the LSS report: binary eco-optG2c (current tree,
compiled with `ECO_STAGING_REPORT=1` so generic papExtends carry `_gencall_reason`, lowered
`ECO_GENCALL_COUNTERS=1 ECO_LSS_DISPATCH_SITE_COUNTERS=1`), self-compile solver+LSS defaults.

| dispatch-stats | sat | gen | typed | fast |
|---|---:|---:|---:|---:|
| eco-optG2c | 74,857,086 | 64,379,752 | 10,477,334 | 376,952,692 |

Generic papExtend executions by codegen reason (`[gencall-stats]`; saturating and PAP-building
alike): local-variable callee 201,242,228; join (`case`/`if` callee) 16,854,000; rest of a stamped
over-applied call 14,464,902; call result 5,301,374; record field 3,394,141; global 1,069,764;
other 8,832; cross-stage / via-applyByStages / fused / untagged 0. Static sites (`lss gencall:`):
segmentation_unknown param 12,549 / local 8,081 / field 830 / global 85 / callResult 20 / join 20 /
other 10; generic_apply param 1,827. `perf`: the generic path is ~1.8 % of cycles in self time
(`eco_apply_closure_eval` 0.85 %, `invokeSaturatedTyped` 0.74 %, `eco_pap_extend_l` 0.22 %), the
typed path 0.42 %.

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
| 11 | afwd=0 | reference | 615.4 | 2245 | 11 | 22844 | 13400752 |
| 11 | afwd=0 | benchmark | 526.7 | 2252 | 11 | 22936 | 13400752 |
| 12 | afwd=1 | reference | 621.0 | 2242 | 11 | 22841 | 13342049 |
| 12 | afwd=1 | benchmark | 521.0 | 2250 | 11 | 22883 | 13342049 |
| 12a | afwd=1 bl=map,foldr | reference | 617.2 | 2242 | 11 | 22849 | 13450845 |
| 12a | afwd=1 bl=map,foldr | benchmark | 517.9 | 2250 | 11 | 22884 | 13450845 |
| 13 | fix afwd=0 | reference | 611.2 | 2245 | 11 | 22865 | 13427210 |
| 13 | fix afwd=0 | benchmark | 525.9 | 2252 | 11 | 22917 | 13427210 |
| 14 | fix afwd=1 | reference | 617.6 | 2242 | 11 | 22865 | 13379444 |
| 14 | fix afwd=1 | benchmark | 520.7 | 2251 | 11 | 22955 | 13379444 |
| 15 | srm=0 | reference | 621.4 | 2255 | 11 | 22981 | 13384421 |
| 15 | srm=0 | benchmark | 516.8 | 2254 | 11 | 23074 | 13384421 |
| 16 | srm=1 | reference | 617.1 | 2255 | 11 | 22980 | 13384418 |
| 16 | srm=1 | benchmark | 521.7 | 2254 | 11 | 23067 | 13384418 |
| 17 | preThr=10 | reference | 623.6 | 2270 | 11 | 23130 | 13397582 |
| 17 | preThr=10 | benchmark | 524.2 | 2264 | 11 | 23087 | 13397582 |
| 18 | preThr=25 | reference | 624.7 | 2290 | 11 | 23197 | 13544817 |
| 18 | preThr=25 | benchmark | 529.5 | 2290 | 11 | 23193 | 13544817 |
| 19 | preThr=0 | reference | 616.7 | 2266 | 11 | 23106 | 13398066 |
| 19 | preThr=0 | benchmark | 530.7 | 2261 | 11 | 23113 | 13398066 |
| 20 | preMono=0 | reference | 621.7 | 2265 | 11 | 23116 | 13398066 |
| 20 | preMono=0 | benchmark | 526.2 | 2260 | 11 | 23098 | 13398066 |
| 21 | flowAll=0 | reference | 622.6 | 2276 | 11 | 23270 | 13403612 |
| 21 | flowAll=0 | benchmark | 530.7 | 2265 | 11 | 23310 | 13403612 |
| 22 | flowAll=1 | reference | 630.9 | 2296 | 11 | 23355 | 13403612 |
| 22 | flowAll=1 | benchmark | 531.0 | 2284 | 11 | 23352 | 13403612 |
| 23 | series=0 | reference | 664.7 | 2408 | 10 | 25463 | 13562125 |
| 23 | series=0 | benchmark | 596.7 | 2402 | 11 | 25457 | 13562125 |
| 24 | series=1 | reference | 692.9 | 2429 | 10 | 25655 | 13597442 |
| 24 | series=1 | benchmark | 587.3 | 2422 | 11 | 25671 | 13597442 |
| 25 | lssAR=0 | reference | 685.2 | 2398 | 10 | 25284 | 13569895 |
| 25 | lssAR=0 | benchmark | 578.6 | 2392 | 10 | 25304 | 13569895 |
| 26 | lssAR=1 | reference | 669.7 | 2402 | 10 | 25292 | 13741944 |
| 26 | lssAR=1 | benchmark | 584.8 | 2398 | 10 | 25293 | 13741944 |
| 27 | lssAR=1 lssSR=0 | reference | 667.5 | 2402 | 10 | 25292 | 13741944 |
| 27 | lssAR=1 lssSR=0 | benchmark | 574.9 | 2398 | 10 | 25293 | 13741944 |
| 28 | 7 flags removed | reference | 642.1 | 2297 | 10 | 24026 | 13458106 |
| 28 | 7 flags removed | benchmark | 546.3 | 2290 | 10 | 23974 | 13458106 |

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
| 15 | srm=0 | reference | 148753 | 100646 | 34631 | 12355 | 1090 | 31 | 90.94 |
| 15 | srm=0 | benchmark | 148753 | 100646 | 34631 | 12355 | 1090 | 31 | 90.94 |
| 16 | srm=1 | reference | 148748 | 100641 | 34631 | 12355 | 1090 | 31 | 90.94 |
| 16 | srm=1 | benchmark | 148748 | 100641 | 34631 | 12355 | 1090 | 31 | 90.94 |
| 17 | preThr=10 | reference | 149873 | 100772 | 34698 | 13276 | 1096 | 31 | 90.39 |
| 17 | preThr=10 | benchmark | 149873 | 100772 | 34698 | 13276 | 1096 | 31 | 90.39 |
| 18 | preThr=25 | reference | 149685 | 99082 | 34314 | 15111 | 1147 | 31 | 89.12 |
| 18 | preThr=25 | benchmark | 149685 | 99082 | 34314 | 15111 | 1147 | 31 | 89.12 |
| 19 | preThr=0 | reference | 150533 | 101246 | 34877 | 13277 | 1102 | 31 | 90.43 |
| 19 | preThr=0 | benchmark | 150533 | 101246 | 34877 | 13277 | 1102 | 31 | 90.43 |
| 20 | preMono=0 | reference | 150533 | 101246 | 34877 | 13277 | 1102 | 31 | 90.43 |
| 20 | preMono=0 | benchmark | 150533 | 101246 | 34877 | 13277 | 1102 | 31 | 90.43 |
| 21 | flowAll=0 | reference | 150259 | 101296 | 34873 | 12958 | 1101 | 31 | 90.62 |
| 21 | flowAll=0 | benchmark | 150259 | 101296 | 34873 | 12958 | 1101 | 31 | 90.62 |
| 22 | flowAll=1 | reference | 150259 | 101296 | 34873 | 12958 | 1101 | 31 | 90.62 |
| 22 | flowAll=1 | benchmark | 150259 | 101296 | 34873 | 12958 | 1101 | 31 | 90.62 |
| 23 | series=0 | reference | 151642 | 115949 | 34068 | 893 | 700 | 32 | 98.93 |
| 23 | series=0 | benchmark | 151642 | 115949 | 34068 | 893 | 700 | 32 | 98.93 |
| 24 | series=1 | reference | 151858 | 116147 | 34160 | 851 | 668 | 32 | 98.98 |
| 24 | series=1 | benchmark | 151858 | 116147 | 34160 | 851 | 668 | 32 | 98.98 |
| 25 | lssAR=0 | reference | 151650 | 116010 | 34089 | 851 | 668 | 32 | 98.98 |
| 25 | lssAR=0 | benchmark | 151650 | 116010 | 34089 | 851 | 668 | 32 | 98.98 |
| 26 | lssAR=1 | reference | 151904 | 115504 | 34954 | 593 | 820 | 33 | 99.05 |
| 26 | lssAR=1 | benchmark | 151904 | 115504 | 34954 | 593 | 820 | 33 | 99.05 |
| 27 | lssAR=1 lssSR=0 | reference | 151904 | 115504 | 34954 | 593 | 820 | 33 | 99.05 |
| 27 | lssAR=1 lssSR=0 | benchmark | 151904 | 115504 | 34954 | 593 | 820 | 33 | 99.05 |
| 28 | 7 flags removed | reference | 149057 | 145053 | 2586 | 572 | 813 | 33 | 99.05 |
| 28 | 7 flags removed | benchmark | 149057 | 145053 | 2586 | 572 | 813 | 33 | 99.05 |

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
| 15 | srm=0 | reference | 16772 | 3356 | 206 | 12 | 9581 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 15 | srm=0 | benchmark | 16772 | 3356 | 206 | 12 | 9581 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 16 | srm=1 | reference | 16772 | 3356 | 206 | 12 | 9581 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 16 | srm=1 | benchmark | 16772 | 3356 | 206 | 12 | 9581 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 17 | preThr=10 | reference | 16780 | 3356 | 206 | 12 | 9589 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 17 | preThr=10 | benchmark | 16780 | 3356 | 206 | 12 | 9589 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 18 | preThr=25 | reference | 16919 | 3365 | 206 | 12 | 10033 | 7 | 1302 | 651 | 358 | 67 | 310 | 0 | 9 | 1730 |
| 18 | preThr=25 | benchmark | 16919 | 3365 | 206 | 12 | 10033 | 7 | 1302 | 651 | 358 | 67 | 310 | 0 | 9 | 1730 |
| 19 | preThr=0 | reference | 16779 | 3356 | 206 | 12 | 9602 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 19 | preThr=0 | benchmark | 16779 | 3356 | 206 | 12 | 9602 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 20 | preMono=0 | reference | 16779 | 3356 | 206 | 12 | 9602 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 20 | preMono=0 | benchmark | 16779 | 3356 | 206 | 12 | 9602 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 21 | flowAll=0 | reference | 16790 | 3356 | 206 | 12 | 9610 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 21 | flowAll=0 | benchmark | 16790 | 3356 | 206 | 12 | 9610 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 22 | flowAll=1 | reference | 16790 | 3356 | 206 | 12 | 9610 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 22 | flowAll=1 | benchmark | 16790 | 3356 | 206 | 12 | 9610 | 7 | 1280 | 649 | 358 | 67 | 310 | 0 | 9 | 1736 |
| 23 | series=0 | reference | 17505 | 3361 | 209 | 12 | 9799 | 7 | 1481 | 529 | 356 | 65 | 319 | 0 | 0 | 1757 |
| 23 | series=0 | benchmark | 17505 | 3361 | 209 | 12 | 9799 | 7 | 1481 | 529 | 356 | 65 | 319 | 0 | 0 | 1757 |
| 24 | series=1 | reference | 17522 | 3370 | 209 | 12 | 9846 | 7 | 1536 | 517 | 356 | 65 | 323 | 0 | 0 | 1778 |
| 24 | series=1 | benchmark | 17522 | 3370 | 209 | 12 | 9846 | 7 | 1536 | 517 | 356 | 65 | 323 | 0 | 0 | 1778 |
| 25 | lssAR=0 | reference | 17495 | 3360 | 209 | 12 | 9839 | 7 | 1525 | 518 | 356 | 65 | 323 | 0 | 0 | 1776 |
| 25 | lssAR=0 | benchmark | 17495 | 3360 | 209 | 12 | 9839 | 7 | 1525 | 518 | 356 | 65 | 323 | 0 | 0 | 1776 |
| 26 | lssAR=1 | reference | 17868 | 3251 | 209 | 9 | 9842 | 7 | 1688 | 711 | 354 | 65 | 323 | 0 | 0 | 1952 |
| 26 | lssAR=1 | benchmark | 17868 | 3251 | 209 | 9 | 9842 | 7 | 1688 | 711 | 354 | 65 | 323 | 0 | 0 | 1952 |
| 27 | lssAR=1 lssSR=0 | reference | 17868 | 3251 | 209 | 9 | 9842 | 7 | 1688 | 711 | 354 | 65 | 323 | 0 | 0 | 1952 |
| 27 | lssAR=1 lssSR=0 | benchmark | 17868 | 3251 | 209 | 9 | 9842 | 7 | 1688 | 711 | 354 | 65 | 323 | 0 | 0 | 1952 |
| 28 | 7 flags removed | reference | 17318 | 3331 | 208 | 9 | 9810 | 7 | 1415 | 524 | 351 | 65 | 323 | 0 | 0 | 1762 |
| 28 | 7 flags removed | benchmark | 17318 | 3331 | 208 | 9 | 9810 | 7 | 1415 | 524 | 351 | 65 | 323 | 0 | 0 | 1762 |

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
| 15 | srm=0 | reference | 2851302516 | 2794054238 | 57248278 | 0 | 2851302516 | 0.00 | 97.99 | 2.01 | 6802 |
| 15 | srm=0 | benchmark | 828577140 | 790211433 | 38365707 | 1048428907 | 1877006047 | 55.86 | 42.10 | 2.04 | 7158 |
| 16 | srm=1 | reference | 2851355963 | 2794109428 | 57246535 | 0 | 2851355963 | 0.00 | 97.99 | 2.01 | 6803 |
| 16 | srm=1 | benchmark | 828593102 | 790227831 | 38365271 | 1048446105 | 1877039207 | 55.86 | 42.10 | 2.04 | 7129 |
| 17 | preThr=10 | reference | 2862448062 | 2804990105 | 57457957 | 0 | 2862448062 | 0.00 | 97.99 | 2.01 | 6817 |
| 17 | preThr=10 | benchmark | 831798846 | 793246304 | 38552542 | 1055000137 | 1886798983 | 55.91 | 42.04 | 2.04 | 7173 |
| 18 | preThr=25 | reference | 2878820098 | 2820387541 | 58432557 | 0 | 2878820098 | 0.00 | 97.97 | 2.03 | 6825 |
| 18 | preThr=25 | benchmark | 838011871 | 799540041 | 38471830 | 1061749307 | 1899761178 | 55.89 | 42.09 | 2.03 | 7207 |
| 19 | preThr=0 | reference | 2855267188 | 2797647055 | 57620133 | 0 | 2855267188 | 0.00 | 97.98 | 2.02 | 6794 |
| 19 | preThr=0 | benchmark | 829936522 | 791198567 | 38737955 | 1053192393 | 1883128915 | 55.93 | 42.02 | 2.06 | 7094 |
| 20 | preMono=0 | reference | 2854163494 | 2796555379 | 57608115 | 0 | 2854163494 | 0.00 | 97.98 | 2.02 | 6765 |
| 20 | preMono=0 | benchmark | 829709242 | 790971287 | 38737955 | 1052614199 | 1882323441 | 55.92 | 42.02 | 2.06 | 7059 |
| 21 | flowAll=0 | reference | 2857933287 | 2759672237 | 98261050 | 0 | 2857933287 | 0.00 | 96.56 | 3.44 | 7013 |
| 21 | flowAll=0 | benchmark | 827779417 | 788905892 | 38873525 | 1055314131 | 1883093548 | 56.04 | 41.89 | 2.06 | 7006 |
| 22 | flowAll=1 | reference | 2897198112 | 2798506391 | 98691721 | 0 | 2897198112 | 0.00 | 96.59 | 3.41 | 7013 |
| 22 | flowAll=1 | benchmark | 842487492 | 803613967 | 38873525 | 1067891481 | 1910378973 | 55.90 | 42.07 | 2.03 | 6977 |
| 23 | series=0 | reference | 2998396130 | 2895987713 | 102408417 | 0 | 2998396130 | 0.00 | 96.58 | 3.42 | 7048 |
| 23 | series=0 | benchmark | 911061173 | 870177392 | 40883781 | 1079644889 | 1990706062 | 54.23 | 43.71 | 2.05 | 7058 |
| 24 | series=1 | reference | 3056786821 | 2954022558 | 102764263 | 0 | 3056786821 | 0.00 | 96.64 | 3.36 | 7058 |
| 24 | series=1 | benchmark | 921082926 | 880097535 | 40985391 | 1101830413 | 2022913339 | 54.47 | 43.51 | 2.03 | 7037 |
| 25 | lssAR=0 | reference | 3023062047 | 2921110413 | 101951634 | 0 | 3023062047 | 0.00 | 96.63 | 3.37 | 7045 |
| 25 | lssAR=0 | benchmark | 908737616 | 868198925 | 40538691 | 1089868621 | 1998606237 | 54.53 | 43.44 | 2.03 | 7054 |
| 26 | lssAR=1 | reference | 3034544032 | 2933399965 | 101144067 | 0 | 3034544032 | 0.00 | 96.67 | 3.33 | 7047 |
| 26 | lssAR=1 | benchmark | 993826340 | 886579039 | 107247301 | 1068020945 | 2061847285 | 51.80 | 43.00 | 5.20 | 7136 |
| 27 | lssAR=1 lssSR=0 | reference | 3034544109 | 2933400036 | 101144073 | 0 | 3034544109 | 0.00 | 96.67 | 3.33 | 7073 |
| 27 | lssAR=1 lssSR=0 | benchmark | 993826340 | 886579039 | 107247301 | 1068020945 | 2061847285 | 51.80 | 43.00 | 5.20 | 7136 |
| 28 | 7 flags removed | reference | 2907671876 | 2810413630 | 97258246 | 0 | 2907671876 | 0.00 | 96.66 | 3.34 | 7016 |
| 28 | 7 flags removed | benchmark | 929988224 | 836492291 | 93495933 | 1035778145 | 1965766369 | 52.69 | 42.55 | 4.76 | 7006 |

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
| 15 | srm=0 | reference | 13170882300 | 15504700387 | 1345422091 | 2634901283 | 393239481 | 0 | 0 | 427521 | 83.95 |
| 15 | srm=0 | benchmark | 12522896669 | 10667271658 | 1345124410 | 658057886 | 649448333 | 0 | 0 | 449403 | 94.60 |
| 16 | srm=1 | reference | 13171095767 | 15504720238 | 1345440206 | 2634947682 | 393244300 | 0 | 0 | 427521 | 83.95 |
| 16 | srm=1 | benchmark | 12523109115 | 10667200409 | 1345142488 | 658067707 | 649455698 | 0 | 0 | 449403 | 94.60 |
| 17 | preThr=10 | reference | 13266160736 | 15578691228 | 1347756622 | 2645146835 | 394885318 | 0 | 0 | 428103 | 83.98 |
| 17 | preThr=10 | benchmark | 12618501592 | 10724952357 | 1347458811 | 660625288 | 652538123 | 0 | 0 | 449991 | 94.62 |
| 18 | preThr=25 | reference | 13348011337 | 15791117991 | 1355140267 | 2658747375 | 398380526 | 0 | 0 | 428103 | 83.99 |
| 18 | preThr=25 | benchmark | 12281539652 | 10924333544 | 1353077332 | 664273800 | 658166379 | 0 | 0 | 459021 | 94.46 |
| 19 | preThr=0 | reference | 13242614657 | 15548546673 | 1342883402 | 2638594110 | 394212223 | 0 | 0 | 428103 | 83.99 |
| 19 | preThr=0 | benchmark | 12598157403 | 10708411143 | 1342615327 | 659280628 | 651391219 | 0 | 0 | 448744 | 94.62 |
| 20 | preMono=0 | reference | 13236815686 | 15542002450 | 1342234932 | 2637545752 | 394029605 | 0 | 0 | 428103 | 83.99 |
| 20 | preMono=0 | benchmark | 12592218581 | 10703864813 | 1341966857 | 659108684 | 651251393 | 0 | 0 | 448744 | 94.62 |
| 21 | flowAll=0 | reference | 13202787029 | 15564125728 | 1343064242 | 2639663752 | 391103741 | 0 | 0 | 429285 | 83.94 |
| 21 | flowAll=0 | benchmark | 12611421751 | 10713743952 | 1342796540 | 656242898 | 648893968 | 0 | 0 | 448921 | 94.64 |
| 22 | flowAll=1 | reference | 13303632836 | 15699241647 | 1354566129 | 2676248139 | 397152696 | 0 | 0 | 429285 | 83.86 |
| 22 | flowAll=1 | benchmark | 12704330133 | 10790168783 | 1354298390 | 669049842 | 659409249 | 0 | 0 | 448921 | 94.59 |
| 23 | series=0 | reference | 14005724983 | 16360128850 | 1401893788 | 2765450253 | 410705011 | 0 | 0 | 434152 | 84.07 |
| 23 | series=0 | benchmark | 13400589939 | 11370916757 | 1401623224 | 726724648 | 661445024 | 0 | 0 | 455215 | 94.44 |
| 24 | series=1 | reference | 14155026289 | 16561633498 | 1429151071 | 2819314329 | 421478010 | 0 | 0 | 434152 | 83.96 |
| 24 | series=1 | benchmark | 13532730486 | 11450324305 | 1428880493 | 732451153 | 675446910 | 0 | 0 | 456892 | 94.44 |
| 25 | lssAR=0 | reference | 13962550641 | 16385040518 | 1414449520 | 2789833065 | 415381381 | 0 | 0 | 433084 | 83.93 |
| 25 | lssAR=0 | benchmark | 13345309894 | 11323638013 | 1414179866 | 723777246 | 666603836 | 0 | 0 | 455762 | 94.44 |
| 26 | lssAR=1 | reference | 13983145613 | 16449171386 | 1423548328 | 2800085162 | 417197980 | 0 | 0 | 433084 | 83.91 |
| 26 | lssAR=1 | benchmark | 13297299168 | 11584285123 | 1423279077 | 807838813 | 719623515 | 0 | 0 | 463376 | 93.95 |
| 27 | lssAR=1 lssSR=0 | reference | 13982893810 | 16449171582 | 1423548371 | 2800085214 | 417198017 | 0 | 0 | 433084 | 83.91 |
| 27 | lssAR=1 lssSR=0 | benchmark | 13297047310 | 11584285134 | 1423279083 | 807838813 | 719623517 | 0 | 0 | 463376 | 93.95 |
| 28 | 7 flags removed | reference | 13359566318 | 15718765828 | 1374064809 | 2682996484 | 398696190 | 0 | 0 | 427610 | 83.88 |
| 28 | 7 flags removed | benchmark | 12693545022 | 11002605289 | 1373769177 | 751568605 | 693275654 | 0 | 0 | 451085 | 94.07 |
