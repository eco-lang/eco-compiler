# LSS flag-off SOLO census — findings

Run 2026-09-18, 09:46 → 14:34 UTC. 32 flags + two baselines, one run each,
zero failures. Protocol: `benchmarks/flag-off-lss-loop.md`. Data:
`benchmarks/flag-off-lss-solo.tsv`; rendered tables in
`benchmarks/flag-off-lss-solo-results.md`.

Instrument: `bin/eco-opt-solo-census` — the SHIPPING compiler (the tree's
fixed-point MLIR lowered with `ECO_LSS_DISPATCH_SITE_COUNTERS=1`), fixed for
every row, under `ECO_DISPATCH_STATS=1 ECO_MONO_LSS_REPORT=1`. Each row turns
off exactly one flag; nothing accumulates.

## 0. The series is trustworthy

Opening and closing baselines, 4h 45m apart, on the same instrument:

| metric | open | close | |
|---|---:|---:|---|
| minor GC / major GC / promoted MiB | 2290 / 10 / 23974 | 2290 / 10 / 23974 | **identical** |
| sat / gen / typed / fast / distinct | 929,988,287 / 836,492,354 / 93,495,933 / 1,035,778,158 / 7,035 | same | **identical** |
| k1 / kN / var / ⊤ | 145,053 / 2,586 / 572 / 813 | same | **identical** |
| `out.mlir` | 13,458,106 | 13,458,106 | **identical** |
| wall | 8:56.71 | 8:50.56 | −1.15 % (band ±2 %) |

Every deterministic metric is identical to the digit. Per-flag deltas below are
real, not drift.

## 1. Headline — 8 of 32 flags change nothing the compiler emits

`vs base` = `same` means the emitted MLIR is BYTE-IDENTICAL with the flag off.

| Flag | sat Δ when off | minor GC Δ | analysis cells moved? |
|---|---:|---:|---|
| `flow.connect` | **−32,625,982** | −51 | yes — var +27, ⊤ −19 |
| `settle.varSucc` | **−12,912,094** | −10 | yes — var +7 |
| `settle.varLambda` | −5,729,566 | −4 | yes — var +7 |
| `settle.varCtorRows` | −1,734,922 | −2 | yes — var +13, kN −13 |
| `flow.letOverlay` | −1,134,136 | −1 | yes — var −6, ⊤ +6 |
| `rsTop` | −78,903 | 0 | **yes, largest: k1 −2,047, ⊤ +2,068** |
| `keyedGlobals` | −65 | 0 | no |
| `muTie` | −63 | 0 | no |

Two distinct classes:

**(a) Real work, zero artifact effect — the retirement candidates.** The top six
all move coverage cells, so they compute something correct, and none of it
reaches the emitted code. `flow.connect` alone costs 32.6 M dispatches and 51
minor GCs of the instrument's own execution.

**`rsTop` is the sharpest case in the census.** It moves 2,047 positions out of
⊤ into k1 — the largest coverage effect of any inert flag, and exactly what it
shipped for (+1.12 pp coverage, 2026-08-29) — and the artifact is byte-identical.
It does substantial correct work that no downstream consumer reads.

**(b) Inert at zero cost — leave alone.** `keyedGlobals` (−65 dispatches) and
`muTie` (−63) move nothing at all. `muTie`'s own landing note says the eligible
population on the self-compile is ZERO; this confirms it from the other
direction. Neither is worth touching: they cost nothing and `muTie` is the
structural terminator that lets `maxSpecsPerGlobal` stay unlimited.

`keyedGlobals` being inert is explained by row 2: `keyed` is ON by default, so
ALL globals are keyed and the selective whitelist has nothing left to select.
It is dead only while `keyed` is on — that is a coupling, not a defect.

## 2. The load-bearing flags

Largest artifact movers (|`out.mlir` Δ|) and what they cost:

| Flag | out.mlir Δ | sat Δ | k1 Δ | kN Δ | var Δ |
|---|---:|---:|---:|---:|---:|
| `enabled` (all LSS off) | −1,173,668 | −388,806,175 | −145,053 | −2,586 | −572 |
| `keyed` | −1,134,616 | −90,138,532 | −44,575 | +20,161 | −177 |
| `layoutQualMembers` | **+649,876** | +13,754,580 | −11,879 | +24,390 | +5 |
| `arrowIdentity` | −313,147 | −24,496,648 | −27,488 | +489 | **+19,803** |
| `rootFold` | +311,725 | +344,537 | −59,655 | **+60,464** | +1 |
| `refIdentity` | −225,646 | −13,009,938 | −8,575 | −1,131 | −30 |
| `regIdentity` | +213,817 | −14,451,049 | −72,253 | +1,775 | +18,559 |

`enabled` off puts the whole LSS analysis at **35 % of compile wall** (5:47 vs
8:57) and 1.17 MB of artifact. The identity mechanisms (`arrowIdentity`,
`regIdentity`, `refIdentity`) each lose tens of thousands of positions to `var`
when removed — they are the backbone.

`sigFlow` is the most expensive single flag to compute that is NOT inert:
+36.9 M sat when off, i.e. it costs that much, and it buys k1 +56,767 and
noInstance −36,902.

## 3. Single-counter specialists

Flags whose effect is concentrated in one decline class — useful because their
purpose is legible in one number:

| Flag | the counter it owns |
|---|---|
| `stamp.flatPeel` | `bodyMismatch` 1,415 → 67 when off (**−1,348**) |
| `stamp.papFast` | `noInstance` +3,331 when off; nothing else moves at all |
| `postSettleDevirt` | `noInstance` +3,719 when off; no coverage change |
| `sigFlow` | `noInstance` +36,902 when off — the largest single-counter effect |

`stamp.papFast` and `postSettleDevirt` are notable for moving `noInstance` and
the artifact while leaving every coverage cell untouched: they are pure
stamping-side mechanisms, invisible to the coverage census.

## 4. What this census does NOT establish

- **Run-time benefit.** These are Arm-A numbers: the instrument's own cost.
  A negative `sat Δ` means "cheaper to compute with the flag off", never "lost
  benefit". What a flag buys at run time needs the second compiler per flag,
  out of scope here — except for the 8 byte-identical rows, where the emitted
  compiler is the same program, so the run-time benefit is provably nil.
- **Generality.** Byte-identical means byte-identical ON THIS WORKLOAD (the
  compiler's own source). A different corpus could exercise paths this one does
  not; the recorded watch item is the elm-aws-codegen pathological class.
- **Wall attribution.** Wall ranged 5:47–9:06 but is flat at 8:20–9:06 for every
  row except `keyed` and `enabled`. It does not discriminate between flags and
  was not used to.

## 5. Recommended next steps

1. **Retire-candidate battery on `flow.connect`, `settle.varSucc`, `rsTop`** —
   the three that cost the most for a byte-identical artifact. Each needs a
   second-corpus check before removal, not removal on this evidence alone.
2. `settle.varLambda`, `settle.varCtorRows`, `flow.letOverlay` are the same
   shape at lower cost; fold them into the same battery.
3. Leave `keyedGlobals` and `muTie` alone — inert but free, and `keyedGlobals`
   is only inert because `keyed` subsumes it.
