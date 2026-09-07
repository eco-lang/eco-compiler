# Converting the `bodyMismatch` declines: one member id, several bodies

**Status: CLOSED UNBUILT 2026-09-06. The P0 census ran and killed it — §8.**

**In one line: the recommended repair (4.A) is refuted outright — every
divergent group is `structural`, none is `annoOnly` — and the population is
worth single-digit millions of dispatches against a ~50 M bar.**

Successor to `plans/lss-instance-qualified-members.md` (LSS_038 instance
qualification, LSS_039 flattened stamping — both DEFAULT-ON since 2026-09-06).
Fix A cleared the arity guard in front of this population and thereby created
it as a visible target: `declinedBodyMismatch` went **78 → 1,194**.

---

## 1. What `bodyMismatch` is

At a call site whose callee annotation is a **singleton** `LSet [m]`,
`AbiCloning` looks `m` up in the instance index and finds a layout group
holding **two or more closures whose body fingerprints differ**
(`instanceFingerprint`: a structural hash of `ClosureInfo` + body, with local
names compared positionally so `MonoInlineSimplify`'s freshened verbatim copies
hash equal). The annotation claims one inhabitant; the index holds several
different ones. Stamping either would direct-call the wrong closure — the E11
representative-hijack SIGSEGV class — so LSS_024's fence declines.

**The decline is correct.** This plan is about removing the *cause*, not the
fence.

### 1.1 The cause is measured, not guessed (arm 4, 2026-09-06)

Running `flatPeel=1` with `layoutQualMembers=0` drives `bodyMismatch` to
**EXACTLY 0**. So the entire population is **LSS_024's deliberate id sharing**:
the member key is `l|<raw>|<annotation-WIDENED spec creation key>`, so two specs
of one global that differ only in their annotations **share one member id by
design**. LSS_017's amendment states it outright — such clones "now share an id
and are fenced at the CONSUMER by LSS_024 fingerprint unanimity, not by id
inequality".

The bodies then diverge because the annotations are **not inert**: an inner
lambda-set annotation drives that inner site's own stamping decision, so two
clones commit their inner calls to different `_fast_evaluator` symbols. LSS_005
says annotation differences never change *observable behaviour*; it does not say
they never change *emitted code*, and here they do. This is exactly
`AbiCloningFenceTest` case 2.

### 1.2 Where it sits (arm 3 = the shipped default)

| decline class | sites | note |
|---|---:|---|
| `noInstance` | 16,223 | largest, untouched, out of scope here |
| `blocked` | 6,616 | staging wrappers / adopted closures |
| **`bodyMismatch`** | **1,194** | **this plan** |
| `shape` (arity 379 + bucket/layout) | 685 | LSS_039 residue |
| `abiMismatch` | 354 | capture-layout divergence; same shape as this |

Generic dispatch after LSS_038+LSS_039: **1,074,741,050**.

---

## 2. P0 census — the dynamic weight of the 1,194 (MANDATORY GATE)

**Site counts have mispredicted weight THREE times in this arc.** `foldrHelper`
held 59 % of `arityOver` sites and 4.45 % of its dispatch; `Dict.foldl` held
2.5 % of sites and 19.95 % of dispatch (107x apart, opposite order); and
LSS_038's **10** sites carried **81.7 M dispatches** while I read the static
table and called it "barely a dent". A fourth repeat is not acceptable.

**Nothing in §4 gets built before this reports.**

### 2.1 What to measure

Extend `AbiCloningStats.instQual` with `bodyMismatchSites : Dict String Int`
keyed `"<host global>|<SpecId>"` at every `bodyMismatch` decline — the SpecId is
required, because the join key against the caller-attributed dynamic census is
the emitted symbol `<Module>_<name>_$_<specid>`, and a host-global key cannot
distinguish a 100 M spec from a cold one.

Then the established two-sided method
(`memory: arityover-dynamic-weight-census`):

1. self-compile with `ECO_MONO_LSS_REPORT=1` → the static per-spec table;
2. the SAME binary under entry-only uprobes on `eco_apply_closure_eval` with
   `@gen[*(uint64*)reg("sp")] = count()` → caller-attributed dispatch;
3. symbolize offline against `nm -n` with the PIE base from `/proc/<pid>/maps`;
4. join on the spec symbol and rank.

Traps, all previously paid for: `BPFTRACE_MAP_KEYS_MAX=1000000` (silent
truncation at 4096); `toComparableGlobal` separates components with **NUL
bytes**, not spaces; `/usr/bin/time` makes `$!` the wrong PID; uprobes cost
~2.5x wall, which is fine for counts.

### 2.2 Also worth one line of the same census

`abiMismatch` (354) is the same shape one guard earlier — same member, same
group, capture layouts disagree. If §4's chosen option generalises, it should be
sized at the same time rather than in a second census.

---

## 3. What the divergence actually is

Before choosing a repair, the census must also answer **why each group's bodies
differ**, because the options split on it. Add a classifier at the fence:

  - **`stampDivergent`** — the clones' bodies differ at positions that drive
    stamping (an inner callee annotation naming a different member). Predicted
    to dominate, per §1.1.
  - **`structDivergent`** — genuinely different code (different call targets,
    different literals, different shape). No identity repair can help; only §4.B.
  - **`captureDivergent`** — same code, different capture layout. That is
    `abiMismatch`, counted separately.

The classifier is a diff of the two fingerprint strings down to the first
differing fragment, bucketed by fragment kind. Cheap, report-gated, and it
decides §4.

---

## 4. The option space

### 4.A Post-stamp fingerprinting — RECOMMENDED IF `stampDivergent` DOMINATES

**Idea.** Today's fingerprint is computed on the **pre-stamp** graph
(`collectInstances` runs before the `stampNode` fold), so it sees raw
annotations and treats every annotation difference as a code difference. But
the thing that reaches codegen is the **stamp** (`closureKind`, `captureAbi`,
`fastEvaluator`) — and `fpClosureParts` already hashes exactly those fields
(`;ck=`, `;cabi=`). So: stamp first, then re-fingerprint on the stamped graph,
then re-decide the sites that declined `bodyMismatch`. Two clones whose inner
sites received the *same* stamps (or both none) compile to identical code and
are genuinely interchangeable; two that received different stamps still decline.

**Strictly more precise than today, and sound in the right direction**: it never
admits a pair whose emitted code differs, because the stamps ARE the emitted
difference.

**THE HAZARD, and it is the reason this is not obviously right:** an outer stamp
changes the CallInfo of a call that usually sits inside another closure's body,
which changes that closure's fingerprint, which can make a third group
non-unanimous and *un*-stamp a site that was stamped. That is a fixpoint, and
not obviously a monotone one. Obligations before building:

  - a monotonicity argument, or an iteration CAP with a proof that capping is
    sound (it is: stopping early only leaves declines, never wrong stamps);
  - determinism — the same graph must produce the same stamps regardless of
    iteration order, or artifacts stop being reproducible;
  - a census of how many iterations actually change anything (expect 2).

### 4.B Guarded direct call (monomorphic inline cache) — the general fallback

**Idea.** Do not repair identity at all. At a declining site, pick the group's
representative, emit a compare of the flowing closure's `evaluator` field
against that instance's fast symbol, and branch: equal → the direct fast call,
otherwise → today's generic dispatch. `Closure.evaluator` is a plain
`EvalFunction` pointer in the header (`Heap.hpp`), so the test is one load and
one compare.

**Works regardless of WHY the bodies diverge**, including `structDivergent`,
and needs no identity change. Costs a compare + branch on the fast path and code
size at every stamped site. Whether that pays depends entirely on §2's weight
distribution: worth it for a handful of very hot sites, not for 1,194 cold ones.

**Distinct from `plans/lss-sum-lowering.md`**, which handles a multi-member
`LSet [m1,m2]` with a static tag. Here the annotation is a SINGLETON and the
discriminator can only be a runtime property of the object.

### 4.C Revert LSS_024 — MEASURED AND REJECTED

`layoutQualMembers = 0` gives SpecId-qualified ids (LSS_017), so every member
becomes a genuine singleton and the fence has nothing to reject.

**Priced on the self-compile (arm 4): `bodyMismatch` 1,194 → 0, stamps
17,122 → 17,398 (+276) — bought with `noInstance` 16,212 → 21,780 (+5,568) and
`.mlir` 15.47 → 15.98 MB (+3.3 %).** That is precisely the member fragmentation
LSS_024 was introduced to prevent. **Do not re-attempt without a new argument;
the numbers are already in.**

### 4.D Late member split with provenance — PARKED

Split a divergent member into sub-members after the bodies exist, then rewrite
each site's annotation to the sub-member that can actually reach it. Blocked on
the provenance question: the site sees a singleton id and has no record of which
clone flows there. Would need the call graph (`callEdges`) and a reachability
analysis. Strictly more work than 4.A for the same population; revisit only if
4.A's fixpoint proves untameable.

---

## 5. Adversarial review

| # | objection | disposition |
|---|---|---|
| C1 | 4.A's re-fingerprint is a fixpoint that can oscillate — a stamp added in round 2 can remove one in round 3 | **UPHELD, and it is the plan's main risk.** §4.A carries the obligation explicitly: monotonicity argument or a capped iteration with a soundness note. Capping is sound (it only leaves declines) but must be shown to be DETERMINISTIC or artifacts stop reproducing. |
| C2 | 4.A could admit a pair whose code differs for a reason the fingerprint does not cover | **ANSWERED, conditionally.** The fingerprint hashes `ck`/`cabi` plus body structure; post-stamp it also reflects `fastEvaluator` — provided `fpClosureParts` is extended to hash it, which today it does NOT. That extension is a REQUIREMENT of 4.A, not an optimisation. |
| C3 | §1.1 asserts the whole population is LSS_024 sharing on ONE arm | **HELD, with a caveat.** Arm 4 drove it to exactly 0, which is strong. But that arm also turns the FENCE off (`fpFence = layoutQualMembers`), so "0 declines" partly means "nothing was checked". §3's classifier is what actually establishes the cause; do not treat arm 4 as sufficient. |
| C4 | 4.B's guard costs a compare on every stamped site, including the 10,551 LSS_039 already converted | **SCOPED.** 4.B applies ONLY at sites that would otherwise decline; an unanimous group keeps today's unguarded stamp. |
| C5 | The whole plan could be worth ~0 if the 1,194 are cold | **THE POINT OF §2, and the most likely outcome to plan for.** LSS_038 showed 10 sites worth 81.7 M; the converse — 1,194 sites worth 2 M — is equally possible and would close this plan unbuilt. |
| C6 | `abiMismatch` (354) is folded in as an afterthought | **NOTED.** §2.2 sizes it in the same census; it gets its own decision, not a free ride on this one. |
| C7 | Fix A's own residue (`arityOver` 379) might be cheaper per dispatch | **OPEN.** §2 should rank all remaining classes together rather than assume this one wins. |

---

## 6. Ordering

| step | content | gate |
|---|---|---|
| **P0** | §2 census (static per-spec + caller-attributed dynamic) and §3 classifier | §7 |
| P1 | If `stampDivergent` dominates AND weight justifies: 4.A, behind `lss.stamp.postStampFp`, default off | fixpoint obligations discharged; unit pins first |
| P2 | Residue that is `structDivergent` and hot: 4.B, separately flagged | its own weight gate |
| P3 | Measurement in the LSS_039 four-arm style; default-flip decision | wall on N>=3 |

---

## 7. The go/no-go

**Proceed only if the §2 census shows the `bodyMismatch` sites carrying
materially more dispatch than the ~2 % of remaining generic dispatch that would
make this noise.**

For calibration: LSS_038 + LSS_039 together removed 420 M dispatches of 1.495 e9
and 7.1 % of wall. A follow-on worth less than ~50 M dispatches is not worth a
fixpoint in `AbiCloning`.

**If the census says cold, close this plan unbuilt and record the number** —
that is a result, and it redirects effort to `noInstance` (16,223 sites, the
largest remaining class and entirely unexamined).

---

## 8. P0 census result — CLOSED UNBUILT (2026-09-06)

Run on `eco-bmon`: a compiler whose OWN code was generated with both flags on
and which runs with both flags on, so the static report and the caller-attributed
dynamic profile describe the same program. It **reproduces its own input byte
for byte** — a bootstrap fixed point — which is also what made the per-spec join
valid (§8.4).

### 8.1 Option 4.A is refuted

```
bodyMismatch kinds: structural|n2=967 structural|n3=286 structural|n4=196
                    structural|n6=76 structural|n5=63 ... (1,755 groups)
```

**Every divergent group classifies `structural`. Not one is `annoOnly`.**
Widening lambda-set annotations away does NOT make the fingerprints agree, so
the bodies genuinely differ — §1.1's reasoning, that the divergence is
annotation-driven and post-stamp fingerprinting would recover it, **was wrong**.
There is nothing for 4.A to convert. The plan's own recommended option, killed
by its own census.

### 8.2 The weight is far below the bar

Total generic dispatch on the stamped binary: **1,095,124,597**.

| bound | dispatch | % |
|---|---:|---:|
| `foldrHelper` bodyMismatch, PRECISE (per-spec, fixed-point join) | 5,266,149 | **0.48 %** |
| `Dict.foldl`'s 6 sites, tight upper bound (its 6 hottest specs) | ≤ 26,705,779 | ≤ 2.44 % |
| whole population, GENEROUS bound (every generic site in all 40 hosts) | 68,491,958 | 6.25 % |

The realistic figure is at the low end: for `foldrHelper` — 850 of the 1,194
sites — only **15 %** of its generic dispatch is at `bodyMismatch` sites
(5.3 M of 34.4 M). Applying that shape puts the true total in the **single-digit
millions**, against §7's **~50 M** bar.

**No top-12 remaining caller is a `bodyMismatch` decliner.** The residual hot
mass is `eco_apply_closure_eval`'s own over-saturation loop (91.5 M, 8.36 %),
the C++ kernel `foldImpl` (54.7 M, 5.00 %) and `IO.andThen`/`IO.map`.

### 8.3 The site-count trap, fourth confirmation

`Dict.foldl` **6 sites / ≤26.7 M** = ≤4.5 M per site. `foldrHelper`
**850 sites / 5.3 M** = 6 K per site. **~700x apart, opposite rank order.**
Four for four in this arc. Treat it as the rule, not the surprise.

### 8.4 Two measurement errors, recorded so they are not repeated

  1. **Joined SpecIds across two different compilations.** The static report's
     ids were assigned by the run being reported; the dynamic symbols' ids were
     assigned by the compiler that BUILT that binary. Different programs.
     (`memory: eco-artifact-canonical-diff` already says never match across
     binaries by index.) Fixed by joining on the GLOBAL NAME.
  2. **Joined static-with-stamps against a binary built WITHOUT them.**
     `eco-bm`'s code came from a flags-off compile, so its dynamic profile was
     pre-Fix-A and showed `Dict.foldl` at 330 M. Fixed by building `eco-bmon`
     with the flags on, so both halves come from one program.

  **The per-spec join is only valid because `eco-bmon` is a FIXED POINT** — the
  ids in its code equal the ids it assigns. Absent that, name-keyed joins are
  the only sound option.

### 8.5 Verdict

**Closed unbuilt.** (Weight re-measured untruncated in §9 — 0.97 %, verdict unchanged.) 4.A refuted, 4.B (runtime guard) cannot justify a
compare-and-branch at 1,194 sites for single-digit millions, 4.C already priced
and rejected (+5,568 `noInstance`, +3.3 % `.mlir` for +276 stamps).

Successor: `plans/lss-no-instance-declines.md` — 16,224 sites, the largest
remaining decline class, and the census above already shows where its weight is.

## 9. Re-measured untruncated (2026-09-07) — verdict UNCHANGED, figure 2x

§8's numbers came off a `List.take 80` on the `bmSites` report line, **ranked
by site count**. That is the truncation defect that hid
`System.TypeCheck.IO.andThen` (284 M, 25.94 % of dispatch) from two other
censuses, so §8's `0.48 %` was untrustworthy on its face and had to be redone.

Re-run: `eco-bm3`, built from the current source with both LSS_038/LSS_039
flags on, `bmSites` take raised to 400,000 (untruncated) plus a new
UNTRUNCATED TOTALS line. `cmp bin/bm3.mlir bin/bm3c-out.mlir` — **FIXED
POINT**, so the per-`SpecId` join is valid (§8.4).

### 9.1 The truncation was real but the hidden hosts are cold

Untruncated: **263 `(host, specId)` keys / 1,173 sites / 43 host globals** —
the take-80 was showing about a third of the keys. Every one of the recovered
hosts is cold: 31 of the 43 hosts have **zero** measured generic dispatch.

**`IO.andThen` is not a `bodyMismatch` host at all** — not truncated away, not
present. Its declines are elsewhere. The three `Parse.Primitives.andThen` and
one `Reporting.Result.andThen` keys that *are* present carry 0 dispatch.

### 9.2 The corrected weight

| bound | dispatch | share of 1,097,024,427 |
|---|---|---|
| host-level UB (§8's shape, all 43 hosts) | 69,592,343 | 6.34 % |
| **per-spec (76 of 263 keys carry any dispatch)** | **10,619,712** | **0.97 %** |
| per-site (the n hottest live sites per spec) | 10,439,368 | 0.95 % |

The per-site line barely moves the per-spec one because in every hot
`foldrHelper` spec the bm site count (10) already **exceeds** the number of
live generic sites (7): *all* of those specs' generic dispatch is at
`bodyMismatch` sites. So **0.97 % is close to exact, not merely an upper
bound** — the first figure in this arc that is.

§8's `0.48 %` was low by 2x. It was not low by 10x, as the `p|` census turned
out to be. The host-level UB stays uninformative for the usual reason:
`Dict.foldl` contributes 2.58 % of it with **0 %** of its weight in a
`bodyMismatch` spec, and only 27 % of `foldrHelper`'s 3.15 % is.

### 9.3 Verdict: still closed unbuilt

10.6 M against §7's ~50 M bar. `structural` is still 1,173 / 1,173 with zero
`annoOnly`, so **4.A is still refuted** by its own premise, and 4.B still has
to buy a compare-and-branch at 1,173 sites for under 1 %.

The re-measurement is worth having anyway: it is the first *tight* weight in
this arc, and it retires the open worry that §8's closure rested on a
truncated line.

## 10. Census removed (2026-09-07)

With the verdict settled twice, the `bodyMismatch` census was deleted rather
than left behind a flag. Removed from `AbiCloning.elm`: `classifyDivergence`,
`blindFingerprint`, `instQualGroupCensus`, `bumpBmSite`, the `Group.divergeKind`
field, and the `instQual` fields `hist` / `divergentGroups` / `bmSites` /
`bmKinds`; and six report lines from `Generate.elm`.

`fpUnanimous` and `repFp` STAY — they are LSS_024's fingerprint fence, which is
what *produces* the `bodyMismatch` decline. Only the classifier of an already
made decision went. `declinedBodyMismatch` stays as a scalar counter.

The reason is not cost — at ~43,000 sites the census was a rounding error
against 9.8 B objects per self-compile. It is that a census which is *wrong*
closes plans: this week produced two silent defects (§9, and
`memory: census-join-and-truncation-defects`) that each reported 0.00 % where
the truth was 284 M. Instrumentation for a question that is answered is a
liability, not an asset.

**The surviving census is now behind `lss.census`** (`ECO_MONO_LSS_CENSUS=1`,
hash token `lssCen=`, DEFAULT-OFF) — `byHost`, `niGuard`, `shape`, `papSites`.
Split from `lss.report` for `qCensus`'s reason (`Compiler/Eco/Config.elm`): the
benchmark protocol mandates `ECO_MONO_LSS_REPORT=1`, so anything billed under
`report` distorts every timed run.

The line is drawn at ALLOCATION, not at "census": the scalar counters
(`dispatchUpgraded`, `declined*`, `stamped*`) are field increments and stay
unconditional, because they are the A/B gate numbers every benchmark reports —
gating them would stop a timed run from stating its own result.

**TRAP, and it is the §8.4 trap again:** with `lss.census` off the Dicts read
EMPTY. A census binary must be BUILT AND RUN with the flag on.
