# LSS flag-off loop — findings

Run 2026-09-03 15:02 → 2026-09-04 03:59 on HEAD `218d1c77`. 24 iterations,
48 measured native self-compiles, no failures. Protocol in
`flag-off-lss-loop.md`; data in `benchmarks/flag-off-lss-loop.tsv`; table in
`flag-off-lss-results.md`.

## 1. The method validated itself

The last iteration is the control. With `enabled=0` — LSS entirely off — the
subst-built reference compiler and the solver-built compiler do the same work
in the same time: **5:55.84 vs 5:58.76, a gap of −2.9 s (−0.8%)**.

When there is no optimization to apply, the harness reports no difference.
Every gap above it is therefore measuring optimization, not binary provenance.

## 2. What LSS costs

Same binary, same source, LSS on vs off:

| Configuration | Wall | Minor GC | Promoted |
|---|---:|---:|---:|
| subst engine (reference build) | 5:00.30 | 1,255 | 19,227 MiB |
| solver, LSS off | 5:55.84 | 1,530 | 19,471 MiB |
| solver, LSS on (defaults) | 14:31.14 | 3,685 | 21,189 MiB |

**+8:35 of analysis, 2.45× compile time, 2.4× minor GCs.** Against subst it is
2.9×, reproducing the recorded "+8:56 native, 2.78× vs subst".

## 3. What LSS buys

**~42 s (~5%) off the compiler's own wall time.**

The ledger for this workload: **spend ~515 s of analysis to save ~42 s of
runtime — 12:1 against.** LSS does not pay for itself on the compiler.

## 4. Where the benefit actually lives

The optimized-vs-standard gap over the whole sequence:

| Flags off | Gap | Note |
|---|---:|---|
| 31 → 8 (twenty precision flags) | 37.8-53.0 s | flat, no trend |
| + `devirtFnGlobals` | 22.5 s | halves |
| + `keyedGlobals` | 28.9 s | stays depressed |
| + `keyed` | 8.7 s | nearly gone |
| + `enabled` | −2.9 s | control, zero |

**Two flags carry essentially the whole benefit: `devirtFnGlobals` and
`keyed`.** Both change *emitted code* — direct calls, specialized clones.
The twenty flags that refine *annotations* moved the gap not at all.

## 5. The twenty precision flags cost time and return nothing measurable

Removing all twenty took the standard run from 14:31.14 to 13:25.06
(**−66 s of analysis**) and the optimized run from 13:49.56 to 12:46.25
(**−63 s**) — the same magnitude, so the saving is analysis cost, and the
quality of the code produced is unchanged: the gap stayed at ~40 s throughout.

Turning them all off is, on this evidence, **strictly better for this
workload**: one minute cheaper per compile, with indistinguishable output
performance.

Flags in that group: `stageAnchor.*`, `flowConnect`, `settle.var*`,
`destrAnno`, `rsTop`, `injTotal`, `refPapSpine`, `rootFold`, `regIdentity`,
`sigRootIdentity`, `papMembers`, `refIdentity`, `arrowIdentity`,
`postSettleDevirt`, `layoutQualMembers`, `sigFlow`, `groundStandalones`,
`muTie`.

Only two showed a step above the ±8 s scatter, both single observations:
`layoutQualMembers` (−20.3 s, plausible — it carries the LSS_024 fingerprint
fence) and `keyed` on the standard side (−18.8 s, with minors −78 and
promotion −122 MiB, consistent with less spec fan-out).

`muTie` is a clean reproduction: its record says the eligible population on
the self-compile is zero, and removing it changed nothing (−3.4 s, GC flat,
no spec spiral).

## 6. Peak RSS is NOT a usable metric here

Old-gen in-use peak is **bimodal at ~8.92 GB vs ~11.0 GB**, and it flips
between runs with no configuration change: iterations 20/19/18/17 standard runs
went 8,921 / 11,072 / 8,917 / 10,921 MB at identical allocation
(~1.606e9 objects, ~72.8 GB), identical majors (8) and identical nursery
(512 MB, 4 grow events). The difference is one extra old-gen growth increment.

A mid-run claim that `injTotal` costs +2.1 GB was **retracted** on this basis —
the claimed effect is the same 2.15 GB as the mode gap. It remains unsettled;
it needs N≥3 runs per arm toggling `injTotal` alone.

Wall showed no such behaviour: 24 pairs, standard 5:55-14:31 monotone-ish with
the config, optimized tracking it, gap in a 15 s window until the two codegen
flags moved it.

## 7. Scope — what this does NOT establish

- **One workload.** The compiler compiling itself. Other programs may cash
  precision differently; the compiler is not a typical Elm application.
- **Wall/GC only.** No coverage, dispatch-count, or output-size metric was
  taken. The precision flags were justified on coverage, which this run does
  not measure and does not refute.
- **No correctness check.** Every iteration produced a working compiler that
  compiled the next stage, which is a real smoke test, but no test suite was
  run at any flag level.
- **Single runs.** No repeats, so per-flag differences under ~10 s are not
  resolvable. The two headline effects (§4) are single observations each,
  though `devirtFnGlobals` is corroborated by the following iteration holding
  the depressed gap.

## 8. Recommended follow-ups

1. **Confirm `devirtFnGlobals`** with N≥3 per arm at one fixed level. It is
   the single largest lever found and would drive real decisions.
2. **Settle `injTotal`'s RSS** the same way, or drop the claim entirely.
3. **Re-run §5 with a coverage metric on** before acting on "turn the
   precision flags off" — this run priced them but did not price what they
   were bought for.
