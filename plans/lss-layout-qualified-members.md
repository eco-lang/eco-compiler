# Instance dedup via layout-qualified member identity (the LSS key-split de-stamp fix)

**Status: COMPLETE (2026-08-21, one day). Landed DEFAULT-OFF; all §6
criteria MET; the §6.4 flip chain is OPEN — see the flip-chain record at the
end of this header block.** Headline: runtime-calls Run AC measures the fix
recovering **100.8%** of the 23.5M-event sigFlow fast gap (coverage 6.10% →
8.34%, ≥85% required), `sat+fast` invariant to the digit, at mono wall FLAT
with majors identical (lss-opt Run AD). Two as-built corrections to §2.4
were forced by the gates and are recorded inline there (positional local
names; flag-gated fence — with a SOUNDNESS FINDING: HEAD stamps four
non-verbatim `Dict.map` multi-groups that the fence declines).

**§6.4 flip-chain record — EXECUTED (2026-08-21, user-directed, two
separate landings per the never-couple rule):**

- **(a) `lss.layoutQualMembers` default-flip — LANDED (Landing 1).** The
  §7.2 Borrow obligation landed WITH it: `Borrow.buildLambdaSigs` carries
  the same fingerprint fence (representative sig only for
  fingerprint-unanimous members; divergent members store the MEET over
  per-instance sigs — `lambdaSigMeets` censused; BORROW_006 amended;
  BorrowFenceTest's order-independence pin is the meet witness, 5/5).
  Battery: unit suite 1,217+5/0 under the new default (MuTieTest and
  LssSigFlowTest now PIN `layoutQualMembers = False` — they test
  LSS_018/020/023 mechanisms in isolation); E2E `--target full`
  1,686/1,686; elm-tests 13,186/12-pre-existing; `--target bootstrap`
  GREEN including Stage-4b (JS) and Stage-8c (native) fixed points;
  same-corpus rail: the env-flag leg byte-equals the default leg. The
  recorded artifact delta (four `Dict.map` bodyMismatch declines) is live
  by default, as decided.
- **(b) `lss.sigFlow` default-flip — LANDED (Landing 2, separate
  battery).** Isolation pins added first (`sigFlow = False` in
  LayoutQualTest, LssGroundingTest, KernelLicenseTest — they pin
  LSS_024/019/021/022 mechanisms; LssSigFlowTest already pins per arm).
  Battery: unit suite 1,217/0 under both defaults on; E2E `--target full`
  1,686/1,686; elm-tests 13,186/12-pre-existing; `--target bootstrap`
  GREEN (Stage-4b + Stage-8c fixed points with BOTH flags default-on);
  same-corpus rail (default vs env `SF=1 LQ=1`) byte-identical. LSS_020's
  row and lss-directed-set-flow §8.3 record the supersession; the default
  artifact now carries the root-split family's duplicate specs by design
  (§6.1), paid back at runtime per Run AC.

**Original §6.4 record (pre-flip):**

- **(a) `lss.layoutQualMembers` default-flip — UNBLOCKED.** §6.1 and §6.2
  both hold. The flip is its own recorded decision requiring: the full
  battery + Stage-4b/8c bootstrap fixed points (the K6/§14 standard); the
  §7.2 Borrow obligation (give `Borrow.buildLambdaSigs` the fingerprint
  gate or record the constraint in BORROW_006 — under LSS_024 stored sigs
  are NO LONGER "equal by construction" across a member's instances); and
  acceptance of the recorded flip-time delta: the four HEAD-stamped
  non-verbatim `Dict.map` groups become `bodyMismatch` declines (soundness
  rationale on the fence's side).
- **(b) `lss.sigFlow` §8.3 flip (plans/lss-directed-set-flow.md) —
  RE-OPENED.** Its only recorded blocker (the runtime de-stamp) is removed
  WHEN combined with `layoutQualMembers=1`: the sf+lq arm beats the sf-off
  baseline on fast events. sigFlow default-on remains a separate decision
  with its own full battery — never couple the two flips in one landing.

Phase 0 record (stop condition did NOT fire; C+F proceeded as specced): Phase 0 record (census artifacts:
`/work/lss-p0-census-sigflow-on.stderr` raw, `/work/lss-p0-census.txt`
control-char-sanitized; one cold sigFlow-on JS-loop self-compile,
instrumentation added and removed same-day per §3; headline counters
reproduce the recorded arm exactly — stampedStaged=453, declinedBlocked=8,
declinedNoInstance=1381):

1. **Slot shape CONFIRMED, count = 6.** With the scanExpr gating bypassed,
   exactly six `System.TypeCheck.IO.andThen` wrapper sites read PURE
   same-raw qualified-sibling 2-sets `{Q(L,S1),Q(L,S2)}` whose minting
   specs are precisely the family split pairs: specs 16373/16375 ←
   `variableToCanType` {16359,16370} (raws 8910/8903), 15850/15851 ←
   `variableToErrorType` {15811,15860}, 15825/15826 ← `getVarNames`
   {15813,15821}. Not LTop — honesty poison is NOT the mechanism. Beyond
   the six: 44 pure same-raw sibling multi-sets total (List.filter/map
   callbacks inside foldl/foldrHelper specs, Data.Map.foldl, Task.map,
   `Utils.filterM`, …) — C recovers more than the solver family. The
   recorded one-multiSet-line census was the under-count the plan
   predicted (35 multiSet sites in andThen specs alone).
2. **ROOT-vs-PROPAGATED split.** The family tops are ROOT splits carried
   by ONE raw-`l|` signature id (raw 9429, < seed 11559): each pair's
   stored types differ by that raw id's presence AND by set-vs-LTop slot
   skeleton — sigFlow fact content, so the 2 specs persist under C. BUT
   their widened creation keys are EQUAL, so C still merges the IDS their
   bodies mint — the de-stamped slots become singletons anyway (the
   runtime win does not need the spec merge). `UnionFind.modify` (10→14)
   is purely PROPAGATED: all 14 specs share one annotation skeleton and
   the varying ids are 100% lq-qualified (9 distinct raws) — collapses at
   creation under C. `UnionFind.get` = 2 layout-differing skeletons, stays.
3. **μ-tie refutation.** `muTied` is EMPTY (tied=0) on this arm — the
   record sentence "declinedBlocked +8 = the μ-tie firing" is REFUTED.
   The 8 blocked declines are RAW-range members 9429 (×7 sites:
   Compile.typeCheck/typeCheckTyped, Solve.solveGo ×4, getFreshVarName)
   and 5832 (×1, MonoSolver.Translate.currentMVarEnv) — index-level
   adoption/wrapper blocking of raw-id closures, nothing to do with
   LSS_018. §6.1 expectation corrected: declinedBlocked UNCHANGED by the
   fix; the §2.3 equal-id bypass sizes at ~0 on the self-compile (it
   remains REQUIRED for spiral termination — the MuTieTest fixture is its
   population). Also live: `Unify.andThen` spec 16266 reads a same-raw
   6-set over six Unify.andThen specs — the E11-divergent family that F's
   fingerprint fence exists to decline.

Original header: **PROPOSED (2026-08-21).**

**Phases 1-2 + §6.1 execution record (2026-08-21, same day).** Substrate
landed as specced with the two §2.4 as-built corrections (local-name
positionalization; flag-gated fence — both found by the §4.5 gate, both
recorded inline in §2.4). Gates, all on the final tree: flag-off `out.mlir`
BYTE-IDENTICAL (two-binary/frozen-corpus, 13,794,917 B); §5.5 determinism ×2
byte-identical; E2E `--target full` flag-off 1,686/1,686 AND flag-on
(`ECO_MONO_LSS_LAYOUT_QUAL=1`, purged per-suite eco-stuff) 1,686/1,686;
elm-tests 13,181 passed / 12 failed, all 12 the documented pre-existing
TYPE_007/POST_010/golden-constraint families. Unit pins: 19/19
(LayoutQualTest + AbiCloningFenceTest + MuTieTest) — including: the spiral
closes at 2 specs under C ALONE (muTie off, nothing blocked); the §2.3
equal-id bypass (tieBypass counts, muTied stays empty); budget-twin sharing;
the E11-shaped bodyMismatch pin; and the fence-off arm reproducing HEAD.
§6.1 (Run AD, benchmarks/lss-opt.md): wall FLAT (+1.5%), majors IDENTICAL
(13/13/13); `stampedStaged` 453→457 (the six de-stamped wrapper stamps
recovered; 4 `Dict.map` stamps fenced; +2 new C-enabled staged stamps);
`layoutQual: mints=75,237 shared=4,538 fallback=0 tieBypass=0`;
`bodyMismatch=11`/`abiMismatch=3` on united groups; artifact −23.7 KB vs the
unfixed sigFlow arm (104 of 242 duplicate instances gone);
`UnionFind.modify` 14→9 with root splits persisting at 2 — the §0
propagated/root split exactly as the Phase-0 census classified. JS and
native artifacts byte-identical on all three arms. `layoutQualMembers`
remains DEFAULT-OFF pending §6.2 (runtime-calls three-leg acceptance) and
the §6.4 flip decisions. Successor to the
`plans/lss-directed-set-flow.md` Phase-E residual chain — the fixed-census
attribution (runtime-calls.md Run AB final addendum,
`/work/lss-spec-construction-diff.md`) named this the ONLY remaining lever on
the sigFlow runtime regression: net 23,231,541 lost fast events in four
solver `IO.andThen` callbacks, 19.29M (83%) in `Type.Type.variableToCanType`'s
chain alone. All code references verified at HEAD 2026-08-21, then
adversarially re-verified by a three-lens review; the E11 soundness question
the first draft deferred to Phase 0 is answered INLINE (§1.1) from the
recorded arc — it reshaped the design. §1.4 gives the mechanisms by worked
example; §10 grounds the design against the LSS paper (whose §6.1/§6.2 turn
out to be, respectively, the E11 lesson and a prescription of this fix).

---

## 0. Evidence and problem statement (read first)

**What is proven** (artifact-level, same-source sigFlow on/off pair):

- sigFlow's entire artifact delta is instance-count only: 59 of 9,675
  canonical roles diverge, every extra flag-on instance is a canonical
  duplicate of an existing body (newBody = 0), and ~6
  `System.TypeCheck.IO.andThen` continuation wrappers lose their
  `singleton_fast` inner-`papExtend` stamp (= mono counter `stampedStaged`
  −6). The split family: `Compiler.Type.Type.variableToCanType` /
  `variableToErrorType` / `getVarNames` (each 1→2 instances),
  `Compiler.Type.UnionFind.get/modify` (10→14),
  `Compiler.Type.Solve.restore`, their `IO.pure/andThen` chains, and scalar
  leaves they drag along. (`/work/lss-spec-construction-diff.md`.)
- The runtime cost is exactly the de-stamped callbacks: fixed-census
  count-multiset diff nets 23,231,541 = the global fast delta to the event —
  `variableToCanType`'s callback 19,286,974; the adjacent chain 2,786,608;
  `getVarNames`' pair 1,153,416. Coverage 8.79% → 7.68% (Run AB, that tree).
- The CAUSE of the duplicates is keying: under ALL-KEYED routing the fully
  annotated demand IS the spec key (`Engine.enqueueSpecKeyed`,
  Engine.elm:1420-1490, under-budget create at :1432-1434 →
  `Registry.getOrCreateSpecIdKeyed` :140-188), and sigFlow's signature facts
  enrich annotations, so the same function instantiates under a second key.
  Lambdas minted inside spec S carry the spec-qualified member id
  `Q(L,S)` = interned `"l|<raw>|<specId>"` (`Engine.lambdaInstanceMemberId`
  :333-390, `mintQualifiedLambda` :400-415, key built at :402, LSS_017), so
  a key split forks the member-id space even when the clone bodies are
  verbatim duplicates.

**The 2026-08-21 refinement (decline-log re-read).** The earlier record
sentence "the de-stamped six are (part of) the +133 noInstance delta" is
REFUTED in detail by the saved logs
(`/work/lss-decline-log-sigflow-{on,off}.txt`): the
`System.TypeCheck.IO.andThen` noInstance population is IDENTICAL across arms
(26 = 26 lines; the +133 lives elsewhere — `Mlir.Bytecode.AttrType.encodeEntry`
+32, `Utils.Main.dictTraverseWithKey` +10, `Elm.JsArray/Array.foldl` +8, long
tail). And each arm logs exactly ONE `multiSet` line — **it is an
`IO.andThen` site carrying a 2-set** (`members=31235,31260` on /
`31106,31131` off): in-hand evidence that the de-stamped callback slots
widen to 2-sets of qualified siblings rather than missing the index. The
multiSet/LTop censuses UNDER-COUNT (they see only sites co-resident with a
singleton candidate — `scanExpr`/`isSingletonHead`, AbiCloning.elm:657-722),
so the six wrappers' exact slot shapes still need Phase 0's un-gated census.
Related, to be explained by the same census: `declinedBlocked` +8
concentrates on TWO member ids (9422 ×7 — `Compile.typeCheck`,
`Compile.typeCheckTyped`, `Type.Solve.solveGo` ×4,
`Type.Type.getFreshVarName`; 5831 ×1 — `MonoSolver.Translate.currentMVarEnv`)
— the μ-tie firing inside the same family.

**Why this matters beyond the 23.2M**: LSS_023's flip decision
(`lss.sigFlow` DEFAULT-OFF) was blocked ONLY by this regression — fidelity
held at wall FLAT (Run AC). Recovering the stamps re-opens the flip. That is
the strategic payoff, and it is written into §6's criteria.

## 1. The identity thesis — and the E11 fact that bounds it

Member identity for keyed-routed lambda instances is currently
**(source lambda × enclosing SpecId)**. The sigFlow splits show SpecId
over-partitions: annotation-only key splits mint distinct ids for clone
instances, and the split ids then fail to re-unite at shared consumer slots
(the observed 2-sets). The tempting fix is to re-anchor identity to
**(source lambda × instantiation layout)**. But that alone is UNSOUND, and
the repo already paid to learn it:

### 1.1 The E11 finding (verbatim, load-bearing)

`plans/lss-dispatch-value-extraction.md` §11.7 ("ROOT CAUSE FOUND
2026-07-20"): the representative-hijack SIGSEGV was "AbiCloning
singleton-REPRESENTATIVE hijack — LSS_009's 'interchangeable representative'
premise is violated by keyed clones … merging same-member
**same-signature-layout** instances into one LayoutGroup, DISCARDING the
second lambdaId … **UNSOUND under keying, where clones are layout-identical
but behaviorally divergent** … TWO **layout-clean** hijacks (10084-PAP read
as 10088-PAP `[value]`, then 9878 closure read as 9877 closure
`[value,value]`)." The divergent pair were sibling `Unify.andThen` clones —
same source lambda, same signature AND capture layouts, NON-recursive (μ-tie
never fires there) — whose enclosing specs differed only in WHICH
continuation member ({m9877} vs {m9878}, different RAW lambdas) their
callback annotation carried. Annotation differences become STAMPS: each
clone's compiled body direct-dispatches a different continuation.
Layout groups and μ-tie fence NEITHER. Today the ONLY fence is LSS_017's id
inequality itself ("Q(L,S1) /= Q(L,S2) makes 'singleton member => unique
behavioral instance' true by construction").

Consequence: **id sharing narrows sets** ({Q1}∪{Q2}→{Q}), and LSS_005's
safety envelope covers widening only. Re-sharing ids without a replacement
fence re-arms the recorded SIGSEGV — the E11 pair's specs are themselves an
annotation-only split, so a layout-qualified key would unite them. The
"newBody = 0" artifact evidence cannot license sharing either: the diff's
canonicalizer strips lambda indices, which is exactly the distinction the
E11 clones differ by.

### 1.2 The design that survives: C + F

- **C — layout-qualified member identity** (producer): qualify lambda mints
  by the LAYOUT of the enclosing instantiation instead of its SpecId.
  Same-layout clones share one id by construction: consumer slots re-become
  singletons, the propagated key splits (callee demands differing only in
  qualified-member annotations) never happen, and the specs→members→keys
  spiral loses its id-fanout engine.
- **F — a verbatim-clone fingerprint fence** (consumer): AbiCloning's
  representative stamp becomes conditional on **fingerprint unanimity**
  across the instances it would speak for. The fingerprint is a canonical
  serialization of the closure BODY — regions zeroed
  (`CafHoist.zeroRegions` precedent), the instance's OWN fresh lambdaIds
  numbered positionally, everything else VERBATIM — annotations, member
  ids, and SpecId references included. The E11 pair fingerprint-differ
  (their annotations name different raw lambdas); genuine verbatim clones
  match. F replaces LSS_017's id-inequality discharge of LSS_009's premise
  with a checkable one: "fingerprint-equal, layout-unanimous clones are
  interchangeable" — textual identity, a strictly weaker premise than
  today's.

C makes F effective: with shared ids, the family's callee demands equalize,
so clone bodies reference the SAME callee SpecIds and verbatim fingerprints
match in practice (without C, cone-referencing bodies never match and F
alone recovers nothing). F makes C sound: any divergent same-layout union
declines instead of stamping. Ship them together; neither alone.

Both halves are licensed by the source paper itself (§10): the paper's §6.1
states that distinguishing lambdas "which differ only by the content of the
other lambdas on which they operate" is *essential* (= why F must compare
annotations — the E11 lesson), and its §6.2 states that distinct derivations
"which ultimately evaluate to the same lambda term" must be collapsed
*before* any cardinality check (= why the 2-set of §1.2's problem is a
bookkeeping artifact the paper would never see). C+F's composite licensing
condition — same source × same layouts × verbatim annotated body — IS the
paper's element identity, factored into a cheap mint-time name plus an
exact consumer-side confirm.

### 1.3 Directions considered and rejected

- **(A) Post-hoc spec-instance merging**: REJECTED. The body does not exist
  at key-commit (`processItem` runs later, Monomorphize.elm:472-693); K5's
  verdict applies ("interning must happen at CONSTRUCTION or not at all",
  +18.3% wall retrofitted); needs congruence closure + MonoVarGlobal/member
  reference repair + MONO_022 orphan handling — to delete ~130 duplicate
  NODES that cost bytes, not events.
- **(B) standalone consumer-side recovery** (multi-member stamping / index
  rescue without C): PARKED. It inherits F's fence obligations while fixing
  only AbiCloning — devirt and every future singleton consumer keep seeing
  split ids, the spiral keeps its engine, and without C the fingerprints of
  cone-referencing bodies never match anyway.

### 1.4 The two mechanisms, by worked example

The hot code both examples live in:

```elm
-- System.TypeCheck.IO
andThen : (a -> IO b) -> IO a -> IO b
andThen f ma =
    \s0 -> let (s1, a) = ma s0 in f a s1   -- W: the wrapper; `f a s1` is the hot site

-- Compiler.Type.Type
variableToCanType : Variable -> IO Can.Type
variableToCanType variable =
    UF.get variable
        |> IO.andThen (\descProps -> ...)   -- L: the callback lambda
```

`f a s1` runs once per bind — ~19M times per compile for this one chain.
It is fast iff AbiCloning stamped it: callee annotation `LSet [m]`
(a singleton — "exactly one function value ever flows here"), `m`'s closure
instance found in the index, layouts unanimous → the site is emitted as a
direct call to that instance's evaluator (`lambda_14620$cap`) with a typed
capture ABI. `LTop` or a 2-set → generic dispatch.

**Example 1 — the defect, and what C does.** Pre-sigFlow there is one spec
of `variableToCanType`, `S1`; translating it mints `L`'s instance with
member id `Q1 = "l|L|S1"` (source lambda × minting SpecId, LSS_017); the
demand for `andThen` carries `LSet [Q1]` on the callback arrow; the wrapper
site reads a singleton; stamp; 19.3M fast events. sigFlow enriches some
caller's demanded type for `variableToCanType`; annotations are part of the
spec key, so a SECOND spec `S2` is minted — whose body is byte-identical to
`S1`'s (measured: newBody = 0). Identity doesn't care: `L` minted inside
`S2` gets `Q2 = "l|L|S2"` ≠ `Q1`. Both paths feed the shared `andThen`
spec, whose callback slot unions to `{Q1, Q2}` — a 2-set — and the stamp is
gone (the leading Phase-0 hypothesis; the one logged multiSet line is
exactly such an `andThen` 2-set). Two ids, one machine code: the
cardinality check ran on DERIVATION TAGS, not content. Under C both mints
qualify by the widened creation key — `S1`/`S2` differ only in annotations,
widening erases them, both render the same string `W` — so both intern
`"l|L|W"`: one id `Q`, union `{Q}`, singleton restored, stamp back.
Second-order effect: demands EMBED member ids, so once the ids agree the
clones' callee demands equalize and the propagated splits
(`UnionFind.get/modify` 10→14) are never minted at all — the split stops
cascading.

**Example 2 — why C alone is a miscompile, and what F does.** A miniature
of the recorded E11 pair (`Unify.andThen` clones, specs `_$_11371`/
`_$_11373`, members m9877/m9878):

```elm
step : (Int -> IO Int) -> IO Int
step k = getValue |> IO.andThen (\v -> k (v + 1))   -- M: inner lambda, captures k
```

Called as `step cont1` and `step cont2` → two specs `SA`/`SB` whose keys
differ ONLY in annotations (`{cont1}` vs `{cont2}` on `k`'s arrow); layouts
identical everywhere. Inside each spec, `M`'s clone is minted — and the
clones are NOT the same code: `M@SA`'s body has its `k (v+1)` site stamped
as a direct call to `cont1`'s evaluator (its annotation there is the
singleton `{cont1}`), `M@SB`'s to `cont2`'s. Same source, same layouts,
same capture shapes — different function addresses baked in. Under C alone
they would share one member id (their enclosing keys widen equal!); a
singleton consumer would stamp ONE representative, and an `M@SB` object
(capturing `cont2`) would run `M@SA`'s code — which jumps to `cont1`'s
evaluator and reads `cont2`'s captures as if they were `cont1`'s. That is
the recorded "layout-clean hijack" SIGSEGV. F prevents it: at index build
the bodies are in hand; the fingerprint (verbatim body, ANNOTATIONS
INCLUDED, regions zeroed, own lambda numbering canonicalized) differs
between `M@SA` and `M@SB` at exactly the `{cont1}`/`{cont2}` annotation →
`fpUnanimous` fails → `bodyMismatch` decline → generic dispatch. Slow,
correct. Example 1's clones fingerprint EQUAL → stamp granted.

**Why identity is factored across two phases**: the exact identity (the
paper's — the lambda term with its concrete annotated types, §10) cannot
be used at the producer: member ids are minted DURING translation, before
the clone's body exists, and must be stable across re-translations. So C
uses the best proxy available at mint time (the enclosing instantiation's
layout) and F performs the exact comparison at the only phase that has
finished bodies. C is the hash, F is the confirm — the same probe/confirm
split K6 uses for types. Neither works alone: C-without-F re-arms
Example 2; F-without-C recovers nothing twice over (the slot is still a
2-set, and without shared ids the clone bodies reference different callee
SpecIds so verbatim fingerprints cannot match).

## 2. Design

### 2.1 The key (C)

`mintQualifiedLambda` currently interns `"l|" ++ raw ++ "|" ++ specId`
(Engine.elm:400-415). Under the new flag it interns instead:

```
"l|" ++ raw ++ "|" ++ widenedKeyOf specId
```

where `widenedKeyOf : SpecId -> Maybe String` is the **annotation-widened,
immutable creation key** of the enclosing spec:
`Mono.toComparableMonoType (Mono.widenSets keyType)` captured once at spec
creation. `widenSets` (Monomorphized.elm:958-977) replaces every arrow's
`LambdaSetAnno` with `LTop` recursively, so annotation-only splits collapse
to equal strings; layout-differing specs differ. The LSS_019
ground-standalone key (`"g|<global>|<widened-arrow-typeKey>"`,
Engine.elm:1034-1044, widened key built at :1104) is the in-tree precedent
for exactly this identity shape, including its μ-severing rationale.

Known under-sharing (recorded, not a defect): `widenSets` passes `MVar`
arms through untouched (:976-977), so creation keys carrying residual MVars
embed per-item MVar ids — same-layout specs then get different widened keys
and simply DON'T share (degrades toward status quo; the mirror of LSS_019's
residual-deferral discipline). Censused as low `layoutQual.shared`, never a
soundness issue. Fallback-vs-widened string collisions are impossible: every
`toComparableMonoType` rendering starts with a letter code, a bare-integer
SpecId suffix never equals one.

### 2.2 The stable-handle capture (corrected seam)

The qualification input MUST be immutable per SpecId and equal across
annotation-only splits. Neither existing store qualifies:
`registry.reverseMapping`'s stored type is REWRITTEN by joins and completion
(HitChangedJoin, Registry.elm:160-171; `updateRegistryType` :249-259), and
`registry.mapping` has no SpecId-indexed reverse. `Registry` is a pure
module and `enqueueSpecCommit` (Engine.elm:1301-1318) has no type in scope —
so the capture happens in the CALLERS, at the two places a keyed-routed spec
is created with its `monoType` in hand:

1. `enqueueSpecKeyed` (Engine.elm:1420-1490): it already detects creation
   via `reg1.nextId > s.registry.nextId` (:1452-1453). On the UNDER-budget
   create path add a flag-gated `Intern.widenSets monoType` probe (today
   only the over-budget arm widens, :1437-1444 — the under-budget arm is
   exactly the sigFlow-split population); the over-budget arm reuses its
   existing widened `keyType` (widenSets is idempotent, so budget-widened
   and annotation-created twins of one global get equal widened keys —
   their lambdas SHARE, a population §5's pins must cover). Render with
   `toComparableMonoType` and record.
2. `seedSpec` AND `seedFlagsDecoder` (Monomorphize.elm:361-395): both
   create via `Registry.getOrCreateSpecId` with `monoType` in hand; under
   the all-keyed default their bodies' mints ARE routed, so capture here
   too (one widenSets for 1-2 specs) — otherwise every entry-global lambda
   takes the fallback and "expected 0" is false by construction.

No capture at `Registry.getOrCreateSpecId`'s other caller (the lss-off arm,
Engine.elm:1252-1258): lss-off never qualifies mints (:339-340). The
unkeyed lss-on arm (:1244-1250) needs no capture either — its globals are
non-routed and their mints stay raw (routing predicates identical,
:344-356 vs :1224-1231).

**Where the store lives**: NOT a new top-level `S` field — `S` sits at 31 of
the native runtime's 32 record-scan slots (Engine.elm:221-225, :686-690:
"adding a top-level field to S breaks the native self-compile at MLIR
parse"). House it inside `LssMemberTable` (Engine.elm:227-233) — the
lss-owned, resetItem-surviving home of `byKey`/`sources`/`lambdaQualified` —
as `specWidenedKeys : CoreDict.Dict Int String` (SpecIds are dense; an
`Array (Maybe String)` is the alternative if probe cost shows up).

Fallback: a mint whose enclosing spec has no entry falls back to TODAY'S
SpecId qualification and bumps `layoutQual.fallback` — fail toward the
status quo, never toward raw ids. Expected 0 once the seed captures land.

Idempotence: capture is write-once at create; LSS_010 re-translations reuse
the same SpecId and re-read the same immutable entry, so re-mints intern the
same string (the property LSS_017 documents at Engine.elm:320-322). MONO_029
saturation passes and `withScratchStore` preserve `currentSpecId`
(Engine.elm:729-742); the subst engine never mints member ids and owns a
separate registry — no interference.

### 2.3 μ-tie interplay (LSS_018) — the equal-id bypass is REQUIRED

The tie arm (Engine.elm:362-383) is raw-keyed and layout-blind: it fires
whenever the spec's stored demand carries ANY qualified member of the raw
lambda being minted (`demandQualifiedFor`, Monomorphize.elm:705-725,
smallest id wins), and on firing it `recordMuTied` — exported as
`MonoGraph.lssBlockedMembers` and FORCE-BLOCKED in AbiCloning (:540-544).
Under C, the demand-carried id of a same-layout sibling EQUALS the id the
mint would produce — an unmodified tie would fire on the equal id, record
it μ-tied, and force-block the very stamps this plan recovers (converting
the expected `stampedStaged` recovery into `declinedBlocked`; the +8 on
members 9422/5831 shows this population is live in the target family).

**Change**: when the demand-carried id equals the layout-qualified id the
mint would intern, take the plain mint path and do NOT record `muTied`.
Only a tie to a DIFFERENT id is the genuinely-divergent recursive class —
that continues to tie, record, and block, preserving LSS_018's
spiral-termination role (C strictly reduces id fan-out: a generation-2
spiral spec is an annotation-only split of generation 1, so its widened key
is equal and the mint re-interns the same string). `lambdaQualified`'s
payload is ALREADY `(raw, minting SpecId)` with first-mint-wins insertion
(Engine.elm:230, :411-415) — no code change; its doc comment gains
"first-minting spec, diagnostics only". The forced-spiral fixture re-run
(closes at 2 specs today) is the gate; any `lssBlockedMembers` shrink must
be the equal-id bypass and nothing else.

### 2.4 The fingerprint fence (F) in AbiCloning

At `collectGo`/`insertInstance` (AbiCloning.elm:281-413) the closure BODY is
in hand and currently discarded. Compute per instance:

```
fp = canonical serialization of the body with regions zeroed and the
     instance's own lambdaIds numbered positionally; annotations, member
     ids, SpecId references, names, CallInfo — VERBATIM.
```

(Serializer precedent: `Diff.serNode`, MonoSolver/Diff.elm:215; zeroing
precedent: `CafHoist.zeroRegions`, CafHoist.elm:1102-1177 — note that one
is annotation-sensitive by ==, which is exactly what F wants.) `LayoutGroup`
gains `fpUnanimous : Bool`, maintained in `joinGroup` (:422-443) alongside
`unanimous`; `resolveInGroups` / `resolveStagedFirstStage` / `papScan`
require it, declining otherwise with a NEW labelled reason `"bodyMismatch"`
(the labelled `Decline` variant is in the tree, :1284-1292; add the stats
counter to the shape-decline family). Lazy variant if cost shows up:
fingerprint only members whose `MemberInfo` holds ≥2 distinct-lambdaId
instances — the unanimity default for singletons is trivially true.

**AS-BUILT CORRECTION (2026-08-21, found by the §4.5 byte-identity gate):
"names VERBATIM" above is WRONG for LOCAL names.** The first gate run
FAILED with exactly −163 `singleton_fast` stamps flag-off: MonoInlineSimplify
freshens let-bound names in its verbatim inline copies
(`freshenLetBoundNames` — the very mechanism the inliner-dup-names fix
installed), so name-verbatim fingerprints false-mismatch every inliner copy.
As built, LOCAL names (params, let/tail defs, destructors, case
labels/scrutinees, capture slot names, local references) compare
POSITIONALLY in first-encounter order — the same device as the own-lambdaId
numbering; SEMANTIC names (record fields, ctors, globals, kernels,
accessors) and everything identity-bearing (annotations, member ids,
SpecIds, CallInfo, literals, decider tests) stay verbatim, so the E11
discrimination (which lives in annotations/SpecIds) is untouched. Aliasing
capture-EXPR outer references across copies is sound: captures are
per-object runtime VALUES loaded from the actual closure object — capture
LAYOUT unanimity (the existing `abiMismatch` fence) is the gate for those,
per LSS_009's original license. The lazy variant is also as-built: `fpOf`
runs only from `joinGroup`'s distinct-lambdaId arm while the group's stamp
is still live (`unanimous && fpUnanimous`), with the rep's fingerprint
memoized in `repFp`.

Soundness note for the record: under C the clones' inner qualified ids
AGREE (same widened key), so verbatim annotation comparison is exact — no
raw-projection or SpecId-congruence is needed in v1. If Phase-3 measurement
shows recovery blocked by residual SpecId differences inside fingerprints,
a congruence extension (SpecId → Global × widened creation key classes) is
the recorded v2, with its own soundness argument — do NOT improvise it in.

Also in this phase: rewrite the stale comment at AbiCloning.elm:208 (multi
"must be 0 under LSS_017 qualified members" — already superseded by the
amended LSS_017 monitoring-delta reading, flat wrong once C ships).

Existing populations under F: MonoInlineSimplify verbatim inline copies are
verbatim ⇒ fingerprint-equal ⇒ no behavior change; staging-wrapper /
adopted blockers and μ-tied force-blocks sit above the fence and are
unchanged. Flag-off, `fpUnanimous` is computed but every group is
single-instance-dominated exactly as today — byte-identity is the gate that
proves it (§4).

**AS-BUILT CORRECTION 2 (2026-08-21): the fence is FLAG-GATED, not
unconditional — the §4.5 gate REFUTED the paragraph above.** After the
local-name positionalization (correction 1), the byte-identity gate still
failed by exactly 4 stamps: the default tree holds FOUR multi groups whose
instances are NOT verbatim, all `Dict.map`-spec staged stamps over
local-multi callback twins. FPDIAG windows (one-shot diagnostics, added
and removed same-day): two mismatch classes, both ANNOTATION differences —
(a) a sibling qualified-member id at the same slot (`A[34133]` vs
`A[34134]`; textually divergent, possibly-identical-behavior clones — the
id congruence that could prove them equal is this plan's PARKED v2, not to
be improvised), and (b) annotation PRECISION on a capture type
(`A[18467]` vs LTop — one twin carries a proof the other lacks; stamping
the proven rep for the unproven object is the unlicensed-direct-dispatch
shape). The fence's declines are doctrinally correct — which means HEAD's
four stamps rest on an unverified verbatim assumption (LSS_017's
"unique behavioral instance by construction" does not cover multi-instance
groups). Landing decision, per this plan's own fail-toward-status-quo
discipline and §6.3's default-byte-identity requirement: `fpUnanimous` is
maintained and enforced ONLY under `lss.layoutQualMembers` (threaded as
`abiCloningPass fpFence`), flag-off keeps HEAD's behavior bit-for-bit, and
the four sites are a RECORDED FLIP-TIME DELTA: any default flip of the
flag converts them to `bodyMismatch` declines, with the soundness
rationale on the fence's side.

### 2.5 Flag, config, census

House wiring (four points + one registration):

- `LssConfig` gains `layoutQualMembers : Bool`, DEFAULT-OFF at landing; doc
  comment names LSS_024, this plan, and the hash token.
- Decoder: appended LAST to `lssDecoder`'s positional apply chain
  (Config.elm:673-689; the APPEND-ONLY-and-LAST warning at :683-685).
- Hash token: muTie-style bidirectional `lssLQ=` when non-default
  (Config.elm:970-978 pattern) so the default hash is stable across an
  eventual flip.
- Env override: `ECO_MONO_LSS_LAYOUT_QUAL` — the override function
  (Builder/Eco/Config.elm:1693-1707 shape) AND its `Utils.envLookupEnv`
  registration in `applyEnvOverrides`' lookup list (the SIG_FLOW row is
  :162).
- Census: ONE nested record field
  `lssStats.layoutQual = { mints, shared, fallback, tieBypass }` — `shared`
  counts id reuse across distinct enclosing specs (the fix working),
  `fallback` counts §2.2 misses (expected 0), `tieBypass` counts §2.3
  equal-id bypasses. NESTED because `LssStats` holds 30 fields against the
  32-slot record-scan cap (Engine.elm:113-157 — the `grounding`/`sigStats`
  sub-records exist for the same reason); one field lands at 31, three flat
  fields would breach.
- The `"bodyMismatch"` decline counter rides `AbiCloningStats` (no cap
  pressure there).
- Flag-off byte-identity of `out.mlir` is the substrate gate.

## 3. Phase 0 — pin the per-site mechanism (one census run)

One-shot instrumentation, decline-log precedent (recipe in
`/work/lss-decline-log-analysis.md`; the labelled `Decline` variant and the
multiSet-arm logging already exist — the NEW parts are logging the `LTop`
arm (:1208) and bypassing `scanExpr`'s singleton-only gating for the census
build so LSet-ms/LTop sites stop being under-counted). Run the sigFlow-on
cold self-compile once. Deliverables:

1. The consulted slot shape of the six de-stamped `andThen` wrapper sites:
   expected 2-sets `{Q(L,S1), Q(L,S2)}` of same-raw qualified siblings (the
   logged `members=31235,31260` line is one already); LTop would indicate
   honesty-poison instead.
2. Per hot split, the ROOT-vs-PROPAGATED classification: does the family
   key split originate in sigFlow FACT content (root — C cannot collapse
   the spec split, only the ids), or in transported qualified-member
   annotations (propagated — collapses under C)? Also classify any raw-`l|`
   ids in the split demands (LSS_017's live signature channel keeps such
   keys split and caps §6's structural expectations).
3. `lambdaQualified`/`muTied` dump restricted to the family's raw lambdas +
   the raw/interned classification of blocked ids 9422/5831 — sizes the
   §2.3 equal-id bypass.

**Stop condition** (the only one left — E11 is answered in §1.1): if the
six sites read LTop from sigFlow's honesty machinery (`widenedByCf`-class),
identity changes cannot recover them; record and re-scope. Otherwise C+F
proceeds as specced; the census only sharpens §6's per-class expectations.

## 4. Phase 1 — substrate (flag off = byte-identical)

1. `LssMemberTable.specWidenedKeys` + the two capture seams (§2.2),
   `Intern.widenSets` probes included. K6 trap: only write tables back when
   they grew.
2. `mintQualifiedLambda`/`lambdaInstanceMemberId`: the widened-key
   qualification under the flag, the SpecId fallback + counter, and the
   §2.3 equal-id μ-tie bypass.
3. The F fence in AbiCloning (§2.4): per-instance fingerprint,
   `fpUnanimous`, the `"bodyMismatch"` decline + counter, the :208 comment
   rewrite.
4. Config/decoder/hash/env wiring + `lssStats.layoutQual` (§2.5).
5. Gates: `--target full` (E2E) flag-off AND flag-on (fresh `eco-stuff` per
   leg — the directed-set-flow Phase-D standard); elm-tests; **flag-off
   `out.mlir` byte-identity** on the solver self-compile (the
   substrate-only check).

## 5. Phase 2 — unit and E2E pins

1. **Engine unit tests**: flag-on, two specs of one Global split by
   annotations alone → lambda mints intern ONE id; layout-differing specs →
   distinct ids; budget-widened + annotation-created twins of one global →
   SHARED id (the §2.2 over-budget population); re-mint after simulated
   re-translation → same id (idempotence); missing widened-key entry → the
   SpecId fallback + counter.
2. **μ-tie pins**: equal-id case takes the mint path, records nothing in
   `muTied` (`tieBypass` bumps); different-id case still ties, records, and
   its sites decline `blocked`. The LSS_018 forced-spiral fixture re-run:
   still closes at 2 specs.
3. **Fence pins (AbiCloning unit tests)**: two verbatim instances under one
   member id, equal layouts → one group, `multi = True`, `fpUnanimous` →
   `Stamp`; an E11-SHAPED pair — same layouts, bodies differing only in
   which member id an inner annotation names → `"bodyMismatch"` decline
   (THE soundness pin for §1.2); a capture-layout-divergent instance →
   `abiMismatch` (existing fence unchanged).
4. **E2E reproducer fixture** (`test/elm/src/`, LssSharedSpecJoinTest
   style): a minimal two-caller family forcing an annotation-only key split
   whose callbacks feed one shared `andThen`-shaped HOF. Pins: flag-off
   stamped; sigFlow-on WITHOUT the fix de-stamped (reproduces the defect);
   sigFlow-on WITH the fix stamped again. If the last pin fails, the
   mechanism story is wrong — that is the plan's refutable claim.
5. **Determinism ×2**: two cold flag-on self-compiles byte-identical to
   each other (the lss-opt.md Run-P standard for accepted output changes).
6. Optional but cheap insurance given E11's failure mode is a SIGSEGV: one
   flag-on `ECO_HEAP_VALIDATE=1` self-compile leg.

## 6. Phase 3 — measurement and the flip chain

Counters first; one cold run per arm; **same-tree pairs only** — the
recorded 8.79/7.68 and sat+fast totals are for orientation, never
comparison (the corpus grows with this plan's own source; re-measure both
arms — the trap runtime-calls.md:1604 records).

1. **lss-opt.md A/B** (same tree, both arms `ECO_MONO_LSS_SIG_FLOW=1`, fix
   on/off): expected counter movement — `stampedStaged` recovers ~+6,
   `layoutQual.shared` > 0, `tieBypass` > 0, `declinedBlocked` shifts per
   the §2.3 bypass, `bodyMismatch` small (each one is a fenced hazard,
   list them), wall FLAT (≥3% band), majors reported. **Structural check**
   (the §0 canonical artifact diff re-run, fix-on vs same-tree sf-off):
   PROPAGATED splits collapse (`UnionFind.get/modify` toward 10, the
   `IO.andThen` +1, the scalar-leaf 1→2s); ROOT fact-driven splits persist
   by design (the family tops may stay 2) — record the split census both
   ways per Phase 0's classification. Diverged roles shrink toward the
   root-split set, not to zero.
2. **runtime-calls.md** (cold SUBST workload, counters-lowered builds,
   same tree, THREE legs: fix-off/sf-off baseline, fix-off/sf-on,
   fix-on/sf-on): ACCEPTANCE — the fix-on/sf-on leg recovers ≥ 85% of the
   same-tree (sf-on vs sf-off) fast-event gap, and the fixed per-fp census
   shows the `variableToCanType` callback's ~19.3M restored. `sat+fast`
   invariance across the same-tree legs and byte-identical workload
   `out.mlir` are the sanity rails. (On the recorded tree that gap was
   23.2M ≙ 1.11 coverage points; +20M there ≙ ~8.6%.)
3. **Default-build non-regression**: flag DEFAULT-OFF at landing; default
   artifacts byte-identical by the Phase-1 gate.
4. **The flip chain — record, do not improvise.** (a) If 1+2 hold:
   `lss.layoutQualMembers` default-flip as its own recorded decision (full
   battery + Stage-4b/8c bootstrap fixed points, the K6/§14 standard).
   (b) THEN re-open the `lss.sigFlow` §8.3 flip decision
   (plans/lss-directed-set-flow.md): fidelity already held at wall FLAT;
   this plan removes the only recorded blocker. sigFlow default-on is a
   separate decision with its own full battery — never couple the two
   flips in one landing.

## 7. Risks

1. **The E11 class** (answered, fenced, pinned): same-layout annotation-only
   clones CAN be behaviorally divergent (§1.1 verbatim record). C alone
   re-arms it; F declines it (`bodyMismatch`); the §5.3 E11-shaped unit pin
   is the regression guard. LSS_009's premise is discharged by FINGERPRINT
   EQUALITY, not by construction — §9's amendments say exactly that.
2. **Borrow is a second representative-premise consumer**:
   `Borrow.buildLambdaSigs` analyzes one representative per member citing
   LSS_009 (Borrow.elm:189-213; BORROW_006 "stored sigs equal by
   construction"). Census/validate-gated today (early-exit, :130-140) — no
   shipped-artifact risk — but the flip decision (§6.4a) must either give
   Borrow the same fingerprint gate or record the constraint in
   BORROW_006. Named here so it cannot be forgotten.
3. **Widened-key collisions / MVar residuals**: collisions across
   layout-DIVERGENT specs land instances in different buckets/groups —
   sites stamp their own-layout group's rep (sound via the site-layout
   filter); same-layout divergent unions are F's job. MVar-residual keys
   under-share (censused, status-quo-degrading). Neither is a soundness
   hazard.
4. **μ-tie/termination**: the equal-id bypass (§2.3) is load-bearing —
   without it C blocks its own recovery; with it, different-id ties keep
   LSS_018's blocking and termination intact. Spiral fixture + `tieBypass`
   census are the gates.
5. **Stale qualification input**: contained by construction — write-once
   immutable capture (§2.2); the idempotence unit pin enforces it.
6. **Determinism**: the widened key is a pure function of the immutable
   creation key; interning stays deterministic (LSS_003's argument extends
   — §9). The §5.5 ×2 gate measures it. Note for census hygiene: interning
   ORDER shifts all numeric member ids — cross-run comparisons match by
   site/label, never by id.
7. **FORBID_OPT_003** (CAF slots per spec): untouched — C merges member
   IDS, never specs; every spec keeps its own emitted symbols and CAF slot.
8. **Cost**: one `Intern.widenSets` probe + comparable-key render per
   CREATED keyed spec (~40k × p50-9-node key DAGs — the speckey census
   prices this class of work as cheap), plus F's per-instance serialization
   (small bodies; lazy variant recorded). lss-opt wall is the check; ≥3% is
   the signal band.

## 8. Non-goals (recorded)

- No spec-node dedup/merging (direction A rejected — §1.3); ROOT
  fact-driven duplicate specs persist by design. Propagated duplicates stop
  being CREATED (that is C working, and the artifact shrinks accordingly) —
  the two statements are about different populations (Phase 0
  classification).
- No raw-`l|` signature-channel fix (LSS_017 v2 stays deprioritized; raw
  ids still decline unstampable-but-sound; any keys they hold split stay
  split — capped expectations in §6.1).
- No standalone multi-member stamping (direction B parked).
- No SpecId-congruence inside fingerprints (recorded v2 only if §6
  measurement demands it).
- No change to `lss.sigFlow`'s default inside this plan (§6.4b is a
  separate recorded decision).

## 9. Invariants delta

- **NEW LSS_024**: layout-qualified lambda-instance members + the
  fingerprint fence — under `lss.layoutQualMembers` (env
  `ECO_MONO_LSS_LAYOUT_QUAL`, hash `lssLQ=` non-default-only), a
  keyed-routed lambda mint qualifies by the enclosing spec's immutable
  annotation-widened creation key (`l|<raw>|<widenedKey>`, captured at
  create per §2.2); same-layout annotation-split clones share one member id,
  layout-differing clones do not; missing captures fall back to SpecId
  qualification (censused); the μ-tie takes the plain-mint path on equal
  ids; AND AbiCloning representative stamps require fingerprint unanimity
  across the group (`bodyMismatch` decline otherwise) — the
  singleton⇒unique-behavior premise is discharged by verbatim-clone
  fingerprint equality, never by id inequality alone.
- **AMEND LSS_017**: under LSS_024 the qualification key is the widened
  creation key; the sentence "keyed clones of one source lambda are
  same-layout but behaviorally DIVERGENT" is retained as the E11 record but
  re-scoped: such clones now SHARE an id and are fenced at the consumer by
  fingerprint unanimity (LSS_024), not by id inequality; raw-`l|` signature
  ids unchanged.
- **AMEND LSS_009**: the representative license adds the fingerprint
  condition; "discharged by LSS_017 fork-qualified members" becomes
  "discharged by LSS_017 id inequality (flag off) or LSS_024 fingerprint
  unanimity (flag on)"; `multiInstanceGroups` population note
  (annotation-only clones now join groups; still a monitoring delta).
- **AMEND LSS_018**: the equal-id bypass (ties fire and record only on
  id inequality); `lambdaQualified` payload semantics ("first-minting
  spec, diagnostics"); spiral termination argument unchanged (strictly
  less id fan-out).
- **AMEND LSS_003**: minting-site enumeration UNCHANGED (the new key form
  still mints via `Engine.memberIdFor`); extend only the determinism note
  (the widened key is a pure function of the immutable creation key).
- **Docs**: amend `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`
  §5's `l|` row per §10.6 when this plan lands.

## 10. Fidelity to the LSS paper

Examined 2026-08-21 against the source paper (Brandon, Driscoll, Dai,
Berkow, Milano — *Better Defunctionalization through Lambda Set
Specialization*, PLDI 2023;
`design_docs/auto-borrow-inference/lambda-set-specialization.pdf`).
Recorded here because the paper turns out to be the strongest license this
plan has — stronger than the LSS_009 paraphrase §1 leans on.

1. **No contradiction — the paper's §6.2 prescribes this dedup.** Its
   implementation note (146:18): lambda sets "may now contain multiple
   distinct substitution expressions which ultimately evaluate to the same
   lambda term. This is not a problem, as we already evaluate substitutions
   before checking lambda sets for **equality, cardinality, or
   inclusion**." Eco's `Q(L,S1)`/`Q(L,S2)` are exactly such distinct
   derivations of one lambda term; the paper computes cardinality AFTER
   normalization and would see §1.4-Example-1's 2-set as a singleton. The
   de-stamp this plan fixes is, in paper terms, a cardinality check run on
   un-evaluated derivation tags.
2. **The paper's §6.1 is the E11 lesson.** Element types recursively
   contain other lambda sets, and this "is in fact an essential feature of
   our formalism, as it allows our type system to distinguish between
   lambdas which differ only by the content of the other lambdas on which
   they operate" (146:17). That is why F compares annotations: the E11
   clones differ ONLY there. The paper agrees with the E11 SIGSEGV, not
   with naked C — layout-only identity under-distinguishes.
3. **C+F's composite identity IS the paper's.** A set element is the lambda
   term WITH its annotated types, body included (Fig. 2:
   `ℓ ::= λ[x:τ₁](y:τ₂).(ε:τ₃)`), post-specialization with σ̄ substituted
   concrete — identity is structural and content-grounded, with no
   derivation tag anywhere. C+F's licensing condition (same source × same
   layouts × verbatim annotated body) is that identity, factored per §1.4
   because eco mints ids before bodies exist.
4. **The drift history, in paper terms.** Raw ids (pre-Fix-B) were COARSER
   than the paper — one id over content-divergent clones, violating §6.1's
   essential distinction (the E11 SIGSEGV). LSS_017's SpecId ids are FINER
   than the paper — content-identical elements kept distinct, violating
   §6.2's normalization — and they embed *specialization identity* in
   elements, which the paper's content-grounded identity structurally
   cannot do and which is the root enabler of the specs→members→keys
   spiral (LSS_018's μ-tie is extra-paper machinery built to terminate an
   extra-paper feedback loop). C+F returns identity to the paper's axis;
   the spiral loses its engine as a corollary (§2.3).
5. **Recorded extrapolations** — all pre-existing eco divergences this plan
   operates inside, none introduced by it: (a) *id-space proxies with
   annotation-widening as the μ-severing device* — the paper severs
   recursive-set circularity with real μ-binders and μ-aware substitution
   (Fig. 10); integer ids cannot express μ, so LSS_019 widened the `g|`
   qualifier and C widens the `l|` qualifier the same way; the price is
   under-distinction, which is exactly why F is mandatory rather than
   optional. (b) *The singleton cliff* — the paper lowers EVERY set to a
   sum type plus a total match (146:16-17); a `bodyMismatch`-declined group
   is, in paper terms, a legal 2-variant match that eco's v1 doctrine
   chooses not to exploit (a stamped 2-way dispatch is a conceivable
   follow-on, out of scope here). (c) *Erasure semantics* — LSS_005 is the
   paper's own semantics-by-erasure (146:6; Thms 4.1/5.1/5.6/5.7):
   annotations never change observable behavior, while both the paper and
   E11 agree they change generated CODE — so interchangeability requires
   identical annotated terms, not identical erasures, which is F's exact
   condition. (d) Mono-Used (Fig. 9) mints one spec per distinct σ̄ and
   never merges distinct-σ̄ specs — consistent with §1.3's rejection of
   direction A.
6. **Fidelity-mapping refinement** (the docs delta in §9): the mapping's §5
   table rates `l|<raw>|<specId>` as "YES — faithful, the id-space image of
   μ-aware substitution". Refine on landing: faithful in DIRECTION
   (instantiation qualification is μ-substitution's image; raw ids are
   proven unsound), unfaithful in PROXY when substituted content coincides
   — the paper's §6.2 collapses that case and eco's SpecId tag does not.
   The row should cite this section.

---

*Measurement anchors for the execution record*: fast coverage 8.79%
(sf-off) / 7.68% (sf-on, unfixed) on the Run-AB tree; net loss 23,231,541
events in four callbacks (19,286,974 = `variableToCanType`);
`stampedStaged` −6; `declinedBlocked` +8 (members 9422 ×7 / 5831 ×1, incl.
`Compile.typeCheckTyped`); `declinedNoInstance` +133 (NOT the hot sites —
§0; `andThen` noInstance 26 = 26); the one logged multiSet line IS an
`IO.andThen` 2-set; instance splits 1→2 / `UnionFind.get/modify` 10→14; 59
diverged roles, newBody = 0.
