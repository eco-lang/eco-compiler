# Root-member fold — one identity per (function, layout), so stamped spines become singletons

**Status:** proposed 2026-08-28; reviewed against code while lowering (AR notes
inline). Successor to `plans/lss-registration-self-identity.md` §8: the
`regIdentity` stamp exposed that a top-level def carries TWO member ids — its
body-root lambda's `l|` id and its standalone `g|` id — and wherever both flow
to one position the set is a sound-but-useless 2-set. 55,664 of the new
defaults' covered positions are kN, a large share exactly these pairs, and
singleton-only consumers (fast-call stamping, devirt) cannot use them.

**Flag:** `lss.rootFold` (`ECO_MONO_LSS_ROOT_FOLD`, hash token `lssRF=`),
DEFAULT-ON since 2026-08-28 (user-directed flip; escape hatch
`ECO_MONO_LSS_ROOT_FOLD=0`, hash token `lssRF=0` rides the OFF arm).
Artifact-affecting (member-id allocation order and set contents
move). **This is the first plan of the arc whose HEADLINE metric is dispatch,
not coverage** — coverage is unchanged by construction (kN→k1 is
gate-0-neutral). *(Metric corrected post-measurement, §4.1: the headline is
`sat` REDUCTION, not `fast %` — this mechanism devirtualizes mostly to DIRECT
calls, which the dispatch census does not count, so `fast %` understates it
~4.7×.)*

---

## §0 Evidence and anchors (all verified 2026-08-28)

- **The pair, measured:** `MSET … 2 l|0|A(…unA…) | g|…unA|A(…)` — the def's
  root-lambda member and its standalone member, both layout-qualified, both
  denoting `unA`. Ctors (no body ⇒ no `l|`) came out k1 in the same run;
  kernels avoided it via the E9.2 fold (`(::)` interns ONE id — *"a split
  g|/k| identity would join to a 2-set and kill singleton consumers"*).
- **The shared mint:** `Engine.lambdaMemberLayoutQualified raw specId`
  (Engine.elm:656) interns `layoutQualKey` = `"l|" ++ raw ++ "|" ++ wkey`
  where `wkey` = the enclosing spec's IMMUTABLE widened creation key
  (`specWidenedKeys`, captured at spec creation), SpecId fallback otherwise.
  ALL translation-phase consumers go through it (via
  `Engine.lambdaInstanceMemberId`), so a fold INSIDE it reaches the set
  injection and the closure-instance linkage with one id, consistently.
- **The ground key:** `Engine.groundStandaloneMemberIdFor g typeKey` interns
  `"g|" ++ toComparableGlobal g ++ "|" ++ typeKey`; the LSS_019 zonk rewrite
  turns every provisional `g|X` reference member into this. `typeKey` at a
  HEAD arrow = `toComparableMonoType (widenSets (mFunction ⊤ [param] result))`
  — and mono types are curried one-arg chains (`classifyGo` builds
  `[mFrom]`; GlobalOpt flattens later, GOPT_016), so the head arrow's widened
  key IS the widened whole type = the spec's creation key. **The two
  qualifier strings agree at the head by construction** — the same equality
  LSS_024 already relies on for demand-carried sibling ids.
- **The root mint site:** `Translate.elm:1681` — the root-lambda head
  classification (the `lssRootAnn` stash path) calls
  `LssInfer.injectLambdaMemberQualified` → `lambdaInstanceMemberId` → the
  shared mint. Root-ness is NOT visible inside the mint today.
- **Root-lambda discovery:** a def node is `Define/TrackedDefine` whose
  expression is `TOpt.Function` carrying `srcLam = Just lamId` — the mapping
  `lamId → global` is derivable when nodes are in scope.

## §1 Design

### §1.1 The fold

Inside `lambdaMemberLayoutQualified`, when the flag is on and `raw` is the
ROOT lambda of global g (a new `rootLamOf : Dict Int Global` lookup), intern

```
"g|" ++ TOpt.toComparableGlobal g ++ "|" ++ <same qualifier as today>
```

instead of the `l|…` key — same qualifier logic including the SpecId fallback,
same census tail, same `lambdaQualified` bookkeeping, PLUS
`insertMemberGlobal` (the id denotes the global; sources must say so for
devirt's reverse lookup) and NEVER `provisionalStandalone` (it is born ground;
grounding passes it through untouched, preserving zonk∘encode∘zonk
idempotence).

Then: root injection, closure-instance linkage (`closureInfo.lssMember`),
reference grounding, and the `regIdentity` head stamp all converge on ONE
string ⇒ one id ⇒ `{l|,g|}` head pairs become singletons wherever layouts
agree.

### §1.2 The rootLamOf table

Populated once per translated def at the point the node's root `Function` is
in hand (the same region that stashes `lssRootAnn`), keyed by the raw
`SrcLambdaId`. Lives on **`LssMemberTable`** (member-mint metadata, beside
`provisionalStandalone`) — NOT on `S`, which is AT the runtime's 32-slot
record GC-scan cap; see §5.2. Not config/cache — nothing serialized changes
shape. Misses simply mint `l|` as today (censused
`rootFold|miss`), so partial coverage degrades to the status quo, never to a
wrong id.

### §1.3 The stamp upgrade

`Translate.stampSelfSpine` depth-0 currently mints the PROVISIONAL `g|X`.
Upgrade: compute `Intern.widenSets monoType` in the wrapper (hash-consed; the
enqueue computes the same thing moments later) and mint the GROUND
`g|X|<toComparableMonoType widened>` directly. `widenSets` ⊤-widens every
anno, so stamped-vs-unstamped demands widen to the SAME string and the key
equals the spec's captured creation key. Depth>0 keeps `p|` (declining class
BY DESIGN — the papMembers lesson; deep-spine `{l|inner, p|}` pairs remain kN,
censused, accepted: the dispatch prize is the head).

### §1.4 Scope cuts (deliberate, censused)

- **Head only.** Deep-spine pairs stay (see §1.3).
- **`rootAnn|absent` fallback path** (root anns that never stashed): keeps
  `l|` today, counted; expected rare.
- **Inference-phase mints** (`injectLambdaMember`, pre-spec by design) are
  untouched — signatures are per-unit; the translation mint is where specs
  and consumers live.

**CORRECTION (2026-09-17):** §1.4's "Head only" was NOT true of the
TRANSLATION-phase mint. `Translate.classifyLambdaHead` calls
`LssInfer.injectLambdaMemberQualified arity`, whose `spineGoC` wrote the
folded GROUND `g|` id at EVERY depth `0..arity-1` of the def's own spine —
i.e. the stampable id landed on partial-application positions, which §1.5
AR-1 requires to stay `p|`. Invisible until `lss.arrowSolverRoots` shipped
default-ON (2026-09-17), which merges a def's depth-`d` slot with the inner
arrow of its call sites and surfaced the pair as `{g|G|L, p|G|d}` at 139
dispatch sites. Repaired by
`plans/lss-root-fold-depth-qualified-spine.md` (`lss.stamp.rootFoldDepth`):
head keeps the ground `g|`, depths `1..arity-1` get `p|g|d`, matching
`stampSelfSpine` and `injectPapSuccessors`.

### §1.5 Soundness (the review, condensed)

- **AR-1 (id truthfulness):** the folded id is attached to exactly the values
  the root lambda produces — the def itself at its layout. `SourceGlobal`
  registration makes it STAMPABLE; a singleton `{g|X|L}` at a position
  licenses devirt to X's spec — true by the same tautology as `regIdentity`'s
  stamp. The papMembers miscompile required a stampable id on a PARTIAL
  application; depth>0 stays `p|` (declining), so that door stays shut.
- **AR-2 (μ-tie / LSS_018):** the fold changes the interned STRING, not the
  tie logic; `demandQualified`-vs-`byKey` comparison operates on ids from the
  same mint, so tieBypass/muTied behaviour is preserved per-id. Pinned by the
  suite staying green (MuTieTest exists).
- **AR-3 (grounding idempotence):** born-ground ids never enter
  `provisionalStandalone` ⇒ LSS_019 passes them through; the finite-lattice
  termination argument (LSS_010) is untouched.
- **AR-4 (allocation order):** member ids allocate in a different order
  flag-on ⇒ artifact-affecting ⇒ the standard two-binary/frozen-corpus rail
  flag-off, and full battery flag-on. Flag-off is byte-identical: the fold is
  behind the flag at the single mint; `rootLamOf` is populated only flag-on.
- **AR-5 (kernel aliases):** kernel-backed defs' root mint would fold to
  `g|X|…` while references fold to `k|…` (E9.2) — a NEW split! The fold must
  route through `LssInfer.kernelAliasOf` first and fold kernel-alias roots to
  the KERNEL member id (or simply skip them — their spines are ⊤-bounded
  anyway, §7 of the regIdentity plan). v1: SKIP kernel-alias globals
  (censused), matching the boundary.

## §2 Implementation edit list

1. **Flag plumbing** — the established 4+2-site pattern (`Compiler/Eco/
   Config.elm`: field+doc, `defaultLss = False`, decoder APPENDED LAST, hash
   token `lssRF=`; `Builder/Eco/Config.elm`: override + env chain row
   `ECO_MONO_LSS_ROOT_FOLD`).
2. **`Engine.S` + `rootLamOf : CoreDict.Dict Int TOpt.Global`** (init empty)
   + `recordRootLam : Int -> TOpt.Global -> S -> S` (flag-gated write).
3. **`lambdaMemberLayoutQualified`**: before building the `l|` key, when
   `s0.env.lss.rootFold` and `CoreDict.get raw s0.rootLamOf = Just g` and
   `LssInfer.kernelAliasOf g == Nothing` — WAIT: Engine cannot import
   LssInfer (cycle, AR from the regIdentity plan). Kernel-alias detection
   must precede table write: `recordRootLam` is CALLED from Translate (which
   can consult `kernelAliasOf`) — kernel-alias roots are simply never
   recorded. The mint then needs no LssInfer: fold key =
   `"g|" ++ TOpt.toComparableGlobal g ++ "|" ++ <qualifier>` with the same
   `layoutQualKey` qualifier tail, `insertMemberGlobal`, census
   `rootFold|folded`.
4. **Populate `rootLamOf`**: in the Translate region that stashes
   `lssRootAnn` (Translate.elm ~1620-1660), where the def's root `Function`
   and `s.env.currentGlobal`-equivalent are in hand — record
   `srcLam → global` (skip kernel aliases via `kernelAliasOf`). Verify the
   exact global source at implementation (the item's global is threaded into
   that region; if only a defKey string is present, thread the `TOpt.Global`
   — smallest sufficient change).
5. **Stamp upgrade** (`stampSelfSpine` depth-0): widen once, mint ground via
   `Engine.groundStandaloneMemberIdFor` (pure — returns table+nextId;
   adapt into the Step by hand like its zonk callers do). Kernel-alias arm
   unchanged (k|), ctor arms unchanged (c| — ctors have no l| to pair with).
6. **Census**: `rootFold|folded`, `rootFold|miss` (root mint with no table
   entry while flag on), `rootFold|kernelSkip`.
7. **Pins** (`LssRootFoldTest`, differential per the arc rule):
   1. head singleton: `plainModule`'s `double` stored head flag-on is
      `LSet 1`, flag-off `LSet 2` (requires `regIdentity` on — it is
      default-on; the harness pins it ON explicitly for self-documentation);
   2. the folded id IS the reference id: a fixture passing `double` as an
      argument — the consumer param singleton and the stored head singleton
      carry the SAME member (compare the ints);
   3. kernel-alias skip: a `(::)`-shaped fixture stays green, head not a
      NEW split (⊤ or set, never `LVar`);
   4. deep spine unchanged: `plus2` depth-1 anno identical across arms
      (id-blind, the 2b pattern);
   5. co-gate: `joinModule` (the crash shape) with `rootFold = True` — no
      false singleton at the consumer.
8. **Battery** (order): save `eco-preFold`; frozen-corpus byte-identity
   flag-off; self-compile A/B — record coverage (expect ≈unchanged
   coveredBp, kN→k1 shift visible in the k1/kN columns) AND the headline:
   **dispatch A/B on the Run-AO rail** (`fast%`, `devirtDirect`,
   `stampedStaged`, `declinedNoInstance`); Q both arms; gate 5b lower+RUN
   (CRITICAL leg — stampable singletons at heads are devirt-live, this is
   the miscompile neighbourhood); elm-tests; E2E both arms; flip decision
   with the user.

## §3 What success looks like

k1 rises by roughly the folded-head population while kN falls in step
(coverage flat); `MSET` pairs of the `l|/g|` shape disappear at folded
layouts; `AbiCloning.instanceMember` head-fallback firings become
minted-member hits; and for the first time in this arc, `fast%` moves.
No number is promised — the battery measures.

## §4 RESULTS (2026-08-28) — the fold works; DISPATCH MOVES for the first time

| gate | result |
|---|---|
| build | clean (after two fixes, §5) |
| elm-tests | 13,377 / pre-existing 12 — all 5 pins pass FIRST TIME |
| frozen byte-identity flag-off vs `eco-preFold` | **IDENTICAL** |
| Q flag-on | `Q-infer diverge=0 REPRODUCES=yes`; `Q-shadow` 70 (unchanged from the regIdentity baseline) |
| gate 5b | lower clean (0 undefined fast evaluator), RUN 200 s healthy |
| E2E flag-off | 1,706/1,706 |

**Analysis A/B (self-compile):** the fold does exactly what it claimed.

| | flag-off | flag-on | delta |
|---|---:|---:|---:|
| k1 | 51,094 | **76,303** | **+25,209** |
| kN | 55,688 | **29,896** | **−25,792** |
| coverage | 8009 bp | 8003 bp | −6 bp (FLAT, as predicted) |
| `rootFold\|folded` | — | 46,062 | |

A near one-for-one conversion of multi-member sets into singletons. Coverage is
flat BY CONSTRUCTION (kN counts as k1 under gate 0) — this plan was never a
coverage play.

**Dispatch A/B (Run-AO rail) — and the metric correction it forces:**

| counter | off | on | delta |
|---|---:|---:|---:|
| **sat** (indirect total) | 2,219,899,146 | 2,194,042,291 | **−25,856,855 (−1.165 %)** |
| `gen` (generic funnel) | 2,184,645,692 | 2,158,788,842 | −25,856,850 |
| `typed` (known-arity) | 35,253,454 | 35,253,449 | −5 |
| **fast** (stamped `$cap`) | 597,403,348 | 602,959,965 | +5,556,617 |
| sat+fast (counted calls) | 2,817,302,494 | 2,797,002,256 | −20,300,238 |
| distinct fps | 7,245 | 7,197 | −48 |
| fast % | 21.205 % | 21.557 % | +0.353 pp |
| wall | 7:39.28 | 7:36.08 | −3.2 s |
| workload output | 14,978,231 B | 14,978,231 B | **IDENTICAL** |

**§4.1 THE HEADLINE METRIC IN §2 WAS WRONG — use `sat`, not `fast %`.**
25,856,855 indirect dispatches were eliminated. Only 5,556,617 (21.5 %) landed
in `fast`; the other **20,300,238 became DIRECT calls, which this census does
not count** (a known limitation of the dispatch counters — direct static calls
have no counter). The workload outputs are byte-identical, so none of it is
"less work". `fast %` therefore UNDERSTATES this change by ~4.7×, and any
future plan whose mechanism devirtualizes to direct calls must headline `sat`
reduction instead.

The whole reduction came from `gen` (the unknown-callee funnel) with `typed`
unmoved to 5 events — the exact signature of a member-IDENTITY change: arity
knowledge is untouched, unknown-callee becomes known-callee.

**Arc context:** every prior plan measured dispatch-neutral (`refIdentity` −274
events, `sigRootIdentity` −7, `regIdentity` −7). This is the first conversion
of completeness into execution.

## §5 IMPLEMENTATION NOTES (two build breaks, both recorded)

1. **Docstring split** — the `mintLayoutQualifiedFold` wrapper was inserted
   between `mintLayoutQualified`'s doc comment and its signature; Elm rejects
   two consecutive doc comments. Same insertion class as the ctor arc. Insert
   ABOVE the target's docstring, not between doc and signature.
2. **The 32-slot GC-scan cap** — `rootLamOf` on `Engine.S` pushed that record
   to 33 fields and the compiler's OWN lowering rejected it:
   `'eco.construct.record' op field_count (33) exceeds Record's 32-slot GC scan
   limit`. This is the documented reason `grounding`/`sigStats`/`layoutQual`
   are sub-records. Moved to `LssMemberTable` — where it belongs anyway, as
   member-mint metadata beside `provisionalStandalone`. **`Engine.S` is AT the
   cap: any future field must go in a sub-record.**
