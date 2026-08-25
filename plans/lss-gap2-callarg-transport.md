# GAP-2 completion: call-argument set transport (the missing hop of α-in-signature)

**Status: CLOSED (v5, 2026-08-24). D0 SHIPPED unconditional; D1/D2 BUILT,
MEASURED, and DELETED from the tree.**

**What survives, in the tree:** LSS_026(a), honest ∅-as-source, on both
readers, ungated. It fixes a REAL MISCOMPILE — `test/elm/src/LssMixedSigHonestyTest.elm`
printed `[42, 42, 42]` for `[41, 42, 82]` at the shipping default (§0.5b) —
and is provably inert on the compiler's own corpus (`topMixedFlex = 0/0`).
Pinned at three levels: store (`LssHonestSourcesTest`, both directions of the
reader), pipeline (`LssHonestSourcesPipelineTest`), runtime (the E2E fixture).
The LSS census instrumentation survives too; it produced every measurement
below.

**What was deleted (2026-08-24):** the whole transport — `connectArgFlow`,
`flowArgWp`, the `ArgStash` carrier, the `itemAux` pending slot, the four
behaviour counters, and the `lss.callArgFlow` flag with its env override and
hash token. It worked exactly as designed (2,480 connections,
`connected + dropped == pop|all` exactly, singleton sets +10.7%, `sigflow
edges` 177 → 16,896) and it cost **+2.68% mono wall** and a **−0.51 pp
fast-dispatch regression** — 11.65 M statically-stamped `$cap` calls converted
to generic — for **zero** consumable gain (`devirtDirect` FLAT at 4,453: the
transported mass is raw `l|`, which declines at AbiCloning under LSS_017).

**The mechanism behind that regression was never identified.** Three
attributions were proposed and all three refuted by measurement (§10, §11.1,
§11.5). The last refutation is the sharpest: a full repair drove its target
counter `declinedBlocked` from 156 to **0** and moved coverage **0.000 pp**.

**Read this next:** `design_docs/auto-borrow-inference/lss-why-the-fidelity-program-failed.md`.
The root cause is not in this plan's subject matter. Sets do not travel with
types in Eco because `Can.TLambda` carries no identity, so `loadType` re-mints
disjoint slots on every load and every "transport" repair — this plan
included — is hand-reconnection of slots a shared representation would never
have split. **Do not re-add a transport layer before fixing arrow identity.**

The plan body below is preserved as the record: the design, the measurements,
and the refutations. The measurements stand; several of the causal inferences
built on them do not, and each is marked where it occurs.

This is the repair plan for fidelity-mapping GAP-2 ("No lambda-set
polymorphism in signatures",
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md:328-349`).
Line numbers drift as edits land — anchor by function name.

Companion outline: `plans/lss-sum-lowering.md` (the downstream consumer of
the sets this plan recovers; inherits §6's agreement obligation).

**Three staleness corrections to GAP-2's register text** (it predates
LSS_023):

1. **The FromArrow half already landed.** `ArrowFact` is
   `{ rep, members, top, sources : List Int }` (Engine.elm:91-96); `sources`
   IS ordinal-indexed flows-into — recorded by `zonkSigGo`'s
   promote-or-internalize walk (LssInfer.elm:713-725 LsFrom arm,
   `sigResolveEdges` :771-790, `sigEdgesGo` :793-855), and the directed slot
   edges are installed at call sites by `applyFactsGo → installSources →
   Store.addSlotSource` (LssInfer.elm:249-288; Store.elm:1000-1048), resolved
   pull-at-read (Store.elm:1507-1552). LSS_023, sigFlow-gated, default-on.
2. **The size-cap rider is discharged** (`widenedBySigSize`,
   LssInfer.elm:696-706 + `finishSigFact` :898-909).
3. **Producers' signatures are non-trivial under default sigFlow.**
   `readPointCell ref = \s -> …` zonks to
   `arrows = [ {rep=0, members=[raw l|lamB], sources=[]}, {rep=1, …} ]` —
   ordinal 0 is the RETURNED `State -> …` arrow (post-order minting,
   Store.elm:194-201), and the inner-lambda member survives the B.1.f
   self-filter (LssInfer.elm:555-568).

**PHASE 0 IS DONE (2026-08-23) — see §2.6 for the measured verdict.** The
instrumentation shipped (report-gated, permanent), the census artifact is
`/work/lss-gap2-phase0-census.txt`, and the headline is: PROCEED with a
corrected scope. The transport population is 3,916 call-shaped arrow
arguments of which **551 are reachable today** (their arg-callee's signature
carries facts), and **78.6% of those 551 sit at five monadic consumers** —
`IO.andThen`, `Engine.andThen`, `IO.map`, `IO.apply`, `Engine.map` — the
exact ⊤-inheritance families this plan was written about, fed by exactly the
producers of the worked example (`readPointCell`, `UnionFind.get/repr/set`,
`constrainWithIds`). The §0.5 escalation gate did NOT fire (mixed-fact
population is 0/0), and the fan-out forecast clears budget 512 with no
consumer above it.

**What is actually broken — the measured chain.** (Provenance: slot-level
numbers below are session measurements of 2026-08-22 whose instrument was
one-shot; they remain PROVISIONAL — Phase 0 measured the argument-side
population and the signature decomposition, not the per-slot zonk-cause
split. The sweep numbers ARE on record:
`/work/lss-knob-sweeps-report.md`.)

The fact-carrying flow **dies at the consumer's argument boundary**. When
`readPointCell ref` (a Call expression) is passed as `IO.andThen`'s `ma`
argument, `argUnifyVar` loads the arg type FRESH (Translate.elm:3137-3155)
and its member-injection helper `injectArgLambdaMember` has no arm for
Call-class args (wildcard no-op :3222-3223, called at :3150); fresh loads
mint fresh arrow slots (LSS_006), so the arg's fact-enriched instantiation
Points never meet the HOF's param slot — the documented A.1 arg-position
leak (LssInfer.elm:1518-1525; fidelity-3 :164-201). The module doc names
the failure verbatim (Translate.elm:3158-3171). Downstream:

- HOP 1: the unconstrained param slot READS BACK `LTop`
  (Store.elm:1554-1556) into the caller's demand.
- HOP 2: the all-⊤ demand keys onto ONE shared key per type shape
  (Engine.elm:1580-1583).
- HOP 3: the spec seed re-encodes stored `LTop` as explicit `LsTop` poison —
  the deliberate demand asymmetry (Store.elm:531-553).
- HOP 4: the body reads poison; its own call demands inherit; recurse.

Session census (PROVISIONAL, both budget extremes): IO.andThen slots read
set=624/987, flex=0, poison=1,684/2,102 with zero local poison writers;
producers read flex 75-94%. On-record: coverage rises 6.56%→22.11% from
budget 1→512, saturates by 512, flat 512→4096 — **the ceiling, not the
curve, is budget-invariant**: the residual ~77.5% is minted positionally at
this hop and no key regime can recover it.

**Scope.** D0 closes a latent soundness seam in the existing machinery
(§0.5); D1/D2 close the transport hop on the translate and inference sides.
Primary deliverable is analysis reach; dispatch wins are predicted per
member class (§3.5), not promised.

---

## §0.5 The latent hole at HEAD (found by this plan's review; owned here)

`Store.resolveSources` reads a terminal FlexVar SOURCE as an ∅ contribution
("as a SOURCE an empty contribution is exact", Store.elm:1622-1627), and
`sigEdgesGo` does the same during signature internalization (FlexVar arm,
LssInfer.elm:849-850) — while a DIRECT read of the same unconstrained slot
is `LTop` (Store.elm:1554-1556). ∅-as-source is exact **only under
write-completeness of every inflow to the source slot** — and A.1's
disconnected instantiation params are precisely a write-INCOMPLETE
population. Constructible at HEAD with default flags:

```
pick c f = if c then f else (\x -> x + 1)
  -- pick's result fact is MIXED: { members = [l|lam], sources = [f's param ordinal] }
  -- (finishSigFact emits members-plus-sources together)
d f = pick c f
  -- inside d, the inference walk never connects the arg f (A.1) → the
  -- source ordinal's slot dangles as FlexVar → d's zonkSigGo internalizes
  -- it as ∅ → d's signature claims result ∈ {l|lam} COMPLETE — while d's
  -- own f flows through at runtime.  Mono.LSet IS a completeness claim.
```

Damping today: raw `l|` singletons decline at AbiCloning (LSS_017
noInstance). The damping does NOT cover `g|`/`c|` members — signature facts
carry those too, they GROUND at the consuming zonk (LSS_019), and a false
`{g|X}` singleton at a saturated plain-var site passes LSS_025's guards and
E9.1 — the representative-hijack miscompile class. Phase 0 sizes the
mixed-fact `g|`/`c|` population; **non-zero ⇒ D0 escalates to an
unconditional soundness fix with its own landing, ahead of everything else.**

### §0.5b ESCALATED — D0 IS UNCONDITIONAL (2026-08-23, Phase 1)

**The escalation fired on a RUNTIME WITNESS, not on the census.** Phase 0's
census counted zero crossings on the self-compile (§2.6 row 2) and the plan
therefore shipped D0 flag-gated. Phase 1's E2E fixture —
`test/elm/src/LssMixedSigHonestyTest.elm`, the §0.5 `pick`/`d` construction
with a `g|` member — **miscompiles at the shipping default**:

```elm
pickG c f = if c then f else incr          -- fact: {g|incr} + source(param f)
d f       = pickG True f                   -- returns f at runtime
List.map (\f -> apply1 (d f) 41) [ ident, incr, double ]
--  expected [41, 42, 82]   ·   HEAD printed [42, 42, 42]
```

Three arms isolate it exactly: `ECO_MONO_LSS_ARG_FLOW=1` (D0 on) PASSES,
`ECO_MONO_LSS_DEVIRT_POST=0` (LSS_025 off) PASSES, `ECO_MONO_LSS=0` PASSES.
So the chain is the predicted one end to end — `d`'s internalization drops a
dangling inflow → publishes `{g|incr}` as a COMPLETE singleton → LSS_025's
post-settle devirt trusts it and rewrites every dispatch to `incr`. The
direct calls (`d ident 41` → 41) stay correct; only the SHARED call site is
hijacked, which is why a monomorphic fixture never sees it and why the
self-compile census reads zero: the compiler's own code does not pass three
different functions through one such wrapper.

**Consequence, applied:** D0 ships unconditional on both readers — the
`Engine.argFlowOn` test is gone from `sigResolveEdges`, and `zonkToMono`
seeds `honestSources = True`. `Engine.argFlowOn` now gates D1/D2 only.
`LssZonkAcc.honestSources` survives as a field solely so the store-level pins
can assert BOTH directions (`LssHonestSourcesTest` test 1b drives the
resolver with it False and asserts the false set comes back — the RED half).

**Cost: nil on the self-compile, and that is provable rather than measured.**
The only behavioral difference lives inside `if sawFlex && …`, and the
report's `topMixedFlex` says how often that branch is entered. See §5
Phase 1 for the measured rail.

**What this corrects in the record.** §2.6's "the false-COMPLETE shape is
real in principle but **unexercised at HEAD** on this workload" was right
about the workload and wrong as a safety conclusion — a zero census over one
corpus is not an absence proof for a soundness hole, and the `edges=177`
observation explains the zero rather than excusing it. The census gate was
the wrong instrument for a soundness question; a constructed witness is the
right one.

## §1 The mechanism, stated as the paper's rule

The paper (Brandon et al., PLDI 2023): TIU-Def-Ref/F instantiate a def's
quantified ᾱ fresh per occurrence (Fig. 4/5, 146:9-10; AT-Def-Ref is the
declarative arbitrary-σ̄ rule), and TIU-App unifies the argument's inferred
type — set annotations included — with the callee's parameter position
(Fig. 5). Crucially there is ONE instantiation per occurrence: nested
applications peel *that* instantiation, so flow-through variables stay
connected to this site's actual arguments.

Eco already instantiates callee signatures per call site
(`instantiateWithSignature`, LssInfer.elm:118-135, reached under
`lss.enabled` via `instantiateLss`, Translate.elm:3651-3657) and unifies the
call shape. Missing is the TIU-App half for **arguments that are themselves
calls**: the arg's own instantiation residual must be CONNECTED to the arg
var that meets the outer param slot. Connection — not copying (a resolved-
members copy is the banned snapshot internalization; a second instantiation
is unsound — §3.0).

Worked example to fix end-to-end:

```
readPointCell ref = \s -> …            -- sig ord0 = {raw l|lamB}  (EXISTS TODAY)
UnionFind.get pt = readPointCell pt    -- get's result composes inference-side (D2)
… IO.andThen k (UnionFind.get pt) …    -- ← THE HOLE (D1): the arg-call's
                                       --   instantiation never connects to
                                       --   andThen's ma param slot
```

---

# PART I — IMPLEMENTATION

Read order for an implementer new to this area: the module docs at
Translate.elm:3158-3171 (the leak), LssInfer.elm:20-42 (Σ scratch, LSS_006
pairing), Store.elm:1445-1464 (zonk policy), then this plan §3.0-§3.4.

House rails that apply to every phase (recorded traps, all previously hit):

- **Two-binary byte-identity**: flag-off must be byte-identical. Every
  compiler edit moves the corpus, so the rail is two binaries built from
  the SAME final source (HEAD+changes flag-off vs HEAD+changes flag-off
  rebuilt), never HEAD vs HEAD+changes. Compare `eco-compiler.mlir` md5.
- **Env vars are not ninja inputs**: delete `bin/eco-compiler{,.mlir}`
  between arms (a stale artifact shows `fast=0` in the census — the tell).
- **eco-config.json must carry `"engine":"solver"`** — a `mono` block
  without it silently flips to subst (Config decoder default) and every
  LSS counter reads zero.
- **Harness cache is env-blind**: touch a test `.elm` before flag-on E2E
  legs; purge `build/test/*/eco-stuff` between E2E legs.
- **Suites run serially** (`~/.eco` typed-artifacts race).
- **Census tsvs compare as multisets** (tie order is ASLR-unstable); match
  by symbol, never by index; never relationally compare hex strings in awk.
- **32-slot record cap**: `Engine.S` and `Engine.LssStats` are both AT the
  cap — every new field in this plan goes into an existing sub-record
  (`itemAux`, `lssStats.sigStats`), never top-level.

## §2 Phase 0 — the census (the gate)

All instrumentation is **report-gated** (`s.env.lss.report`, the
`edgesInstalled` precedent — zero cost on the default path) and lands with
the W0 plumbing so it can ship permanently; no strip-after step this time.
The heavy rows only populate when report=True.

### §2.1 Rows and their exact instrumentation sites

All census tallies go into ONE new sub-record field
`lssStats.sigStats.argFlowCensus : CoreDict.Dict String Int` (see W0.4),
rendered as sorted `ARGF\t<key>\t<n>` lines by `renderLssReport`
(Monomorphize.elm:134+, extend near the `sigflow:` line at :252).

1. **Transport population.** Site: `translateGlobalCallSlow`
   (Translate.elm:2815) — after `unifyParamsCollect` returns, fold the args:
   for each arg with `isDirectCallShape arg && canTypeHasArrow (TOpt.typeOf
   arg)` bump keys `"pop|hof=" ++ TOpt.toComparableGlobal global` and, when
   the arg's func is a `VarGlobal g`, `"pop|callee=" ++
   TOpt.toComparableGlobal g` plus `"pop|calleeTrivial=<0|1>"` (force
   `LssInfer.signatureFor g` — memoized). `isDirectCallShape` = the arg is
   `TOpt.Call _ _ _ _` (v1 scope; wrapped shapes are row 5).
2. **Mixed-fact population (the §0.5 gate).** Two sites, counted even with
   the behavior flag OFF (counters are artifact-neutral; only report-gated):
   (a) `sigResolveEdges` (LssInfer.elm:771): when the walk saw a dangling
   FlexVar (the new `sawFlex` bit, §3.2b) AND members/ordinals are
   non-empty, bump `"mixed|sig"` and per-member-class rows
   `"mixed|sig|<class>"` where class ∈ {l, g, c, k} via
   `Engine.standaloneMemberGlobal`-family reverse lookup (member ids the
   table does not know are lambda-family → `l`). (b) demand side,
   `resolveSlotMembers` (Store.elm:1579): same condition on its new
   `sawFlex` → bump `"mixed|demand"` (class split via the ctx member
   table). **Branch condition: `mixed|sig|g` + `mixed|sig|c` > 0 ⇒ §0.5
   escalation — D0 ships unconditionally, first, own battery.**
3. **Trivial-mass decomposition.** Sites: the body-less fabrication arms in
   `resolveUnit` (LssInfer.elm:408-424) bump `"triv|ctor"` etc. per arm;
   `zonkSigGo`'s terminal arm (:642-654) classifies a finished signature
   under report: `n == 0` → `"triv|arrowfree"`; `trivial` → `"triv|allflex"`;
   any `fact.top` → `"sig|hasTop"`; else `"sig|carrying"`. (The recorded
   prior figure is 8,673/8,673 trivial PRE-sigFlow, fidelity-mapping :333;
   the sigFlow-era decomposition is itself a Phase-0 output.)
4. **Key fan-out proxy** (computable one-shot, no dry-run circularity).
   Site: same fold as row 1: bump
   `"fan|" ++ hofKey ++ "|" ++ argCalleeKey ++ "|" ++ canKind (TOpt.typeOf arg)`
   (`canKind`, Translate.elm:3720-3748 — static, store-effect-free).
   Post-process: distinct keys per hof = the fan-out forecast. Compared
   against the budget: the sweep already shows `Task.andThen` at 790 specs
   under budget 64 with permanent over-budget join absorption
   (`unionAnno`, compiler/src/Compiler/AST/Monomorphized.elm:1442-1452;
   `HitNoopJoin` Registry.elm:160-162) — see §4 sequencing.
5. **Adjacent-leak rows** (follow-up sizing, not v1 scope): the Let-shape
   annotation drop — site Translate.elm:4030-4050, bump `"leak|letAnno"`
   when the annotation-free branch is taken and the def type mentions an
   arrow; blind-arg shapes — at row 1's fold, an arrow-mentioning arg that
   is neither Function/TrackedFunction/Var*/Call bumps `"leak|blindShape"`
   (the D2 poison-cost forecast); local-callee and kernel-callee arg-calls
   bump `"leak|localCallee"` / `"leak|kernelCallee"`.

### §2.1b Census scope limits (recorded at implementation)

- **Consumer class**: the `pop|`/`fan|`/`shape|` rows are counted at
  `translateGlobalCallSlow` only — i.e. arguments of GLOBAL calls. That is
  the complete arrow-bearing population for global consumers (an
  arrow-mentioning argument forces `lssFastOk = False`, Translate.elm's
  `lssFastOk` arrow guard, so no such call can take a cached fast path),
  but arguments of LOCAL-MULTI and INDIRECT consumer calls are not
  censused. Those are separate, smaller populations; D1 covers local-multi
  consumers, so a follow-up census run can add the same fold at
  `translateLocalMultiCall` if the local consumer share matters.
- **Arg-callee triviality** is read from the memo (`memoizedSignatureTrivial`)
  AFTER the arguments are translated, never forced: forcing would move
  member-id allocation order, and `lss.report` is excluded from the config
  hash, so a report-on run must produce the same artifact as a report-off
  one. A `pop|calleeTrivial=?` row would mean that assumption broke.
- **Mixed-fact rows are flag-independent**: `mixed|sig*` / `mixed|demand*`
  count the crossings under the CURRENT default configuration
  (`callArgFlow` off), which is exactly the §0.5 exposure question. The
  policy that widens them to ⊤ is gated; the counters are not.
- `mixed|*|gc` uses the coarsest class present in the fact's member list
  (`gc` ≻ `k` ≻ `l`) — a fact mixing a lambda id with a standalone global
  counts as `gc`, which is the conservative direction for an escalation
  gate.

### §2.2 Stop/branch conditions

- `pop|*` ≈ 0 → the HOP chain is refuted; stop, re-derive.
- ≥90% of reachable arg-callee signatures trivial AND row 3 shows the mass
  is honest (arrow-free/body-less) → PARK; producer-side plan first.
- `mixed|*|g`+`mixed|*|c` > 0 → D0 unconditional-first (§0.5).
- fan-out forecast materially above the shipping budget for hot consumers →
  the budget-512 default flip (`/work/lss-knob-sweeps-report.md`
  recommendation) becomes a PREREQUISITE landing; Phase-4 measurement runs
  at the shipping budget regardless (§4).

### §2.6 MEASURED — Phase-0 results (2026-08-23)

Artifact: `/work/lss-gap2-phase0-census.txt` (3,456 rows). Arm: shipping
config (solver, budget 64, sigFlow/layoutQual/devirtPost on, `callArgFlow`
OFF — HEAD's exposure, not the repair). Rail: the instrumented binary's
output is byte-identical to the HEAD binary's on the same source (md5
`5836c7d47d2cdc4e3c7de37262c22742`), so the instrumentation is
artifact-neutral and `report=1` does not perturb.

**Row 1 — transport population.** 3,916 call-shaped arrow arguments at
global consumers:

| arg-callee | sites | share |
|---|---:|---:|
| global, signature CARRIES facts (**reachable today**) | **551** | 14.1% |
| global, signature trivial (nothing to transport) | 2,791 | 71.3% |
| non-global (local 571, kernel 3) — out of v1 scope | 574 | 14.7% |
| not-yet-memoized (`?` — would break the read-only rule) | 0 | — |

Local-multi CONSUMERS contribute 68 arrow arguments and **zero** call-shaped
ones (verified live: the same fold runs there and the `shape|` rows grew by
68 while `pop|all` did not move). D1's local-multi arm is therefore inert on
this corpus — keep it for generality, expect nothing from it here.

**Row 1b — the decision cross-tab (`popt|`): the reachable population is the
monadic families.**

| consumer | reachable | trivial | non-global | % reachable |
|---|---:|---:|---:|---:|
| `System.TypeCheck.IO.andThen` | 212 | 78 | 51 | 62.2% |
| `MonoSolver.Engine.andThen` | 78 | 58 | 5 | 55.3% |
| `System.TypeCheck.IO.map` | 75 | 62 | 20 | 47.8% |
| `System.TypeCheck.IO.apply` | 46 | 6 | 13 | 70.8% |
| `MonoSolver.Engine.map` | 22 | 36 | 0 | 37.9% |
| *(top 5)* | **433** | | | **78.6% of all 551** |
| *(top 18)* | 502 | | | 91.1% |

By contrast the big trivial-callee consumers are combinator plumbing:
`Basics.composeR` 240 trivial / 4 reachable (1.6%), `List.any` 88/4 (4.3%),
`List.foldl` 42/4 (7.3%).

**Row 1c — producers (`calleeTriv|`).** 133 distinct arg-callees carry facts
(551 sites); 696 carry nothing (2,791 sites). The fact-carrying head is the
plan's own worked example: `constrainWithIds` 31, `readPointCell` 29,
`UnionFind.get` 25, `Engine.andThen` 22, `IO.andThen` 20, `IO.apply` 20,
`UnionFind.repr` 17, `IO.pure` 16, `UnionFind.set` 15, `Engine.traverse` 14,
`Instantiate.fromSrcType` 12, `Occurs.occursHelp` 12, `Type.getVarNames` 12.
The empty head is combinators: `composeL` 222, `composeR` 157,
`Bytes.Decode.listStep` 121, `Json.Decode.apply` 83, `Bytes.Encode.jsonPair`
81, `Basics.always` 77, `List.maybeCons` 77, `Flip.flip` 73.

**Row 2 — the §0.5 escalation gate: NOT FIRED.** `mixed|sig = 0`,
`mixed|demand = 0` (hence no class split to report). Across the whole
self-compile, not one fact combines members with a dangling-FlexVar source.
The false-COMPLETE shape is real in principle (the `pick`/`d` construction
still type-checks) but **unexercised at HEAD on this workload**. Cause is
visible in the same report: `edges=177` — the directed-inclusion channel is
barely populated, so the mixed shape has almost no opportunity to arise.
Consequence: **D0 stays flag-gated** (no unconditional escalation), but it
remains a hard prerequisite for D1/D2, which by construction CREATE
edge-reachable sources.

**Row 3 — signature decomposition (11,538 zonk events).**

| class | count | share |
|---|---:|---:|
| `allflex` — has arrow slots, body contributed nothing | 7,218 | 62.6% |
| `bodyless` — Ctor/Enum/Box/Manager/Kernel/port | 2,388 | 20.7% |
| `arrowfree` — no arrow slots at all | 1,538 | 13.3% |
| **`carrying`** — members and/or promoted sources | **321** | **2.8%** |
| `hasTop` — at least one ⊤ fact | 73 | 0.6% |

So §0's staleness correction 3 ("producers' signatures are non-trivial under
sigFlow") is TRUE for `readPointCell` but NOT at population scale: only 2.8%
of signatures carry anything, and 62.6% are the honest-looking-but-empty
`allflex` class. **The producer side is the ceiling on D1's value.**

**Row 4 — fan-out forecast.** Distinct (arg-callee × layout) per consumer:
`Task.andThen` 184, `Json.Decode.apply` 101, `List.map` 81, `IO.andThen` 79.
Four consumers exceed budget 64; **none exceeds 512**. The budget-512 flip
is confirmed as a real and SUFFICIENT prerequisite (§4).

**Row 5 — non-call arrow arguments (23,459).** `local` 41.9%, `lambda`
32.9%, `standalone` 24.9%, `accessor` 0.2% — the first three are already
transported today (`enrichFromEnv` / `injectArgLambdaMember`). Blind and
wrapped shapes total 47 (`blind` 35, `branchWrapped` 10, `letWrapped` 2), so
**D2's publish-or-poison rule costs at most 47 poisoned positions** — the
honesty rule is cheap. Call-shaped args are 3,916 of 27,375 arrow-bearing
argument positions = 14.3%.

**Budget-exclusion control (budget 4096, same binary).** The population is
structural, not a budget artifact:

| row | budget 64 | budget 4096 |
|---|---:|---:|
| reachable (`calleeTrivial=0`) | 551 | **551** |
| `mixed|sig` / `mixed|demand` | 0 / 0 | **0 / 0** |
| `sig|allflex` / `carrying` / `hasTop` | 7,218 / 321 / 73 | **identical** |
| fan-out >64 / >512 / max | 4 / 0 / 184 | **4 / 0 / 184** |
| `pop|all` | 3,916 | 3,910 |
| `shape|` total | 23,459 | 24,063 |

Only the site COUNTS move (±0.2% on `pop|all`, +2.6% on `shape|`), as
expected — a different budget mints a different number of specs and
therefore a different number of translation events. Every structural
quantity is invariant. This is the population-level twin of the earlier
coverage sweep's budget-invariant ceiling.

**Flag-on inertness (falsifiable prediction, CONFIRMED).** Because
`mixed = 0`, turning `callArgFlow` ON must change nothing: D0 only fires on
mixed facts, and D1/D2 are not built. Measured — `ECO_MONO_LSS_ARG_FLOW=1`
produced a **byte-identical artifact** (md5
`5836c7d47d2cdc4e3c7de37262c22742`, same as flag-off). This exercises the
whole flag path end to end (env override → decoder → `argFlowOn` → both
gated arms) and proves D0-with-no-mixed-facts is inert.

That arm also produced an unplanned measurement: **`argFlowDropped = 3,375`**
— every `StashArgFlow` entry the D1 carrier created (nothing consumes them
yet, so all fall to the defensive clear). Against the census population of
3,916, **541 call-shaped arrow args (13.8%) never reach the stash at all**.
The likely cause is `unifyParamsCollect`'s `arrowParts` early-exit arm
(over-applied or opaque callee spine → `StashNone` for every remaining arg);
Phase 2 must attribute it with its own counter, because those sites are
structurally unreachable for D1's connect regardless of producer facts. So
D1's mechanical reach is ≤ 3,375 sites and its *useful* reach is the
intersection with the 551 fact-carrying ones.

**§2.2 verdict: PROCEED, scope corrected.**

- `pop|all` ≈ 0? No (3,916) — the HOP chain is not refuted.
- ≥90% trivial AND the mass honest? Trivial is 71.3% (< 90%) and the mass is
  NOT honest (62.6% `allflex`) — **PARK does not trigger**.
- mixed `g|`/`c|` > 0? No — D0 ships flag-gated, not escalated.
- fan-out above the shipping budget? Four consumers above 64, none above
  512 — budget-512 lands first, as already required.

Read plainly: D1 is a NARROW fix (551 sites ≈ 2% of arrow-arg positions)
that lands almost entirely (78.6%) on the five monadic families whose ⊤
inheritance produced the measured 77.5% residual, fed by exactly the
producers the investigation named. Its value is bounded by the producer
side, which is now the top-ranked follow-on: 7,218 `allflex` signatures
against 321 carrying ones.

**NEW LEAD found by row 1c (not previously on any register).** The empty
head is dominated by polymorphic combinators — `composeL`/`composeR` (379
sites), `always` (77), `flip` (73), `Tuple.pair` (32) ≈ 560 sites, a
population the same size as D1's entire reach. Why they are empty matters,
and the first candidate is already REFUTED:

- **REFUTED 2026-08-23, by code reading — no census needed: the
  length-guard poison story.** This entry previously claimed these are the
  `applyFacts` arrow-count-mismatch class injecting ⊤ over the whole
  instantiation. They are not. `applyFacts` tests `sig.trivial` FIRST and
  returns early (LssInfer.elm:202-203); the length guard at :205-206 is
  reachable ONLY for non-trivial signatures, and row 1c measured every one
  of these callees at `triv=1`. They short-circuit and poison nothing —
  mere emptiness, exactly as the row says. Recorded because the wrong
  version was briefly on the register.
- **STILL OPEN, and the better question: WHY is the signature empty?** Two
  mechanisms, distinguishable by one census row:
  - (a) **PAP-shaped arguments.** `composeL f g` (2 of 3 params),
    `always x` (1 of 2), `flip f a` — as ARGUMENTS these are usually
    PARTIAL applications, so the value is a PAP of the combinator itself.
    That identity is exactly what B.1.f `selfIdOf` FILTERS OUT of the
    signature (LssInfer.elm:549-568), on the recorded rationale that
    "callers already receive the def's identity via the `g|` standalone
    spine injection … and via `injectArgLambdaMember` translate-side".
    That rationale holds for a BARE `VarGlobal` argument — but a
    partial-application CALL argument takes NEITHER channel, so the
    identity may be dropped on both sides. If so this is the recorded
    `spineArity` / LSS_013 arity-bound lever (§8 non-goal), now with a
    measured population.
  - (b) **Type-variable positions.** `always : a -> b -> a` builds no
    closure at all; its honest statement is "result ⊇ param 0", but the
    annotation has a type VARIABLE there and `loadTypeC` mints slots only
    at syntactic `TLambda` nodes — no slot exists to link, so the ordinal
    scheme cannot express it. This is §6 loss item 1/4 (the loader
    boundary) — the paper's α at a tyvar position — and it is a deep
    change (slots at tyvar positions, or occurrence-typed signatures),
    not a counter-sized one.

**BOTH ROWS MEASURED 2026-08-23. Result: (a) CONFIRMED and dominant; the
length-guard risk is nil.** Artifact:
`/work/lss-gap2-phase0-census.txt` (arm x4, budget 512).

**Row 6 — `poison|lenGuard` = 0.** The `applyFacts` arrow-count guard
(LssInfer.elm:205-206) does not fire ONCE on the whole self-compile — no
callee, no shape. Three consequences: the refuted poison story is now
refuted by measurement as well as by reading; the risk this row was added
to check (the guard eating D1's own 551 non-trivial sites) is **nil**; and
LSS_006's annotation-first pairing is empirically validated across ~9,850
memoized signatures — the "sound fallback" branch is dead code on this
workload.

**Row 7 — saturation: the transport population is PAP-dominated.**

| class | sites | share |
|---|---:|---:|
| **`partial`** (supplied < declared — value is a PAP of the callee) | **2,475** | **63.3%** |
| `saturated` | 826 | 21.1% |
| `unknown` (non-global callee) | 574 | 14.7% |
| `over` | 35 | 0.9% |

The combinator head is **100% partial**: `composeL` 216/216, `composeR`
157/157, `always` 77/77, `flip` 73/73, `Tuple.pair` 32/32, `List.maybeCons`
77/77, `Bytes.Decode.listStep` 121/121. Arities are self-verified by the
`arity|` row rather than assumed — `composeL` 3 declared / 2 supplied,
`always` 2/1, `Tuple.pair` 2/1, `List.foldl` 3/2.

**Why this is the biggest thing Phase 0 found — and what it implies.** For a
partially-applied call argument the runtime value IS a PAP of a known
global, so `g|<callee>` at the residual arrow is a SOUND member — LSS_013's
arity bound licenses exactly this (supplied < declared ⇒ the residual arrow
lies within the declared arity; contrast `readPointCell`, where the
returned value is an inner lambda, not a PAP, and stamping would be
unsound). Today that identity reaches the caller through NEITHER channel:
`injectArgLambdaMember` has no Call arm (the GAP-2 hole itself), and the
signature channel cannot carry it because B.1.f `selfIdOf` deliberately
FILTERS the def's own id (LssInfer.elm:549-568) on the recorded rationale
that "callers already receive the def's identity via the `g|` standalone
spine injection … and via `injectArgLambdaMember` translate-side" — a
premise that holds for a BARE `VarGlobal` argument and is FALSE for a
partial-application CALL argument. **D1 alone therefore delivers nothing
here**: it would connect the residual to a slot the trivial signature never
wrote. Lighting these up needs D1 PLUS a residual-arrow self-id at
partially-applied call sites. Population 2,475 vs D1's standalone reach of
551 — 4.5× — which makes it a candidate for its own plan rather than a
rider on this one. (The two populations overlap; a callee can be both
non-trivial and partially applied, so they are not additive.)

**Row 8 — heat join (offline, 2026-08-23): the transport family owns the
dispatch heat; the PAP family is cold on this workload.** Method: the
sweep's `lss-budget-512-dispatch.tsv` (per dispatched-to symbol, gen+typed
events) joined against the SAME corpus's `nb-512.mlir` (round-tripped via
`mlir-cat`; the recorded trap applies — symbol indices are corpus-specific,
the first attempt against a different-era mlir resolved 0 of the top
symbols). Provenance = the function that CONSTRUCTS each dispatched
closure, two hops deep for lambda-built-by-lambda chains; top-400 symbols =
96.3% of all gen+typed events, 4.0% left unresolved:

| family | gen+typed events | share |
|---|---:|---:|
| IO-monad (`System.TypeCheck.IO.*`) | 520.9 M | 31.7% |
| UnionFind / Type-solve | 345.7 M | 21.0% |
| IORef / MVar infra | 261.8 M | 15.9% |
| List/Dict HOFs | 196.1 M | 11.9% |
| GlobalOpt / AST walks | 158.5 M | 9.6% |
| other/unresolved | 65.6 M | 4.0% |
| Bytes/encoders | 41.1 M | 2.5% |
| Engine-monad | 27.9 M | 1.7% |
| **Basics combinators (composeL/R, always, flip)** | **17.3 M** | **1.1%** |
| Parse | 4.6 M | 0.3% |
| (Combine parser: below top-400 entirely) | ~0 | ~0% |

The IO-chain cluster (IO-monad + UnionFind/Type + IORef/MVar) = **68.6%**
of gen dispatch — D1's exact family. The PAP-lever families (combinators +
Bytes + Parse + Combine) total **≈ 3.9%**. Sequencing consequence: D1/D2
proceed as planned; the PAP plan is REACH-COMPLETENESS work (the standing
criterion — workloads that pass combinators around more than a compiler
does), not self-compile heat work, and does NOT jump the queue. Caveat:
this is self-compile heat; the 2,475-site population is real and the PAP
plan stays worth writing — with this table in its §0 so it makes no heat
claims.

### §2.6b MEASURED — Phase-0 pass 2 (2026-08-23; rows 1-7 of the gap-closing
batch; artifact refreshed, 23,590 rows)

**Row 9 — zonk-cause split (Phase 4's baseline, now ON RECORD).** 422,341
classified readbacks: `flex` 39.8% / `poison` 36.2% / `set` 24.0% /
`edgeSet`+`edgeEmpty`+`edgeTop` **all 0**. The former PROVISIONAL slot
numbers are now reproduced at the shipping budget: `IO.andThen` set=987,
poison=2,102, **flex=0** (every annotation slot demand-written — HOP 3
exactly); producers keep large flex shares (`UnionFind.modify` 216/396).
Surprise worth recording: **the LsFrom demand-read path is completely
unexercised at HEAD** (0 edge-cause readbacks against 177 installed edges —
they sit at positions demand zonk never reads). D1 will be that path's
first real customer; the Phase-2 unit pins must cover LsFrom readback
explicitly since no production traffic does.

**Row 10 — the stash gap is NOT the early exit.** `stashmiss|* = 0`: at
budget 512 the `arrowParts` early-exit never fires with a call-arrow arg
remaining. The 541-site gap (`dropped` 3,375 vs pop 3,916) was measured at
budget 64 PRE-flip — most likely over-budget spec erasure opaquing callee
spines, a regime the 512 default has since removed. Phase 2's
`connected + dropped == StashArgFlow population` assertion settles it on
the shipping config; no pre-work needed.

**Row 11 — sigfacts: D1's per-producer yield, now audited (394 defs
dumped).** The hot producers are EXACTLY the clean shape D1 wants — one
fact, at the RESIDUAL ordinal, one lambda member, no sources, no top:
`readPointCell` / `UnionFind.get` / `UnionFind.repr` / `IO.pure` all read
`ord0: m=1,l`; `IO.andThen` carries at ord3 only. But the dump splits the
"carrying" class by CONTENT: 321 defs carry members, **73 carry only ⊤
facts** — and `constrainWithIds`, the #1 reachable arg-callee (31 sites),
is `ord0: t=1`. Joining quality against the 551 reachable sites:

| producer content | sites | D1 delivers |
|---|---:|---|
| members | **403** | concrete sets (351 `l\|`-only, 36 `k\|`, 16 `g\|`/`c\|`) |
| top-only | 148 | explicit ⊤ into a slot that already read ⊤ — sound no-op |

**D1's effective yield is 403 sites**, not 551; and it contains a small
directly-exploitable slice (36 `k|` + 16 `gc` = 52 sites whose transported
members are stampable by the kernel/E9 devirts, unlike the `l|` mass).

**Row 12 — partialDepth: 87.7% of the PAP population is depth 1**
(2,171/2,475; depth 2 = 263, ≥3 = 41). The PAP plan needs only
head-plus-one injection for the bulk — the cheap end of the spineArity
machinery.

**Row 13 — bounds for D2 and the non-goals.** `encl|` = 958 distinct
enclosing defs contain call-arrow args — so even if all were `allflex`,
arg-connection explains ≤ ~13% of the 7,218 allflex mass: **the producer
emptiness is mostly NOT the A.1 leak** (tyvar positions / no closure flow
dominate — the deep end). `leak|letAnno` = 44 (the Let-wrapper non-goal is
negligible). `d2|localCalleeArrowArg` = 57 (D2's poison rule at shared
family points has a tiny blast radius — the honesty rule is safe).

**Pass-2 rail, restated honestly.** The original HEAD-vs-instrumented
byte-identity rail stopped being meaningful this pass — NOT because of the
census, but because the host binary predates the budget-512 default flip,
so the two binaries now compile at different budgets by design (13,866,842
vs 14,383,079 B — the known +3.7% signature; `byBudget` 8,575 in the
report confirms the 512 regime). Passes 3-4's rails were, in hindsight,
not re-verified after the flip. The census-neutrality rail is now
**report-ON vs report-OFF on the SAME instrumented binary at the same
config** — MEASURED AND PASSED: both legs md5
`854c2bc20f3e4e7a6ef322a4ace020d6` (argf-x5.mlir vs argf-x5off.mlir). All
pass-2 instrumentation — the zonk-cause bumps on the hot readback path
included — is artifact-neutral, and the read-only census discipline (never
force a signature) held through the largest instrumentation load so far.

**Bug found and FIXED in the process (shipped with this census).**
`declaredArityGo` matched only `TOpt.Function` bodies under
`Define`/`TrackedDefine`, but `LocalOpt.Typed.Module.addDefNode` emits
**`TrackedFunction`** for any def with parameters — so the walk silently
floored the DOMINANT def shape at 1. Dormant today (`spineArity = False`
short-circuits `spineDepthForGlobal` before it consults the walk), which is
why it survived; it would have under-deepened nearly every standalone spine
injection the moment that flag was flipped, i.e. the `spineArity` feature
was inert-by-bug for most defs. Two arms added (LssInfer.elm, artifact-
neutral at the default flag). The first cut of row 7 was invalidated BY this
bug (`composeL` read as arity 1 → 216/216 "over"); the `arity|<callee>` row
now publishes the resolved arity so the split is auditable rather than
trusted.

### §2.5 Census recipe (self-contained)

1. Build the instrumented compiler (W0 landed): `cmake --build build
   --target ecor` (or the full-preset ninja leg per the harness).
2. Arm config — write BOTH keys (decoder trap):
   `{"mono":{"engine":"solver","lss":{"report":true}}}`.
3. Native self-build harness (validated 2026-08-22, recipe + validation
   levels in `/work/lss-knob-sweeps-report.md` Appendix A): HEAD binary +
   config → `arm.mlir` → eco-boot-native lower → run. Capture stderr to a
   file — the harness swallows census stderr when piped naively; use
   `2> arm.census`.
4. Extract: `grep -P '^ARGF\t' arm.census | sort` → preserve the dump under
   `/work/lss-gap2-phase0-census.txt` (the provenance failure §2 exists to
   prevent). One arm at shipping config; a second at budget 4096 as the
   budget-exclusion control.
5. The report line additions (W0.5) also print the steady counters:
   `argFlow: connected/dropped, wpFlowed/wpPoisoned, topMixedFlex sig/dem`.

## §3 Design & work orders

### §3.0 What the review refuted (do not re-invent)

v1's D1 minted a SECOND isolated instantiation of the arg-callee at
`argUnifyVar` time and unified its peeled residual into the arg var. Refuted
three ways: (a) the second instantiation's applied params are orphaned by
construction (the real inner args unify with the FIRST instantiation during
the arg's own translation) — every mixed fact then transports a members-only
set missing its flow-through inhabitants: manufactured §0.5 holes at scale;
(b) sourcing the signature from the occurrence type violates
`instantiateWithSignature`'s annotation-first precondition
(LssInfer.elm:112-117; `sigSourceTypeFor` :187-194) — arrow-count mismatch
triggers whole-spine `poisonArrowSets` (applyFacts :205-206), and unifying
explicit ⊤ into shared slots is join-absorbing, strictly worse than today's
silent flex; (c) copying the arg's resolved/zonked members instead is the
banned snapshot internalization (LSS_020 amendment — deferred sources grow
after any snapshot). Hence: **connect the ONE existing instantiation; never
instantiate twice; never copy.**

### §3.1 W0 — shared plumbing (lands first, behavior-neutral)

**W0.1 Flag.** `compiler/src/Compiler/Eco/Config.elm`:

- `LssConfig`: append `callArgFlow : Bool` LAST (after `postSettleDevirt`,
  :320), with a doc comment in house style (LSS_026; artifact-affecting
  under keyed routing; hash token `lssAG=` when non-default).
- `defaultLss` (:342-357): `callArgFlow = False`.
- `lssDecoder` (:721-739): append LAST —
  `|> D.apply (D.optionalField "callArgFlow" D.bool defaultLss.callArgFlow)`.
  The chain is POSITIONAL (append-only hazard comment at :731-733) — never
  insert mid-chain.
- Hash-token function: clone the `lssDP=` block (the last one, ~:1052) as
  `lssAG=`, muTie-style (emit only when ≠ default). Token inventory after:
  lssMU/lssGS/lssSF/lssLQ/lssDP/lssAG — no collision.
- Any record-literal constructors of `LssConfig` elsewhere fail to compile
  until the field is added — let the compiler enumerate them.

`compiler/src/Builder/Eco/Config.elm`:

- Env chain (:160-175): add a step
  `Utils.envLookupEnv "ECO_MONO_LSS_ARG_FLOW" … applyLssArgFlowOverride`.
- `applyLssArgFlowOverride`: clone `applyLssDevirtPostOverride`
  (:1749-1764), field `callArgFlow`, doc noting DEFAULT-OFF so `1|true|yes`
  is the opt-in.

**W0.2 Gate helper.** `Engine.elm`, near the LSS helpers:

```elm
{-| LSS_026 master gate: the D0/D1/D2 arms are DOUBLE-gated on sigFlow —
sources/LsFrom only exist under sigFlow (Store.elm:996-998), and no flag-off
producer or propagator of LsFrom may exist (LSS_023 byte-inertness rule). -}
argFlowOn : S -> Bool
argFlowOn s =
    s.env.lss.enabled && s.env.lss.sigFlow && s.env.lss.callArgFlow
```

**W0.3 Per-item pending slot.** `Engine.elm` `ItemAux` (:885-892): add
`argFlowExpected : Maybe IO.Variable`
— the outer arg var awaiting connection, set by `translateArgsWith` just
before translating a Call-class arrow arg, consumed at `translateCall`
entry (§3.3). Update `emptyItemAux` (:895-897) with `Nothing`. **`clearedAux`
(:900-905) must ALSO clear it** (scratch-store Point indices are meaningless,
same rationale as the read lists), and `restoredAux` (:908-913) restores the
outer value — mirror `ecoResidualReads` handling exactly. Check `resetItem`
re-seeds itemAux per item (it does today via `emptyItemAux`; verify at
implementation).

**W0.4 Counters.** `Engine.elm` — `S` and `LssStats` are both at the
32-slot cap (comments at S:857-861 and LssStats:156): everything goes into
the existing `sigStats : SigFlowStats` sub-record. Add fields (init literal
at Engine.elm:309 updated in the same edit):

```elm
, argFlowConnected : Int   -- D1 residual↔arg-var unifications performed
, argFlowDropped : Int     -- pending expected consumed by a non-connecting path
, argFlowWpFlowed : Int    -- D2 honest/opaque arg points flowed into params
, argFlowWpPoisoned : Int  -- D2 blind (WpNone/WpSelf) arrow args poisoned
, topMixedFlexSig : Int    -- D0 signature-side mixed-fact widenings
, topMixedFlexDemand : Int -- D0 demand-side mixed-resolution widenings
, argFlowCensus : CoreDict.Dict String Int -- §2 rows; populated only under report
```

Bump helpers clone the `edgesInstalled` pattern (Engine.elm:701-703; the
behavior counters bump unconditionally — they are artifact-neutral ints;
`argFlowCensus` bumps only under `s.env.lss.report`).

**W0.5 Report.** `Monomorphize.elm` `renderLssReport`: extend the
`sigflow:` line (:252) with
` argFlow=<connected>/<dropped> wp=<flowed>/<poisoned> topMixedFlex=<sig>/<dem>`
and append the sorted `ARGF\t…` census dump (CoreDict fold — sorted,
deterministic).

**W0.6 ArgStash refactor** (behavior-neutral; D1's carrier).
`Translate.elm`: `unifyParamsCollect` (:3003-3069) currently returns
`List (Maybe IO.Variable)` — `Just` marks ONLY the local-multi fresh var.
Replace with an explicit union so the arg var can ride without overloading
Maybe:

```elm
type ArgStash
    = StashNone
    | StashLocalMulti IO.Variable  -- GAP-9b fresh instantiation (existing Just)
    | StashArgFlow IO.Variable     -- LSS_026: outer arg var of a Call-class arrow arg
```

- LM arm (:3048): `StashLocalMulti freshVar0 :: restStash`.
- non-LM arm (:3066): when `Engine.argFlowOn s && isDirectCallShape arg &&
  canTypeHasArrow (TOpt.typeOf arg)` → `StashArgFlow argVar :: restStash`
  (argVar = the canVar `argUnifyVar` just returned and unified with
  `pParam`); else `StashNone :: restStash`.
- no-arrow early exit (:3068-3069): `List.map (\_ -> StashNone) args`.
- `translateArgsWith` (:3076-3103): pattern
  `( StashLocalMulti v, Just localName )` keeps the existing instance-record
  path VERBATIM; `( StashArgFlow canVar, _ )` is D1's arm (§3.3);
  everything else → `translate arg`.
- `unifyParamsWithArgExprs` (:2991-2993) unchanged (maps to ()).
- Flag-off, `StashArgFlow` is never constructed: the refactor must be
  byte-neutral — verified by the two-binary rail in Phase 1.

### §3.2 D0 — honest ∅-as-source (both readers)

Gate: `argFlowOn` (escalation path: if Phase-0 row 2 shows `g|`/`c|`
exposure, re-land unconditionally — the diff is the same minus the gate).

**(a) Demand side — `Store.elm`.** `resolveSources` (:1584-1631) gains a
`sawFlex` accumulator:

```elm
resolveSources : List IO.Variable -> List Int -> Bool -> Maybe (List Int) -> ZonkCtx -> ( Maybe (List Int), Bool, ZonkCtx )
```

Every arm threads the Bool; the FlexVar arm (:1622-1627) recurses with
`True` (keep its comment, rewritten: "an unconstrained source contributes
nothing NOW, but under LSS_026 a members-carrying resolution that crossed
one may not claim completeness — the caller applies the policy").
`resolveSlotMembers` (:1579-1581) applies it:

```elm
resolveSlotMembers members0 srcs c0 =
    case resolveSources srcs [] False (Just members0) c0 of
        ( Nothing, _, c1 ) ->
            ( Nothing, c1 )

        ( Just ms, sawFlex, c1 ) ->
            if sawFlex && not (List.isEmpty ms) && honestSourcesOn c1 then
                -- LSS_026(a): members + a dangling inflow = an INCOMPLETE
                -- set that would read as complete. ⊤, never a false set.
                ( Nothing, bumpTopMixedFlexDemand c1 )

            else
                ( Just ms, c1 )
```

`honestSourcesOn` reads a new `LssZonkAcc` field (`Store.elm:1195-1212`):
add `honestSources : Bool` (+ `topMixedFlexDemand : Int`), seeded in
`zonkToMono` (:1215-1226) from `Engine.argFlowOn s`; grep for every other
`LssZonkAcc`/`ZonkCtx` construction site and seed there too (tests included).
The fold-back into `S.lssStats` (zonkToMono's exit) forwards the counter
into `sigStats.topMixedFlexDemand`.

Policy notes (write them as code comments):
- `Just [] + sawFlex` stays `Just []` — the empty-resolution arm at
  zonkSetSlot :1521-1527 already reads LTop; not mixed, no bump.
- The ONLY caller is `zonkSetSlot`'s LsFrom arm (:1507-1552) — no other
  behavior changes. `LssDirectedFlowTest` constructs the walk directly and
  must be updated for the new signature (mechanical) plus new cases (§5
  Phase 1).

**(b) Signature side — `LssInfer.elm`.** `sigEdgesGo` (:793-855) return
type `Maybe ( List Int, List Int )` → `Maybe ( List Int, List Int, Bool )`
(members, promoted ordinals, sawFlex); the FlexVar arm (:849-850) recurses
with `True`; all arms thread. `sigResolveEdges` (:771-790) applies:

```elm
Ok ( Just ( members, ordinals, sawFlex ), s1 ) ->
    if sawFlex && Engine.argFlowOn s1 && not (List.isEmpty members && List.isEmpty ordinals) then
        -- LSS_026(a): a members- or sources-carrying fact that internalized
        -- a dangling (FlexVar) inflow may not claim completeness — the
        -- dangling inflow is an untracked inhabitant channel (§0.5). A
        -- promoted-ordinals-only fact is NOT exempt: the caller-side edges
        -- deliver ordinal members, but the dangling inflow is in NEITHER
        -- channel.
        Ok ( { top = True, members = [], sources = [] }, Engine.bumpTopMixedFlexSig s1 )

    else
        <existing self-filter + List.sort path verbatim>
```

The all-empty case (`members=[] ∧ ordinals=[]`) keeps today's non-top empty
fact — consumers write nothing (applyFactsGo :234-265 touches a slot only
for top/members/sources), the slot stays flex, reads ⊤: sound, and it
preserves the trivial mass. Census bumps (report-gated, flag-independent)
per §2.1 row 2 sit in the same branch.

### §3.3 D1 — translate-side connection (the core)

**Design.** For a Call-class argument, its own translation already unifies
its callee-instantiation residual with a fresh load of the arg-call's
canType (`unifyResultWithExpected`, Translate.elm:3755-3766 →
`resultVarAfter` :3769-3784). The outer call separately loaded the SAME
canType as `canVar` (`argUnifyVar` :3137-3155) and unified it with the
param slot. Two loads of one canType share only leaf MVarIds (LSS_006) —
the arrow classes are disjoint: that is the leak. D1 threads `canVar` into
the arg's translation and adds ONE best-effort unification: arg-call
residual ↔ `canVar`. Facts (members) and live LsFrom edges then ride the
shared UF class into the outer param slot; pull-at-read keeps deferral
(slot unify merges LsFrom keeping sources — Compiler/Type/Unify.elm:790-804).
No second instantiation, no snapshot, no annotation-first hazard.

**Edits (`Translate.elm` unless noted).**

1. **Set** — `translateArgsWith`'s new arm (§3.1 W0.6):

```elm
( StashArgFlow canVar, _ ) ->
    \s0 ->
        let
            aux0 = s0.itemAux
        in
        case translate arg { s0 | itemAux = { aux0 | argFlowExpected = Just canVar } } of
            Err e ->
                Err e

            Ok ( monoArg, s1 ) ->
                let
                    aux1 = s1.itemAux
                in
                case aux1.argFlowExpected of
                    Nothing ->
                        -- consumed at translateCall entry (connected or
                        -- counted as dropped there)
                        Ok ( monoArg, s1 )

                    Just _ ->
                        -- never reached translateCall (defensive): clear +
                        -- count. Sound: canVar stays unwritten → flex →
                        -- ⊤-at-read.
                        Ok ( monoArg, Engine.bumpArgFlowDropped { s1 | itemAux = { aux1 | argFlowExpected = Nothing } } )
```

2. **Consume at `translateCall` ENTRY** (:1548-1583) — this is the fence
   that stops the pending var leaking into NESTED translations (fast paths
   translate their args internally; an indirect call translates its func
   expr — a nested Call there must never see the pending). Wrap the body:

```elm
translateCall region func args callCanType s00 =
    let
        ( maybeOuter, s0 ) =
            Engine.takeArgFlowExpected s00   -- reads + clears itemAux.argFlowExpected
    in
    case func of
        TOpt.VarGlobal … -> … translateGlobalCall region funcRegion global funcCanType args callCanType maybeOuter s1
        TOpt.VarKernel … -> dropArgFlow maybeOuter (translateKernelCall …)     -- count-drop
        TOpt.VarDebug …  -> dropArgFlow maybeOuter (translateKernelCall …)     -- count-drop
        TOpt.VarLocal / TrackedVarLocal -> localCalleeCall … maybeOuter …      -- threads to the LM path
        _ -> dropArgFlow maybeOuter (translateIndirectCall …)                  -- v1: count-drop (census row leak|indirect)
```

   `takeArgFlowExpected : S -> ( Maybe IO.Variable, S )` (Engine.elm helper);
   `dropArgFlow` bumps `argFlowDropped` iff `Just _` and runs the
   continuation. When `argFlowOn` is off the pending is always Nothing and
   `takeArgFlowExpected` is a cheap read — but keep it UNCONDITIONAL so a
   stale value can never survive (belt over the flag).

3. **Thread** `maybeOuter` through `translateGlobalCall` (:2439-2474): the
   fast arms (M2a `translateGlobalCallFast`, M2b
   `translateGlobalCallGroundMemo`) get `dropArgFlow maybeOuter (…)` — note
   an arrow-bearing arg already forces `lssFastOk = False`
   (:2486-2487), so a Just here is only reachable via the `groundCanType`
   guards' edge cases; count-drop keeps it honest. Both slow-arm calls pass
   it through. `localCalleeCall` (:1592-1604) threads to
   `translateLocalMultiCall`; its non-LM branch (indirect) count-drops.

4. **Connect** — in `translateGlobalCallSlow` (:2815-2869), new parameter
   `maybeOuter`, one new step between `unifyResultWithExpected` (:2837) and
   `translateArgsWith` (:2842):

```elm
{-| LSS_026(b): connect this call's instantiation residual to the OUTER
call's arg var — the TIU-App half for call-shaped arguments. Additive: the
existing expected-load unify ran first and is untouched. Best-effort: a
shape mismatch leaves the store as-is (the arg var stays flex → ⊤-at-read —
sound; the declined-class invariant). -}
connectArgFlow : Maybe IO.Variable -> IO.Variable -> Int -> Step ()
connectArgFlow maybeOuter funcVar argCount s0 =
    case maybeOuter of
        Nothing ->
            Ok ( (), s0 )

        Just outerVar ->
            case resultVarAfter funcVar argCount s0 of
                Err e ->
                    Err e

                Ok ( Nothing, s1 ) ->
                    -- over-applied/opaque spine: nothing to connect
                    Ok ( (), Engine.bumpArgFlowDropped s1 )

                Ok ( Just residualVar, s1 ) ->
                    case unifyStepBestEffort residualVar outerVar s1 of
                        Err e ->
                            Err e

                        Ok ( _, s2 ) ->
                            Ok ( (), Engine.bumpArgFlowConnected s2 )
```

   Same insertion in `translateLocalMultiCall` (:1613-1659, after its
   :1631 `unifyResultWithExpected` step) — an arg that is itself a
   local-multi call connects identically.

5. **Soundness/behavior notes (put in the landing commit message):**
   - The unification joins two skeletons of the SAME canType whose leaves
     are already memo-shared — no new scalar/number information is
     introduced; set slots only ever JOIN (LsMembers union / LsFrom
     source-keeping merge). A best-effort failure no-ops (store untouched).
   - Declined-class invariant (LSS_026(c)): every path that declines to
     connect (kernel, indirect, fast, over-applied) leaves `canVar`
     member-UNWRITTEN — flex → ⊤ at read; never a members-carrying slot
     with an untracked inflow. `argFlowDropped` counts every decline.
   - The pending-slot discipline (set → consume-at-entry → defensive clear)
     makes mis-attribution to a nested call impossible by construction;
     `argFlowDropped` + `connected` sum to the `StashArgFlow` population
     (assert in the Phase-2 unit test).

### §3.4 D2 — inference-side twin (close A.1, with the honesty rule)

**Design.** The inference walk's `unifyParamsBestEffort`
(LssInfer.elm:1354-1384) already unifies each param position with a fresh
load of the arg's canType — memberless (A.1). D2 threads the args' OWN
WalkPoints in and flows them INTO the param positions, converting dangling
sources into real inflows. The Call arm currently walks args only AFTER
walkCall and discards their points (walkExpr :1006-1017, walkChildren
:2606-2618); `walkCollect` (:2587-2599) already exists.

**Edits (`LssInfer.elm`).**

1. **Call arm restructure** (flag-gated; flag-off body VERBATIM):

```elm
TOpt.Call _ func args meta ->
    \s0 ->
        if Engine.argFlowOn s0 then
            case walkCollect letEnv args [] s0 of
                Err e -> Err e
                Ok ( argWpsRev, s1 ) ->
                    case walkCall letEnv func args (List.reverse argWpsRev) meta s1 of
                        Err e -> Err e
                        Ok ( wp, s2 ) ->
                            -- args walked ONCE above; only func remains
                            case walkChildren letEnv [ func ] s2 of
                                Err e -> Err e
                                Ok ( _, s3 ) -> Ok ( wp, s3 )
        else
            <existing: walkCall (argWps = []) then walkChildren (func :: args)>
```

   (`walkCollect` prepends — reverse before use.) Recorded consequence: the
   flag-on arm walks args BEFORE the callee shape-unify. The scratch store
   is a monotone-join fixpoint read once at unit end, so ordering is not
   semantically load-bearing; flag-off order is untouched (byte-identity),
   and flag-on divergence is gated by the Phase-3 battery + determinism ×2.

2. **Threading.** `walkCall` (:1258-1283) gains `argWps : List WalkPoint`:
   - `VarGlobal`/`VarCycle` → `applyCalleeAt g … argWps`;
   - `VarKernel`/`VarDebug` → UNCHANGED (pass nothing; kernel boundaries
     are LSS_021/022's domain — licensed rows already define param
     semantics, poison rows poison; v1 does not flow arg points across the
     kernel ABI);
   - `VarLocal`/`TrackedVarLocal` → `localCalleeJoin … argWps`;
   - `_` → `Ok ( WpNone, s0 )` unchanged.
   `applyCalleeAt` (:1286-1324) passes argWps to `unifyCallShape` in BOTH
   arms (the Σ in-progress arm included — flowing a self-call's arg points
   into the shared signature slots IS TIU-Self-Ref-compatible: monotone
   joins into the same slots the unit already owns).
   `unifyCallShape` (:1334-1351) passes to `unifyParamsBestEffort`.

3. **The flow + honesty rule.** `unifyParamsBestEffort` (:1354-1384) gains
   the wps list (zip; when wps run out — flag-off callers pass `[]` — pad
   `Nothing` and the step is skipped entirely, preserving today's ops
   exactly). After the existing `Store.unifyBestEffort pParam argVar`
   (:1375), one new step per arg:

```elm
{-| LSS_026(d): flow an argument's walked point into the callee
instantiation's param position — the inference half of the TIU-App repair.

  - WpHonest/WpOpaque: DIRECTED flow, arg INTO param (`flowArrowSetsSig`,
    the :1478 orientation). Empty-or-honest (WpOpaque) is sound to EDGE
    from under D0: an empty (flex) source now widens any members-carrying
    readback to ⊤ instead of vanishing (§0.5) — this is the B.0
    re-argument, recorded in fidelity-3 by this landing. Symmetric HUB
    mixing of opaque points stays banned (unchanged).
  - WpNone/WpSelf on an ARROW-MENTIONING arg: POISON the param position
    (`Store.poisonArrowSets pParam`). A silent skip would leave a
    members-only fact with NO trace of this arg's inhabitants —
    publish-while-blind, the one §0.5 shape D0 cannot see (no edge to
    catch). Explicit ⊤ is the honest price; `argFlowWpPoisoned` counts it
    and the §2 blind-shape row forecasts it.
  - Arrow-free args: skip (no set positions exist).
-}
flowArgWp : Maybe WalkPoint -> TOpt.Expr TypeIds.MVarId -> IO.Variable -> Step ()
```

   In `joinCallArgs` (:1442-1489, the local-callee/letEnv-family path) the
   same step follows the existing `flowArrowSetsSig argVar pParam` (:1478).
   Note the poison arm there hits the SHARED family point — that is the
   correct semantics (the family aggregates all sites; one blind site means
   the family's set is incomplete at that position), but it is the
   mechanism by which honesty costs precision — the census row and Phase-3
   counters decide whether a narrower v1 (skip-at-family + recorded
   residue) ships instead. Default: poison, per the invariant.

4. **Docs updated by this landing:**
   `design_docs/auto-borrow-inference/lss-fidelity-3-*.md` — §B.0 WpOpaque
   re-argument (text above); the A.1 ledger row → "closed for global-callee
   and local-callee args under lss.callArgFlow; kernel-boundary and
   fresh-load residues remain open (rows)". The `walkCall` module doc
   (:1252-1256) and the A.1 doc (:1387-1393, 1518-1525) rewritten to
   describe the flag-on arm.

### §3.5 Exploitation honesty (per member class)

- **Raw `l|` members** (the IO-family case): unstampable at AbiCloning
  (LSS_017 noInstance — expect `declinedNoInstance` to GROW as slots
  convert from flex to concrete-raw). Buys: analysis reach, sum-lowering
  feedstock (`plans/lss-sum-lowering.md`), BORROW_006 meets, de-⊤'d demand
  keys. Stamping enablers stay separate (LSS_017-v2 /
  `plans/lss-fork-qualified-members.md` §8).
- **`g|`/`c|` members**: signature facts carry these too; they GROUND at
  the consuming zonk (LSS_019) and ARE consumable by LSS_025 post-settle
  devirt and E9.1. LSS_025's licence text is unchanged but its candidate
  population GROWS — the Phase-2 pins cover both directions (sound stamp,
  false-stamp guard) with `postSettleDevirt=1`, `devirtFnGlobals=1`.
- Phase-4 watches the sigFlow-arc failure mode (de-stamping via key
  reshuffling): acceptance is "no fast-coverage regression on
  exact-count-matched per-fp census; analysis metrics move as predicted";
  gains are upside, not gate.

## §4 Soundness, termination, invariants

- **Direction of error.** Forward-channel completeness rests on four legs:
  (i) unconstrained direct reads = LTop (Store.elm:1554-1556); (ii) empty
  LsFrom resolution = LTop (:1521-1527); (iii) hub-opacity poison; (iv)
  write-completeness of edge-reachable sources. Leg (iv) is what D0 guards
  and D1/D2 preserve (connect-or-⊤); §3.3's declined-class inventory is the
  enumeration. `Mono.LSet` is a completeness claim; `LTop` is the honesty
  fallback — never `LSet []` (LSS_001).
- **LSS_005 envelope**: annotations/spec counts/dispatch tiers may move;
  observable behavior may not. Flag-on self-compile + determinism ×2 + E2E
  both arms are the behavioral gates.
- **Termination.** Transport-enriched demands mint keyed specs whose
  lambdas intern Q(L, annotation-WIDENED creation key); `widenSets` strips
  exactly what the transport adds, so annotation-only generations re-intern
  generation-1 ids (LSS_024) and the id universe is fixed after ≤2
  generations (raw→qualified is the one new id per lambda; LSS_018 covers
  the SpecId-fallback arm). Under `layoutQualMembers=0 ∧ muTie=0` the
  budget is the only terminator — the flag doc states this configuration
  dependence. Ground-id interning is bounded by globals×layouts; MONO_030
  watchdogs backstop. LSS_010's monotone join + ≤100 flush rounds
  unchanged.
- **LSS_013**: D1/D2 add no `injectSpineMemberId` site; facts reaching the
  arg-callee's own param ordinals are written by the standard
  `applyFactsGo` at its single instantiation — today's behavior at every
  direct call. The argument-position injection ban is untouched. (D2's
  poison arm writes ⊤, which LSS_013 never restricted — widening only.)
- **LSS_020/023**: honesty rule enforced (publish-or-poison); snapshot
  internalization stays banned (D1 connects, never copies); D2's directed
  flows carry the variance argument in-code (the `flowArrowSetsSig`
  orientation comments).
- **Budget sequencing — ✅ DISCHARGED 2026-08-23.** The prerequisite is met:
  `defaultLss.maxSpecsPerGlobal` is now **512** (was 64), landed with
  benchmarks/lss-opt.md **Run AF** as this plan's baseline. Evidence at the
  flip: `widened byBudget` 39,052 → 8,575 (−78%) against the same source at
  64, `joins changed` 1,732 → 600, `retranslations` 542 → 232,
  `devirtDirect` 4,000 → 4,453, and 512 captures ~77% of the distance to
  4096 at a fraction of its fan-out. GC-neutral (minor 1,485 → 1,484,
  majors equal at 16). Every Phase-2/3/4 measurement therefore runs at 512
  by default; keep a 64 arm only as the absorption control if one is needed.

## §5 Phases — work orders

### Phase 0 — census — ✅ DONE 2026-08-23

1. ✅ W0 (§3.1) landed + the §2.1 census bumps, permanent and report-gated
   (no strip-after step). Artifact rail PASSED twice: the instrumented
   binary's self-compile output is byte-identical to the HEAD binary's on
   the same source (`5cd0f1d6…`, then `5836c7d4…` after the cross-tab
   addition) — artifact-neutral flag-off, report-neutral, bootstrap fixed
   point intact.
2. ✅ Census run per §2.5; artifact `/work/lss-gap2-phase0-census.txt`
   (3,456 rows). Three arms: shipping config, budget-4096 control, flag-on
   inertness.
3. ✅ §2.2 evaluated — see §2.6. Verdict PROCEED, scope corrected.
4. Test status at Phase 0: elm-tests **13,192 passed / 12 failed**. All 12
   failures are typechecker constraint-generation gates (POST_010,
   TYPE_007, golden fingerprints) and are **PRE-EXISTING, not from this
   change**: their test modules import neither `MonoSolver` nor
   `Eco.Config` (verified), the monomorphizer runs strictly downstream of
   constraint generation, `Compiler/Type/Constrain/Typed/Expression.elm`
   was last modified 2026-08-20 (the in-flight typechecker refactor,
   3 days before this work), and the artifact rail is byte-identical. They
   must be green again before this plan's own flip, but they do not gate
   Phase 1.

**Baseline for everything below: benchmarks/lss-opt.md Run AF** (2026-08-23,
budget 512, this plan's census instrumentation in): wall 359.7 s, minor
1,484, major 16, promoted 14,747 MiB, `out.mlir` 14,370,158 B. Recorded
instrument cost of the census under `report=1` is ≤0.75% wall and +2 major
GCs versus the same source with no census — carried identically by every
later row, so AF→AG comparisons are clean, but AE→AF ones are not. If that
+2 majors ever masks a signal, move the long-key rows (`fan|`, `popt|`,
`calleeTriv|`) behind their own env before the run rather than reading
through it.

### Phase 1 — D0 + pins — ✅ DONE 2026-08-23, ESCALATED TO UNCONDITIONAL

**Outcome: D0 is no longer flag-gated.** The §0.5 hole is a LIVE MISCOMPILE
at the shipping default — see §0.5b for the witness, the three-arm isolation
and the applied consequence.

Landed:

1. ✅ §3.2 was already in at HEAD (flag-gated); this phase removed the gate on
   both readers. `zonkToMono` seeds `honestSources = True`;
   `sigResolveEdges` no longer consults `Engine.argFlowOn`.
   `LssZonkAcc.honestSources` survives for the pins only.
2. ✅ Pins:
   - NEW `compiler/tests/TestLogic/Monomorphize/LssHonestSourcesTest.elm`
     (12 tests, store level, `LssDirectedFlowTest` harness precedent): the
     mixed → ⊤ / mixed → false-set RED/GREEN pair, the `Just []` non-case,
     the written-source control, ⊤-absorption-beats-mixed, cycle-with-flex,
     and the `gc`-vs-`l` class split of `mixedFlexGc`.
   - NEW `compiler/tests/TestLogic/Monomorphize/LssCallArgFlowTest.elm`
     (pipeline level, `LssSigFlowTest` harness precedent) — the §0.5
     `pickG`/`d` fixture in both the `g|` and the lambda variant, the
     unmixed negative control, and the counter-line accounting.
   - NEW `test/elm/src/LssMixedSigHonestyTest.elm` — the runtime witness.
3. ✅ Gates:
   - elm-tests **13,210 passed / 12 failed**; the 12 are byte-for-byte the
     SAME pre-existing typechecker constraint-gen failures as the Phase-0
     baseline (`diff` of the sorted `✗` lists is empty). +18 = the new pins.
   - E2E full suite: **1,687 / 1,687 PASSED**.
   - Self-compile at the shipping config: `topMixedFlex=0/0`. The rule's
     only behavioral branch is never entered on the compiler's own corpus,
     so the escalation is inert THERE by construction — a stronger statement
     than a byte comparison, which cannot apply because the self-compile
     corpus IS the edited source (the artifact moved 80 B, exactly the
     deleted branch).

**Correction to a Phase-0 conclusion.** §2.6 read `mixed = 0` as "the shape
is unexercised at HEAD". That is true of the self-compile and false as a
safety claim: a zero census over one corpus is not an absence proof for a
soundness hole. The census was the wrong instrument for the question; the
constructed witness was the right one. This is why the pin lives in
`test/elm/src` and not only in a unit test.

<details><summary>Original Phase-1 work order (superseded above)</summary>

1. Implement §3.2 (both readers).
2. Unit tests:
   - NEW `tests/TestLogic/Monomorphize/LssHonestSourcesTest.elm` (store
     level, `LssDirectedFlowTest` harness precedent — hand-built store,
     ZonkCtx built directly): (a) members + dangling-flex source →
     honest-on resolves Nothing(⊤) / honest-off resolves the members
     (RED/GREEN pair); (b) members=[] + dangling flex → `Just []` both arms
     (unchanged LTop path, no counter bump); (c) members + written source →
     exact union, unchanged; (d) cycle/⊤ cases from LssDirectedFlowTest
     re-asserted under the new signature.
   - NEW sig-side pipeline pin (in `LssSigFlowTest.elm` or a sibling): the
     `pick`/`d` §0.5 fixture — flag-OFF: d's result fact reads
     `{members=[l|lam]}` (the RED pin: asserts the HOLE EXISTS at HEAD so
     the record stays honest); flag-ON: `top=True` (D0, pre-D2). Phase 3
     updates the flag-on expectation to the connected form.
   - E2E runtime pin: `test/elm/src` program in the `pick`/`d` shape whose
     OUTPUT would differ under a false-singleton stamp (e.g.
     `d identity 41` must print 41); runs in both arms.
3. Gates: flag-off byte-identity; elm-tests; flag-on solver+LSS
   self-compile green; E2E full both arms (fresh eco-stuff, touched
   fixture, serial).

</details>

### Phase 2 — D1 + pins — ✅ DONE 2026-08-23

**Landed** (`Translate.elm`): `translateCall` takes the pending at ENTRY via
`Engine.takeArgFlowExpected` before dispatching on the callee — that
placement is the fence against nested attribution, and it is unconditional
(belt over the flag). `dropArgFlow` count-drops the kernel/Debug/indirect
arms and the M2a/M2b fast arms; `maybeOuter` threads through
`translateGlobalCall` → `translateGlobalCallSlow` and `localCalleeCall` →
`translateLocalMultiCall`. `connectArgFlow` (via `unifyResultAndConnect`,
sequenced after `unifyResultWithExpected` so the pre-LSS_026 op order is
preserved) peels `argCount` arrows with `resultVarAfter` and
best-effort-unifies the residual with the outer arg var.

**Rails — all PASS** (native self-build harness, budget 512, `report=1`).
Rail logic: self-hosting is a tested fixed point, so the emitted `.mlir` is a
function of (source, config) only — WHICH correct compiler compiles is
immaterial. So the inertness rail is OLD-code binary vs NEW-code binary over
the SAME final source:

| rail | result |
|---|---|
| flag-off inertness (old-code vs new-code binary, same source) | **PASS** — byte-identical, md5 `f0f33fecca6c25ba78985e15c27c0cdc` |
| flag-on determinism ×2 | **PASS** — md5 `6f873d4d38f2fc9dc850a5000ae67cbd` both runs |
| bootstrap fixed point | implied by the first row (the new binary reproduces its own input) |

That one identity also discharges D0's escalation rail: the flag-off arm
carries unconditional D0 and still lands byte-identical to the pre-D0 binary.

**Counters, flag-off → flag-on:**

| counter | off | on |
|---|---:|---:|
| `argFlow connected` | 0 | **2,480** |
| `argFlow dropped` | 0 | 1,442 |
| `pop\|all` (census) | 3,916 | 3,922 |
| singleton sets (`sizeHist 1->`) | 100,999 | **111,769** (+10.7%) |
| `grounding grounded` | 12,657 | 12,706 |
| `layoutQual shared` | 8,632 | 8,711 |
| `devirtDirect` | 4,453 | **4,453** |
| `widened byBudget` | 8,585 | 8,584 |
| `topMixedFlex` | 0/0 | **0/0** |
| `stashmiss\|all` | 0 | 0 |
| `out.mlir` (B) | 14,385,140 | 14,395,736 (+0.07%) |

Four things worth stating plainly:

1. **The accounting identity is exact on the self-compile**:
   `connected 2,480 + dropped 1,442 = 3,922 = pop|all`. LSS_026(c) holds with
   no residue, and this settles §2.6's open "541-site gap" — it was the
   budget-64 regime, as §2.6b row 10 predicted; at 512 `stashmiss` is 0 and
   every armed stash is accounted for.
2. **+10,770 singleton sets** is the analysis-reach win, and it is larger
   than the 2,480 connections because a transported set propagates through
   the keyed specs downstream of each connected site.
3. **`devirtDirect` is FLAT at 4,453** — exactly §3.5's honesty statement.
   The transported mass is raw `l|`, which declines at AbiCloning
   (LSS_017 noInstance). Reach was the deliverable; dispatch was not
   promised.
4. **`topMixedFlex` stays 0/0 with the flag ON.** D1 does not manufacture
   mixed facts — connecting is precisely what stops a source dangling, so
   the two halves of LSS_026 compose in the intended direction rather than
   fighting.

**Pins** (`LssCallArgFlowTest.elm`, 13 tests): the transport pin (flag-off ⊤
at the consumer's param arrow, flag-on a carried member); the accounting
identity against the `pop|all` census row; the under-applied arg call
connecting at the right depth; a LOCAL-MULTI arg-callee connecting (found by
the test — the let-bound `h = mkAdd` case takes the local-multi arm, not the
indirect one); a CASE-bound (genuinely indirect) callee declining; a
trivial-signature arg-callee transporting nothing and leaving ⊤ rather than
`LSet []`; and the §0.5 guard re-asserted with `postSettleDevirt` and
`devirtFnGlobals` both ON.

<details><summary>Original Phase-2 work order (superseded above)</summary>

1. Implement §3.3.
2. Unit pins (elm-test, Monomorphize dir):
   - readPointCell-shape producer + andThen-shape consumer: flag-on the
     consumer's param-position annotation zonks `LSet [l|inner]`, flag-off
     `LTop`.
   - under-applied arg call: residual connects at the right depth.
   - trivial-sig arg-callee: no-op; `argFlowDropped` accounts for it;
     assert `connected + dropped == StashArgFlow population`.
   - transported bare-`g|` (producer returning a top-level global):
     consumer site with `postSettleDevirt=1`, `devirtFnGlobals=1` —
     stamp-correct-or-decline, and the §0.5 E2E pin stays green (the
     false-stamp guard).
   - kernel-callee arg and indirect-callee arg: dropped (⊤-reachable), not
     connected — the declined-class pins.
3. Gates: Phase-1 list + determinism ×2 (two runs, byte-identical
   artifact) + poly-rec fixture still watchdog-aborts.

</details>

### Phase 3 — D2 + honesty — ✅ IMPLEMENTED + PINNED 2026-08-23

**Landed** (`LssInfer.elm`), all flag-gated with the flag-off arm verbatim:

- `walkExpr`'s `Call` arm: under `argFlowOn`, `walkCollect` the args FIRST and
  keep their points (reversed — `walkCollect` prepends), then `walkCall` with
  them, then `walkChildren [ func ]` only. Flag-off keeps the old
  `walkCall … []` + `walkChildren (func :: args)` order untouched.
- `walkCall` → `applyCalleeAt` (BOTH arms, Σ in-progress included) →
  `unifyCallShape` → `unifyParamsBestEffort` thread `argWps`; the zip pads
  `Nothing`, so flag-off callers passing `[]` reproduce today's op sequence
  exactly. `localCalleeJoin` → `joinCallArgs` threads the same list (the
  alias-chase arm does NOT consume a position).
- `flowArgWp`: `WpHonest`/`WpOpaque` → `flowArrowSetsSig argPoint pParam`
  (`argFlowWpFlowed`); `WpNone`/`WpSelf` at an arrow-mentioning arg →
  `Store.poisonArrowSets pParam` (`argFlowWpPoisoned`); arrow-free → skip.
- Kernel boundaries pass `[]` explicitly, in both `walkCall`'s arm and the
  licensed `kernelCallBoundary` path — v1 does not flow arg points across the
  kernel ABI, since the audited LSS_021/022 rows already define param
  semantics there.

**THE RESULT THAT MATTERS — D2 closes the §0.5 hole rather than widening over
it.** Measured on the `pickG`/`d` fixture:

| | flag-off | flag-on (D1+D2) |
|---|---|---|
| `topMixedFlex` | **1/0** | **0/0** |
| `d`'s result annotation | `LTop` (D0 widened it) | `LSet[…]` of size **2** |

Flag-off the inflow really dangles, so D0 must widen. Flag-on D2 CONNECTS it,
so the fact is no longer mixed at all and the caller resolves the TRUE union —
`{g|incr}` plus the caller's own lambda. Soundness and precision move the same
way, which is the outcome §4's "connect-or-⊤" was aiming at. This is exactly
the Phase-4 closure criterion ("`mixed|*` reads 0 with the repair on — the hole
is CLOSED, not merely widened-over") demonstrated at fixture scale.

**Self-compile counters, D2 flag-off → flag-on** (the D1 columns are the
Phase-2 table; these are the same binary with D2 also in):

| counter | off | on | reading |
|---|---:|---:|---|
| `argFlow wpFlowed` | 0 | **11,885** | the inference-side flows D2 adds |
| `argFlow wpPoisoned` | 0 | **104** | blind arrow args — the honesty price, and it is small (§2.6b row 13 forecast 57 at local-callee family points) |
| `sigflow edges` | 177 | **16,896** | the LsFrom channel goes from barely-populated to heavily used — §2.6b row 9 predicted D1/D2 would be "that path's first real customer" |
| `sigflow widenedByCf` | 5,344 | 8,218 | container-degraded flows, up 54% |
| `sigflow degraded` | 4 | 394 | ditto |
| **`topMixedFlex`** | 0/0 | **2/0** | ← see below |
| signatures trivial | 9,472 | 9,468 | four more signatures went non-trivial |
| singleton sets | 101,002 | 111,772 | unchanged from D1 alone |
| `devirtDirect` | 4,453 | 4,453 | flat, as at D1 |

**`topMixedFlex` 0 → 2 is the single most important number in this phase.**
§0.5 said D0 "remains a hard prerequisite for D1/D2, which by construction
CREATE edge-reachable sources". That was a prediction; it is now measured.
With the transport on, the self-compile produces two members-carrying facts
that reach an unwritten inflow — and without unconditional D0 those two would
have been published as COMPLETE sets. The transport did not just fail to need
the honesty rule; it manufactured work for it.

**Read honestly, D2's marginal precision on THIS corpus is small.** 11,885
flows and 16,896 edges buy four more non-trivial signatures and zero
additional singleton sets beyond D1's. That is not a failure of the
mechanism — it is Phase 0's headline restated (`allflex` 62.6% vs `carrying`
2.8%: the producer side is the ceiling) — but it does mean D2's case rests on
fidelity and on unblocking the producer-side work, not on this workload's
numbers. Phase 4 measures what it costs.

**Pins** (`LssCallArgFlowTest.elm`, now 16 tests): `wpFlowed > 0` on a def that
passes its own arrow-typed parameter as an argument; `wpPoisoned > 0` on a
case-bound (blind) arrow argument; both D2 counters zero flag-off; and the §0.5
pins retargeted to the honest predicate (⊤ **or** a ≥2-set — never the false
singleton).

**Gates — all PASS:**

| gate | result |
|---|---|
| flag-off inertness (two-binary rail, same final source) | **PASS** — md5 `8f4160bf3bdc2903a2d4ce8da18c15e1` |
| flag-on determinism ×2 | **PASS** — md5 `ddfd249803005c3700882efea54a2842` |
| elm-tests | **13,220 passed / 12 failed**, failure set byte-identical to the Phase-0 baseline (+28 pins across the three phases) |
| E2E full, flag OFF | **1,687 / 1,687** |
| E2E full, flag ON | **1,687 / 1,687** |

(The determinism pair also settled an incidental question: a doc-comment edit
landed between the two flag-on arms and the artifacts are still byte-identical,
so comment-only edits are artifact-neutral — `srcLambdaKey` is an allocated
`Id`, not a region.)

**Two fixture facts worth recording, both found by the tests:**

- A case-destructuring of a LITERAL tuple is folded away before mono, so the
  first blind-arg fixture registered no walk event at all. The scrutinee has to
  be a parameter.
- The "trivial arg-callee" pin refuted its own premise: `pickId n = idf incId`
  RETURNS a standalone global, so its signature is not trivial and the
  transported `LSet[g|incId]` is a true singleton. The test was rewritten as
  the LSS_001 pin it should have been — a connect must never manufacture
  `LSet []` — checked over every annotation of every fixture in both arms.

<details><summary>Original Phase-3 work order (superseded above)</summary>

1. Implement §3.4 (walk restructure, threading, flowArgWp, joinCallArgs
   arm), including the walk-order line item and the fidelity-3 §B.0 + A.1
   ledger edits.
2. Pins: `UnionFind.get`-shape wrapper (def whose body is
   `producer arg`) — flag-on `get`'s signature carries the composed fact
   (members or promoted source), flag-off trivial-or-⊤ as today; a
   blind-arg case (case-bound local passed to a HOF) → param fact top=True,
   `argFlowWpPoisoned` bumped; the §0.5 fixture's flag-on expectation
   updated to the connected 2-set/promoted-source form.
3. Gates: Phase-2 list, both arms.

</details>

### Phase 4 — measurement — ✅ DONE 2026-08-23 (budget 512; no 64 arm — see below)

All arms are the SAME binary (`eco-compiler-d2`, built from the final source)
compiling the compiler; only `ECO_MONO_LSS_ARG_FLOW` moves. Wall/GC measured
with the census and the dispatch counters OFF; the dispatch census measured on
separately-lowered counters binaries with `ECO_DISPATCH_STATS=1` in BOTH arms,
so its ~7.5% overhead is a constant offset that cancels.

**A/B wall + GC (`/usr/bin/time -v`, cold `eco-stuff`, n=1 per the determinism
record):**

| | flag OFF | flag ON | Δ |
|---|---:|---:|---:|
| wall (s) | 358.11 | 367.72 | **+2.68%** |
| max RSS (kB) | 6,905,748 | 6,928,244 | +0.33% |
| minor GCs | 1,514 | 1,526 | +0.79% |
| **major GCs** | **15** | **15** | **0** |
| promoted (MiB) | 14,826 | 14,847 | +0.14% |
| `out.mlir` (B) | 14,389,393 | 14,399,989 | +0.07% |

Wall is **above the ±1.1% noise floor and below the ≥3% action band** — a real
but small cost, and it is where the mechanism says it should be: D1 adds one UF
unify per call-shaped arrow argument (3,922 of them) and D2 adds 11,885 set
flows plus 104 poison walks. Majors identical at n=1 is the strong GC statement
(majors are a deterministic step function of occupancy, not a lottery).

**No budget-64 control arm was run.** §4's prerequisite is discharged (512 is
the shipping default) and Phase 0's budget-exclusion control already showed
every STRUCTURAL quantity invariant between 64 and 4096, so a 64 arm would
re-measure absorption, not this change. Recorded rather than silently skipped.

**Dispatch census — THE FLIP GATE, and it FAILS.** Both arms lowered with
`ECO_LSS_DISPATCH_SITE_COUNTERS=1` from their own `.mlir`, each running the
corpus with `ECO_DISPATCH_STATS=1`:

| | flag OFF | flag ON | Δ |
|---|---:|---:|---:|
| `sat` | 1,780,856,389 | 1,792,507,699 | +11,651,310 |
| `gen` | 1,749,945,178 | 1,761,596,488 | **+11,651,310** |
| `typed` | 30,911,211 | 30,911,211 | **0** |
| `fast` | 505,374,807 | 493,723,497 | **−11,651,310** |
| **`sat + fast`** | **2,286,231,196** | **2,286,231,196** | **0 — EXACT** |
| **LSS coverage** | **22.105%** | **21.596%** | **−0.51 pp (−2.31% rel.)** |
| distinct fps | 7,069 | 7,078 | +9 |

Two things are exactly true and worth separating:

1. **The `sat + fast` invariance rail PASSES to the event** — 2,286,231,196 in
   both arms. The transport converts dispatch TIERS; it removes no counted
   work, so the comparison is clean and the census overhead cancels.
2. **Every lost `fast` dispatch became a `gen` dispatch** — the two deltas are
   ±11,651,310 and `typed` is bit-identical. So this is not a re-tiering into
   statically-known-arity dispatch; it is 11.65 M `$cap` calls falling out of
   static stamping into the generic/unknown-saturation funnel. That is the
   §7-risk-2 **de-stamping-via-key-reshuffling** class, exactly as forecast:
   the transported sets change annotation-keyed spec identity, LSS_024
   shelters annotation-ONLY splits, and layout-differing splits are outside
   that shelter.

**No per-symbol attribution is offered, deliberately.** `lambda_N` numbering
is corpus-specific and the two arms are different corpora, so a symbol-keyed
join across them aliases unrelated functions (the recorded trap — match by
symbol within an arm, never across binaries by index). The aggregate above is
index-independent and is the number the gate is written against; a per-site
attribution needs canonicalized body-hash multisets, which is follow-up work,
not a Phase-4 deliverable.

**Other Phase-4 checks:** MONO_030 watchdogs quiet (no EngineBug on either
arm); `join flush rounds=3 retranslations=235` identical in both arms;
`widened byBudget` 8,585 → 8,584, so fan-out did not move against budget 512
(Phase-0's forecast max was 184 distinct keys per consumer); AbiCloning
`declined=0` in both arms.

**`mixed|*` closure check — the one result that reads BACKWARDS from the plan's
expectation, and it is the right way round.** §5's Phase-4 item 4 expected
`mixed|* == 0` with the repair on, reasoning that connecting removes crossings.
Measured: **0/0 flag-off, 2/0 flag-on**. Both are consistent with the design
and the plan's own §0.5 sentence ("D1/D2 by construction CREATE edge-reachable
sources"), which the Phase-4 item did not carry through. At fixture scale the
transport CLOSES a crossing (`topMixedFlex` 1 → 0 on `pickG`/`d`); at
self-compile scale it also OPENS two new ones, because 16,896 fresh edges
create inflows that can dangle where none existed before. Both facts are the
same mechanism. The actionable reading is not "investigate before flip" but
"D0 is load-bearing under the transport" — without it those two facts publish
as complete sets.

<details><summary>Original Phase-4 work order</summary>
1. §2.5 census re-run: IO-family consumer slots' flex+inherited-poison
   share vs the Phase-0 prediction (LSS_024's ≥85%-of-prediction device);
   `argFlow` counters; `declinedNoInstance` growth recorded, not feared;
   trivial-signature count.
2. lss-opt A/B: wall (±1.1% observed floor; ≥3% action band) + GC majors
   (exact at n=1 per the determinism record).
3. Dispatch census via `/work/benchmarks/dispatch-census.sh`:
   exact-count-matched per-fp multisets, match by symbol never index; the
   `sat+fast` invariance rail; per-arm `rm bin/eco-compiler{,.mlir}`.
4. Spec fan-out vs the Phase-0 proxy; MONO_030 quiet; `mixed|*` counters
   read 0 with D0 on (the hole is closed, not merely widened-over) —
   nonzero means an unconnected class still carries members: investigate
   before flip.

</details>

### Phase 5 — flip decision — ✅ DECIDED 2026-08-23: **DO NOT FLIP.**
### `lss.callArgFlow` ships DEFAULT-OFF.

**The gate is explicit and it failed.** §3.5's acceptance condition for the
flip is "no fast-coverage regression on exact-count-matched per-fp census".
Phase 4 measured a **−0.51 pp (−2.31% relative)** LSS coverage regression —
11,651,310 statically-stamped `$cap` dispatches converted to generic dispatch —
on a census whose `sat + fast` total is exactly equal between arms, so the
measurement is not an artefact of the comparison. One failed hard gate is
enough; the decision needs no balancing.

For the record, the rest of the ledger, since it is what a re-open would have
to change:

| | |
|---|---|
| fast coverage | **−0.51 pp — GATE FAILURE** |
| mono wall | +2.68% (above the ±1.1% noise floor, below the ≥3% action band) |
| major GCs | 0 (15 = 15) |
| `out.mlir` | +0.07% |
| singleton sets | +10.7% |
| `sigflow edges` | 177 → 16,896 |
| `devirtDirect` | flat at 4,453 |
| non-trivial signatures | +4 |

Read together: the transport delivers exactly what §3.5 promised (analysis
reach) and exactly what §3.5 declined to promise (dispatch), and it charges
2.68% wall plus a coverage regression for the privilege. **There is no consumer
today that can spend the reach** — the transported mass is raw `l|`, which
declines at AbiCloning under LSS_017 noInstance, and the two consumers that
could use it (LSS_017-v2 raw→qualified bridging, and sum lowering) are recorded
non-goals of this plan, unbuilt. Paying a measured regression now for a benefit
that has no consumer yet is the trade this register has declined before (the
List.map template landed default-off on the same reasoning).

**Re-open criteria — flip when EITHER holds, and re-run Phase 4 as written:**

1. **A consumer lands that can spend `l|` reach** — LSS_017-v2 /
   `plans/lss-fork-qualified-members.md` §8 (raw→qualified stamping), or
   `plans/lss-sum-lowering.md`. Then the coverage regression may be paid for
   by a larger stamping gain, and the arithmetic changes.
2. **The de-stamping is repaired at its source.** The loss is entirely
   `fast → gen` with `typed` bit-identical, which points at annotation-keyed
   spec identity splitting sites that previously shared a stamped `$cap`.
   LSS_024's layout qualification already shelters annotation-only splits;
   extending that shelter to the splits the transport introduces would remove
   the gate failure without giving up the reach. **This is the highest-value
   follow-up this plan produced** and it is a concrete, bounded question:
   canonicalized body-hash multisets over the two arms will name the split
   sites (the per-symbol join cannot — see Phase 4).

**Because the decision is NOT to flip, the Stage-4b/8c bootstrap fixed points
were not run, and here is why that is sound rather than a gap.** Those gates
exist to protect a DEFAULT-path change. The default path here is flag-off, and
flag-off was proved byte-identical twice, by the strongest available rail: a
binary built WITHOUT the change and a binary built WITH it produce identical
`.mlir` from the same source (`f0f33fec…` at Phase 2, `8f4160bf…` at Phase 3).
Identical output from an identical input is precisely what the fixed-point
check asserts, so the bootstrap chain cannot diverge on an artifact that did
not move. They ARE required before any future flip, when the default path
starts to differ — recorded as a prerequisite of the re-open, not as
discharged.

**D0 is a separate matter and it DID change the default path.** It is a
soundness fix with a runtime witness (§0.5b), it is provably inert on the
compiler's own corpus (`topMixedFlex = 0/0` flag-off), and its gates are green:
elm-tests 13,220/12 with the failure set identical to baseline, E2E 1,687/1,687,
and the same two byte-identity rails above. It ships unconditional.

## §6 Fidelity to the paper (validation ledger)

| paper mechanism | Eco realization after this plan | verdict |
|---|---|---|
| One α shared between signature and body positions expresses flow-through (twice, 146:7 — α at ONE signature arrow position + body `as α` annotations; multi-position sharing licensed by the Fig. 2 grammar and mgu) | `ArrowFact.rep` (equality half) + `sources` (inclusion half, LSS_023) over signature ordinals | FAITHFUL for slotted arrow positions; **directed where the paper is symmetric** — divergence note below |
| Q's ground constraints `l ⋹ α` lower-bounding an open position (make-mult, 146:8) | `ArrowFact.members` at the ordinal; callers union per-instantiation | FAITHFUL at slotted positions; recorded divergence: the paper's inference never unions CONCRETE sets (146:10 — var~var equalities only; per-σ̄ specs never cross-join), while Eco's LSS_010 registry join + budget widening are cross-caller pollution the paper structurally lacks |
| Fresh instantiation per use (TIU-Def-Ref, 146:10) | `loadTypeIsolatedWithArrows` per call site | FAITHFUL for the instantiation; registry-layer caveat above |
| Argument's inferred type unifies with callee param (TIU-App, Fig. 5) | **D1/D2 — LANDED.** `connectArgFlow` (translate) + `flowArgWp` (inference), both connecting the SINGLE per-occurrence instantiation, the paper's own shape | FAITHFUL for global and local-multi/letEnv callees; kernel boundaries decline by design, indirect callees are a v1 non-goal — both count-dropped and ⊤-reachable, never silently partial |
| Internalization S(Q,α) (Fig. 7, 146:11) | `zonkSigGo` promote-or-internalize (per-def one-shot — faithful at the id level); demand-side pull is a global least fixpoint, precision-equivalent **only under write-completeness** — D0/D1/D2's obligation | FAITHFUL-with-obligation; the obligation is now DISCHARGED by construction rather than by hope — LSS_026(a) refuses to publish a set that crossed an unwritten inflow, so a write-incomplete region degrades to ⊤ instead of lying |
| TIU-Self-Ref / no set-parameter poly-rec (146:10,12-13) | Σ shared-scratch unit inference (LssInfer.elm:20-24) prevents set-parameter poly-rec by construction. TYPE-level poly-rec has no paper counterpart (L^src is simply typed, 146:5): in Eco it typechecks, runs on the JS target, and diverges in native mono, bounded by MONO_030 watchdogs (monomorphization-plan.md:1618-1630) | FAITHFUL on the paper's axis |
| μ lambda sets + μ-aware substitution (146:11,15) | id-only members sever set-in-own-identity (`widenSets`, LSS_019/024 keys) | DIVERGENT by design (μ-shaped residue re-enters at GAP-3, mapping :107) |

**Directed-vs-symmetric, restated.** Dropped BACKWARD flows are not
inhabitant channels; forward completeness rests on §4's four legs, of which
leg (iv) is this plan's own obligation — §0.5 is what its violation looks
like. Roc rejected directed flow for a layout reason this plan carries
forward, not waves at (`roc/reunify.md` §12.4 item 2: sets determine
closure LAYOUT; one-way ⊆ permits two layouts for one value, needing
re-tag coercions). Eco escapes today because lowering dispatches on ids —
but **sum lowering re-imports the objection wholesale**; the agreement
obligation and the chosen answer (lowering-time agreement closure) are
recorded in `plans/lss-sum-lowering.md`. The v1 claim that a symmetric
fallback is "a one-line change" is retracted — it stops being true the
moment a layout consumer exists.

**What the ordinal restriction cannot express** (fallback is ⊤, never
empty):

1. The boundary is the LOADER's: `loadTypeC` mints a slot for every
   `TLambda` it descends — including under containers (Store.elm:185-201) —
   and `applyFacts` pairs by that enumeration. The members/Q channel works
   at ALL loader-enumerated positions; containers lose only the DIRECTED
   discipline (`flowArrowSets` degrades subtrees to symmetric,
   LssInfer.elm:2210-2260); non-enumerated positions lose everything
   (⊤-by-absence via the length guard :205-206 — sound).
2. μ-recursive SETS — obviated by id-only members; sets under recursive
   DATATYPES follow item 1's loader boundary.
3. Non-spine equalities among unslotted positions — recorded, accepted.
4. The Q-ground channel — covered AT SLOTTED POSITIONS surviving the
   length guard; occurrence types instantiating tyvars into extra arrows
   poison the whole spine (sound, imprecise).
5. The `(λ…) as σ` target-set/agreement channel (146:6 bullet 3) — no Eco
   analog; inert while lowering is id-based; first obligation of sum
   lowering (see `plans/lss-sum-lowering.md` §2).

## §7 Risks

**Status 2026-08-23: 1, 6 and 7 are DISCHARGED; 3 was discharged before the
work started (budget-512 flip); 2, 4 and 5 are Phase-4 measurements.**

1. **The §0.5 class** — ✅ DISCHARGED, and it was the one risk that turned out
   to be a live defect rather than a hypothetical. Owned now by unconditional
   D0 + the connect + three layers of pin: store-level (`LssHonestSourcesTest`,
   both directions of the reader), pipeline-level (`LssCallArgFlowTest`, the
   `pickG`/`d` fixture in `g|` and `l|` variants), and RUNTIME
   (`test/elm/src/LssMixedSigHonestyTest.elm`, which fails on the pre-fix
   compiler). On the self-compile the counter reads 0 flag-off AND flag-on,
   and on the fixture it reads 1 flag-off / 0 flag-on — closed, not
   widened-over.
2. **De-stamping via key reshuffling** (Run-X/AB class): ⚠️ **MATERIALISED —
   this is the risk that decided the plan.** Measured at −0.51 pp fast
   coverage (11,651,310 `$cap` calls → generic dispatch, `sat + fast`
   exactly equal between arms, `typed` bit-identical). It is the reason
   `callArgFlow` ships DEFAULT-OFF, and repairing it — extending LSS_024's
   annotation-split shelter to the splits the transport introduces — is the
   highest-value follow-up this plan produced.
3. **Fan-out vs budget**: ✅ DISCHARGED. `widened byBudget` 8,585 → 8,584
   flag-on; fan-out did not move against budget 512.
4. **D2 poison cost** (blind args at shared family points): ✅ SMALL, and the
   pre-approved fallback is NOT needed. `argFlowWpPoisoned = 104` against
   11,885 flows on the whole self-compile — the honesty rule costs under 1%
   of the flows it guards. Default (poison) stands.
5. **Mono wall**: ⚠️ REAL but sub-action-band — **+2.68%** (floor ±1.1%,
   action band ≥3%), majors identical at 15. Attributable: 3,922 extra
   union-find unifies (D1) plus 11,885 set flows and 104 poison walks (D2).
   Not a gate failure on its own; it is a cost with no consumer today, which
   is the flip decision's second reason.
6. **Refactor rails**: ✅ DISCHARGED twice. The ArgStash/threading change
   (Phase 2) and the walk-arm split (Phase 3) each landed byte-neutral
   flag-off on the two-binary rail, run after the last source edit of the
   phase.
7. **Unify-two-loads risk** (D1's connect joins parallel skeletons of one
   canType): ✅ DISCHARGED empirically — determinism ×2 byte-identical, E2E
   1,687/1,687 in BOTH arms, elm-tests' pre-existing-12 unchanged. The
   principle (no new scalar information; set slots only ever join) held.

## §8 Non-goals (recorded)

- Sum lowering — outlined separately (`plans/lss-sum-lowering.md`); it
  inherits §6's agreement obligation.
- LSS_017-v2 / raw→qualified bridging (the `l|` stamping enabler).
- The PAP argument-member transport (the 2,475-site lever Phase 0 found) —
  outlined separately at `plans/lss-pap-argument-members.md`; sequenced
  after this plan's D0/D1.
- `spineArity` flip + LSS_025 re-argument (true-PAP producers; sized by
  Phase 0's rows).
- Kernel-boundary poison (LSS_004/021/022 — the dominant genuine-poison
  family) and flowing arg points across the kernel ABI.
- Indirect-callee arg connection (census row `leak|indirect`; follow-up).
- Wrapped arg shapes (Let/If around the Call — `leak|letAnno` row).
- Container directed-flow, non-spine equalities (§6 losses).
- GAP-9 (measured closed); GAP-3 (evidenced by the sweep; own flip).

## §9 Invariants & register delta — ✅ ALL LANDED 2026-08-23

| item | status |
|---|---|
| NEW `LSS_026` in `design_docs/invariants.csv` | ✅ landed, all five clauses, with clause (a) marked UNCONDITIONAL and clause (e) carrying the DEFAULT-OFF decision + its measured evidence + both re-open criteria |
| AMEND `LSS_020` (A.1 residue closed; B.0 WpOpaque re-argued) | ✅ landed in-row |
| Fidelity mapping — GAP-2 rewritten, `sources` named as the landed promoted-ᾱ | ✅ `lss-paper-fidelity-mapping.md`, both the §3.1 table row and the GAP-2 entry (original text preserved in a `<details>` block) |
| `plans/lss-fidelity-3-*.md` — A.1 ledger + §B.0 re-argument | ✅ landed |
| `benchmarks/lss-opt.md` Run AG | ✅ landed (A/B wall + GC, dispatch census, summary rows AG-off / AG-on) |
| `runtime-calls.md` | not touched — the dispatch movement is recorded in Run AG where the A/B lives; there is no new runtime-call behaviour to record |

**Artifacts preserved** (the §2 provenance rule):
`/work/lss-gap2-d2-argflow-{on,off}.census` (full LSS census + `ARGF` rows,
both arms) and `/work/lss-gap2-dispatch-{on,off}.tsv` (per-fp dispatch census,
both arms), alongside the Phase-0 `/work/lss-gap2-phase0-census.txt`.

<details><summary>Original §9 work order</summary>

- NEW **LSS_026** (design_docs/invariants.csv), licence text: (a) a
  members- or sources-carrying internalization that crossed a terminal
  FlexVar source resolves ⊤ (both readers); (b) a Call-class argument's
  instantiation residual may be connected to the arg var ONLY via the
  single per-occurrence instantiation — second instantiations and snapshot
  copies are banned; (c) every unconnected arg class leaves its slot
  ⊤-reachable, never a silent FlexVar under a members-carrying LsFrom; (d)
  inference-side arg flows are publish-or-poison (WpHonest/WpOpaque flow
  directed; blind arrow args poison), with the variance argument in-code;
  (e) all arms double-gated `lss.callArgFlow ∧ lss.sigFlow`.
- AMEND **LSS_020**: A.1 residue row → closed for global/local-callee args
  under the flag (kernel/fresh-load residues open); B.0 WpOpaque rationale
  re-argued (§3.4's text).
- Fidelity mapping: GAP-2 rewritten per §0's corrections; §3.1 "ABSENT as
  polymorphism" row names `sources` as the landed promoted-ᾱ; the §6 loss
  inventory + sum-lowering agreement obligation recorded.
- `benchmarks/lss-opt.md` / `runtime-calls.md`: Phase-4 runs recorded in
  the house format.

</details>

## §10 What this plan produced, and what it hands on

**Landed and shipping:** LSS_026(a), unconditional. It fixes a real
miscompile, costs nothing measurable on the compiler's own corpus, and is
guarded at three levels (store, pipeline, runtime).

**Landed behind `lss.callArgFlow`, default-off:** D1's translate-side connect
and D2's inference-side flow. GAP-2's missing TIU-App hop is now implemented
and pinned; it is switched off because it does not pay yet.

**The single highest-value follow-up this plan produced** is not on the
original register: **explain and repair the de-stamping.** Phase 4 showed the
transport converts 11,651,310 `fast` dispatches to `gen` with `typed`
bit-identical and `sat + fast` exactly preserved.

**§11 pursued this to a conclusion, and the conclusion is that the mechanism
is still unknown.** Two attributions were proposed and both are now refuted
by measurement: annotation-keyed spec splits (§10's, refuted in §11.1) and
adoption-blocking of one hot member (§11.1's, refuted in §11.4 — the repair
drove `declinedBlocked` 156 → 0 and coverage moved 0.000 pp). The surviving
untested hypothesis is TRAFFIC RELOCATION: `dispatchUpgraded` and the static
`$cap` site count do not fall, so the stamps are not being lost — the hot
traffic is arriving somewhere else. §11.6 specifies the per-site dynamic
attribution that must come before a third mechanism is proposed.

**Re-ranked below that**, unchanged from Phase 0's finding: the PRODUCER side
is the ceiling (7,218 `allflex` signatures against 321 carrying). D1/D2 widen
the pipe; they do not fill it. And the PAP lever
(`plans/lss-pap-argument-members.md`, 2,475 sites, 87.7% at depth 1) remains
reach-completeness work rather than self-compile heat work, per Phase 0's
row-8 join.

## §11 The de-stamping repair (follow-up, 2026-08-23) — **BUILT, MEASURED, NO-GO**

**Verdict up front: the repair was implemented in full, passed every rail,
drove its target counter to zero — and moved dispatch coverage by 0.000 pp,
while costing 19 k singleton sets and 60% of grounding. It is REVERTED.
§11.1's causal attribution is REFUTED by §11.4's experiment, as §10's earlier
one was refuted by §11.1's census. The mechanism behind the fast→gen
conversion remains UNKNOWN; §11.6 says what the next attempt must measure
before proposing a third.**

The section is kept in full — hypothesis, design, experiment, refutation —
because the two refuted attributions are the cheapest part of this record to
re-derive by accident.

### §11.1 The measured mechanism — and the refutation of §10's first guess

*(This subsection's conclusion is itself refuted in §11.5. Its MEASUREMENTS
stand; its causal inference does not.)*

§10 (and Run AG's note, and LSS_026(e)'s first text) attributed the
−0.51 pp coverage loss to "annotation-keyed spec identity splitting sites
that previously shared a stamped `$cap`" — the Run-X/AB class LSS_024
sheltered. **That attribution is REFUTED by the offline census join** (the
replacement offered below is refuted in turn by §11.5 — only the
measurements here survive). The evidence, all from the preserved Phase-4
artifacts
(`/work/lss-gap2-d2-argflow-{on,off}.census`,
`/work/lss-gap2-dispatch-{on,off}.tsv`, the two arms' `.mlir`):

1. **The analysis does not degrade — it improves nearly everywhere.**
   Zonk-cause totals off → on: `set` 203,092 → 224,634 (+10.6%), `poison`
   305,780 → 287,096 (−6.1%), `flex` ~flat. Per-consumer, the WORST set
   loss anywhere is −12 (`Combine.succeed`); `IO.andThen` gains +239 sets,
   `Chomp.apply` +4,114. Key-splits degrading site annotations would show
   the opposite sign.
2. **`sizeHist` 2-sets move by exactly +1** (300 → 301) — no
   singleton→2-set pollution wave.
3. **Static `$cap` call sites GROW** (+18, `mlir-cat` round-trip count:
   14,313 → 14,331), and `dispatchUpgraded` is flat (4,485 → 4,486). The
   de-stamp is not a net loss of stamped sites; it is hot traffic
   relocating onto declined sites.
4. **The one static counter that de-stamps EXISTING sites moved hard:
   `declinedBlocked` 8 → 156 (+148)** — and the `declineByMember` census
   attributes ALL of it to **ONE member: id 9540, 146 declined sites, no
   group reps** (reps empty = buckets dropped = blocked). The two arms'
   top-20 decline lists are otherwise IDENTICAL. `declinedNoInstance`
   +112 is the neutral raw-`l|` class (those sites read ⊤ flag-off — gen
   before, gen after).
5. **The blocker was then NAMED, not inferred.** A permanent report-gated
   probe (`AbiCloningStats.blockedMembers`: member id + the BLOCKING
   instance's lambdaId, printed as `lss census blockedMembers`) run on the
   un-repaired flag-on arm reports exactly two blocked members —
   `Compiler_Type_Type_lambda_41139` (the 146-site one) and
   `Compiler_MonoSolver_Translate_lambda_42662` (~10). Both blocker
   symbols carry REAL module homes, not `Rewriter.wrapperHome`, so they
   are the ADOPTION path (`isAdopted`), not the staging-wrapper path — and
   a GlobalOpt-minted lambda living in the wrapped def's own home is
   precisely `ensureCallableForNode`'s `freshLambdaId home`. (Member ids
   shift between runs as the corpus grows; the SYMBOL is the stable join
   key, which is why the probe prints it.)

**The mechanism, named.** `AbiCloning.instanceMember` ADOPTS a member for
any closure instance with `srcLambda = Nothing` and no `lssMember` whose
TYPE's head annotation is a singleton `LSet [m]` — and adoption BLOCKS `m`
graph-wide (LSS_008: a GlobalOpt-synthesized wrapper could impersonate `m`
at singleton sites; blocking declines them all). The synthesized closures
are `wrapTopLevelCallables`' wrappers (`MonoGlobalOptimize.ensureCallableForNode`),
minted for every top-level node whose value is function-typed but not a
syntactic closure — point-free/eta-reduced defs, bare global/kernel
aliases — **at the NODE's stored MonoType**.

Flag-off, wrap-class node types carry ⊤ at the head arrow (the A.1 leak
kept them flex), so adoption almost never fires (`declinedBlocked` = 8
baseline). Flag-on, D1/D2 do exactly what they were built to do and the
head arrow of a wrap-class def now carries the honest-of-the-PRE-WRAP-value
singleton — e.g. `wrapped = mk 5` carries `{l|lamB}`, the inner lambda of
`mk`. The wrapper adopts `lamB`'s member and blocks it, **de-stamping the
146 legitimate `lamB` sites everywhere else in the graph** — sites whose
annotations came from ordinary lambda-literal channels and whose runtime
values really are `lamB` instances. One hot member × 146 sites = the
11.65 M dynamic events.

So the falseness is real but MISPLACED: the set `{l|lamB}` was true of the
pre-wrap value; GlobalOpt then mints a NEW inhabitant (the wrapper) for
exactly that position, after mono's completeness claims are frozen. The
§0.5 write-completeness obligation has a pipeline-stage edition: **a
completeness claim must survive every later inhabitant-minting stage, and
`wrapTopLevelCallables` is such a stage.** Adoption-blocking is the sound
backstop; it is also a graph-wide sledgehammer for what is a one-position
problem.

### §11.2 The repair — anticipate the wrapper at mono (both channels), keep adoption as the belt

For a **wrap-class def** — body is not a syntactic `Function`/
`TrackedFunction`, node type is arrow-rooted, i.e. exactly the class
`ensureCallableForNode` will wrap — the def's EXPORTED head-arrow claim is
made honest about the wrapper before it exists:

- **(i) Signature side** (`LssInfer.inferUnitInScratch`): the member's
  head-arrow ordinal (located by pointKey against `arrowSetSlot` of the
  loaded root — never by assumed walk order) gets the DEFAULT fact
  `{rep = own, top = False, members = [], sources = []}` at readback.
  Claiming nothing = consumers write nothing = the slot stays flex and
  reads ⊤ — the flag-off behavior exactly, and it preserves the trivial
  mass (the all-empty-case precedent, §3.2). NOT `top = True`: an explicit
  ⊤ write is a join-absorbing store op the flag-off arm never performs.
- **(ii) Item side** (`Monomorphize.defineFrom`): the produced
  `MonoDefine`'s node type gets its HEAD annotation widened to `LTop`
  (`Mono.mFunction Mono.LTop args ret`; interior annotations untouched —
  the wrapper delegates, so interior positions genuinely share the wrapped
  value's structure). This is the exact input of
  `Mono.singletonHeadMember` at adoption, so the wrapper has nothing to
  adopt and the member never blocks.

**Both halves are one landing — (ii) without (i) is a MISCOMPILE.** With
the member unblocked, a consumer slot still carrying the def's head fact
(e.g. `let h = wrapped in h 10`) would stamp `lamB`'s evaluator at a site
whose runtime value is the WRAPPER — reading the wrapper's capture record
(the wrapped PAP pointer) through `lamB`'s capture ABI. (i) removes the
claim from every consumer; (ii) removes the adoption trigger; adoption
remains in place as the backstop for every wrap-class shape v1 does not
predict (Cycle members, ports — recorded residue).

**Gating: `Engine.argFlowOn`, same double gate as D1/D2** — required for
the byte-inertness rail, and NOT merely a formality: the pins measured that
**the hazard class predates the transport.** In the §11 fixture the
wrap-class head carries its singleton FLAG-OFF too, because plain
`lss.sigFlow` already transports `mk`'s result fact to the call site
`mk 5`. That is exactly the measured flag-off baseline
`declinedBlocked = 8`; the transport multiplies the class ~20× (to 156)
rather than creating it. So §11 gated leaves those 8 in place by design —
recorded as residue, with the un-gating decision deliberately deferred to
the same re-open that flips `callArgFlow` (un-gating is an artifact-moving
default change and must not ride along on a default-off landing).

**Member-class scope: UNIFORM** — the override applies whatever the head
fact carries (`l|`, `g|`, `c|`, `k|`). A narrower lambda-only rule was
considered and rejected: for `g|` heads the wrapper-delegation equivalence
argument is not a licence to publish a completeness claim (E9.5's
zero-capture premise is FALSE for a general wrapper holding a PAP capture),
and uniform-⊤ is the reading that needs no per-class soundness argument.
`devirtDirect`/`devirtKernel`/`devirtPost` are watched in §11.4's A/B; a
dent there re-opens the scoping question with numbers.

### §11.3 What this is NOT

- **Not an LSS_024 shelter extension.** No spec keys change, no member
  qualification changes. §10's "extend the shelter" framing is retired by
  the measurement.
- **Not a change to adoption/blocking.** LSS_008's rule is untouched and
  still load-bearing (the belt for unpredicted wrap shapes).
- **Not a fix to the census probe.** The `blockedMembers` attribution line
  added to `AbiCloningStats` (member id + blocker symbol) is permanent,
  print-only, report-gated — the instrument that found member 9540.

### §11.4 Acceptance (the §3.5 gate, re-run) — BUILT AND MEASURED

The repair of §11.2 was implemented in full (both channels), gated on
`argFlowOn`, and put through the acceptance battery. Rails first:

| rail | result |
|---|---|
| flag-off inertness (two-binary, same final source) | **PASS** — md5 `19db04f8f676486617ea9142b3501225` |
| flag-on determinism ×2 | **PASS** — md5 `0981321c3a643218d5035bb123e40a9f` |
| LSS unit/pipeline suite | **PASS** (76 tests incl. 2 new §11 pins) |

**The repair hit its target exactly.** Flag-on, `declinedBlocked`
**156 → 0** and the `blockedMembers` census line reads **(none)** — not one
member blocked, below even the flag-off baseline of 8.

**And it moved dispatch coverage by nothing at all.**

| | flag OFF | flag ON (repaired) |
|---|---:|---:|
| `sat + fast` | 2,289,801,291 | 2,289,801,291 (EXACT) |
| `typed` | 30,959,533 | 30,959,533 (bit-identical) |
| `fast` | 506,169,102 | 494,496,308 |
| **coverage** | **22.105%** | **21.596%** |

21.596% — **the same figure, to three decimals, as the UN-repaired flag-on
arm.** `fast` fell by 11,672,794 against the un-repaired arm's 11,651,310
(the difference is corpus drift: §11's own code enlarged the compiler).

### §11.5 VERDICT: NO-GO, and §11.1's causal claim is REFUTED

**Driving `declinedBlocked` from 156 to 0 changed dispatch coverage by
0.000 pp. The blocked member was not the cause of the de-stamping; it was a
correlated symptom.**

§11.1 had two real measurements — `declinedBlocked` +148 concentrated in one
member, and `fast` −11.65 M — and joined them into a causal story that was
never tested. This experiment is that test, and it fails. The story was
plausible (a blocked member declines ALL its sites, so one hot member CAN
explain a coverage move the per-site counters cannot) and it was wrong. §10's
earlier attribution to LSS_024-class annotation-key splits was also refuted,
by the §11.1 evidence. **Two attributions offered, two refuted; the mechanism
behind the fast→gen conversion is still unknown.**

**The repair also carried a large cost, which is why it does not ship even
gated.** Defaulting the head fact pushed **184 signatures into `trivial`**
(9,482 → 9,666), and triviality short-circuits the whole fact channel for a
producer (`lssFastOk` lets its callers take the cached fast path, which
stamps ⊤). The cascade:

| counter | flag-off | flag-on (repaired) | vs un-repaired flag-on |
|---|---:|---:|---|
| singleton sets | 101,106 | **82,134** | was 111,772 — a 29.6 k loss |
| `grounding grounded` | 12,659 | **5,123** | −60% |
| `set-writes flex` | 177,126 | 129,686 | −27% |
| signatures trivial | 9,482 | **9,666** | +198 |

So the repaired flag-on arm is **19 k singletons BELOW the flag-off
baseline** — the repair does not merely fail to help, it destroys more
analysis than the transport creates. Wall was 365.5 → 370.0 s (+1.2%).

**Reverted.** Both behavioural halves are out of the tree (`defineFrom`'s
head widening, `zonkSignatures`' head override and its four helpers), each
site carrying a NO-GO comment pointing here. `Engine.wrapClassBody` is gone.

**KEPT — the instrument that produced the attribution**, because it is
print-only, report-gated, and it is what makes the next attempt cheaper:
`AbiCloning.MemberInfo.blockedBy` + `AbiCloningStats.blockedMembers`,
rendered by `Builder.Generate.abiCensusLines` as
`lss census blockedMembers (member:blockerSym)`. It named
`Compiler_Type_Type_lambda_41139` in one run where the member id alone was
useless (ids shift with the corpus; the SYMBOL is the stable join key).

**Two facts this work established that outlive the failed repair:**

1. **The wrap-class adoption hazard predates the transport.** The §11 pin
   measured a wrap-class head carrying its singleton FLAG-OFF, because plain
   `lss.sigFlow` already transports the producer's result fact to the
   point-free call site. That is the flag-off `declinedBlocked = 8` baseline;
   the transport multiplies the class ~20×, it does not create it.
2. **Adoption-blocking is the CHEAP sound answer, not an obstacle.** The
   alternative — retracting the claim so the wrapper has nothing to
   impersonate — costs 19 k singletons and 60% of grounding to save 146
   declined sites. LSS_008's sledgehammer is, on this corpus, ~100× cheaper
   than the surgical version. Anyone tempted to "fix" blocking should read
   this row first.

### §11.6 What the next attempt must do FIRST

Do not propose another mechanism for the fast→gen conversion without first
MEASURING which sites moved. Two attributions have now been refuted by
reasoning from aggregate counters; the aggregates are exhausted. The open
facts to explain:

- `sat + fast` is invariant to the event across every arm measured, and
  `typed` is bit-identical — so the conversion is purely fast→gen at a fixed
  population of dispatch events.
- `dispatchUpgraded` is flat (4,485…4,489 across all four arms), so the
  NUMBER of stamped sites does not move. Static `$cap` call sites even GROW
  (+18). **The stamps are not being lost — the hot traffic is arriving
  somewhere else.**

That last line is the surviving hypothesis and it has never been tested:
**traffic relocation** — the transport keys specs differently, so the
instantiation that carries the 11.65 M events lands in a spec whose site is
not stamped while a cold sibling keeps the stamp. Testing it needs per-site
dynamic attribution, not per-symbol: instrument the dispatch counters to
record the SPEC and the enclosing function of each `gen` event in both arms,
and diff the two by canonicalized enclosing-function key. Until that exists,
the −0.51 pp has no owner.

<details><summary>The original §11.4 acceptance criteria (as written before the run)</summary>


1. Flag-off byte-inertness on the two-binary rail (the repair is fully
   inside `argFlowOn`).
2. Flag-on determinism ×2.
3. Pins: the existing 16 `LssCallArgFlowTest` pins green; NEW pins — a
   wrap-class producer's head fact reads default/⊤ flag-on at both
   channels, and interior facts survive; the `LssMixedSigHonestyTest`
   runtime pin green in both arms.
4. elm-tests pre-existing-12 only; E2E 1,687 both arms.
5. **The gate: flag-on LSS fast coverage ≥ the flag-off 22.105% on the
   exact-count-matched dispatch census** (`sat + fast` invariance rail),
   `declinedBlocked` back at ~baseline (8) flag-on, `blockedMembers` line
   naming no transported member.
6. Wall within the ±1.1%…3% band vs Run AG's flag-on arm (the repair adds
   two per-def O(#slots) checks — expected ≈ free).

</details>
