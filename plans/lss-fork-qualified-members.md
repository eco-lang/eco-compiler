# Fix B: fork-qualified lambda-set members

**Status: IMPLEMENTED + ALL GATES GREEN (2026-07-20, same day).** B0+B1 landed
together; B2 repro green (the all-keyed self-compile completes in 4:21 where it
SIGSEGV'd at ~7 s); B3 measured — **Run M in `benchmarks/runtime-calls.md`:
first-ever all-keyed census, coverage 6.81 % → 13.22 % (fast 51.3 M → 99.6 M/run,
1:1 out of gen) at identical 752.9 M total events and wall parity (4:32 @ 10
majors)**. Gates: corpus 1625/1625, elm-tests 12,999/12 baseline, stock stamps
unchanged (+21 List-chain specs, +0.07 % MLIR), `unqualifiedLambdaMints=0`,
orphan-twin signature gone (every Unify.andThen continuation has exactly one
singleton_fast site; IO_andThen clones 187→192). See the §9 B1 GATE CORRECTION
for the `multiInstanceGroups` probe semantics (verbatim inliner copies mint
fresh lambdaIds — the counter is a monitoring delta, not a zero-gate).
E11 is now a COST question, not a soundness prerequisite.
Fixes the all-globals-keying "Descriptor-into-Context" SIGSEGV at its root
(`debug-context.md`, `plans/lss-dispatch-value-extraction.md` §11.6 final
subsection) and is the prerequisite for E11 key-on-conflict (§11.7). The
user chose this over the minimal Fix A (multi-instance decline in
AbiCloning); Fix A's check survives here as a verification probe (§9/B1).

All file:line references verified against HEAD on 2026-07-20.

---

## 1. The problem (one paragraph)

Lambda-set members for source lambdas are minted per SOURCE lambda —
`LssInfer.injectLambdaMember` (LssInfer.elm:141-148) writes
`Engine.srcLambdaKey lamId = Id.toComparable` (Engine.elm:160-162), a pure
function of the Phase-0 `SrcLambdaId`. Under keying, one source lambda gets
N same-layout, behaviorally DIVERGENT instances (one per keyed spec of its
defining global), all sharing one member id. Sets that should distinguish
the clones look like the same singleton; downstream keyed specs dedup onto
one shared clone (`toComparableSpecKey` embeds member ints verbatim —
Monomorphized.elm:1351-1362); and AbiCloning's singleton stamp routes ALL
instances to one `LayoutGroup.rep` (joinGroup discards the second
`lambdaId`, AbiCloning.elm:403-422; resolveInGroups stamps `g.rep`,
:1167-1175). LSS_009's "interchangeable representative" premise (instances
are verbatim copies) is violated → the 10084-PAP is dispatched as a
10088-PAP → SIGSEGV. Proven end-to-end by bpftrace/gdb/MLIR evidence.

## 2. Design essence

**Qualify a lambda's member id by the specialization that mints its
instance.** One rule:

> When translating spec `S` of a keyed-routed global `G`, a lambda literal
> with `srcLambda = L` contributes member `Q(L,S)` — a fresh interned id —
> instead of the raw `srcLambdaKey L`. The instance's `ClosureInfo` is
> stamped with the same `Q(L,S)`.

Everything else follows from existing machinery:

- `Q(L,S1) ≠ Q(L,S2)` → sets flowing from different forks genuinely differ
  → `toComparableSpecKey` keys differ → downstream globals FORK per clone
  (the shared `IO_andThen_$_11397` splits into one clone per handler) →
  each fork's set is a true singleton again → the devirt is **recovered
  legitimately**, not declined.
- "Singleton member ⇒ unique behavioral instance" becomes true BY
  CONSTRUCTION: `Q(L,S)` names exactly the one `MonoClosure` minted while
  translating `S` (plus LSS_008 wrapper stages that adopt it — which block
  stamping, unchanged). AbiCloning's rep-sharing premise is restored.

### 2.1 Member id representation

Reuse the existing interning table — no new id infrastructure:

- `Q(L,S)` = `Engine.memberIdFor ("l|" ++ String.fromInt (Id.toComparable L)
  ++ "|" ++ String.fromInt specIdInt)` (Engine.elm:499-516; supply
  `nextMemberId`, S-field :218, seeded past the lambda supply per LSS_003 —
  no collision with raw ids by construction).
- Interning is idempotent (same string → same int), which gives LSS_010
  dirty-flush re-translation stability for free: re-translating spec `S`
  re-mints the SAME `Q(L,S)`; sets stay monotone.
- Add the census label at mint: `lamLabels`-style `defKey#lam@spec`
  (Engine.elm:185 pattern) so reports stay readable.

### 2.2 Qualification condition

Qualify exactly when the DEFINING global is keyed-routed — the same
predicate `enqueueSpec` uses to choose the keyed path (Engine.elm:609-616:
`s.env.lss.keyed || CoreDict.member gkey s.lssKeyedSet`), evaluated for
`s.currentGlobal` at mint time. Rationale:

- Non-keyed-routed globals cannot mint same-layout duplicate instances
  (their spec keys are today's keys — same layout ⇒ same spec ⇒ one
  instance), so raw ids remain sound there AND shipping output stays
  byte-identical except for lambdas defined INSIDE the whitelisted List
  chain (`defaultKeyedGlobals` = foldl/foldr/foldrHelper/map — first-order,
  ~no internal lambdas; expected byte-identical, gate B1 verifies).
- Under `lss.keyed = True` (all-globals), everything qualifies — the config
  that crashes today.
- **Verify-in-implementation (V1):** confirm the non-keyed spec key
  derivation (Engine.elm:626 "keys are today's keys" / the non-keyed
  `Registry.getOrCreateSpecId` route) is annotation-INsensitive. If it
  turns out anno-sensitive, qualification of keyed-routed members can still
  perturb non-keyed neighbors' partitioning via flowing sets — the B1 byte
  gate catches it; the fallback knob is to widen the qualification
  condition or accept the (deterministic) re-partition with a census
  explanation.

## 3. Where the spec identity comes from

The engine translates once per SPEC (`processItem specId`,
Monomorphize.elm:398-439) but the `specId` is never threaded into
`Translate.*`; only `currentGlobal` lands in `Engine.S` (:230). `S` sits
exactly at the native 32-slot record cap (Engine.elm:111-115) — do NOT add
a top-level field. Instead:

- Add `currentSpecId : Maybe Int` to the existing per-item nested record
  `ItemAux` (Engine.elm:269-274, reached as `s.itemAux`) — nested records
  don't consume S slots (that is `itemAux`'s stated purpose).
- Set it in `processItem` right where `currentGlobal` is set
  (Monomorphize.elm:431); clear it at `finishNode` (:799) and the
  non-retranslatable early-out (:489), exactly mirroring `currentGlobal`'s
  lifecycle. (If `resetItem` rebuilds `itemAux`, set AFTER `resetItem`, as
  `currentGlobal` already is.)
- Mint-time fallback: `currentSpecId == Nothing` (a mint outside any spec
  item, if any exists) → keep the raw id and bump a new census counter
  `unqualifiedLambdaMints`. Expected 0; nonzero is a finding, not a crash.

## 4. Mint-site changes (translation phase only — 3 sites)

New helper in LssInfer (or Engine): `injectLambdaMemberQualified`, same
shape as `injectLambdaMember` (LssInfer.elm:141-148) but resolving the id
via §2.1/§2.2 (reads `s.currentGlobal` + `s.itemAux.currentSpecId`), then
`injectSpineMemberId arity qid funcVar` unchanged. Switch these callers:

1. `Translate.classifyLambdaHead` :1419 (from `specializeLambda` :1367) —
   lambda literal head classification.
2. `Translate.injectArgLambdaMember` :2936 and :2939 — lambda literal
   passed directly as a call argument (writes the callee's param-arrow
   slot).

**Unchanged (stay raw):**

- The INFERENCE-phase mints in `LssInfer.walkExpr` :598/:611 — they run
  once per unit in a scratch store (`inferUnitInScratch` :434) and bake
  member ids into signatures (`ArrowFact.members`, Engine.elm:76-80),
  applied later at `applyFacts` → `Store.unifySlotWithSet False
  fact.members slot` (LssInfer.elm:213). At application time only the
  CALLEE global is known — the callee's spec does not exist yet — so
  signature-transported lambda members CANNOT be spec-qualified. v1
  accepts this; see §6 for why it is sound and §8 for the (small) coverage
  cost.
- All standalone members (`g|`/`c|`/`k|`/`a|`, LssInfer.elm:626-656,
  Translate.elm:2976/2983): globals and kernels re-derive their
  specialization from the SITE's demand types at devirt/call time
  (`devirtDirectTarget` Translate.elm:1985-1994 → spec resolution by
  demand; kernel ABI derived from actual monoArgs per the E9.2 guards), so
  one member per global remains sound. Do not qualify.

## 5. Instance stamping and AbiCloning

The annotations and the instance index must live in ONE key space:

- Add `lssMember : Maybe Int` to `Mono.ClosureInfo`
  (Monomorphized.elm:952-954 region). Stamped in
  `Translate.specializeLambda` (:1350-1358) with the SAME `Q(L,S)` (or raw
  id when unqualified) that `classifyLambdaHead` injected — compute once,
  use twice. `ClosureInfo` is never persisted (mono graph is
  session-internal; `srcLambda` itself is explicitly not serialized,
  TypedOptimized.elm:888-897) — the field addition is artifact-safe.
- `AbiCloning.instanceMember` (:467-474): use `closureInfo.lssMember`
  when present, else the existing `Id.toComparable srcLambda` /
  `singletonHeadMember` adoption fallbacks. Under lss.enabled the field is
  always stamped alongside `srcLambda`, so the fallback only serves
  LSS-off graphs (where the pass is inert anyway, :507).
- LSS_008 identity adoption: `Staging/Rewriter.elm:599` copies
  `srcLambda = originalInfo.srcLambda` into wrapper stages — copy
  `lssMember` identically. The adoption-blocks-stamping semantics
  (AbiCloning.elm:270-272) are unchanged.
- `kindIdFor` (AbiCloning.elm:1256-1265) dense-renumbers member→
  `ClosureKindId` per graph — qualified ints flow through untouched; raw
  member ints still never reach MLIR (audit: only `_closure_kind` dense id
  and `LambdaId` symbol refs are emitted — Generate/MLIR/Expr.elm:1081-1092).

## 6. Soundness argument

1. **Qualified singletons are safe to stamp.** `Q(L,S)` has exactly one
   minting instance (the `MonoClosure` of `L` in spec `S`; `lambdaId`s are
   fresh per spec — Translate.elm:1446-1448). Wrapper stages that adopt it
   block the member (existing behavior). So a `LayoutGroup` under a
   qualified member holds one distinct `lambdaId` (+verbatim inliner
   copies of that same instance, which share the `lambdaId`/body) —
   rep-stamping is sound again.
2. **Raw lambda members become unstampable, never wrong.** After B1, no
   instance is indexed under a raw lambda id (instances carry `lssMember`).
   A signature-transported raw singleton at a site therefore MISSES the
   index → `Decline` → generic dispatch → the closure's own evaluator runs
   → correct. (Today signatures are 8,673/8,673 trivial — E0.5 — so this
   population is ~empty; see §8.)
3. **Mixed joins degrade monotonically.** `{Q(L,S1)} ∪ {Q(L,S2)}` = a
   2-member set → not a singleton → no stamp (sound). Set-size overflow →
   `LTop` (Store.zonkSetSlot :1159-1161) → no stamp. Budget overflow →
   keys widen to `LTop` (`Mono.widenSets`, Engine.elm:718-723) → shared
   spec whose STORED type joins to multi-member/LTop → no stamp. Every
   escape path lands on "decline", never on "wrong rep".
4. **Standalone members stay sound unqualified** (§4): their consumers
   re-derive the target from site types, which under keying include the
   full annotations — the E9/E9.2 paths are demand-correct, not
   layout-blind.
5. **Termination.** Qualification feeds member ids back into keyed spec
   keys, so a recursive flow can spiral (S1 mints Q(L,S1) → keys S2 → mints
   Q(L,S2) → …). The spiral is bounded by the existing M4 budget:
   past `maxSpecsPerGlobal`, keys widen to LTop and the fan-out stops
   (Engine.elm:712-723). Watch `widenedByBudget` in the census; a
   materially higher count under all-keying is expected and benign, but a
   runaway on a specific global is the signal to inspect.

## 7. What the fix recovers (the repro's expected new shape)

On the `allkey-bin` workload under Fix B + all-globals keying:

- `Unify.andThen` forks 11371/11373 mint distinct handler members
  `Q(handler,S_11371)` / `Q(handler,S_11373)` → the IO.andThen demand keys
  differ → TWO `System_TypeCheck_IO_andThen` clones (today: one shared
  `_$_11397`) → each clone's inner `9900`-sibling stamps `singleton_fast`
  to ITS OWN handler clone.
- Greppable gate on the text MLIR: `singleton_fast` sites targeting BOTH
  handler-family `$cap`s exist (today `10084$cap` appears at zero dispatch
  sites); no member's instance population exceeds 1 distinct lambdaId
  (the Fix-A probe, §9/B1).
- The self-compile completes (the SIGSEGV repro is the primary gate).

## 8. Costs, risks, open items

- **Fan-out multiplier (all-keying only).** Qualified members make keyed
  keys finer; spec counts and compile wall rise vs today's (miscompiling)
  all-keyed baseline (+5.7% wall, §11.6). Measure in B3; budget caps the
  worst case. Shipping config expected ~unchanged (§2.2).
- **Cross-layout-join stamp loss (non-all-keyed modes).** Today two
  DIFFERENT-layout instances of one lambda meeting at a join keep a
  singleton `{L}` and AbiCloning picks the right instance by the site's
  layout bucket (sound). Under qualification that join becomes 2-member →
  declines. v1 accepts the loss; census `dispatchUpgraded` delta on
  shipping/B1 quantifies it (expected ≈0 — such joins require the same
  lambda flowing from two differently-typed specs into one call site,
  which then couldn't be layout-consistent for both). v2 recovery if
  needed: AbiCloning may layout-partition multi-member sets whose members
  share one source lambda (needs a Q→(L,S) reverse map exported).
- **maxSetSize pressure.** More distinct members → more `LTop` widening at
  zonk (`widenedBySize`). Census-watch in B3.
- **V1 (verify): non-keyed spec-key annotation sensitivity** (§2.2).
- **V2 (verify): mints with no current spec** — `unqualifiedLambdaMints`
  census counter must read 0 at self-compile; investigate otherwise.
- **Signature-transported members stay raw** — becomes interesting only
  when signatures stop being trivial at scale (post-S/E4a growth). The
  v2 design for qualifying them is enqueue-time rewriting (qualify at the
  moment the callee spec id is created), which requires rewriting demand
  types before keying — deliberately out of v1 scope.

## 9. Milestones and gates

Standing discipline applies (plan §13): touch-all before corpus gates
under changed flags; census runs manual from build-kernel; record major-GC
counts with every wall; heap config pinned for A/Bs.

- **B0 — plumbing (no behavior change).** `ItemAux.currentSpecId` +
  set/clear in `processItem`/`finishNode`; `memberIdFor` namespace helper
  (`lambdaInstanceMemberId`); census counters (`unqualifiedLambdaMints`,
  `multiInstanceGroups` probe in AbiCloning: count groups holding ≥2
  distinct lambdaIds — report-only). GATES: flag-off byte-identical;
  LSS-on shipping byte-identical (nothing calls the new helper yet).
- **B1 — qualification live.** Switch the 3 translation mint sites;
  `ClosureInfo.lssMember` + `specializeLambda` stamp + `Rewriter:599` copy
  + `instanceMember` read + `lssMember = Nothing` strip at the 4
  MonoInlineSimplify reshape sites + the LSS_002 pin
  (`LambdaSetIntegrity`) checks the minted-under id. GATES: shipping
  (Tier-1 defaults) corpus 1625/1625 + elm-tests baseline + self-compile
  green; shipping MLIR delta census-explained; E5KeyedDispatchTest still
  shows ≥2 distinct fastEvaluators keyed.
  **GATE CORRECTION (found at implementation, 2026-07-20):**
  `multiInstanceGroups == 0` is NOT achievable and was a design error —
  `MonoInlineSimplify` mints FRESH lambdaIds for verbatim inline copies
  (`freshLambdaIdForSpec`), so verbatim-copy groups legitimately hold ≥2
  distinct ids (1,721 such groups on the stock self-compile; all sound —
  identical bodies). The counter cannot distinguish verbatim copies from
  divergent clones without body comparison; it stands as a MONITORING
  DELTA (unexplained growth = investigate), and the decisive soundness
  gate is B2's repro. Divergent-clone groups are prevented by
  construction (qualified members split them before the index is built),
  not detected by the counter.
- **B2 — the repro gate.** Rebuild the all-keyed compiler
  (`ECO_MONO_ENGINE=solver ECO_MONO_LSS=keyed`), run the exact
  `debug-context.md` repro → must complete (no SIGSEGV); grep gates from
  §7 on the text MLIR; all-keyed corpus 1625/1625 (touch-all).
- **B3 — measurement + E11 decision.** All-keyed self-compile wall/output/
  census vs Run-L baselines (majors recorded): if all-globals keying is
  now SOUND and remains cheap (≈+6% wall, §11.6), re-open the §11.7
  sequencing question — E11 key-on-conflict may retire in favor of
  simply enabling broader keying; otherwise E11 proceeds on a now-sound
  substrate. Also record `widenedByBudget`/`widenedBySize` deltas and the
  new-member cardinality (`nextMemberId` census line).
- **B4 — bookkeeping.** invariants.csv rows (§10); update plan §11.6/§11.7
  and `debug-context.md` status; memory refresh.

## 10. Invariants delta

- **LSS_017 (new):** Under lss.enabled, a lambda instance minted while
  translating spec S of a keyed-routed global carries member `Q(L,S)`
  (interned `l|lam|spec`), stamped identically in its set injection and
  its `ClosureInfo.lssMember`; raw `srcLambdaKey` ids may appear only in
  signature facts and are never carried by any instance.
- **LSS_009 (amended):** the "interchangeable representative" premise is
  discharged by LSS_017 (singleton member ⇒ unique behavioral instance);
  the `multiInstanceGroups == 0` census probe is its standing check.
- LSS_003 (shared id supply, no collisions) unchanged in force —
  qualified ids draw from the interned supply which is seeded past the
  lambda supply.

## 11. Rejected alternatives

- **Fix A as the fix** (decline stamps on multi-instance groups): sound
  and minimal, but permanently forfeits the devirt on exactly the sites
  keying exists to win, and leaves the false-singleton sets in place
  (latent for every future singleton consumer — E9-family, E11, DF).
  Retained as the B0/B1 verification probe.
- **Qualify inside `SrcLambdaId` (composite id type):** touches Phase-0
  stamping and the opaque-Id discipline for no benefit — interning at the
  engine layer is strictly smaller.
- **AbiCloning-side layout/body disambiguation (verbatim-body hashing):**
  treats the symptom at one consumer; other singleton consumers would
  each need their own guard. Fixing the identity fixes all consumers.
