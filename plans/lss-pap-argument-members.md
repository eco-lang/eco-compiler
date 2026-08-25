# PAP argument members: transport `g|` identity for partially-applied call arguments — OUTLINE

**Status: OUTLINE (2026-08-23). Captures the idea and its evidence; not
implementation-ready. Sequenced AFTER GAP-2 D0/D1
(`plans/lss-gap2-callarg-transport.md`), whose Phase-0 census discovered and
sized this lever and whose plumbing (ArgStash, census rows, honesty rails)
this plan reuses.**

## 1. The idea

When a call argument is a PARTIAL application of a known global,

```
h (composeL g f)      -- composeL: 3 declared params, 2 supplied
List.foldr (Dict.insert flag) d xs
```

the argument's runtime value IS a PAP of that global — not an anonymous
inner lambda, the global itself, partially applied. So `g|<callee>` is a
SOUND member for the argument's residual arrow: LSS_013's arity bound
licenses exactly this (supplied < declared ⇒ the residual arrows lie within
the declared arity; contrast `readPointCell ref`, whose returned value is an
inner lambda and where stamping the global would be unsound).

Today that identity reaches the consumer's param slot through NEITHER
channel:

- **Translate side**: `injectArgLambdaMember` transports lambda literals,
  bare `VarGlobal`/ctor/cycle references — but its wildcard arm no-ops on
  Call-shaped args (Translate.elm, the GAP-2 hole).
- **Signature side**: B.1.f `selfIdOf` deliberately FILTERS the def's own
  id out of its signature (LssInfer.elm:549-568), on the recorded premise
  that "callers already receive the def's identity via the `g|` standalone
  spine injection … and via `injectArgLambdaMember` translate-side". That
  premise is TRUE for a bare `VarGlobal` argument and **FALSE for a
  partial-application CALL argument** — the class this plan serves.

The fix is an arg-site injection, not a signature change: the `selfIdOf`
filter stays (its rationale gets amended); the member is minted where the
PAP is visible — at the argument position.

## 2. Evidence (GAP-2 Phase-0 census, `/work/lss-gap2-phase0-census.txt`)

- **Population: 2,475 sites** — 63.3% of all call-shaped arrow arguments at
  global consumers, 4.5× GAP-2 D1's 551-site reach (overlapping, not
  additive: a callee can be both fact-carrying and partially applied).
- The combinator head is 100% partial: `composeL` 216/216, `composeR`
  157/157, `always` 77/77, `flip` 73/73, `Tuple.pair` 32/32,
  `List.maybeCons` 77/77, `Bytes.Decode.listStep` 121/121.
- **Depth: 87.7% are depth 1** (declared − supplied = 1; 2,171 sites),
  depth 2 = 263, ≥3 = 41 — head-of-residual injection covers the bulk.
- Arities self-verified by the `arity|` census row (`composeL` 3/2,
  `always` 2/1) — this matters because the census exposed and fixed the
  `declaredArityGo` TrackedFunction bug (see §5).
- **Heat: the PAP families carry ≈3.9% of self-compile generic dispatch**
  (combinators 1.1%, Bytes 2.5%, Parse 0.3%, Combine ≈0 — GAP-2 plan §2.6
  row 8), versus 68.6% for the IO-chain cluster GAP-2 targets. This plan is
  therefore **reach-completeness work under the standing criterion**
  (workloads that pass combinators/encoders around more than a compiler
  does), not a self-compile heat lever — and it must not claim otherwise.

## 3. Why the payoff differs in KIND from GAP-2's

GAP-2 D1 transports mostly raw `l|` members, which decline at AbiCloning
(LSS_017) — analysis reach and feedstock. This plan's member is a
**provisional `g|`** that GROUNDS at zonk (LSS_019) and is consumable by
E9.1 / LSS_025 post-settle devirt and the kernel devirt (via the
kernel-alias fold) — i.e. singleton sites become **directly stampable**.
The flip side: a wrong `g|` is the representative-hijack miscompile class,
so the soundness argument (§4) carries real weight and the pins must cover
both stamp-correct and decline directions.

## 4. Mechanism sketch

**Translate side (the core).** A new arm in `injectArgLambdaMember` (or the
`ArgStash` classification GAP-2 added) for
`TOpt.Call _ (VarGlobal/VarEnum/VarBox/VarCycle g) innerArgs _` with
`supplied < declaredArityOf g`:

- mint the standalone member exactly as `standaloneArgMember` does for the
  bare reference (same id family, kernel-alias fold included, so one
  identity per global — the E9.2 lesson);
- inject at the argument var's residual spine: the arg's canType IS the
  residual, so `injectSpineMemberId` with depth `declared − supplied`,
  bounded per LSS_013 (87.7% of sites: depth 1 = the head arrow).

**Inference side (the twin).** Same classification in the walk's argument
handling (`unifyParamsBestEffort` / `joinCallArgs` class), injecting into
the loaded arg type, so producer SIGNATURES that pass PAPs onward compose —
mirroring `spineDepthForGlobal`'s two-sided lockstep discipline.

**What this is NOT**: the `spineArity` default flip. That flag deepens
injection for BARE references globally; this plan injects per ARG SITE
where partial application is syntactically proven, under its own flag
(`lss.papArgMembers`, env `ECO_MONO_LSS_PAP_ARGS`, hash token `lssPA=`,
DEFAULT-OFF; single-gated on `lss.enabled` — the members channel does not
depend on sigFlow).

## 5. Prerequisites and dependencies

1. **GAP-2 D0/D1 landed** (shared ArgStash/census plumbing; D0's honesty
   rails; D1's connect makes the two transports compose at the same sites).
2. **The `declaredArityGo` TrackedFunction fix** (landed 2026-08-23 with
   the census): before it, the arity walk floored the dominant def shape at
   1, which would have made this plan silently inject at wrong depths.
   Needs its own unit pin (composeL reads 3, always reads 2) as part of
   THIS plan's battery, since this plan is its first soundness-bearing
   consumer.
3. The budget-512 default (landed) — new `g|` members mean new keyed
   splits; the sat census's per-callee tables bound the fan-out.

## 6. Census still needed (this plan's own Phase 0 — one row)

Population and depth are already measured. Missing: **exploitability** —
how many of the 2,475 sites' consumers can consume a `g|` singleton
(saturated plain-var call sites per LSS_025's guards; kernel-devirt-eligible
positions for the `k|`-folded subset)? One report-gated row at the same
census fold, plus the standard stop condition: if the exploitable share is
negligible AND the reach criterion alone doesn't justify the risk class
(§3), PARK.

## 7. Risks (headline only)

- **False `g|` = miscompile**: the member must be the VALUE's identity —
  true by construction for a direct partial application, but the pins must
  cover: over-application (`sat|over` = 35 sites — no injection), unknown
  arity (`unknown` — no injection), eta/wrapper shapes, and PAP-of-PAP
  (inner func itself a Call — v1 declines).
- **Consumer arity discipline**: a stamped direct call to a PAP-of-global
  must respect the residual arity (LSS_025's arity/eqLayout guards; the
  kernel-devirt arity table for `k|` folds) — under-application beyond
  depth 1 pinned both ways.
- **Fan-out/de-stamp**: new members → new keys → the Run-X reshuffling
  class; exact-count per-fp dispatch census at the measurement phase.

## 8. Non-goals

- Signature-side self-id transport (the `selfIdOf` filter stays; only its
  doc premise is amended).
- The global `spineArity` flip (separate decision; this plan neither needs
  nor implies it).
- Wrapped shapes (`Let`/`If` around the partial application — the GAP-2
  census's `leak|` rows measured these negligible).
- Any heat claim on the self-compile (§2 — the honest ceiling is ≈3.9%).
