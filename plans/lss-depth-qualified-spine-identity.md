# LSS: depth-qualified spine identity — stop `{g|G, p|G|d}` co-residency under `arrowSolverRoots`

**Status: PROPOSED (2026-09-17). P0 IS NOT OPTIONAL — §3's mechanism is a
HYPOTHESIS, not a measurement, and §4 is the probe that must confirm it before
any of §5 is built.**

**Headline, measured this session (§0): co-resident `{g|G, p|G|d}` sets — one
code object named at two application stages — DO NOT OCCUR at dispatch sites
under the shipping default. They are created by `lss.arrowSolverRoots` (Phase
2b), and they are 57.2 % of the multi-set sites that flag adds.** This plan is
therefore a **prerequisite repair for flipping 2b**, not an independent win at
HEAD. Anyone reading it as "fix the staging families" has the wrong frame.

**Supersedes an earlier claim made in the same session and now withdrawn:** an
arrow-level census (`ECO_MONO_LSS_ARROW_CENSUS=1`, `MSET` block) put 96.9 % of
multi-member sets at "all members name one global". That number is a **union
across specializations** — `lss-unknown-elimination.md` §11.2 says so in as many
words — and does not mean any single site ever saw such a set. The per-site
census built for this plan measures the co-residency directly and contradicts it
at the default.

---

## §0 The measurement

New instrument: `AbiCloningStats.instQual.multiSites` (`AbiCloning.elm`,
`noteMultiSite`), gated on `lss.census`, rendered by `Builder/Generate.elm` as
one `MSITE<TAB><sites><TAB><size>|<kinds>|<nIds>|<identities>` line per distinct
site shape. `nIds` is the count of DISTINCT code objects the members name, so
`1id` is exactly the staging-family shape and `2id`+ is genuine alternation.
Member kind letters are `l`/`g`/`c`/`k`/`a`/`p`; `?` is a member absent from
`lssMemberKinds`.

Workload `compiler/src/Terminal/Main.elm`, `bin/eco-boot-runner.js`,
`rm -rf eco-stuff` per arm, `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1`:

| arm | multi-set sites | `1id` (one code object) | `2id`+ (alternation) |
|---|---:|---:|---:|
| `ARROW_ROOTS=0` (shipping) | **13** | **0 (0.0 %)** | 13 (100.0 %) |
| `ARROW_ROOTS=1` (2b) | **243** | **139 (57.2 %)** | 104 (42.8 %) |

Per-arm `MSITE` site totals reconcile exactly with the independently-computed
`multiSetSiteHist` (A: `2->11 3->2`; B: `2->207 3->8 4->4 5->9 6->4 7->4 8->2
9->1 12->4`), which is the instrument's self-check.

The 2b-only `1id` population is dominated by `gp` kinds — 145 of 243 sites —
and names ordinary two-or-more-arity globals: `MonoTraverse.mapExprTypes` (18
sites), `MonoInlineSimplify.computeCost` (10), `Type.Solve.makeCopyHelp` (10),
`TypedOptimized.exprEncoderS` (9).

**2b also finds real alternation**: `2id`+ sites go 13 → 104. That half is
feedstock for `plans/lss-sum-lowering.md` and is NOT what this plan touches.

### §0.1 Method caveat — absolute counts are not comparable across runs

An earlier native-compiler run (`bin/eco-compiler-boot`, `ECO_MONO_LSS_REPORT=1`
only) reported the `ARROW_ROOTS=0` arm at **66** multi-set sites; this
JS-compiler run reports **13** for the same nominal configuration. The `B_on`
arms agree closely (237 vs 243). **The cause is unknown.** Candidates not yet
discriminated: different bootstrap-stage compiler (native Stage 7 vs JS Stage
2), and `ECO_MONO_LSS_CENSUS=1` present in one run and not the other.

Consequence: **only WITHIN-run A/B is quotable.** Before any absolute site count
from this plan is used in a decision, re-run both arms with one compiler and one
env set. This is the same class of error as §11.3's cross-arm `ArrowId` join and
should be treated with the same suspicion.

---

## §1 The defect

A lambda set annotates ONE arrow. In the paper the members of a set are all
lambdas of that arrow's type — enforced by the type system, which is what makes
§5.2's lowering total (one sum variant per member, all arms the same type). Eco
represents a set as `LambdaSet1 Bool (Dict Int ())`: a bag of ints with no
typing relation to the arrow it hangs off.

`{g|G, p|G|1}` on one arrow is the observable consequence. Read at a HEAD
annotation — which is what every consumer reads (`singletonHeadMember`,
AbiCloning's stamp arms, `multiSetSiteHist`) — `g|G` names `G` unapplied and
`p|G|1` names `G` with one argument supplied. Different arity, different type,
same arrow.

It is **sound** — a set is an upper bound, and naming an extra inhabitant costs
precision, never correctness; unsoundness is the LSS_002 direction, a member
that can arrive being absent. It is **not well-formed**, and Eco has no
invariant requiring well-formedness. The cost today is precision: every
consumer declines a non-singleton, so 139 sites per compile are declined for
naming one code object twice.

---

## §2 What already exists — this is a repair, not a new mechanism

Depth-qualified injection is **already built and default-on**. Do not
re-implement it.

- `LssInfer.injectPapSuccessors` (`lss.refPapSpine`, default ON) writes
  `p|<g>|<d>` at result-spine depth `d` in `1..declaredArity-1`, deliberately
  "the SAME id `Translate.injectPapMember` and `Translate.memberIdForDepth`
  mint, so the three paths unify at every join (E9.2 one-identity)".
- `LssInfer.injectPapSuccessorsFrom` does the same from a residual head
  (`lss.injTotal`).
- `Engine.papMemberKey g d` = `"p|" ++ global ++ "|" ++ d` is the one key
  builder.
- `standaloneMember` for a global is HEAD-ONLY by default
  (`spineDepthForGlobal`, `lss.spineArity = False`).

So the intended layout is already non-overlapping: head ← `g|G`, depth `d` ←
`p|G|d`. The 2b-only co-residency means something is putting a head member and
a depth member **in the same slot**, not that the ids are unqualified.

`LssInfer.injectSpineMemberId`/`spineGoC` is the one walk that writes the SAME
`mid` at every depth of a spine. Under `spineArity = False` it is called with
`arity = 1` for standalone globals, so it writes only the head — but it is
called with the lambda's full parameter count from `injectLambdaMember`
(LSS_013), and that is a second candidate source. §4 must attribute before §5
chooses.

---

## §3 Hypothesis (NOT MEASURED)

`lss.arrowSolverRoots` keys `Store.loadTypeC`'s `arrowMemo` by the
typechecker's union-find root instead of per-occurrence `ArrowId`. Two arrows
the SOLVER unified then share one set slot. The conjecture is that for a global
`G`, some head arrow and some depth-`d` arrow of `G`'s own type land in one
root class — at which point the head's `g|G` and the successor's `p|G|d` merge
into one slot and read back as a 2-set.

This is consistent with everything measured (the population is 2b-only, `gp`-
kinded, and names ordinary multi-arity globals) and with the user's framing —
use sites inside a body are not being distinguished finely enough, so their
sets union. **It is not established.** Competing explanations not yet excluded:

- `injectLambdaMember`'s full-arity spine (LSS_013) writing one `mid` across
  depths that 2b then merges with a `p|` successor;
- `sigRootIdentity`'s scratch-store root keying interacting with 2b (the two
  are mutually exclusive by construction — `recordRootKey` does not run when
  `useSolverRoots` is on — so a 2b-only defect cannot come from it, but the
  *absence* of the side table changes which slots the inference walk shares);
- `Translate.injectPapMember`'s producer-side residual head coinciding with a
  reference head.

---

## §4 P0 — attribute before building

Run these BEFORE §5. Each is census-only and artifact-neutral.

1. **Name the arrows.** Extend `noteMultiSite` to record the site's callee
   `ArrowId` (available via `itemAux.arrowOfSlot` at mono time; at AbiCloning
   time it is not, so this likely belongs in the mono-side `MSET` walk rather
   than in AbiCloning). For each `1id` site under 2b, report the ArrowId and
   whether its root class contains more than one occurrence id.
2. **Attribute the writers.** For a handful of the top hosts
   (`MonoTraverse.mapExprTypes`, `MonoInlineSimplify.computeCost`,
   `Type.Solve.makeCopyHelp`), instrument which injection site wrote each
   member into the shared slot — `injectPapSuccessors`, `injectLambdaMember`,
   `standaloneMember`, or `Translate.injectPapMember`.
3. **Confirm the depth.** For each co-resident pair, record the spine depth at
   which the `p|G|d` was written and the depth at which the site reads. If they
   differ, §3 is confirmed; if they are equal, the two writers disagree about
   what depth the arrow IS, which is a different bug with a different fix.

**Exit criterion:** a named mechanism with file:line evidence for at least the
top three hosts. Without it, §5 is guesswork, and this register's record
(`lss-why-the-fidelity-program-failed.md` §6: three causal attributions
proposed and all three refuted by measurement) says guesswork loses.

---

## §5 Candidate repairs — ranked, NOT YET CHOSEN

**SUPERSEDED (2026-09-17):** the writer was attributed by code reading —
`Translate.classifyLambdaHead` → `injectLambdaMemberQualified` writes the
root-folded stampable `g|G|L` at depths 0..arity-1 (`LssInfer.spineGoC`),
while the other two spine writers put `p|G|d` at depth ≥ 1. R1 and R2 below
are replaced by `plans/lss-root-fold-depth-qualified-spine.md`, which fixes
that writer; R3 is unnecessary once the slot holds one name. §4 P0 still
applies as the census confirmation of that attribution.

- **R1 — depth-aware slot keying.** If §3 holds, the arrow memo must not merge
  arrows at different spine depths of the same root class. Narrowest form: key
  the memo by `(rootKey, depth)` rather than `rootKey`. Cost: a wider key,
  and `provenance:`'s `rootClasses` stops being the tie count.
- **R2 — one identity per depth, enforced.** Make the head member of a global's
  spine `p|G|0` rather than `g|G`, so every depth has the same key shape and a
  merge produces a set whose members are comparable. Blast radius: `g|` is the
  devirt key for LSS_015/E9.1 and the `stampable-class` path that MISCOMPILED
  when `g|` reuse was drafted for PAPs (`lss-solver-root-signature-identity.md`
  R1) — this is the dangerous option and needs its own soundness argument.
- **R3 — collapse at the consumer.** Teach the stamp guards that a set whose
  members all name one global with a single distinct depth is stampable via
  LSS_011's existing `fastPapPrefix` machinery. Cheapest; does not fix the
  representation; must decline sets spanning multiple depths (runtime-varying
  saturation genuinely needs a switch).

R1 is the principled fix if §3 holds. R3 is the fallback if §4 shows the merge
is legitimate and the ids are simply redundant.

---

## §6 Gates

- Two-binary byte-identity with `arrowSolverRoots=0` (the shipping default must
  not move; this plan is 2b-only by construction).
- Per-site census: `1id` sites under 2b → 0, `2id`+ sites unchanged or higher.
- `declinedShape`, `declinedBodyMismatch`, `declinedNoInstance` under 2b move
  toward the `ARROW_ROOTS=0` arm.
- `singleton_fast` share of `eco.papExtend` under 2b recovers toward the 46.06 %
  of the default arm (2b measured 44.75 %). Use `ecoc --emit=mlir-opt`, not
  static stamp counts — `dispatchUpgraded` moved +2.07 % under 2b while
  `singleton_fast` moved −0.8 %, and the emitted code is the one to believe.
- elm-tests + E2E ×3 legs + bootstrap 8c, both flag arms.

---

## §7 What not to do

- **Do not quote §0's absolute site counts across runs** until §0.1 is closed.
- **Do not size this from static site counts.** The runtime attribution
  (`lss-why-the-fidelity-program-failed.md` §5) found 620 M generic dispatches —
  27 % of all dispatch — on TWELVE closures, each with exactly one `papCreate`
  site. Those are k=1 opportunities that failed to resolve, not k≥2 needing a
  switch. 139 static sites may be worth nothing at runtime.
- **Do not treat this as a prerequisite for sum lowering at HEAD.** At the
  shipping default there are 13 multi-set sites and all are genuine
  alternation; nothing here blocks that plan.

---

## §8 Relationship to other plans

- `plans/lss-unknown-elimination.md` — §11 is 2b (`arrowSolverRoots`); this plan
  is a repair to it, and §11.7's "it should STAY off until Phase 3" is the
  standing verdict this plan would help revisit.
- `plans/lss-ref-pap-spine.md` — built `injectPapSuccessors`, the depth-
  qualified writer this plan does NOT need to rebuild.
- `plans/lss-solver-root-signature-identity.md` — R1 there records the
  `g|`-reuse miscompile that makes §5's R2 dangerous.
- `plans/lss-sum-lowering.md` — consumes the `2id`+ half (13 sites at default,
  104 under 2b); disjoint from this plan.
- `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` — the
  type-homogeneity property §1 names is the one Eco has never represented.
