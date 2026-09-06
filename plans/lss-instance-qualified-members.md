# Instance-qualified lambda members: (lambda, spec) → (lambda, spec, local-multi instance)

**Status: FIX A BUILT AND MEASURED 2026-09-06 — `arityOver` −96.9 %, dispatch
−22.7 %, wall −5.2 %; with instance qualification also on, dispatch −28.1 % and
wall −7.1 %. Output byte-identical, all gates green. Both flags DEFAULT-OFF
pending a flip decision. See §18 for results, §15-§17 for the design.**

**Read §18.4 if you read nothing else: `instanceQual` moves only TEN sites and
removes 81.7 MILLION dispatches (2.0 % of wall). The flag §12 shipped
default-off as "negligible" is worth 2 % of self-compile wall — but only once
Fix A has cleared the guard standing in front of it. Site counts have now
mispredicted weight three times in this arc; stop reading them as impact.**

**The P0 census killed the motivation (§12). The mechanism is real and the
implementation is correct — the unit differential shows the shared member pair
splitting and the consumer gaining a keyed specialization — but the class it
fixes (`declinedBodyMismatch`) is 78 sites out of ~35,600 declines, and
`Dict.foldl` is not one of them. `mRecord`'s 79.5 M dispatches decline on
`arityOver`, a staging/currying problem, before member identity is consulted.
Read §12 before spending anything else here.**

Successor to the Dict/Set fold devirtualization question. Sibling invariants:
LSS_017 (fork-qualified members), LSS_024 (layout-qualified members +
AbiCloning fingerprint fence), LSS_018 (μ-tie), LSS_009 (representative
license), LSS_010 (dirty-flush re-translation).

---

## 1. The asymmetry this plan closes

Two mechanisms disagree about how many things a let-bound function is.

**Local-multi instance keying is annotation-SENSITIVE.**
`Engine.recordMultiInstance` (Engine.elm:2487) keys `entry.instances` by the
demanded `MonoType` under `Mono.SpecMap` — `specHashOf` / `eqKeySpec`, which
the comment at :2490 spells out as deliberate: *"local-multi instances are
specialization-intent — differing lambda sets mint separate per-instance
bindings (f / f$1), never share."* So two uses of one let-function whose only
difference is the lambda set of an argument produce **two** instances, and
`Translate.buildLocalDefs` (:7224) emits two defs by re-translating the same
RHS twice through `retranslateAt`.

**Lambda member qualification is instance-BLIND.**
`Engine.lambdaInstanceMemberId` (:576) qualifies a lambda instance's member id
by the source lambda and the enclosing spec — `l|<raw>|<specId>` under
LSS_017, or `l|<raw>|<widenedKey>` under LSS_024, which is default-on
(`defaultLss.layoutQualMembers = True`). Both re-translations happen inside
**one** spec of the enclosing global, so both mint the **same** member id.

The result is a member id that claims one behaviour and indexes two. The
consumer's set is a singleton `LSet [m]`; AbiCloning finds `m` with two
instances in one layout group whose fingerprints differ; LSS_024's fence
declines with `declinedBodyMismatch`; the site stays `generic_apply`.

**The decline is correct.** It is the only thing standing between us and a
representative hijack (the E11 SIGSEGV class). The defect is upstream: the id
should have split when the instance split.

### 1.1 The shape, minimally

`Compiler/AST/Monomorphized.elm:483` — the compiler's own #1 remaining
dispatch source, 79.5 M generic dispatches on a self-compile:

```elm
mRecord fields =
    let
        seed = mixHash 13 (Dict.size fields)
        fold hashOf =
            Dict.foldl (\name t h -> mixHash (mixHash h (String.length name)) (hashOf t)) seed fields
    in
    MRecord (packHashes (fold layoutHashOf) (fold specHashOf)) fields
```

`fold layoutHashOf` and `fold specHashOf` have the *same* type modulo the
lambda set of `hashOf`, so local-multi mints `fold` and `fold$1`; the
`Dict.foldl` callback is ONE source lambda re-translated twice; both closures
carry one member id; `Dict_foldl` gets ONE spec; the callback call is generic.

Reduced to ~20 lines in
`<scratchpad>/dictprobe/src/Main.elm` (`mRecordShape`), which emits one
`Dict_foldl_$_14`, two lambda globals, `_call_kind = "generic_apply"`. The
contrast probe — two *textually distinct* lambdas at three call sites — emits
**three** `Dict_foldl` specializations, so keying itself works. The gap is id
distinctness, not key richness.

### 1.2 Why fixing the id is the whole fix

Distinct member ids ⇒ distinct annotations at the callback position ⇒
different `specHashOf` ⇒ `keyed` (default `True`, ALL globals) splits
`Dict_foldl` in two ⇒ each spec's `func` set is a singleton whose member has
exactly ONE instance ⇒ `unanimous && fpUnanimous` hold trivially ⇒ AbiCloning
stamps a direct `_fast_evaluator`. Nothing else in the chain needs touching.

**E4a is load-bearing here.** `Translate.flushLocalMultiEnrich` is what carries
the per-instance re-translated def's annotations onto the already-emitted USE
sites; without it the uses hold `LTop` and the split never reaches
`Dict.foldl`'s call site. Any regression in the overlay silently reverts this
plan's payoff to zero, so the §1 census reads the use sites, not the defs.

---

## 2. Census (P0) — MUST run and report before §4 is written

The question is not "does the mechanism exist" (§1 proves it does for one
function). It is **how much mass has this shape**, because the plan's cost —
spec fan-out — is paid corpus-wide while the benefit is paid only where the
shape occurs.

Everything here is report-gated, pure, and mints nothing.

### 2.1 New `AbiCloningStats` fields

`Compiler/GlobalOpt/AbiCloning.elm`. `collectInstances` already builds the
layout groups and already maintains `multi` and `fpUnanimous`; the census is a
fold over the finished index plus a bump at the existing decline site.

| field | meaning |
|---|---|
| `groupInstanceHist : Dict String Int` | `"<n>"` → layout groups holding n instances |
| `fpDivergentGroups : Int` | groups with `multi && not fpUnanimous` — **the target class** |
| `fpDivergentByHome : Dict String Int` | `<home spec's global>` → divergent groups minted there |
| `declineByCallee : Dict String Int` | `<callee global>\|<reason>` bumped at every declined site |
| `declineWeightByCallee : Dict String Int` | the same key, but bumped by the site's enclosing spec — the join key for the runtime census |

`declineByCallee` is the one that answers the user's question directly:
`Dict.foldl|bodyMismatch` vs `Dict.foldl|multiMember` vs
`Dict.foldl|noInstance` separates "one incoming lambda that we mis-identify"
(fixable here) from "genuinely several incoming lambdas" (not fixable here).

Rendered in `Builder/Generate.elm` beside the existing `topSiteShapes` block
(:1220–1274), under the same `lss.report` gate.

### 2.2 The four buckets, and which one this plan owns

At every call site whose callee carries an annotation:

| bucket | condition | this plan |
|---|---|---|
| **A** genuine multi | `LSet [m1, m2, …]`, ≥2 members | **no effect** — needs multi-set lowering |
| **B** false singleton | `LSet [m]`, m has ≥2 instances, fingerprints DIVERGE | **the target** |
| **C** true multi-instance | `LSet [m]`, ≥2 instances, fingerprints AGREE | already stamps |
| **D** no set | `LTop` / `LVar` | out of scope |

Bucket B ⇒ same member ⇒ same `(raw, widenedKey)` ⇒ same source lambda by
construction. Inliner copies are verbatim, so they land in C. **Divergent ⇒
local-multi (or a staging wrapper, which is a separate BLOCKER class).** No
extra attribution machinery is needed to make that inference.

### 2.3 Static counts are not dispatch weight

Recorded trap (LSS_025, and `topSiteShapes`' own doc): `stampCall` consults
every call, so these are SITE counts. The go/no-go needs the dynamic side:

1. Self-compile with `ECO_MONO_LSS_REPORT=1` → the static tables above.
2. Self-compile with `ECO_DISPATCH_STATS=1` → callee-keyed dispatch counts.
3. Join on the callee global; rank bucket-B callees by measured dispatch.

Both runs on the **native** compiler (`eco-boot-native <mlir> -o <elf>`), never
the JS build — the JS self-compile needs `--max-old-space-size=16384` and
measures a different machine.

### 2.4 Deliverable

A table of bucket-B callees ranked by measured dispatch, with `mRecord`'s
79.5 M as a known member, plus the corpus totals `fpDivergentGroups` and
`declinedBodyMismatch`. §11's gate reads exactly this table.

---

## 3. The design

### 3.1 The discriminator: an ORDINAL, not a type hash

The obvious discriminator is the instance's `MonoType` — it is what caused the
split. **It must not be used.**

`specHashOf` is annotation-SENSITIVE. Putting it in the qualifier would make
the member id a function of the annotations, which are a function of member
ids: the specs → members → keys spiral LSS_018 was built to terminate. LSS_024
avoids exactly this by qualifying with the *widened* (annotation-blind) key —
and widening is unavailable to us, because the split we are trying to expose IS
an annotation-only split.

So the discriminator is the instance's **ordinal within its local-multi
entry** — the integer already in its emitted name (`fold` = 0, `fold$1` = 1).
It is:

- **bounded** — by the number of instances of that one let-function;
- **already load-bearing** — `freshName` is assigned from `specMapSize` at
  insert time and `Mono.SpecMap` iterates in insertion order (Engine.elm:1514),
  so if the ordinal were unstable the *emitted def names* would already be
  unstable, and they are not. That is the stability argument, and it costs
  nothing new;
- **idempotent** under LSS_010 dirty-flush re-translation, for the same reason.

### 3.2 Nesting: compose, don't overwrite

A let-function instance may contain another multi-instantiated let-function.
If the inner retranslation overwrites the tag, two different outer instances
containing inner instances with the same inner ordinal collide again. The tag
is therefore a **composition**: `tag' = mix tag (ordinal + 1)`, seeded 0, with
`+1` so a leading ordinal-0 is not absorbed. `Monomorphized.mixHash` is **not
exposed** — define the two-line mixer locally in `Engine` rather than widening
that module's interface for one caller.

### 3.3 The hard cap (K)

Termination is bounded, not proven. An annotation split adds instance N+1,
whose new member id can cause a further annotation split, adding N+2. The
lattice is finite per item but can oscillate, and `maxSpecsPerGlobal` is 0
(unlimited) by default since 2026-08-29.

**Requirement: instance qualification applies only to ordinals in `[1, K)`
(`instanceQual.maxInstances`, default 8).** Ordinal 0 and everything at or
beyond K mint today's key — the fence declines, the site stays generic, the
status quo. Cap hits are censused (`instanceQual.capped`, expected small; a
large number is itself the finding). One (lambda, spec) is therefore bounded to
K identity classes: K-1 tagged plus the shared untagged one.

**Ordinal 0 is never tagged**, and that is not just cap bookkeeping. A
let-function with exactly ONE instance — the overwhelmingly common case — has
no ambiguity to resolve, so tagging it would mint fresh member ids and split
specs corpus-wide for nothing. Only the siblings a split actually created pay
for the split. It also makes the cap exact: `maxInstances = 1` tags nothing and
reproduces the flag-off collapse byte for byte, which is what test 4 pins.

(This was a REVIEW MISS, caught by the unit test: the first draft tagged every
ordinal, so `maxInstances = 1` still split a two-instance let — instance 0
tagged, instance 1 capped-and-untagged — and the cap did not mean what §3.3
claimed. The fix is strictly better on fan-out as well.)

### 3.4 The key string

Always present, so there is no with/without ambiguity:

```
l|<raw>|<inst>|<widenedKey>      (LSS_024 path, default)
l|<raw>|<inst>|<specId>          (LSS_017 path / LSS_024 fallback)
```

`<inst>` is a bare integer, `0` meaning "not inside any qualifying local-multi
instance". A bare integer followed by `|` then a rendering that always starts
with a letter code is unambiguous — the same discipline `layoutQualKey`'s
fallback note already relies on.

**Flag-off emits today's two-component string byte-for-byte**, so the flag-off
rail stays byte-identical and the two-binary comparison still applies in that
direction.

### 3.5 rootFold must not be instance-qualified

`lambdaMemberLayoutQualified` folds a def's ROOT lambda onto its global's
ground key (`g|<global>|<tail>`) so `{l|, g|}` head pairs collapse to
singletons. LSS_019 grounding produces that key **from a reference**, with no
instance component, so an instance-qualified root lambda would no longer match
and the collapse would break — a coverage regression, silently.

**Requirement: when `raw` is in `lssMemberTable.rootLamOf`, take today's key.**
Censused as `instanceQual.rootFoldSkip`.

### 3.6 The μ-tie must become instance-aware

`itemAux.demandQualified : Dict Int Int` maps **raw** → the smallest qualified
member id in the spec's stored demand, and both mint paths consult it by
`raw`. Left alone, a mint inside instance B finds instance A's id and ties to
it — reusing A's id and force-blocking the stamp, i.e. defeating the entire
change while *looking* like it worked.

Fix, minimal-diff: compose the tie key the same way the qualifier is composed.

- `lambdaQualified : Dict Int (Int, Int)` keeps its shape; its first component
  becomes `qualRaw = if inst == 0 then raw else mixHash raw inst`
  (the second is documented as diagnostics-only under LSS_024).
- `demandQualifiedFor` (Monomorphize.elm:4433) keys by that first component
  unchanged — it already just reads it.
- Both mint paths look up `qualRaw`, not `raw`.

LSS_024's `tieBypass` (compare `byKey key == tiedId`) is unchanged and still
does its job, now against the instance-qualified key.

### 3.7 Number-multi is explicitly OUT

`buildFloatDefs` shares `retranslateAt`, so the tag would ride along for free.
It must not. Int/Float instances differ in **layout**, so they already land in
different AbiCloning layout buckets and already stamp; qualifying them would
mint new member ids, split more specs, and buy nothing.

Consequence for the implementation: the tag is set at the `buildLocalDefs`
call site, **not** inside `retranslateAt`. (This reverses the convenient
shape; the convenience is what makes it wrong.)

---

## 4. Implementation

### 4.1 Config — a sub-record, not a flag

`LssConfig` holds **31** fields. The Record op verifier hard-errors above 32
(`runtime/src/codegen/EcoOps.cpp:455`), so one more bare `Bool` lands exactly
on the cap and the flag after it is a build break. Add a sub-record, as
`settle` and `stageAnchor` already do:

```elm
type alias LssInstanceQualConfig =
    { enabled : Bool          -- default False until §11's gate passes
    , maxInstances : Int      -- default 8; 0 = unlimited (do not ship 0)
    }
```

- `LssConfig.instanceQual : LssInstanceQualConfig` → 32 fields, at the cap.
- Decoder entry in `Compiler/Eco/Config.elm` (`optionalField "instanceQual"`).
- Env overrides in `Builder/Eco/Config.elm`: `ECO_MONO_LSS_INSTANCE_QUAL`,
  `ECO_MONO_LSS_INSTANCE_QUAL_MAX`, following
  `applyLssLayoutQualOverride`'s shape exactly.
- **Hash tokens `lssIQ=` / `lssIQM=`, non-default arm only**, muTie-style, so
  the default hash is stable across an eventual default flip. Env vars are not
  ninja inputs and the harness cache is env-blind: without the token, an A/B
  serves stale artifacts and both arms measure the same binary.

### 4.2 `Engine.ItemAux` — one field

```elm
, currentLocalInstance : Int   -- composed local-multi instance tag; 0 = none
```

11 → 12 fields, far from any cap.

- `emptyItemAux` (:1462): `currentLocalInstance = 0`.
- `clearedAux` (:1473): **not** cleared — `retranslateAt` sets it explicitly
  after the clear, and the composition needs the outer value from `s0`.
- `restoredAux` (:1481): **must be added to the restore-from-`outer` list.**
  The default is keep-from-`inner`, which would leak an inner instance's tag
  into the enclosing item. This is the single easiest thing to get wrong.

### 4.3 `Engine` — the mint

New helper, exposed for the unit pins:

```elm
mixTag : Int -> Int -> Int           -- local mixer (§3.2 — mixHash is not exposed)
instanceTag : Int -> Int -> Int      -- outer -> ordinal -> composed
qualifierTag : S -> Int -> Int       -- 0 when disabled / rootFolded / capped
```

`qualifierTag` returns 0 when any of: `not instanceQual.enabled`;
`itemAux.currentLocalInstance == 0`; `CoreDict.member raw rootLamOf` (§3.5).
The cap (§3.3) is applied where the tag is *minted* (§4.4), not here, so the
composed value stays a single int.

Then:

- `mintQualifiedLambda` — key becomes
  `"l|" ++ raw ++ "|" ++ tag ++ "|" ++ specId`; `lambdaQualified` records
  `( qualRaw, specId )`.
- `layoutQualKey` — takes the tag, emits
  `"l|" ++ raw ++ "|" ++ tag ++ "|" ++ wkey` (and the same in the SpecId
  fallback). The `rootFold` `String.dropLeft (length ("l|" ++ raw))` then
  carries `|<tag>|<wkey>` into the `g|` form automatically — which is exactly
  why §3.5 forbids reaching that branch with a non-zero tag rather than trying
  to make the two forms agree.
- Both `demandQualified` lookups key on `qualRaw`.
- Census counters on `lssStats`: `instanceQual = { applied, capped,
  rootFoldSkip }`.

**Flag-off / tag 0 must produce the OLD string, not `…|0|…`.** Two arms of one
`if`, not a uniform format. This is the byte-identity rail.

### 4.4 `Translate.buildLocalDefs` — set the tag

```elm
Engine.traverse
    (\( ord, inst ) ->
        Engine.map (\e -> Mono.MonoDef inst.freshName e)
            (retranslateAtInstance ord defBody inst.monoType)
    )
    (List.indexedMap Tuple.pair (Mono.specMapValues entry.instances))
```

`retranslateAtInstance ord` is today's `retranslateAt` with the tag resolved by
`Engine.localInstanceTagFor ord`: `mixTag outer ord` when
`instanceQual.enabled && ord >= 1 && ord < maxInstances`, else `outer`
unchanged (so ordinal 0 and an inner cap hit both keep the ENCLOSING tag rather
than clearing it). `buildFloatDefs` calls the unchanged `retranslateAt` (§3.7).

The bare-def arm (`specMapIsEmpty`) and the `Nothing` arm are untouched.

### 4.5 Files touched

| file | change |
|---|---|
| `Compiler/Eco/Config.elm` | `LssInstanceQualConfig`, field, decoder, hash tokens |
| `Builder/Eco/Config.elm` | two env overrides |
| `Compiler/MonoSolver/Engine.elm` | `ItemAux` field, `clearedAux`/`restoredAux`, `instanceTag`/`qualifierTag`, both mint paths, `layoutQualKey`, both μ-tie lookups, `lssStats` |
| `Compiler/MonoSolver/Monomorphize.elm` | `demandQualifiedFor` payload read; report line |
| `Compiler/MonoSolver/Translate.elm` | `buildLocalDefs`, `retranslateAtInstance` |
| `Compiler/GlobalOpt/AbiCloning.elm` | §2.1 census fields only |
| `Builder/Generate.elm` | render the census |
| `design_docs/invariants.csv` | amend LSS_017; new LSS row for the ordinal + cap |

No change to the subst engine: the LSS handshake is inert there.

---

## 5. Tests

**Unit, and they are the fast gate — seconds, not a self-compile.**

`compiler/tests/TestLogic/Monomorphize/LssInstanceQualTest.elm`:

1. `mRecordShape` (§1.1) flag-OFF → one `Dict_foldl` spec, `generic_apply`.
   Pins today's behaviour so the differential is real.
2. Same flag-ON → **two** specs, each callback stamped. The plan's entire
   claim, in one assertion.
3. Nested local-multi (§3.2): inner instances under two outer instances get
   four distinct member ids, not two.
4. Cap (§3.3): 9 instances with `maxInstances = 8` → the 9th takes today's key
   and bumps `capped`.
5. rootFold skip (§3.5): a def root lambda keeps its folded `g|` id flag-ON.
6. Key-string pins: `layoutQualKey` renders the old two-component string at
   tag 0 and the three-component string otherwise (`layoutQualKey` is already
   exposed pure for the §5.1 LSS_024 pins — reuse that door).

**Runtime differential** — `test/elm/src/LssInstanceQualTest.elm`, in the
`LssMixedSigHonestyTest` mould: two callbacks over one source lambda that
compute *different* values, so a representative hijack prints the wrong number
rather than merely being slower. A unit test cannot catch that class; only a
lowered, executed binary can.

**Per-mechanism arms** (§8.4 lesson): run `instanceQual` alone, never coupled
with a `layoutQualMembers` or `muTie` flip. Combined arms hide what
per-mechanism arms catch.

---

## 6. Gates

Byte-identity does **not** apply flag-on: member ids feed annotations feed
keyed spec keys feed fan-out. It applies flag-OFF, and that is the rail.

| gate | requirement |
|---|---|
| flag-OFF byte-identity | `.mlir` identical to HEAD (canonical diff — the `.mlir` is bytecode; `mlir-cat` round-trips) |
| unit | §5 1–6 green; `elm-tests` at the recorded baseline exactly (13,355 pass / 12 fail — if-chain + 11 POST_010/TYPE_007) |
| E2E | `--target full` at the recorded pass count, both arms |
| lowering | self-compile **lowers, exit 0, ZERO undefined-`_fast_evaluator` errors** — the LSS_031 class, and the one failure mode that blocks regardless of coverage |
| bootstrap fixed point | compiler-built-by-compiler reaches a fixed point; this replaces byte-identity as the correctness gate |
| runtime | `test/elm/src/LssInstanceQualTest.elm` prints the right numbers |

**A regression from a singleton to a multi-set is not a blocker** (LSS_027's
governing rule). A lowering failure is.

---

## 7. Measurement

Same-source arms only; same-day baselines drift. Delete
`bin/eco-compiler{,.mlir}` between arms — and note `--target full` deletes
`eco-boot.js`, so build `--target eco-boot` first if the JS gate is wanted.

| metric | how | expected |
|---|---|---|
| dispatch | `ECO_DISPATCH_STATS=1`, `sat`/`gen`/`fast` | `gen` down, `fast` up |
| wall | native self-compile, N≥3 | the number that decides |
| allocation | `ECO_INLINE_ALLOC=0` (honest counts) | flat-to-down |
| **spec count** | mono report | **the cost — watch it** |
| `.mlir` size + Stage-6 lowering time | file size; stage timing | the second cost |
| `instanceQual.{applied,capped,rootFoldSkip}` | mono report | `capped` small |
| `muTied` | mono report | not up — §3.6 working |

**Peak RSS is bimodal at identical allocation** (old-gen 8.9 vs 11.1 GB) and is
NOT a usable per-flag metric. Do not report it as a result.

---

## 8. Adversarial review

Conducted before lowering to §4; the corrections are already folded into the
body above. Recorded so the reasoning is not re-derived.

| # | objection | disposition |
|---|---|---|
| A1 | Type hash as discriminator reopens the members→keys spiral LSS_018 exists to close | **UPHELD, plan changed.** §3.1: ordinal, not type hash. This was the original sketch and it was wrong. |
| A2 | Even bounded, the ordinal can oscillate: a split mints a member, which splits, which adds an instance | **UPHELD, plan changed.** §3.3 hard cap K=8, censused. Bounded risk, not proven termination — stated as such. |
| A3 | The μ-tie silently defeats the change: instance B's mint ties to A's id and force-blocks | **UPHELD, plan changed.** §3.6. This would have looked like "implemented, no effect" and cost a build to diagnose. |
| A4 | Instance-qualifying a rootFolded root lambda breaks the `{l\|,g\|}` collapse against LSS_019's reference-side ground key | **UPHELD, plan changed.** §3.5 skip + census. |
| A5 | Number-multi rides along for free through the shared `retranslateAt` and buys nothing | **UPHELD, plan changed.** §3.7; tag set at the call site, not inside `retranslateAt`. |
| A6 | `restoredAux` keeps inner values by default — the tag leaks out of the scratch | **UPHELD.** Called out explicitly in §4.2 as the easiest error. |
| A7 | Key-string ambiguity: `l\|5\|A\|B` could parse two ways | **UPHELD.** §3.4: tag always present, bare integer, before the letter-initial rendering. |
| A8 | `LssConfig` is at 31 of 32 fields; a bare flag lands on the cap | **UPHELD.** §4.1 sub-record. |
| A9 | A stamp is not an inline: the site becomes a `fast` dispatch, not a removed one | **PARTLY UPHELD.** True, and §7 measures wall rather than declaring victory on the dispatch counter. Direct-call inlining is downstream work this unblocks, not something this plan delivers. |
| A10 | The win is asserted for `mRecord`; the other ~240 `Dict_foldl` specs may be genuine multi-member (bucket A), where this does nothing | **UPHELD — this is why §2 is P0 and §11 is a gate, not a formality.** |
| A11 | Spec fan-out is paid corpus-wide, the benefit only where the shape occurs | **UPHELD.** §7 tracks spec count, `.mlir` size and Stage-6 time as first-class costs, and §11 can fail on them. |
| A12 | The mint costs a concat and a lookup per lambda | **DISMISSED.** ~825 K slot mints/run; below the noise floor of every metric in §7. |
| A13 | E4a's overlay could regress and silently zero the payoff | **NOTED.** §1.2; the census reads USE sites. |
| A14 | Is the LSS_009 stamp actually sound afterwards? | **SOUND.** One instance per member by construction — strictly the premise LSS_009 asks for, and stronger than the fingerprint fence that replaced it. |
| A15 | A unit test cannot catch a representative hijack | **UPHELD.** §5's runtime differential exists for exactly that; the recorded precedent is `LssMixedSigHonestyTest` (a zero census over one corpus is not an absence proof). |

---

## 9. What this does not do

- **Bucket A** (genuinely several incoming lambdas) is untouched. That needs
  multi-set lowering (`plans/lss-sum-lowering.md`), not identity.
- **No inlining.** The callback becomes a direct call; folding it into
  `Dict.foldl`'s loop is separate, downstream work.
- **No compiler special-casing.** The mechanism is lambda-identity precision
  in the monomorphizer; it never names `Dict`, `Set`, or any compiler-internal
  module. It applies to any HOF receiving instances of a shared source lambda.

---

## 10. Ordering

| step | content | gate to proceed |
|---|---|---|
| **P0** | §2 census, both static and dynamic, reported | §11 |
| P1 | §4.1–4.2 config + `ItemAux`, no behaviour change | flag-off byte-identity |
| P2 | §4.3 mint + §3.6 μ-tie + §3.5 skip + §3.3 cap | §5 unit tests 1–6 |
| P3 | §4.4 `buildLocalDefs` wiring | §5 runtime differential |
| P4 | §6 full gates, §7 measurement | wall + spec count |
| P5 | default-flip decision | §7 table |

P1–P3 are one coherent change; splitting them is for bisecting a failure, not
for shipping increments.

---

## 11. The go/no-go

**Proceed to P1 only if the §2 census shows bucket-B callees carrying
materially more measured dispatch than `mRecord`'s 79.5 M alone.**

79.5 M is 21 % of the Dict/Set fold total and ~5 % of all remaining dispatch
after the IO-monad work. If bucket B *is* essentially just `mRecord`, the
honest move is to rewrite `mRecord` — two textually distinct lambdas instead of
one parameterised helper, which probe 1 shows already devirtualizes — and
close this plan unbuilt. Spec fan-out corpus-wide is not worth 5 % bought at
one call site.

**Abandon after P4 if** spec count or Stage-6 lowering time regresses more than
the dispatch win recovers in wall. The `maxSpecsPerGlobal = 0` default means
there is no backstop catching that for us.

---

## 12. What the census actually said (2026-09-05)

Self-compile with `eco-census` (HEAD + the §2 instrumentation), 7:59.95 wall,
`.mlir` 15,423,085 bytes.

### 12.1 The go/no-go table

```
lss globalopt: dispatchUpgraded=6567 stampedPapPrefix=3 stampedStaged=670
  declinedBlocked=6616 declinedNoInstance=16205
  declinedShape=12684 (arity=12378 [zero=0 under=0 over=12378]
                       bucketMiss=258 layout=46 char=2 nonArrow=0)
  declinedAbiMismatch=31 declinedBodyMismatch=78
  devirtPost(fn/ctor/noSpec)=70/319/0 multiInstanceGroups=3694
lss census instQual divergentGroups: 1758
```

| decline reason | sites | share of declines |
|---|---:|---:|
| noInstance | 16,205 | 45.5 % |
| **shape / arityOver** | **12,378** | **34.8 %** |
| blocked | 6,616 | 18.6 % |
| abiMismatch | 31 | 0.09 % |
| **bodyMismatch — THIS PLAN'S CLASS** | **78** | **0.22 %** |

### 12.2 The refutation, in one line

```
lss census instQual declines by host top60:
  Gelm core List foldrHelper|arityOver=7350
  Gelm core List foldl|arityOver=782
  Gelm core Dict foldl|arityOver=308        <-- mRecord's call site
  Gelm core Dict merge|arityOver=180
  Gelm core Dict foldr|arityOver=178
  Gelm core Dict map|arityOver=49

lss census instQual bodyMismatch by host top40:
  System.TypeCheck.IO andThen=20  Compiler.Parse.Primitives andThen=16
  elm/core List map=11  Generate.MLIR.Expr finishSpineCase=10
  elm/core Dict map=8   MonoSolver.Monomorphize settleVarCtorRows=3
  … a tail of 1s and 2s.
```

**`Dict.foldl` does not appear in the bodyMismatch list at all.** Its 308
declining sites are `arityOver` — the site applies more args than its own
callee type's first stage, which `AbiCloningStats` already documents as
"dispatch exists but needs staging-aware stamping — v2". That decline happens
BEFORE member identity is consulted, so no amount of id precision reaches it.

### 12.3 Where §1's reasoning went wrong

§1 inferred the decline reason from two facts — the probe emitted
`generic_apply`, and the two instances shared a member id — and concluded
`bodyMismatch`. Both facts are true; the conclusion did not follow. The shared
id is real (1,758 of 3,694 multi-instance groups are fingerprint-divergent) and
WOULD cost a stamp if the site got that far. It does not get that far.

**The general lesson, and it is the same one §2.3 already stated in the
abstract: a mechanism that is real is not thereby the mechanism that is
costing you.** The plan's own §11 gate was written to catch exactly this and
it worked — it just caught something worse than the failure mode it
anticipated. §11 imagined bucket B might be "only mRecord"; the truth is
mRecord was never in bucket B.

### 12.4 What was kept, and why

Shipped DEFAULT-OFF rather than reverted:

  - it closes a genuine identity gap cheaply, with a bounded, censused cap;
  - the flag-off path is byte-identical by construction (tag 0 reproduces the
    old key string exactly), so the dormant code costs nothing;
  - if `arityOver` is ever fixed, some of those 12,378 sites will arrive at
    the NEXT guard, and a share of them will land on `bodyMismatch`. The 78 is
    a floor, not a ceiling, conditional on that work;
  - `LSS_038` records the whole mechanism so it need not be re-derived.

### 12.5 The successor target

`arityOver` = 12,378 sites, 34.8 % of all declines, and it hosts EVERY hot
fold callback (`List.foldrHelper` 7,350 alone). That is where the dispatch is.
It is a staging/currying problem — the flowing value is a curried closure and
the site applies its args flat — not an analysis-precision problem, so it is
independent of the whole LSS identity arc.

Do not open that work on this plan's evidence alone: the same discipline
applies. Census the arityOver sites by DYNAMIC dispatch weight first, then
decide.

---

## 13. The successor census: `arityOver` by DYNAMIC weight (2026-09-05)

§12.5 said "census the arityOver sites by dynamic dispatch weight first, then
decide". Done, on the binary that produced §12's static tables — one run, so
the two halves cannot drift.

**Method.** `eco-census2` self-compiling `/work/compiler/src` under entry-only
uprobes on `eco_apply_closure_eval` and `eco_apply_segmentation_unknown`, with
`@gen[*(uint64*)reg("sp")] = count()` — the return address at function entry
names the CALLER, which for a fold callback is the host spec. 20:32.88 wall
probed (8:06 unprobed, so ~2.5x uprobe overhead), rc=0, 7,556 map rows,
symbolized offline against `nm -n` with the PIE load base read from
`/proc/<pid>/maps`.

### 13.1 The answer

**Total caller-attributed generic dispatch: 1,568,262,288.**
**Hosts whose static declines include `arityOver`: 521,098,747 = 33.2 %.**

| host | dispatches | % of all | static arityOver sites | dispatch/site |
|---|---:|---:|---:|---:|
| `Dict.foldl` | 312,899,274 | **19.95 %** | 308 | 1,016,000 |
| `Dict.foldr` | 108,447,545 | 6.92 % | 178 | 609,000 |
| `List.foldrHelper` | 69,736,287 | 4.45 % | 7,350 | 9,488 |
| `Dict.map` | 22,714,722 | 1.45 % | 49 | 463,000 |
| `List.foldl` | 7,300,919 | 0.47 % | 782 | 9,336 |
| **total** | **521,098,747** | **33.2 %** | 8,667 | |

### 13.2 Site count is inversely related to weight here

`List.foldrHelper` holds **7,350 of the 12,378 arityOver sites (59 %)** and
carries **4.45 %** of the dispatch. `Dict.foldl` holds **308 sites (2.5 %)**
and carries **19.95 %**. That is **107x more dispatch per site**, in opposite
rank order — the sharpest instance yet of the recorded trap that a static
census collapses at the admissibility gate and only dynamic heat ranks
correctly. A plan sized off the static table would have optimised
`foldrHelper` first and captured a seventh of the available mass.

### 13.3 It is concentrated enough to attack directly

```
Dict_foldl:        312,899,274 over 181 live specs
   Dict_foldl_$_32636   100,284,646   32.1 % of the family — 6.39 % OF THE WHOLE COMPILER
   Dict_foldl_$_22408    27,718,858    8.9 %
   Dict_foldl_$_32691    23,766,561    7.6 %
Dict_foldr:        108,447,545 over  80 live specs   (top two = 65 %)
List_foldrHelper:   69,736,287 over 421 live specs   (top = 20 %, diffuse)
```

**`Dict_foldl_$_32636` is a single specialization carrying 6.39 % of every
generic dispatch in the compiler** — the largest single dispatch site in the
program.

### 13.4 Other things the run settled

  - **The IO monad is still #2 and #3**: `IO.andThen` 283,339,275 (18.07 %) and
    `IO.map` 150,316,396 (9.58 %) — **27.6 % together**, AFTER P0/P1/P3 cut it
    43 %. Neither declines on `arityOver` (their static reasons are `blocked`
    and `bodyMismatch`), so they are a separate track.
  - **`eco_apply_closure_eval` attributes 91,258,832 (5.82 %) to ITSELF** —
    return addresses inside the funnel are the over-saturation staging loop
    ("an over-saturated apply records one `gen` per stage"). An independent
    measure of over-application cost, and it is not small.
  - `_ZL8foldImplN3Elm4HPtrES0_S0_b` (the C++ kernel Dict fold) 54,558,560
    (3.48 %) — kernel-side, outside the Elm stamping story.
  - `seg` was **0**: nothing routes through `eco_apply_segmentation_unknown` on
    this workload, so the whole generic population is the `closure_eval` funnel.

### 13.5 What the fix would be, and what it is worth

The guard is `resolveStagedFirstStage` (AbiCloning): when a site applies more
args than its callee type's FIRST STAGE, v2 stamping already tries to stamp
batch 1 and apply the remainder generically. It succeeds 670 times
(`stampedStaged`) and misses 12,378. So the mechanism EXISTS and
under-performs — this is not greenfield work.

Wall arithmetic, with its assumption stated: at the 47.7 ns/dispatch figure
from the IO-monad arc, 521 M dispatches is **24.9 s of a 486 s compile
(5.1 %)**, and `Dict.foldl` + `Dict.foldr` alone is 20.1 s (4.1 %). **That is
an upper bound and will not be realised**: a stamped dispatch becomes a direct
or fast call, not a free one, so expect a fraction of it. It is still an order
of magnitude more than §12's 78 sites.

### 13.6 Before opening it

The census says WHERE, not WHY. The open question is producer-side: why is the
callee's type first-stage shorter than the flat call's arg count, when
`Dict.foldl`'s `func key value acc` should saturate a 3-param callback? That is
mono-uncurry / staged-currying territory (`plans/mono-uncurry-implementation.md`,
`plans/global-staged-currying-soundness.md`), and it is the thing to diagnose
on `Dict_foldl_$_32636` specifically — one spec, 100 M dispatches — before any
design work. Do not re-run the §1 mistake of inferring a mechanism from a
symptom.

---

## 14. Diagnosis of `Dict_foldl_$_32636` — why the first stage is short (2026-09-06)

§13.6 said the open question is producer-side and must be diagnosed on the one
spec carrying 100 M dispatches before any design work. Done. **The first stage
is not "short" by accident or by a lost optimisation: every arrow type is
curried by construction, one parameter per stage, while the closure and the
call site are both flat.**

### 14.1 The evidence chain

**(1) The producer.** `Compiler/MonoSolver/Store.elm:3607`, `classifyGo`:

```elm
Can.TLambda _ from to ->
    ...
    -- One arrow per MFunction, mirroring zonkFlat's Fun1 arm
    -- (GlobalOpt flattens later per GOPT_016).
    Ok (Engine.consS (Mono.mFunction (Mono.topOfKind topKind) [ mFrom ] mTo) s2)
```

`[ mFrom ]` — a ONE-element param list, per `Can.TLambda`. So `Dict.foldl`'s
`func : k -> v -> b -> b` classifies as

```
MFunction _ [k] (MFunction _ [v] (MFunction _ [b] b))
```

**first stage = 1 parameter, for every arrow type in the program.**

**(2) The guard.** `AbiCloning.resolveRepresentative` reads the callee
EXPRESSION's type and compares against the flat arg count:

```elm
case calleeType of
    Mono.MFunction _ _ fargs fret ->
        ...
        else if argCount > List.length fargs then   -- 3 > 1
            resolveStagedFirstStage fargs fret memberInfo   -- misses -> "arityOver"
```

**(3) The call site**, emitted MLIR inside `@Dict_foldl_$_32636`:

```mlir
%9 = "eco.papExtend"(%arg3, %4, %5, %8)
       <{_result_kind = 1 : i8, newargs_unboxed_bitmap = 16 : i64}>
       {_call_kind = "generic_apply"} : (!eco.value, !eco.value, !eco.value, i64) -> i64
```

Three arguments, flat, in one op. `argCount = 3`, `List.length fargs = 1`.

**(4) The closures are FINE**, in `@Compiler_AST_Monomorphized_mRecord_$_32623`:

```mlir
%2 = "eco.papCreate"() <{arity = 3, function = @Terminal_Main_lambda_27312, num_captured = 0}>
%3 = "eco.call"(%2, %1, %arg0) <{callee = @Dict_foldl_$_32636}>
%4 = "eco.papCreate"() <{arity = 3, function = @Terminal_Main_lambda_27314, num_captured = 0}>
%5 = "eco.call"(%4, %1, %arg0) <{callee = @Dict_foldl_$_32636}>
```

Both callbacks are **arity 3, zero captures, two distinct functions**. The
value is uncurried and flat; only the TYPE is curried.

So: the callback's VALUE is flat-3, the call is flat-3, and the callback's TYPE
says stage 1 has one parameter. The guard compares (3) against (1) and
declines. No stamp is possible because `resolveStagedFirstStage` can only match
an instance whose first stage is one parameter, and the instance's `paramTypes`
is `[k, v, b]`.

### 14.2 The rule this predicts, and it holds

If the cause is "curried type vs flat call", then **exactly the HOFs whose
callback takes ≥ 2 arguments decline `arityOver`**, and callback-arity-1 HOFs
never do (1 == 1 is the exact branch). Checked against the census:

| HOF | callback | in `arityOver`? |
|---|---|---|
| `elm/core List.map` `(a -> b)` | 1 | **no** |
| `elm/core List.any` `(a -> Bool)` | 1 | **no** |
| `elm/core List.filter` `(a -> Bool)` | 1 | **no** |
| `elm/core Maybe.map` `(a -> b)` | 1 | **no** |
| `elm/core List.foldl` `(a -> b -> b)` | 2 | **yes** (782) |
| `elm/core Dict.map` `(k -> v -> b)` | 2 | **yes** (49) |
| `elm/core List.foldrHelper` `(a -> b -> b)` | 2 | **yes** (7,350) |
| `elm/core Dict.foldl` `(k -> v -> b -> b)` | 3 | **yes** (308) |
| `elm/core Dict.foldr` | 3 | **yes** (178) |
| `elm/core Dict.merge` | 3 | **yes** (180) |

A clean split at callback arity 1 vs ≥ 2, with no exceptions in the table.
**This is why the fold family dominates the census: folds are the multi-argument
callback HOFs, and they are also the hot ones.**

### 14.3 It independently re-kills §1's plan

The two callbacks at this site already carry **distinct lambdaIds (27312 /
27314) and zero captures**. Even with perfect member-id precision — even with
`Dict_foldl` split into two specs each holding a genuine singleton — the site
would STILL decline, because the arity guard fires before the member index is
consulted. Instance qualification could never have reached this site. §12's
verdict is confirmed a second way, from the emitted code rather than from the
decline counters.

### 14.4 What the fix would be

`resolveStagedFirstStage` is the right place and already exists; it is looking
at the wrong thing. Two candidates:

  - **(A) Peel the curried type at the guard.** When the callee type is a
    curried chain and the site applies `n` args flat, accumulate stages until
    the parameter count reaches `n`, and compare THAT list against the
    instance's `paramTypes`. `[k] -> [v] -> [b]` accumulates to `[k, v, b]`,
    which matches the arity-3 instance exactly, and the existing
    `eqLayoutLists` + capture-unanimity + fingerprint machinery then applies
    unchanged. This is a COMPARISON fix, local to AbiCloning, changing no
    representation. Must land exactly (fail if the accumulation overshoots `n`),
    and must still handle producers that already emit multi-param `MFunction`s
    (`zonkFlat`, GlobalOpt flattening) — so peel-until-equal, not peel-`n`-times.
  - **(B) Make `classifyGo` build flat `MFunction`s.** A representation change
    with a wide blast radius — LSS_006 arrow ordinals count POSITIONS over a
    signature's arrow structure, so collapsing stages moves every ordinal. Not
    the first attempt.

**(A) is the one to try**, and the gate is cheap: this one spec, and whether
`stampedStaged` (670 today) and `declinedShapeArityOver` (12,378 today) move in
opposite directions by roughly the same amount.

**Unverified residual:** I derived `List.length fargs = 1` from `classifyGo`
being the only producer of this type rather than measuring it. The guard only
proves it is 1 or 2. A `(firstStageArity -> argCount)` histogram on the
`arityOver` path would settle it and cost one rebuild; worth doing as step 0 of
the fix, since (A) is sized by exactly that distribution.

---

## 15. The fixes: A (implement) and B (fallback)

### 15.0 The finding that reorders everything

`Dict.foldl` has EXACTLY ONE decline reason corpus-wide — `arityOver=308`, no
other — and the whole self-compile holds only **16** multi-member-set sites
(`multiSetSites 2->11 3->2 4->1 9->2`). So the callback parameter at every
`Dict_foldl` spec, including `_$_32636`, carries a **singleton** `LSet [m]`.

But §14.1 showed TWO distinct closures reaching that one spec —
`Terminal_Main_lambda_27312` and `_27314`. A singleton member indexing two
different bodies is precisely §1's false singleton, and §12 measured its class
at 1,758 fingerprint-divergent groups.

**Therefore, at the hottest site in the compiler, the two defects are stacked:**

```
argCount 3 > |fargs| 1        -> Decline "arityOver"        <- fires FIRST, today
   [if Fix A lands]
group found, 2 instances, fingerprints differ
   -> fpUnanimous = False     -> Decline "bodyMismatch"     <- the NEXT guard
   [if lss.instanceQual is ALSO on]
two members, one instance each, unanimous
   -> Stamp                                                  <- the win
```

**Fix A alone moves `Dict_foldl_$_32636` from `arityOver` to `bodyMismatch`,
not to a stamp.** It needs `lss.instanceQual` on to convert.

This is the concrete realisation of §12.4's conditional: *"if `arityOver` is
ever fixed, some of those 12,378 sites will arrive at the NEXT guard, and a
share of them will land on `bodyMismatch`. The 78 is a floor, not a ceiling."*
The floor is now measurable, and the 100 M-dispatch site is sitting on it.

**Consequence for the work plan: A must be measured in TWO arms —
`instanceQual` off and on — or its headline number will read far worse than it
is, and the wrong conclusion ("A does not pay") will be drawn.**

### 15.1 Fix A — peel the curried callee type at the guard (IMPLEMENT)

**The idea.** The bug is a category error: `resolveRepresentative` compares a
**representation-agnostic type** (a curried arrow chain, which says nothing
about how many args a closure takes at once) against a
**representation-specific call** (a flat n-arg application). The instance index
is the only thing that knows the representation — it holds the closure's real
`paramTypes`. So compare against THAT.

**The change**, in `AbiCloning.resolveRepresentative`'s over-applying branch:
peel the callee type's stages until the accumulated parameter count equals the
site's `argCount`, then run the ordinary exact-path group match against the
accumulated list. `[k] -> [v] -> [b] -> b` accumulates to `[k,v,b] -> b`, which
matches the arity-3 instance exactly, and every existing gate —
`eqLayoutLists`, `charFree`, `unanimous`, `fpUnanimous` — then applies
unchanged.

**Why it is sound.** Identical premises to the exact path, plus one:

  1. singleton `LSet [m]` and `m` is in the instance index (already required to
     reach `resolveRepresentative` at all);
  2. the group's `paramCount == argCount` and its param/return layouts equal
     the peeled view — so the flowing value is an n-param closure and the
     n-arg call **saturates its own stage**, meeting CGEN_052's
     `remaining_arity` truthfulness obligation exactly as the exact path does;
  3. the intermediate `MFunction` nodes the peel discards never materialise at
     runtime — the call never dispatches through them. Dropping their
     annotations is the same trade `MonoInlineSimplify.flattenArrowOnce`
     already documents ("annotation soundness over precision"), and here it is
     not even a widening: nothing reads them.

**Why NO emission change is needed** — the load-bearing detail:
`Expr.fastDispatchStamp` gates on `List.length args == List.length
abi.paramTypes`, comparing the ARG COUNT against the STAMPED INSTANCE's param
list. **It never consults the callee's curried type.** So a stamp carrying
`captureAbi.paramTypes = [k,v,b]` at a 3-arg site takes
`generateFastDispatchCall` and emits `singleton_fast`. And `generateCall`'s
`Mono.CallGenericApply` arm — which is exactly this site's kind — consults
`fastDispatchStamp` FIRST, before falling through to
`generateGenericApplyCoerced`. The whole downstream is already shaped for this.

**Result:** a plain `Stamp`, not `StampStaged`. The site stops being a staged
call at all; it becomes an ordinary saturating fast dispatch.

### 15.2 Fix B — flatten `classifyGo` (FALLBACK, and probably WRONG)

**The idea.** Change `Store.classifyGo`'s `Can.TLambda` arm to collect the whole
arrow spine — `TLambda a (TLambda b (TLambda c d))` -> `mFunction anno [a,b,c] d`
— so the type agrees with the flat call by construction and the guard needs no
change.

**Why it is kept as a fallback and not the plan:**

  - **It asserts a representation the type cannot know.** An arrow type is
    inhabited by BOTH a flat n-param closure and a curried chain, and by PAPs
    (`resolvePapSuffix` exists precisely because partially-applied values flow
    through these positions). `classifyGo` classifies an ANNOTATION, before any
    closure has flowed there, so it cannot know which. Flattening maximally
    makes the type lie whenever a genuinely staged value arrives — trading a
    missed stamp for a wrong one.
  - **LSS_006 blast radius.** Arrow ordinals are POSITIONS over a signature's
    arrow structure, and `applyFacts` poisons on ordinal-count mismatch.
    Collapsing three `MFunction` nodes into one moves every ordinal in every
    signature that mentions a multi-arg arrow.
  - **Total artifact churn.** `toComparableMonoType` renders the type, so every
    spec key changes; `loadTypeC` mints one arrow SLOT per `Can.TLambda` and
    would disagree with `classifyGo` unless changed in lockstep; GOPT_016's
    `callKind` classification reads staging off the type.
  - It would, however, also attack the 26,037 `segmentation_unknown` sites,
    which A does not touch. That is the only reason to keep it on the shelf.

**If A fails**, B is not the next step either — the next step is to ask why A's
peel missed, which the §17.4 census answers directly.

---

## 16. Adversarial review of A and B

Corrections are folded into §15 and §17 above/below; recorded so the reasoning
is not re-derived.

| # | objection | disposition |
|---|---|---|
| B1 | A stamps a flat n-arg call against a type that says the value is curried — if the runtime value really IS a curried chain, this miscompiles | **ANSWERED, and it is the crux.** The stamp is licensed by the INSTANCE (`paramCount == argCount` with matching layouts), never by the type. A curried chain is a DIFFERENT instance with `paramCount == 1`, whose layout fails the match, so the peel misses and we fall back. The type is not evidence either way — that is the bug being fixed. |
| B2 | A PAP of a bigger closure could match the flattened layout and be stamped as a saturating call | **UPHELD, guard required.** `resolvePapSuffix` exists because PAPs flow here. The flattened path must require `g.paramCount == argCount` EXACTLY (never a suffix match) and must not fall through to `papScan` — §17.2 states this, and §17.3 pins it. |
| B3 | A changes what the census means: sites move out of `arityOver` into other buckets, so the counter cannot be read as before | **UPHELD, plan changed.** §17.2: a flattened MISS falls back to `resolveStagedFirstStage`, preserving today's decline attribution exactly. Only genuine matches leave the bucket, and they leave it for `stampedFlattened` or for the gate that actually rejected them. |
| B4 | **A alone will not stamp the 100 M site** — it lands on `bodyMismatch` | **UPHELD, and it reorders the whole plan.** §15.0. Two-arm measurement is now mandatory; a one-arm result would read as "A does not pay". |
| B5 | The peel could overshoot (a stage with k>1 params jumps past `argCount`) and silently take a wrong list | **UPHELD.** §17.1: accumulate and compare each step; `>` fails closed to `Nothing`. Peel-until-EQUAL, never peel-n-times. |
| B6 | Multi-param `MFunction`s already exist (`zonkFlat`, GlobalOpt flattening, `flattenArrowOnce`), so "one param per stage" is not universal | **CORRECT, and A handles it by construction** — the peel accumulates `List.length params`, not 1, per stage. It is also why B5's overshoot check is not theoretical. |
| B7 | The peeled return type may not be the site's actual result type | **NOTED, no change.** The exact path already fingerprints on the CALLEE TYPE's return, not the call's `resultType`; the peel keeps that invariant by using the innermost `to`. Deviating would change the exact path's semantics too. |
| B8 | §14's claim `List.length fargs = 1` is derived from `classifyGo`, not measured; the guard only proves 1 or 2 | **UPHELD, unchanged from §14.4.** §17.4 makes the `(firstStageArity, argCount)` histogram step 0, because A's payoff is sized by exactly that distribution and a peel that must cross two stages is no harder than one. |
| B9 | A is a comparison change, so it cannot regress flag-off byte-identity — no flag needed | **REJECTED, flag required.** A changes which sites get stamped, hence CallInfo, hence emitted MLIR. It is artifact-affecting and needs the same flag + hash-token discipline as every other arm in this arc (`lssFP=`). |
| B10 | Char captures: batch-1 args load through the capture path, so the `charFree` gate matters | **ALREADY HANDLED** — the flattened path routes into the ordinary group gates, which include `charFree`. Listed so the reviewer does not "simplify" it away. |
| B11 | `resolveInGroups` falls through to `resolvePapSuffix`, which would fire on a flattened miss and mis-attribute the decline | **UPHELD** — this is B2 and B3's shared mechanism. §17.2 uses a dedicated scan, NOT `resolveInGroups`, precisely to avoid inheriting that fallthrough. |
| B12 | B (flatten `classifyGo`) is the "root cause" fix and A is a workaround | **REJECTED, and the reasoning inverts.** The type is representation-agnostic by design; the instance is the only representation authority. A compares against the authority. B would make the type assert something it cannot know. A is the conceptually correct fix; B is the expedient one. |
| B13 | Cost: a peel per over-applying site | **DISMISSED.** Bounded by arrow depth (≤ ~5), runs only on the over-applying branch, allocation-free apart from one small list. |

---

## 17. Fix A, lowered to implementation

All changes are in `compiler/src/Compiler/GlobalOpt/AbiCloning.elm` unless
stated. **No emission change** (§15.1), **no representation change**.

### 17.1 The peel

Pure, total, allocation-light, exposed for the unit pins.

```elm
{-| Accumulate the callee type's stages until the parameter count reaches
`want`, returning the flattened parameter list and the stage's return type.

`Nothing` when the type runs out of arrow before reaching `want`, or when a
stage OVERSHOOTS it — peel-until-EQUAL, never peel-n-times. Overshoot is real:
`zonkFlat` and GlobalOpt flattening both emit multi-parameter `MFunction`s, so
a stage may carry more than one parameter (review B5/B6).

Intermediate stages' lambda-set annotations are dropped. They never
materialise at runtime — the flat call never dispatches through them — which
is the same trade `MonoInlineSimplify.flattenArrowOnce` documents.
-}
peelStages : Int -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelStages want ty =
    peelGo want 0 [] ty


peelGo : Int -> Int -> List (List Mono.MonoType) -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelGo want have acc ty =
    case ty of
        Mono.MFunction _ _ params ret ->
            let
                have1 =
                    have + List.length params

                acc1 =
                    params :: acc
            in
            if have1 == want then
                Just ( List.concat (List.reverse acc1), ret )

            else if have1 > want then
                Nothing

            else
                peelGo want have1 acc1 ret

        _ ->
            Nothing
```

### 17.2 The guard

Replace the over-applying branch of `resolveRepresentative`:

```elm
                else if argCount > List.length fargs then
                    -- Fix A: the site applies its args FLAT while the callee
                    -- TYPE is curried (Store.classifyGo emits one parameter
                    -- per MFunction stage — §14.1). The type is
                    -- representation-agnostic and cannot license a stamp; the
                    -- INSTANCE is the representation authority. Peel the type
                    -- to the site's own arg count and match the instance
                    -- against THAT.
                    case flattenedResolution argCount calleeType memberInfo of
                        Just resolution ->
                            resolution

                        Nothing ->
                            -- Unchanged fallback, so the decline census keeps
                            -- today's attribution exactly (review B3).
                            resolveStagedFirstStage fargs fret memberInfo
```

```elm
{-| Fix A: the flattened-view match for an over-applying site.

`Just` only when the peel lands EXACTLY on `argCount` and a layout group
carries that full parameter list; the gates are then the exact path's, in the
exact path's order. A dedicated scan rather than `resolveInGroups`, because
that function falls through to `resolvePapSuffix` — a PAP suffix must NEVER
satisfy a flattened match (review B2/B11): the whole licence is that the
flowing value is an n-parameter closure the n-arg call SATURATES.
-}
flattenedResolution : Int -> Mono.MonoType -> MemberInfo -> Maybe Resolution
flattenedResolution argCount calleeType memberInfo =
    case peelStages argCount calleeType of
        Nothing ->
            Nothing

        Just ( flatArgs, flatRet ) ->
            case Dict.get (siteFingerprint flatArgs flatRet) memberInfo.buckets of
                Nothing ->
                    Nothing

                Just groups ->
                    flattenedScan argCount flatArgs flatRet groups


flattenedScan : Int -> List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Maybe Resolution
flattenedScan argCount flatArgs flatRet groups =
    case groups of
        [] ->
            Nothing

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes flatArgs && Mono.eqLayout g.rep.returnType flatRet then
                Just
                    (if not g.charFree then
                        Decline "char" bumpShapeChar

                     else if not g.unanimous then
                        Decline "abiMismatch" bumpAbiMismatch

                     else if g.fpUnanimous then
                        Stamp g.rep

                     else
                        -- The §15.0 stack: A gets past the arity guard and
                        -- the site lands HERE unless lss.instanceQual is on.
                        Decline "bodyMismatch" bumpBodyMismatch
                    )

            else
                flattenedScan argCount flatArgs flatRet rest
```

`Stamp g.rep` — not `StampStaged`. `Expr.fastDispatchStamp` sees
`List.length args == List.length abi.paramTypes` and emits `singleton_fast`
(§15.1); `generateStagedFastDispatchCall` is never reached.

### 17.3 Flag, census, invariant

  - **Config**: `lss.flatPeel : Bool`, default `False`, inside the existing
    `LssInstanceQualConfig` sub-record (renamed `LssStampConfig`) — `LssConfig`
    is AT the 32-field cap, so no new top-level field. Env
    `ECO_MONO_LSS_FLAT_PEEL`, hash token `lssFP=` on the non-default arm
    (review B9: A is artifact-affecting; env vars are not ninja inputs and the
    harness cache is env-blind).
  - **Census**, on `AbiCloningStats.instQual`: `flatStamped`, `flatPeelMiss`
    (peel failed or overshot), `flatBucketMiss`, `flatBodyMismatch`. The last
    is the §15.0 number and the direct measure of what `instanceQual` would
    then convert.
  - **Invariant**: new `LSS_039` recording the licence — *an over-applying site
    may be stamped as saturating when the peel lands exactly on `argCount` and
    the group's `paramCount == argCount` with matching layouts; the instance,
    never the type, is the representation authority; a PAP suffix never
    qualifies.* Amend `LSS_014` (E2.7 staged stamping) to say the flattened
    path is tried first and `StampStaged` is now the fallback.

### 17.4 Step 0, before writing any of the above

One rebuild, report-only, to size the work (review B8):

  - `arityOverShape : Dict String Int` keyed
    `"<firstStageArity>-><argCount>"` — settles whether `fargs` is 1 (as §14.1
    derives from `classifyGo`) or sometimes 2, and how many stages the peel
    must cross;
  - the same key with the host global, and **the SpecId**, so
    `Dict_foldl_$_32636` can be confirmed as an `arityOver` decliner directly
    rather than by elimination (§15.0 infers it from "Dict.foldl has exactly one
    decline reason"; that is strong but it is an inference).

If the histogram shows most sites needing a multi-stage peel with a clean
landing, A's ceiling is the full 12,378. If many overshoot or run out of arrow,
A is smaller than §13 suggests and that is worth knowing before the build.

### 17.5 Tests

`compiler/tests/TestLogic/Monomorphize/AbiCloningFlatPeelTest.elm` — unit,
seconds, the fast gate:

  1. `peelStages 3 (curried k->v->b->b)` = `Just ([k,v,b], b)`.
  2. `peelStages 2` on the same = `Just ([k,v], b->b)` — partial peels land.
  3. Overshoot: a 2-param first stage with `want = 1` -> `Nothing` (B5).
  4. Runs out of arrow: `peelStages 3 (k -> v -> Int)` -> `Nothing`.
  5. Already-flat input: `peelStages 3 (MFunction [k,v,b] b)` = `Just ([k,v,b], b)`
     — the B6 case, one stage, no peeling.
  6. **DIFFERENTIAL, the plan's claim**: the §14 fold shape flag-off emits
     `generic_apply`; flag-on emits a stamp. Reuse
     `LssInstanceQualTest.foldShapeModule`, asserting on `CallInfo.fastEvaluator`.
  7. **PAP NEVER QUALIFIES** (B2): a member whose only instance has
     `paramCount = 4` at a 3-arg site must NOT stamp, even though a
     1-dropped suffix would match.
  8. **Census honesty** (B3): a flattened miss still increments
     `declinedShapeArityOver`, unchanged.

Runtime differential: extend `test/elm/src/LssInstanceQualTest.elm` — it
already routes two behaviourally different callbacks through one shared
`Dict.foldl`-shaped site, which is exactly the §15.0 stack. Its CHECK lines
must hold in all FOUR arms (flatPeel x instanceQual).

**GAP, recorded rather than glossed (state at the 2026-09-06 build):** pins 1-5
of this list plus three more shipped as
`compiler/tests/TestLogic/Monomorphize/AbiCloningFlatPeelTest.elm` (8 tests,
green) and they cover `peelStages` exhaustively — exact landing, partial
landing, OVERSHOOT, running out of arrow, already-flat input, a mixed
2-then-1 chain, zero, and non-arrow. **Pins 6 and 7 were NOT written.** The
pipeline differential needs a `TestPipeline` entry point that threads an
`LssConfig` into `globalOptimizeWithStats` (today's hardcodes
`{ defaultLss | enabled = True }`), and the PAP pin needs `MemberInfo` /
`LayoutGroup` exported or a hand-built graph in the `AbiCloningFenceTest`
mould.

That leaves **the PAP guard (review B2) enforced only structurally** —
`g.paramCount == argCount` is an exact equality and `flattenedScan` never
reaches `papScan` — with no independent test. It is the one soundness property
of Fix A that is not pinned, and the corpus arms cannot substitute for it: a
wrong PAP stamp is a MISCOMPILE, which a dispatch counter reads as a win. Write
pin 7 before any default flip.

### 17.6 Measurement — two arms, mandatory

Per §15.0, A must be measured with `instanceQual` off AND on, or the headline
misreads:

| arm | `flatPeel` | `instanceQual` | what it shows |
|---|---|---|---|
| 1 | off | off | baseline (today) |
| 2 | **on** | off | A alone — expect `arityOver` down, **`bodyMismatch` UP** |
| 3 | on | **on** | the real number — both guards cleared |
| 4 | off | on | already measured (§12): +12 stamps |

Headline metrics: `dispatchUpgraded`, `declinedShapeArityOver`,
`declinedBodyMismatch`, `singleton_fast` vs `generic_apply` static counts, and
the caller-attributed dynamic census re-run on arm 3 to confirm the
521 M/33.2 % actually converts. Wall on N>=3 same-source runs; peak RSS is
bimodal and is NOT a per-flag metric.

Gates: flag-off byte-identity; `elm-tests` at the 12-failure baseline; E2E
`--target full`; self-compile LOWERS with **zero undefined-`_fast_evaluator`
errors** (the LSS_031 class — the one failure that blocks regardless of
coverage); bootstrap fixed point.

---

## 18. Fix A: BUILT AND MEASURED (2026-09-06)

**Dispatch −28.1 %, wall −7.1 %, output byte-identical.** All gates green.

### 18.1 Step 0 settled §14 by measurement, not derivation

The `overApply shape` histogram (`<firstStage>-><argCount>|<peel>|<reason>`),
flag-off, whole self-compile:

```
1->2|exact 9,815(arityOver) 1,303(blocked) 29(bodyMismatch)
1->3|exact 1,573 + 20      1->4|exact 512    1->5|exact 220 + 1
1->6|exact 125   1->7|exact 88   1->10|exact 22   1->9|exact 12
1->8|exact 8     1->12|exact 4   1->13|exact 3
```

**Every over-applying site in the compiler has `firstStage = 1`** — there is not
one `2->N` entry — confirming §14.1's derivation from `classifyGo`'s "one arrow
per MFunction". **And every site peels `exact`: zero misses, zero overshoots.**
Review B8's residual is closed, and it explains why the conversion below is
near-total. (The B5 overshoot guard therefore never fires on this corpus. It
stays: `zonkFlat` and `flattenArrowOnce` can produce multi-param stages, and a
guard that is unexercised here is not a guard that is unnecessary.)

### 18.2 Static effect

| metric | arm1 base | arm2 `flatPeel` | arm3 `+instanceQual` |
|---|---:|---:|---:|
| `declinedShape` **arityOver** | 12,382 | **379 (−96.9 %)** | 379 |
| `dispatchUpgraded` | 6,571 | **17,122 (+160 %)** | 17,142 |
| `flatStamped` | 0 | 10,551 | 10,567 |
| `declinedBodyMismatch` | 78 | **1,204** | 1,194 |
| `declinedAbiMismatch` | 31 | 357 | 354 |
| `.mlir` | 15,435,238 | +30,889 (+0.20 %) | +36,632 (+0.24 %) |

### 18.3 The payoff — each arm's OUTPUT lowered and run on identical input

The §18.2 arms measure the compiler DOING the stamping; they say nothing about
the stamps, and their wall was flat (8:09.7 / 8:09.4 / 8:13.2) because all
three do the same work. The payoff needs each arm's `.mlir` lowered to a
compiler and THAT run:

| arm | wall | dispatch (`sat`) | vs base |
|---|---|---:|---|
| arm1 base | 7:46.70 | 1,495,307,332 | — |
| **arm2 `flatPeel`** | **7:22.53** | **1,156,416,981** | **dispatch −22.66 %, wall −5.18 %** |
| **arm3 `+instanceQual`** | **7:13.67** | **1,074,741,050** | **dispatch −28.13 %, wall −7.08 %** |

`gen` fell by 338,890,356 against `sat`'s 338,890,351 — the removed dispatch is
**entirely generic**, and `typed` is unchanged to within 5 counts
(40,310,261 / …266 / …261), so this converts generic dispatch to direct calls
rather than shuffling it between classes.

### 18.4 The site-count trap, a third time

**`instanceQual` moved only 10 sites (`bodyMismatch` 1,204 → 1,194) and removed
81,675,931 dispatches — 7.1 % of what remained, worth 2.0 % of wall.**

On seeing the static table I wrote that `instanceQual` "barely dents it". That
was wrong, and wrong in the way this whole arc keeps being wrong: **10 sites at
8.2 M dispatches each**. The §15.0 stacking claim is vindicated on WEIGHT even
though the site-count reasoning behind it was off. The flag §12 shipped
default-off as negligible is now worth 2 % of self-compile wall — but only once
Fix A has cleared the guard in front of it.

### 18.5 Gates

| gate | result |
|---|---|
| flag-off byte-identity (same SOURCE, two binaries) | **IDENTICAL** — `eco-iq` flag-off vs arm1 |
| all three arms lower | rc=0, no undefined `_fast_evaluator` |
| **semantic equivalence** | the three lowered compilers emit **byte-identical** output, equal to the flag-off reference |
| `elm-tests` | 13,442 pass / 12 fail = the exact pre-existing baseline |
| unit pins | `AbiCloningFlatPeelTest` 8/8 (peel) + `AbiCloningFlatPeelPassTest` 4/4 (pass level) |
| **E2E `--target full`, both flags DEFAULT-ON** | **1719 / 1719 PASSED** |

**§17.5's recorded gap is CLOSED.** `AbiCloningFlatPeelPassTest` supplies the
two pins that were missing: the flag differential (declines off, stamps on) and
**the PAP-never-qualifies soundness property** — a 4-parameter instance is not
stamped at a 3-argument site, even though a 1-dropped suffix would match. A
third pin fixes the §15.0 interaction in place: Fix A must land divergent-body
sites on `bodyMismatch`, never on a stamp, or it would have opened the
representative-hijack hole the fence exists to close.

**BOTH FLAGS FLIPPED DEFAULT-ON 2026-09-06** (`lss.stamp.enabled` and
`lss.stamp.flatPeel`). The hash tokens `lssIQ=` / `lssFP=` therefore now ride
the OFF arm, so the default config's cache key changes once and invalidates
`eco-stuff` / `~/.eco`.

**`instanceQual`'s value is CONDITIONAL on `flatPeel`**: alone it is +12 stamps
and flat wall (§12); behind the cleared arity guard it reaches 10 sites worth
81.7 M dispatches. If `flatPeel` is ever reverted, re-evaluate `instanceQual`
rather than assuming it still earns its default.

The semantic-equivalence check is the strongest correctness evidence here: three
compilers differing by 10,551 stamped call sites produce the same bytes.

**FIRST RAIL ATTEMPT WAS INVALID and is recorded so it is not repeated:** it
compared `iq-off.mlir` against `fa-arm1.mlir`, but the compiler's own source
changed between those runs, so the INPUTS differed. A two-binary rail must
re-run the older binary on the CURRENT source.

### 18.6 Wall model, checked against itself

§13.5 predicted 521 M dispatches x 47.7 ns = 24.9 s as an **upper bound that
"will not be realised"** because a stamp is a direct call, not a free one.
Actual: Fix A removed 338.9 M dispatches and **24.17 s** — the wall win
essentially MATCHED the upper bound while removing a third fewer dispatches.

So the per-dispatch saving is larger than 47.7 ns here, or there are secondary
effects (a direct call also stops allocating the intermediate staged closure
the generic path materialises). **The 47.7 ns/dispatch model under-predicts
this class and should not be reused without re-derivation.**

### 18.7 What remains

  - `arityOver` 379 survivors — the sites whose bucket or layout still misses.
  - **`bodyMismatch` 1,194 — CAUSE IDENTIFIED AND PRICED (arm 4).** Running
    `flatPeel=1` with `layoutQualMembers=0` drives `bodyMismatch` to **exactly
    0**, so the whole population is LSS_024's DELIBERATE id sharing: two specs
    of one global differing only in annotations share a member id by design,
    and the fence catches those whose bodies actually diverge. It is a designed
    trade, not a defect.

    Reverting LSS_024 is NOT the answer on these numbers: +276 stamps
    (17,122 -> 17,398) bought with **+5,568 `noInstance`** (16,212 -> 21,780)
    and **+3.3 % `.mlir`** (15.47 -> 15.98 MB) — precisely the member
    fragmentation LSS_024 was introduced to prevent. The identity population
    therefore splits cleanly: 10 sites from local-multi collision (fixed, 81.7 M
    dispatches) and ~1,184 from LSS_024 sharing (understood, priced, parked).
  - `abiMismatch` 354 (from 31) — same story, capture-layout disagreement.
  - `noInstance` 16,212, untouched and still the largest class.
  - The 26,037 `segmentation_unknown` static sites, which Fix A does not reach
    and Fix B would.
