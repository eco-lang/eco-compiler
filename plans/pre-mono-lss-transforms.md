# Pre-mono LSS transforms — outline plan

**Status:** OUTLINE (2026-09-10), lowered the same day into six implementation-ready child plans:

| item | plan | status |
|---|---|---|
| 0 | `pre-mono-lss-transforms-00-assign-mvar-ids-first.md` | ready; step 0a re-verifies the §16 alias fix reproduces 1,865 / 864 |
| 1 | `pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` | **BUILT, DEFAULT-OFF (Sep 10)** — reproduces the hand rewrite line-for-line; BLOCKED on a pre-existing miscompile it exposes (`/work/combinator-uf-devirt-error.md`). See its §9 |
| 2 | `pre-mono-lss-transforms-02-inline-preserve-sets.md` | ready; independent of items 0/1/3/4/5 |
| 3 | `pre-mono-lss-transforms-03-lift-closed-lambda-args.md` | **CLOSED UNBUILT** (2026-09-12) — census ran: all 1,758 `g1absentl` are POST-mono artifacts (1,146 loopify, 612 other reshapes, **0 genuine**; they vanish at `postMono=0`), so a pre-mono lift repairs nothing. Site count inversely ranked to weight AGAIN: `List.foldl` = 60 % of sites, 0.66 % of dispatch; `IO.andThen`/`IO.map` = 10.6 % of sites, 24.95 %. See its §11 |
| 4 | `pre-mono-lss-transforms-04-alias-forwarding.md` | **BUILT, DEFAULT-ON (2026-09-14)** — 15,343 calls + 1,539 values forwarded on the self-compile; measuring it found and fixed a pre-existing emission gap (`CGEN_080`: AbiCloning stamps discarded on `CallDirectKnownSegmentation` closure calls, ≈17 M fast dispatches/compile at the defaults); with the fix, `gen` −0.16 %, `fast` +4.9 M, `out.mlir` −0.36 %, wall flat; bootstrap 8c fixed point byte-identical. Kernel-alias VALUES (v2, §10) still deferred |
| 5 | `pre-mono-lss-transforms-05-determines-caller-binders.md` | **§2.5 BUILT DEFAULT-OFF + MEASURED-OUT; §2.1/§2.4 CLOSED UNBUILT (2026-09-14)** — `inline.skipRefMetas` recovers 136 declines for +34 inlines and a 3-byte `out.mlir` move, dispatch flat (call-stats Runs 15/16). Both target classes are cold: the residual 861 sites are `Pretty.*` (26 calls in 12.5 e9), and §2.1's top 18 hosts are 0.0001 % of runtime calls because `MonoInlineSimplify` already eliminates them. See its §10 |

Two facts established while lowering, recorded once here so the children can cite them: (a)
`TOpt.Link` is NOT an alias node (effect managers and cycle members only), and LSS already folds
KERNEL aliases via `LssInfer.kernelAliasOf` (LSS_016) — item 4's new part is global→global; (b) the
flags-decoder node inserted by `EntryPrep` becomes visible to the pre-mono passes after item 0, and
items 1 and 4 must skip `EntryPrep.flagsDecoderName` (item 1 does).

**A third fact, established by BUILDING item 1 and worth citing before items 3/4/5 touch
anything:** (c) an existing type sub-term may NOT be spliced at a new position — one `ArrowId`
at two occurrences is the LSS_009 shape and `Fresh.assertMinted` rejects it, so every type a
transform places somewhere new must have its arrow slots cleared and be re-minted; and (d) a
callee's arity must be read from the GRAPH, never from its type, because an arrow chain counts
the arrows of its RESULT (a 6-arrow type for a 3-parameter global miscompiled `CombinatorTest`).
Item 1's §2.4 and §2.7 carry both in full.

**Tree state warning (2026-09-10 09:26):** the §16 alias fix and Q1 census fields in
`InlineSimplify.elm`/`Generate.elm` were reverted by a working-tree restore performed outside this
session (git is driven from the host; `/work/.git` is a worktree pointer) and re-applied at 09:48.
They are UNCOMMITTED until committed from the host; a known-good copy is in the session scratchpad
under `good-src/`.

**Origin:** `/work/pre-mono-transformation.md` (the four-question investigation) and
`plans/pre-mono-inline-simplify.md` §11–§16 (the pre-mono inliner, its two blockers, and their
fixes). The ranking below is that report's §6 table, preceded by the IR change that every later
item is written against.

## 0. Why this order

Item 0 changes the IR the pre-mono passes operate on (`TOpt.Expr Name` → `TOpt.Expr MVarId`).
Every later item creates or copies nodes, so writing them against `Name` and porting afterwards is
double work. Item 0 goes first even though it moves no dispatch.

Items 1–5 are in the report's evidence-weighted order: the one class that is both heavy and
measured reachable first (η-expansion, 55.3 % of generic dispatch), then the small configuration
fix that makes `both on` free of the set-loss objection, then the numerous-but-unweighted classes
whose censuses gate them, then the inliner completeness items.

**The two facts every item is checked against** (report §0): (1) pre-mono, nothing can be
destroyed because no LSS identity exists yet — a guarantee that item 0 turns into a DISCIPLINE;
(2) types are frequently still variables pre-mono, and `number` defaulting keys on surviving uses,
so transforms decided by arity, alias structure, closedness or term shape are safe and
type-dependent ones inherit the ceiling.

## Standing gates (every item)

- `.mlir` byte-identical at defaults, and the bootstrap fixed point re-established (a codegen
  change moves the first iteration; the second must be byte-identical).
- Full E2E 887/889 in BOTH arms (`preMono=1 postMono=0` and defaults); the two residual failures
  are `FlagsRecordTest`/`PortEchoTest`, pre-existing.
- `ECO_INLINE_THRESHOLD=0` over the full E2E suite — the check that no transform has become a
  correctness dependency (it found a shipped miscompile the first time it ran, plan §13).
- `PreMonoInlineTest`, `RecordNarrow01/06`, `LetNumberFoldr/ApplyTo`, `PapFastStampTest` as the
  fast smoke — the fixtures that broke §12.
- Census behind `inline.report` (or the item's own report flag); zero cost when off. Flags
  default-OFF until measured under `benchmarks/lss-opt.md`'s protocol; dispatch via a separate
  uprobe run, never read wall under a probe.

---

## Item 0 — run `AssignMVarIds` before the pre-mono inliner; mint on copy

**What.** Move the assignment out of `MonoSolver.monomorphize` (`Monomorphize.elm:90`) to
`Generate.runMonoOptPipeline`, before `InlineSimplify`. The FULL pass runs, unchanged: `MVarId`s
(per-definition `SchemeEnv`, root-merged via `schemeRootsForDef`/`rootEnv`), `SrcLambdaId`s and
`ArrowId`s. The inliner and every later pre-mono pass then operate on `TOpt.GlobalGraph MVarId`
and receive `GlobalMVarState`.

**Mint, not clear.** A copied body needs, per node: a FRESH `SrcLambdaId` for every
`Function`/`TrackedFunction` (from `nextLam`; `Nothing` = memberless, the post-mono failure mode;
a shared id = LSS_009 impersonation across different instantiations); a FRESH `ArrowId` for every
`TLambda` slot (from `nextArrow`; root-backed ids are shared across every occurrence of a solver
root via the GLOBAL `arrowRootEnv`, so copies must not keep them); and for `MVarId`s, substitute
where the call site determines them (`matchType`, as now) and mint fresh from `nextId` otherwise,
copying the super into `superVars` by id. Spliced-in CALLER types keep the caller's ids verbatim.

**What goes away.** The `_pi<n>` TYPE-name suffix in `suffixType`; `withRenamedSupers`
(`varSupers` keyed by name); the "never add renamed names to `schemeRoots`" subtlety; the
`SolverRoot → NoArrow` clearing. The term-level `_pi` rename of `VarLocal` binders STAYS — those
are names the pass never touches.

**What it does not buy.** Grounding. `determines` sees the same variables (caller-polymorphic
520, unsolved locals 188, `number` 22 — all decided on the mono side). Item 5 is what recovers the
first of those.

**The discipline it imposes on items 1, 3, 4.** Identity now exists during the pre-mono passes.
Every node a transform creates must be minted (lambda id, arrow ids, mvar ids) and no id may be
shared between two nodes with different types. A missed mint is a silent shared identity — a
miscompile class, not a crash. Provide ONE helper (`freshenCopy`/`mintNode`) in a shared module and
make every pass use it; a per-pass reimplementation is where the miss will happen.

**Touches.** Both engines under `selectMonomorphizer` and `TestPipeline` need the pre-assigned
entry shape; `InlineSimplify` re-parameterised `Name → MVarId` (`matchType`, `candidateTypeVars`,
`determines`, `suffixExpr` become id-based; the `TAlias` parameter handling of §16 carries over —
alias params are `(MVarId, Type)` pairs and are still alias-local); the §12 unit tests re-pointed.

**Gates.** Byte-identical at defaults (this reorders identity assignment, so the default path must
not move at all); EARLY-arm inline count unchanged from 1,865 (nothing grounded, nothing lost);
`PreMonoInlineTest` in the EARLY arm; full E2E both arms.

## Item 1 — η-expand definitions and continuation lambdas to declared arity (cheapness-gated)

**Class.** The shared state monad, `System.TypeCheck.IO` — 55.3 % of generic dispatch. MEASURED
on probes: `SeqEta` 5 → 1 live generic sites, `StateEta2` → 0, all `singleton_fast`; the residual
is a genuine 3-member set (GAP-6). Report §4.A.

**What.** For a definition `d : T` with body `e` where `expand(T)` (aliases expanded via
`Can.TAlias _ _ _ (Filled|Holey t)`) is `τ₁ -> … -> τₙ -> ρ` with `n` greater than `e`'s
syntactic parameter count, and for a lambda literal in ARGUMENT position whose expected type
expands likewise, rewrite to `\x₁…xₙ -> e x₁ … xₙ`, then beta the adjacent application
(`(andThen f ma) s` → `andThen f ma s`). `IO.andThen`/`map` are ALREADY arity-3
(`IO.elm:239,254`); all 169 callers write `x |> IO.andThen (\r -> …)` — the deficit is entirely
caller-side, which is why this and not arity raising is the transform (report §3.2).

**Why it survives Fact 2.** Arity is read off alias STRUCTURE, known even when the type variable
is not. No ground types needed.

**Do NOT η-expand PAP ARGUMENTS** (`applyI (add 5)` → `applyI (\v -> add 5 v)`): MEASURED
negative (17 → 12 stamps) — LSS_040 already stamps `p|` at 84 % and an `l|` lands in
`g1absentl`. Rule: saturate CALLS; never manufacture lambdas around PAPs (report §3.1).

**Hazards.** (a) Work duplication — a CAF computed once becomes a function re-run per call.
Mandatory GHC-style cheapness gate: expand only when the expression left of the new binders is a
lambda, a variable, a global, a saturated call of a known-cheap global, or a PAP chain of those.
For a bind chain the pre-`s0` work is only PAP construction, so it is a win; `let big = expensive
in \s -> …` is not. (b) `Debug.log`/crash ORDER moves — the hazard `arityRaise` already accepts.
(c) Values of alias-arrow type stored in DATA (`List (IO a)`) are untouched. (d) Specialization
budget: `andThen` has 425 specs today; saturation moves sites from "shared spec, generic inside"
to "per-demand spec, direct inside"; `maxSpecsPerGlobal` guards it.

**Under item 0's discipline.** Every new `Function` node and every new arrow gets minted ids.

**Order of work.** Report-gated CENSUS first: definitions whose declared arity exceeds syntactic
arity, and continuation lambdas likewise, split cheap/non-cheap — on `IO a`-typed code this is the
whole 55 %. Then build, default-off, then the two-arm protocol run plus a dispatch uprobe run.

## Item 2 — `inline.preserveSets`

**Class.** The ONLY set-clearing site on real code: `MonoInlineSimplify.tryInlineCall`'s
strictly-partial branch (`:4838-4882`), 863 of 65,949 inlines (1.31 %), whose stampable subset
weighs 0.245 % of dispatch. Everything else the pass does preserves or is LSS-positive; `both on`
MEASURED at cleared 864 vs 863 alone. Report §2.

**What.** Decline the strictly-partial inline (return `Nothing`, leave the PAP for LSS_040's `p|`
stamp) instead of minting an identity-less residual. One Bool on `RewriteCtx` from
`inline.preserveSets`, hash token; the same guard on `betaReduce`'s partial branch (`:3194`, dead
today) for symmetry. ~15 lines.

**Why.** With it on, the post-mono pass has no clearing site, so `preMono=1 postMono=1` carries
no "loses sets" objection — the configuration the user actually wants to run.

**Expected.** FLAT on wall and dispatch (plan §8 fact 2: clearing does not reduce stamping at the
aggregate). One protocol run to confirm; the reshape census must read `cleared=0`.

## Item 3 — lambda-lift CLOSED lambda arguments to top-level globals

**Class.** `g1absentl` — an `l|` member with no instance in AbiCloning's index — 1,439 sites
(decline census #4); the non-IO residue of group D. Weight UNMEASURED (site count only). MEASURED
on probe: `LiftLam` 1 `generic_apply` → `LiftFn` 0, the callee becomes `g|ins` and mono
substitutes it (`g2global`), emitted as `eco.call`. Report §3.4.

**What.** A lambda literal in argument position with NO free locals becomes a fresh top-level
`Define` (a new `Global`, minted ids), and the argument becomes `VarGlobal`. Closedness is
syntactic — Fact-2-immune. Capturing lambdas are excluded: lifting would turn captures into
parameters and change the HOF's interface.

**Order of work.** CENSUS FIRST — one report line classifying `g1absentl` sites closed/capturing.
This arc has mispredicted from site counts four times; the self-compile's continuations are mostly
capturing, so the closed share may be small. Build only if the closed share is worth it; measure
dispatch, not sites.

**Note.** General lambda lifting has no LSS gain (a closed `l|` callback stamps identically to a
`g|`; zero-capture closures are already interned). This item is the argument-position case only.

## Item 4 — alias forwarding pre-mono

**Class.** ≈35,100 of LATE's 66,301 inlines (53 %) are parameter-less alias forwards —
`Basics.add = Elm.Kernel.Basics.add`, `append`, `eq`, `List.cons`, `Task.succeed/andThen`,
`Doc.fromChars = P.text`, `Leijen.text = P.string`, `Bytes.Encode.*` — which the pre-mono inliner
skips at `List.isEmpty params` / `bodyOf`. ≈14k source sites. MEASURED by census join. Report §1.3
R3.

**What.** `Call (VarGlobal f) args` → `Call (VarGlobal g | VarKernel …) args` where `f`'s body is
a bare reference, with `f`'s reference meta replaced by the alias body's; iterate to a fixpoint for
chains. No type reasoning, no lambda, no lambda set touched — LSS then sees the REAL callee
(`g|Pretty.string`) instead of a wrapper, which is a §3/§4 win as much as a completeness one.

**Under item 0's discipline.** Creates no nodes; the replaced reference meta carries the alias
body's ids (a generic reference type, the normal shape `translateVarRef` already receives).

**This makes the two inliner positions comparable in coverage.** LATE's 66k is 27,130 source
sites × 2.43 per-spec multiplicity; a complete pre-mono pass tops out near 27k. With forwarding
the EARLY arm reaches most of the source sites even though it will never match the count.

## Item 5 — `determines`: accept caller-binder bindings

**Class.** 520 of the remaining 864 `undetermined` calls are bound to the CALLER's own scheme
binder (`Array a -> Int` called inside a function polymorphic in `a`). MEASURED census; +≈450
inlines net. Report §1.3 R1.

**What.** A bound type is acceptable if it is ground OR every free variable is a binder of the
enclosing definition's annotation `Forall` (an `MVarId` present in the caller's annotation after
item 0). Substitute verbatim. Sound because inside the copy the variable is then an ordinary
occurrence of the caller's own scheme variable — `AssignMVarIds.rewriteNodes` gives each top-level
node one `SchemeEnv`, and `ensureBinder` yields the SAME id as every other occurrence in the
caller's body; the `let p = arg` wrappers are today's un-annotated-let shape (`withFreshBinding`,
`translateLet` defers to the body type when the declared one has MVars).

**Exclude bottom-shaped callees** — a result that is a bare variable absent from every parameter
(`crash : String -> a`, 68 sites) — which re-expose the per-name kernel ABI conflict
(`Eco_Kernel_Crash_crash` registered as two ABIs, plan §15.3).

**Follow-ons in the same vein, smaller:** R2 ignore reference-node metas in `candidateTypeVars`
(+≈150); R4 port `kernelCostClasses` to the pre-mono `cost` (LATE inlines 8,954 of pre-mono
over-budget callees, bounded +≈1,470 source sites); per-round re-costing in `rounds`.

---

## Per-item gate summary

| item | flag | census first? | pass gate | measurement |
|---|---|---|---|---|
| 0 | none (IR move) | no | byte-identical at defaults; EARLY inline count = 1,865; both-arm E2E | none — no dispatch change expected |
| 1 | new, default-off | YES (arity-deficit census, cheap/non-cheap) | both-arm E2E; `ECO_INLINE_THRESHOLD=0` leg | protocol two-arm + dispatch uprobe; headline = generic dispatch at the IO-monad specs |
| 2 | `inline.preserveSets`, default-off | no | reshape census `cleared=0`; both-arm E2E | one protocol run; expect FLAT |
| 3 | ~~new, default-off~~ CLOSED UNBUILT | census RAN 2026-09-12 | — | — (genuine population measured at ZERO; see item 3's §11) |
| 4 | fold into `inline.preMono` | no | byte-identical at defaults; EARLY count; both-arm E2E | EARLY-arm inline census; then Run-AT-style two-arm |
| 5 | fold into `inline.preMono` | no (census done) | `PreMonoInlineTest`; both-arm E2E | EARLY-arm inline census, +≈450 |

## Out of scope, recorded so nobody re-derives it

Arity raising pre-mono (its named target, `IO.andThen`, is already arity-3 — subsumed by item 1);
higher-order inlining on syntactic-lambda arguments (fold callbacks already 100 % stamped via
Fix A; breaks `number` defaulting); η-expansion of PAP arguments (measured negative); uncurrying
callback types (Fix B — moves LSS_006 ordinals); general lambda lifting / let-floating /
case-of-known-constructor (LSS-neutral); source defunctionalization (needs the sets — GAP-6,
post-LSS). Not source-reachable at all: over-application re-entry (9.9 %), the kernel callback
boundary (12.4 %), μ-tie `blocked` (6,618), the kernel-ABI ⊤ manufacturers.
