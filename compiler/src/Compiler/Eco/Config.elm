module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash, clamp
    , BorrowConfig, BorrowReify(..), CafHoistConfig, CafMemoConfig, CseConfig, ListConfig, LssConfig, LssFlowConfig, LssSettleConfig, LssStageAnchorConfig, LssStampConfig, MonoConfig, MonoEngine(..), SpecLimits, borrowReifyFromString, defaultLimits, defaultLss, monoEngineFromString
    )

{-| Project-level tunable compiler settings, read from `eco-config.json`
beside `elm.json`. Pure data + decoder + a stable cache key; the IO that
reads the file lives in `Builder.Eco.Config`.

All fields are optional in the JSON and merge over `default`, so a partial
or absent config reproduces the built-in behaviour exactly.


# Types

@docs EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig


# Values

@docs default, decoder, hash, clamp

-}

import Compiler.Json.Decode as D


{-| The full effective configuration.
-}
type alias EcoConfig =
    { inline : InlineConfig
    , bytesFusion : BytesFusionConfig
    , logicalTypes : LogicalTypesConfig
    , cafMemo : CafMemoConfig
    , mono : MonoConfig
    , borrow : BorrowConfig
    , list : ListConfig
    , aggPromote : Bool -- U-T1.3.1 (plans/opt-tier1-aggregate-promotion.md): emit eco.make.tuple2/3 for let-bound tuples proven non-escaping by the per-def use walk; DEFAULT-ON since 2026-08-04 (ship config); env ECO_AGG_PROMOTE=0 disables; artifact-affecting (hash token "aggp")
    , ctorInline : Bool -- U-T1.3.2c (plans/opt-tier1-aggregate-promotion.md): saturated direct ctor calls emit eco.construct.custom inline in the caller (call overhead erased; nullary excluded — intercepted one level up as embedded null-cons constants via Ctx.nullConsBySpec, plans/null-cons-hpointer-embedding.md); DEFAULT-ON since 2026-08-04 (ship config); env ECO_CTOR_INLINE=0 disables; artifact-affecting (hash token "ctori")
    , sretResults : Bool -- U-T1.3.3 (plans/opt-tier1-aggregate-promotion.md): result promotion via the sret ABI — functions returning a locally-constructed tuple2/3 gain a multi-result $sret worker (caller-slot ABI, CGEN_067); destructuring call sites migrate per-site; DEFAULT-ON since 2026-08-04 (ship config); env ECO_SRET_RESULTS=0 disables; artifact-affecting (hash token "sretr")
    , psplitParams : Bool -- U-T1.3.5 (plans/opt-tier1-aggregate-promotion.md): param-side promotion — projection-only tuple2/3 / single-ctor-custom params gain a $psplit worker taking the fields as scalars; call sites with free-slot args migrate per-site; DEFAULT-ON since 2026-08-04 (ship config); env ECO_PSPLIT_PARAMS=0 disables; artifact-affecting (hash token "psplit")
    , sretFresh : Bool -- U-T1.3.8: widen sretResults selection to helper-mediated results — a result leaf that IS a direct call to an already-promoted callee with identical slots is admissible (selection fixpoint); emission feeds the multi-result $sret call through. DEFAULT-ON since 2026-08-04 (user decision; measured neutral, Run M); env ECO_SRET_FRESH=0 disables; artifact-affecting when enabled (hash token "sretf=1"); no-op unless sretResults
    , sretTailFuncs : Bool -- U-T1.3.6: widen sretResults selection to tail funcs (result columns through the while loop). DEFAULT-ON since 2026-08-04 (user decision, ACCEPTING the measured ~+4% wall self-compile regression — 2026-08-03 isolation A/B: it cancelled T1.3.3's −4% exactly; per-iteration slot-column carry in hot loops); env ECO_SRET_TAILFUNC=0 disables; artifact-affecting when enabled (hash token "srtf=1"); no-op unless sretResults
    , stringLengthOp : Bool -- kernel-opt-04: emit eco.string.length (an inline header-size load) instead of the Elm_Kernel_String_length call. DEFAULT-ON since 2026-08-11 (all 101 self-compile call sites convert; wall FLAT at -0.12%, so it ships for the deleted calls and statepoints, not a measured win); env kill switch ECO_STRING_LENGTH_OP=0; artifact-affecting (hash token "strlen=1" when enabled). The BACKEND knob ECO_STRING_LEN_INLINE=0 separately chooses a plain kernel call as the lowering, needing no compiler rebuild
    , appendSplit : Bool -- kernel-opt-05: split Elm_Kernel_Utils_append into typed eco.string.append / eco.list.append at mono sites that statically know the operand type. DEFAULT-ON since 2026-08-11 (3,468 self-compile sites -> 67; 2,695 string + 706 list; wall FLAT at +0.80%, so it ships for the typed boundary and the deleted runtime dispatch, not a measured win); env kill switch ECO_APPEND_SPLIT=0; artifact-affecting (hash token "apsplit=1" when enabled). Polymorphic residue (any MVar operand) keeps the kernel call
    , stringOrderIntrinsic : Bool -- kernel-opt-06: lower Utils.lt/le/gt/ge on [MString,MString] to eco.string.cmp3 + a SIGNED sign test against 0, instead of the boxed kernel call + eco.unbox. DEFAULT-ON since 2026-08-11 (95 of 121 sites convert: lt 79->14, gt 40->10, ge 2->2; wall FLAT at -0.34%); env kill switch ECO_STRING_ORDER_INTRINSIC=0; artifact-affecting (hash token "strord=1")
    , valueEq : Bool -- kernel-opt-03: lower boxed structural equality to eco.value.eq (word-equality / embedded-constant / kernel-call diamond) instead of a boxed Elm_Kernel_Utils_equal call + eco.unbox. DEFAULT-ON since 2026-08-11 (all 1,452 self-compile Utils_equal/notEqual sites convert; wall -1.84%, inside the noise band so recorded FLAT); env kill switch ECO_VALUE_EQ=0; artifact-affecting (hash token "veq=1"). Bool == is NOT gated by this -- it is unconditionally better
    , kernelGcLeaf : Bool -- kernel-opt-08 (CGEN_072(f)/KERNEL_FACTS_001): stamp `eco.gc_leaf` on the func.func decl of every kernel whose KernelFacts row is gcLeafEligible, so the backend may attach gc-leaf-function and RS4GC skips statepointing its call sites. DEFAULT-ON since 2026-08-12 (10 of the 14 eligible kernels still have stubs to stamp -- the other 4 lost their call sites to kernel-opt-03/04/06; +2,223 de-statepointed sites, binary -287,952 B of which 99% is .llvm_stackmaps; wall FLAT at -1.25%); env kill switch ECO_KERNEL_GCLEAF_EMIT=0; artifact-affecting (hash token "kgcl=1"). The BACKEND kill switch ECO_KERNEL_GCLEAF=0 separately ignores an attr already in the .mlir
    , callPurityAttrs : Bool -- kernel-opt-12 (plans/kernel-opt-12-eco-call-purity-attr.md): stamp `eco.cse_safe` on direct eco.call ops whose KernelFacts row derives `droppable` (cseSafe AND totality == Total); licenses MLIR merge+DCE of those calls before EcoGCPrepare, which strips the attr. DEFAULT-ON since 2026-08-13 (Run R: byte-identical binary with CSE off, exe -16 KB and bit-identical counters with CSE on -- free either way); env kill switch ECO_CALL_PURITY=0; artifact-affecting (hash token "cpur=1")
    , cse : CseConfig
    }


{-| Mono-level CSE knobs (kernel-opt-13, executing plans/cse-pure-calls.md).

`enabled` runs `MonoCse` over the post-GlobalOpt graph, merging structurally
equal pure calls at bounded distance; DEFAULT-OFF, artifact-affecting (hash
token `cse=1`). `report` is the C1 census, stderr-only and **excluded from
`hash`** (pattern: `list.report`). `minCost` is the cost floor below which a
candidate is not worth a let binding, and `maxPerDef` caps groups per body so a
pathological definition cannot blow up compile time; both contribute a hash
token only when `enabled` AND non-default.

-}
type alias CseConfig =
    { enabled : Bool
    , report : Bool
    , minCost : Int
    , maxPerDef : Int
    }


{-| Chunked-list knobs (plans/chunked-list-representation.md §6).
`chunks = True` (the default since the quiet-window wall verdict, Aug 3
2026: parity wall, lower minor-GC time and RSS, −4.28% objects) enables
hybrid chunk spines; `chunks = False` (JSON `"chunks": false` or env
`ECO_LIST_CHUNKS=0`) reproduces the pre-chunk pipeline byte-for-byte.
`chunks` is artifact-affecting (hash token `lchunks=1` when enabled; L1.2+
codegen consults it). `consIntrinsic` (kernel-opt-01, DEFAULT TRUE since 2026-08-10) lowers saturated
`x :: xs` to `eco.construct.list` instead of `Elm_Kernel_List_cons*`, so each
cons pays the HEAP\_034 inline nursery bump instead of a statepointed runtime
call; env kill switch `ECO_LIST_CONS_INTRINSIC=0`, artifact-affecting (hash
token `lcons=1` when enabled). Measured on the self-compile: all 4,304 kernel
cons call sites convert, EcoListTemplate chunk parity is exact, and wall is
FLAT (+0.36%, inside the noise band) — it ships for the deleted call sites and
statepoints, not for a measured wall win. `mapTemplate`
(plans/list-map-mlir-template.md, DEFAULT FALSE at landing) replaces the body
of a LICENSED `List.map` specialization with a forward-iterating
`eco.list.map` op instead of the elm/core foldr lowering; licensing needs a
transitive Debug-freedom proof on the callback (policy D-4a) and is computed
by `Compiler.GlobalOpt.MapTemplate`. Env `ECO_LIST_MAP_TEMPLATE=1`;
artifact-affecting (hash token `lmapt=1` when enabled); inert unless `chunks`
is also on, since the scratch/chunk machinery is the substrate. `report` (env
`ECO_LIST_REPORT=1`, never from JSON) renders the combinator-recognition
census to stderr — output-only, excluded from `hash`.
-}
type alias ListConfig =
    { chunks : Bool
    , consIntrinsic : Bool
    , mapTemplate : Bool
    , report : Bool
    }


{-| Borrow-inference (GlobalOpt Phase 6) knobs (design §6, D2: top-level,
engine-agnostic). `enabled = False` reproduces today's pipeline byte-for-byte
(the pass is not run). `reify = ROff` runs the analysis as an inert census
oracle (graph returned unchanged); `RRc` (unused until B4) emits RC ops.
`report`/`validate` are output-only and excluded from `hash`.

`oracleOpt` (OC0.1, plans/borrow-oracle-consumers.md; env `ECO_BORROW_OPT=1`)
opts a build into the oracle-coupled transforms (OC1+): the distilled facts
are derived at MLIR-emission time (`Borrow.deriveFacts`) and consumed by
codegen. ARTIFACT-AFFECTING — the only borrow knob in `hash` (token
`bopt=1`); default off preserves T1-R1 for default builds.

-}
type alias BorrowConfig =
    { enabled : Bool
    , reify : BorrowReify
    , report : Bool
    , validate : Bool
    , oracleOpt : Bool
    }


type BorrowReify
    = ROff
    | RRc


{-| Which monomorphizer engine to run.

  - `EngineSubst`: the original Dict-substitution engine
    (`Compiler.Monomorphize.Monomorphize`). Reproduces the legacy behaviour.
  - `EngineSolver` (default): the solver-based engine (`Compiler.MonoSolver.Monomorphize`).
  - `EngineDiff`: run both and assert their MonoGraph output matches — the A/B
    gate. Emits the original engine's graph so the build still succeeds.

-}
type MonoEngine
    = EngineSubst
    | EngineSolver
    | EngineDiff


{-| Monomorphizer selection + debug knobs.

`diffDump` (env `ECO_MONO_DIFF_DUMP=1`, never from JSON) makes `EngineDiff`
embed both `Debug.toString` renderings in the mismatch error for offline diff.

-}
type alias MonoConfig =
    { engine : MonoEngine
    , diffDump : Bool
    , validate : Bool -- env ECO_MONO_VALIDATE=1, never from JSON: run the MONO_029 layout-agreement validator after mono and FAIL the compile on violations (output-only, excluded from hash — a failed compile is never cached)
    , lss : LssConfig
    , limits : SpecLimits -- MONO_030 spec watchdogs; failure-only, EXCLUDED from `hash`
    }


{-| MONO\_030 spec watchdogs (`plans/lss-fidelity-1-watchdogs-budget-accounting.md`
§1): loud, clean failures replacing the silent hang/OOM the monomorphizer
otherwise runs into on polymorphic recursion (expressible in legal Elm through
annotated mutual cycles — see `plans/monomorphization-plan.md` §3's correction
note) or unbounded type growth. `0` disables a limit.

Env overrides: `ECO_SPEC_TYPE_NODE_LIMIT` / `ECO_SPEC_BREADTH_LIMIT`.

**Excluded from `hash`**: the watchdogs never change the output of a PASSING
compile (a failed compile is never cached), so limits are freely tunable
without invalidating artifact caches — the same class as `report`/`validate`/
`diffDump`.

-}
type alias SpecLimits =
    { specTypeNodes : Int -- max logical MonoType nodes in one spec's demanded type
    , specBreadth : Int -- max CREATED specs for one global
    }


{-| Defaults chosen ≥25× the observed self-compile maxima (breadth: 1,939
specs for `List.foldl` on the Aug-4 census; key sizes ~10³ nodes) so they can
never false-positive on real programs while still bounding runaways.
-}
defaultLimits : SpecLimits
defaultLimits =
    { specTypeNodes = 400000
    , specBreadth = 50000
    }


{-| Lambda-set specialization knobs (design\_docs/monomorphization/
lambda-set-specialization-design.md §10). `enabled = False` must reproduce
today's pipeline byte-for-byte: every arrow annotation is `LTop` and no set
slots are minted in solver stores. Only meaningful under `EngineSolver`;
`EngineDiff` always forces it off (the subst engine cannot produce sets).

  - `enabled`: master switch (M2+).
  - `keyed`: lambda sets participate in specialization keys (M4+) — ALL
    globals.
  - `keyedGlobals`: E5 selective keying — key ONLY these globals (user format
    `author/project:Module.Name.value`, e.g. `elm/core:List.foldl`); the
    engine converts to comparable gkeys at init. Irrelevant when `keyed` is
    already True.
  - `maxSetSize`: a zonked set larger than this widens to `LTop`;
    **0 = UNLIMITED, and 0 is the DEFAULT since 2026-08-29** (was 8, user
    decision): a whole self-compile produces exactly 8 oversize sets
    (6×9, 1×12, 1×21), so the limit bought nothing and cost precision
    (plans/lss-provenance-join-and-demand-sigs.md §4.7).
    `ECO_MONO_LSS_MAX_SET_SIZE` overrides; enforced at the two
    Store readback caps and the two signature-channel B.4 riders.
  - `maxSpecsPerGlobal`: registry budget; past it, NEW demands key set-widened;
    **0 = UNLIMITED, and 0 is the DEFAULT since 2026-08-29** (was 512 since
    2026-08-23, 64 before; user decision). The §4.7 same-binary A/B killed
    all 8,818 budget-widen events for ZERO wall/RSS cost, positions +5,584,
    coverage ratio +0.44 pp, top −31 — budget widening is KEY-MINTING
    policy, not a ⊤ manufacturer, and since LSS\_018 μ-tie the budget is
    fan-out POLICY, not a termination requirement (see `muTie` below).
    History: the 2026-08-22 sweep (`/work/lss-knob-sweeps-report.md`) showed
    dispatch flat 512→4096; the elm-aws-codegen pathological-workload class
    (§11.7 census note) was the reason to keep a backstop — that class is now
    the WATCH ITEM for this raise, and `ECO_MONO_LSS_MAX_SPECS` restores any
    budget without a rebuild. NOTE: pre-2026-08-29 experiments that set the
    budget to 0 meant ZERO budget (everything widened) — that configuration
    is now spelled `ECO_MONO_LSS_MAX_SPECS=1`-ish, not 0. Artifact-affecting;
    hash token `lssB=<n>` when non-default, so a build pinned to another
    budget keys its own cache entries.
  - `report`: render an LSS census to stderr after mono (excluded from `hash`,
    like `diffDump` — output-only).

-}
type alias LssConfig =
    { enabled : Bool
    , keyed : Bool
    , keyedGlobals : List String
    , devirtFnGlobals : Bool
    , maxSetSize : Int
    , maxSpecsPerGlobal : Int
    , report : Bool

    -- S.10 (F-5C): inject standalone members through the first
    -- `declaredArity` arrows instead of the head arrow only, so a
    -- partially-applied global or ctor still carries a resolvable member at
    -- the callback position. Default OFF: it is artifact-affecting when
    -- enabled (hash token `lssSA=1`), and the soundness argument scopes it
    -- to `g|`/`c|` mints — kernels stay head-only.
    , spineArity : Bool

    -- LSS_018 μ-tie (plans/lss-fidelity-1-watchdogs-budget-accounting.md §2):
    -- a lambda mint whose enclosing spec's demand already carries a qualified
    -- member of the same raw lambda reuses that id, closing the
    -- specs→qualified-members→keys spiral WITHOUT the budget, which demotes
    -- `maxSpecsPerGlobal` from load-bearing terminator to fan-out policy.
    -- Tied members are AbiCloning-blocked (never rep-stamp — plan §2.4).
    --
    -- DEFAULT-ON since 2026-08-18 (B3), on measured evidence: the mechanism
    -- is proven by a forced-spiral fixture (65 specs → 2 —
    -- tests/TestLogic/Monomorphize/MuTieTest.elm), while on the self-compile
    -- the eligible population is ZERO, so enabling it is behavior-neutral
    -- there (byte-identical MLIR) at unmeasurable cost (wall/GC counters
    -- identical; benchmarks/lss-opt.md Run M). Artifact-affecting when it
    -- differs from this default (hash token `lssMU=0` then).
    , muTie : Bool

    -- LSS_019 standalone-member grounding (GAP-1,
    -- plans/lss-fidelity-2-standalone-member-grounding.md): a provisional
    -- `g|`/`c|` member read back from a set slot at a residual-free arrow is
    -- rewritten at zonk to the ground member `g|<global>|<arrow-typeKey>` —
    -- element identity becomes (global × instantiation layout), the paper's
    -- post-substitution element identity. Artifact-affecting under keyed
    -- routing (member ids → annotations → keyed spec keys → fan-out); hash
    -- token `lssGS=` when it differs from this default.
    --
    -- DEFAULT-ON since 2026-08-19 (G3), on measured evidence: self-compile
    -- grounded=4,955 / deferred=11 with joinRounds, devirt counters, budget
    -- widening and spec fan-out all UNMOVED vs flag-off on the same tree
    -- (byBudget 36,691→36,693; devirtDirect 3,984 both; foldl=2,052 both);
    -- flag-on E2E 1,682/1,682 and the Stage-8c bootstrap fixed point is
    -- byte-identical. The feared budget-pressure spiral from finer ids is
    -- unrealized on this workload; plan 1's watchdogs + μ-tie stay armed.
    , groundStandalones : Bool

    -- LSS_020 signature set-flow completion (GAP-2,
    -- plans/lss-fidelity-3-signature-flow-completion.md §B): the inference
    -- walk connects ground-typed intra-def flow to signature slots
    -- (member-root joins, param binding, If/Case hubs, Let rhs joins,
    -- local-callee call shapes — all set-slot-only), so def signatures stop
    -- being trivial and callers receive rep links + members. Includes the
    -- signature-channel maxSetSize widening rider (`widenedBySigSize`).
    -- Artifact-affecting under keyed routing (signature members reach caller
    -- instantiations → annotations → keys); hash token `lssSF=` when it
    -- differs from this default.
    --
    -- DEFAULT-ON since 2026-08-21 (the lss-directed-set-flow §8.3 flip,
    -- re-opened and taken after LSS_024): LSS_023's directed edges made the
    -- mono wall FLAT (lss-opt Run AC) and LSS_024 removed the runtime
    -- de-stamp that was the flip's only recorded blocker — with
    -- layoutQualMembers on, the sigFlow arm BEATS the sf-off baseline on
    -- fast dispatch (runtime-calls Run AC: coverage 8.34% vs 8.32%,
    -- +192K fast events; sat+fast invariant). Landed as its own battery
    -- (never coupled with the layoutQualMembers flip): E2E full,
    -- elm-tests, Stage-4b/8c bootstrap fixed points, same-corpus rail.
    , sigFlow : Bool

    -- LSS_024 layout-qualified lambda-instance members + the AbiCloning
    -- fingerprint fence (plans/lss-layout-qualified-members.md): a
    -- keyed-routed lambda mint qualifies by the enclosing spec's immutable
    -- annotation-widened creation key (`l|<raw>|<widenedKey>`) instead of its
    -- SpecId, so annotation-only spec splits mint ONE member id and consumer
    -- slots stay singletons; AbiCloning representative stamps additionally
    -- require fingerprint unanimity across the group (`bodyMismatch` decline
    -- otherwise — the E11 same-layout divergent-clone fence). Artifact-
    -- affecting under keyed routing (member ids → annotations → keys →
    -- fan-out); hash token `lssLQ=` when it differs from this default.
    --
    -- DEFAULT-ON since 2026-08-21 (the plan's §6.4a flip), on measured
    -- evidence: runtime-calls Run AC — 100.8% of the 23.5M-event sigFlow
    -- fast-dispatch gap recovered (coverage 6.10%→8.34%, ABOVE the sf-off
    -- baseline); lss-opt Run AD — wall FLAT, majors identical; full
    -- battery + Stage-4b/8c bootstrap fixed points. Recorded flip deltas:
    -- four HEAD-stamped non-verbatim `Dict.map` multi-groups become
    -- `bodyMismatch` declines (the fence's soundness rationale), and the
    -- §7.2 Borrow obligation landed with the flip (BORROW_006 fence in
    -- `Borrow.buildLambdaSigs`, `lambdaSigMeets` census).
    , layoutQualMembers : Bool

    -- E9.5 post-settle devirt (plans/lss-post-settle-fn-global-devirt.md):
    -- at AbiCloning, rewrite a singleton g|/c| noInstance call site (plain
    -- local callee, exact arity) to a DIRECT call of the lowest-SpecId
    -- eqLayout-matching spec of the member's origin global/ctor — the
    -- commit-after-settle completion of E9.1's translate-time arm (LSS_025).
    -- DEFAULT-ON since 2026-08-22 (user-directed flip, same day as the
    -- landing battery: devirtPost 86/311/0 census-exact, minor/major GC
    -- identical across arms, byte-identity + determinism + E2E both arms +
    -- elm-tests green — lss-opt Run AE; ECO_MONO_LSS_DEVIRT_POST=0 is the
    -- escape hatch). Built on the reach-completeness criterion — the
    -- self-compile heat of the population is ≈0.24% upper bound (plan
    -- §2.R); the point is closing the exploitation gap for workloads that
    -- pass bare globals/ctors around more than a compiler does.
    , postSettleDevirt : Bool

    -- Phase 2a arrow identity (plans/lss-unknown-elimination.md §4):
    -- `Can.TLambda` carries a per-OCCURRENCE `ArrowId`, and `Store.loadTypeC`
    -- memoises one SET SLOT per id per item, so repeated loads of the SAME
    -- stamped type object share their lambda-set slots instead of minting a
    -- disjoint slot each time (LSS_006's per-load fragmentation — the reason
    -- ~11 hand-written transport artifacts exist).
    --
    -- DEFAULT-ON since 2026-08-25 (plans/lss-paper-inclusion-constraints.md
    -- §5.A3). §0.3 measured that this switch ALONE closes both transport gaps
    -- the paper-fidelity work set out to close — the list-literal probe goes
    -- `kN=0` -> `kN=1` and the Task probe `kN=0` -> `kN=4`, with the members
    -- exactly the two globals in question — because the mechanism was LSS_006
    -- slot-disjointness, not a missing set variable.
    --
    -- The ids are minted unconditionally (harmless — nothing reads them when
    -- this is off) but the MEMO is gated, so flag-OFF remains byte-identical
    -- to pre-2a and the two-binary rail still applies in that direction.
    -- Artifact-affecting, so the hash token `lssAI=0` now rides the OFF arm.
    -- Escape hatch: `ECO_MONO_LSS_ARROW_ID=0`.
    , arrowIdentity : Bool

    -- Phase 2b solver-root arrow ids (plans/lss-unknown-elimination.md §4.9).
    -- Requires `arrowIdentity`. Instead of one id per SYNTACTIC arrow
    -- occurrence, take the id from the arrow's union-find ROOT — so two arrows
    -- the type checker UNIFIED share a lambda-set slot. EXP-2a measured why
    -- this matters: a def's annotation and its body node's type are
    -- structurally-equal DISTINCT objects 97.5% of the time (§10.4), so
    -- occurrence ids cannot tie them and solver identity can.
    --
    -- DEFAULT-ON since 2026-09-16 (call-stats Runs 25/26): completeness first
    -- — coverage 98.98 % -> 99.05 %, `var` 851 -> 593 — at the priced cost
    -- §10.9 predicted: slot sharing WITHOUT a per-use set variable trades the
    -- context sensitivity that manufactures usable singletons (`k1` −506,
    -- `⊤` +152, fast dispatch share −2.73 pp, wall flat). Subsumes
    -- `sigRootIdentity` (Run 27: byte-identical emission with it off), which
    -- went default-off in the same flip. Escape hatch
    -- `ECO_MONO_LSS_ARROW_ROOTS=0`; hash token `lssAR=0` rides the OFF arm.
    , arrowSolverRoots : Bool

    -- §5.2/§5.3 (plans/lss-paper-inclusion-constraints.md): consume the
    -- signature as the paper's SCHEME `d⟨ᾱ⟩ : (Q ⇒ τ)` rather than as a
    -- pre-solved answer.
    --
    -- Flag-OFF is today's path: `applyFacts` copies `ArrowFact.members` into
    -- the instantiation's slots, and a def's set variables are committed by
    -- the eager write that put them there.
    --
    -- Flag-ON instantiates: freshen `ᾱ` (the fresh slots), tie the ordinals
    -- that share a `rep` into one variable, then re-emit `Q` against those
    -- variables; and at the def boundary internalize the variables that do NOT
    -- reach the signature to `S(Q,α)`, the paper's minimal solution, instead
    -- of reading whatever the eager union left behind.
    --
    -- DEFAULT-OFF. Hash token `lssQS=1`; env `ECO_MONO_LSS_QSOLVE`.
    , qSolve : Bool

    -- §5.4 (GAP-A): classify a bare global reference STORE-AWARE when its type
    -- mentions an arrow, instead of with the storeless classifier that stamps
    -- LTop on every arrow. `translateGlobalCall` already gates that classifier
    -- on `lssFastOk`; `translateVarRef` did not, which poisoned every bare
    -- reference's arrows before a member could reach them.
    --
    -- DEFAULT-ON since 2026-08-26, on the day's full battery: analysis
    -- coverage +7.14 pp at artifact positions (16.59% -> 23.73%, `coverage:`
    -- census line — the largest single completeness gain measured in this
    -- arc), `top` positions -7,754, `kN` positions 682 -> 2,276; mono wall
    -- +0.60% = FLAT (lss-opt Run AN — Run AM's +4.3% was the Q verifier
    -- billing the census, not the change); runtime dispatch NEUTRAL to the
    -- event (-274 fast of 560M, one spec split, runtime-calls Run AO);
    -- self-compile lowers both arms (0 undefined fast evaluator); E2E
    -- `--target full` 1,691/1,691 with every test freshly compiled flag-on;
    -- elm-tests 13,355/12 = the pre-existing failure set exactly. Escape
    -- hatch `ECO_MONO_LSS_REF_IDENTITY=0`; hash token `lssRI=0` now rides
    -- the OFF arm.
    , refIdentity : Bool

    -- §5.1/§5.6 shadow `Q` (plans/lss-paper-inclusion-constraints.md): record
    -- every `ℓ ⋸ σ` the solver emits, solve it at the inference boundary, and
    -- score it against what the eager path left in the store.
    --
    -- SPLIT FROM `report` 2026-08-26. It used to ride `lss.report`, and the
    -- benchmark protocol MANDATES `ECO_MONO_LSS_REPORT=1` — so every timed run
    -- paid for recording ~106k constraints per compile plus a solve and a
    -- reachability walk per inference unit, inside the measured wall/RSS/GC.
    --
    -- This is a VERIFIER, not a census to read once: it is the standing guard
    -- on LSS_037 — every path that puts a member in a slot must be a recorded
    -- constraint. Turn it on when a write path changes.
    --
    -- DEFAULT-OFF. Hash token `lssQC=1`; env `ECO_MONO_LSS_QCENSUS`.
    , qCensus : Bool

    -- INJECTION COMPLETENESS (plans/lss-injection-completeness.md): a PARTIAL
    -- application of a known global is a PAP of that global, so the callee's
    -- member is sound on the residual arrows (LSS_013's arity bound: "a PAP of
    -- member m is m"). It is the ONE producer form that injects nothing today
    -- — P0's injection-totality census measured 3,624 such positions on the
    -- self-compile, ≥84 % of the whole totality gap — and that hole is what
    -- manufactured the `arrowSolverRoots` false singleton that compiled
    -- `Task.map f` into the identity map.
    --
    -- This is the paper's own soundness mechanism, not a mitigation: L^src has
    -- no currying, so `(::) x` is necessarily a λ there and `𝒬` injects EVERY
    -- λ (Fig. 6) — the false singleton cannot form, and no ⊤-widening is
    -- needed. Injecting here restores that property.
    --
    -- Artifact-affecting (members → annotations → keyed spec keys → fan-out).
    -- DEFAULT-ON since 2026-08-27: +4.20 pp analysis coverage, all gates green
    -- (E2E 1,691/1,691, `Q` REPRODUCES, elm-tests at the pre-existing set).
    -- Flipped TOGETHER WITH `sigRootIdentity`, and it must never be the one
    -- turned off while that stays on — see the REQUIRES note there; the pair
    -- is a soundness constraint, not a preference. Escape hatch
    -- `ECO_MONO_LSS_PAP_MEMBERS=0`; hash token `lssPM=0` now rides the OFF arm.
    , papMembers : Bool

    -- SOLVER-ROOT SIGNATURE IDENTITY
    -- (plans/lss-solver-root-signature-identity.md): inside the INFERENCE
    -- scratch store only, key an arrow's lambda-set slot by the type
    -- checker's union-find ROOT instead of by syntactic occurrence. A def's
    -- annotation arrow and its body node's arrow are structurally-equal
    -- DISTINCT objects 97.5 % of the time, so occurrence identity cannot tie
    -- them: the body's members land in slots `zonkSigGo` never reads, and the
    -- signature comes back `allflex`. Tying them is what makes a def's
    -- signature conduct — MEASURED for this flag on the self-compile
    -- (2026-08-27): `sigfacts` 751 -> 1,825 rows over 857 newly-carrying
    -- defs, analysis coverage 27.85 % -> 28.72 % (+0.87 pp), ⊤ −1,445
    -- positions and `kN` +953, `out.mlir` −228,690 B. Fast dispatch is
    -- UNCHANGED (21.200 % both arms, −7 events of 571 M) and wall is flat, so
    -- the completeness gain costs nothing at runtime.
    --
    -- This is the paper's inference step (3): `ζ = 𝓔(ξ)`, the lambda-set
    -- equalities implied by the type equalities (146:10). Eco reads them off
    -- the checker's own solve rather than re-deriving them, and confines the
    -- substitution to inference so the specialization phase keeps
    -- per-occurrence identity and per-call-site instantiation — which is what
    -- `arrowSolverRoots` (2b) gives up, and why that flag costs context
    -- sensitivity.
    --
    -- REQUIRES `papMembers`: root-shared classes export through signatures,
    -- so an injection-INCOMPLETE class publishes a false singleton to every
    -- caller. That combination is the recorded identity-map miscompile; it
    -- may be run only as a deliberate negative probe. Both went default-on
    -- together, and disabling `papMembers` while leaving this ON re-creates
    -- exactly that miscompile — so if you turn one off, turn off both.
    --
    -- Artifact-affecting. DEFAULT-ON 2026-08-27 .. 2026-09-16, then
    -- DEFAULT-OFF: with `arrowSolverRoots` on, `AssignMVarIds` already gives
    -- every solver-root slot one shared arrow id, so this memo translation has
    -- nothing left to merge (call-stats Run 27: emission byte-identical with it
    -- off). Turning it back on is only meaningful with `arrowSolverRoots` off,
    -- and then still REQUIRES `papMembers`. Hash token `lssSR=1` rides the ON
    -- arm; env `ECO_MONO_LSS_SIG_ROOT_ID`.
    , sigRootIdentity : Bool

    -- ARROW LIVENESS CENSUS (plans/lss-provenance-ratio-census.md §7): mark
    -- every arrow PEELED BY AN ARGUMENT, so `var`/`set` arrows can be split
    -- into applied and never-applied.
    --
    -- SPLIT FROM `report` for `qCensus`'s reason, which this repository has
    -- already paid for once: the benchmark protocol MANDATES
    -- `ECO_MONO_LSS_REPORT=1`, so anything left under `report` is billed to
    -- every timed run. This one costs a union-find `repr`, two dict lookups
    -- and two counter bumps PER APPLICATION — 512,757 applications on one
    -- self-compile.
    --
    -- REQUIRES `report`: the `ArrowId` comes from `itemAux.arrowOfSlot`, which
    -- `Store` populates only under `report`. With `report` off this census can
    -- name nothing, so both must be set. The `liveness:` line prints ONLY when
    -- this flag is on — all-zero counters under `report` alone would read as a
    -- census that ran and found nothing, which is exactly the misreading the
    -- `qCensus` split exists to prevent.
    --
    -- Read-only: no artifact effect. DEFAULT-OFF. Hash token `lssAC=1`; env
    -- `ECO_MONO_LSS_ARROW_CENSUS`.
    , arrowCensus : Bool

    -- REGISTRATION SELF-IDENTITY (plans/lss-registration-self-identity.md):
    -- stamp the tautological self/PAP members onto the leading spine of every
    -- solver demand at spec registration. The value at spec-g's spine
    -- position d IS g's spec applied to d arguments — the global is literally
    -- in the registry key — yet 93.7 % of all ⊤ positions (54,631 of 58,287,
    -- census 2026-08-27) were exactly these, because `classify`'s placeholder
    -- ⊤ rides demands into the registry and the LSS_010 join absorbs
    -- (⊤ ∪ x = ⊤, and LSet ∪ LVar = ⊤ too — Monomorphized.unionAnno).
    --
    -- Member ids are the SAME ones the reference paths mint (kernel-alias
    -- fold k|, ctor c|, plain/cycle g|, PAP depths p|<g>|<d>), so every join
    -- with an existing injection is idempotent — the E9.2 one-identity rule.
    -- Depth is bounded by declaredArity (LSS_013): returned closures are
    -- never claimed.
    --
    -- Artifact-affecting (stored types and keyed spec keys move).
    -- DEFAULT-ON since 2026-08-28: analysis coverage 28.60 % -> 80.26 %
    -- (+51.66 pp, the arc's largest completeness win) at EXACTLY neutral
    -- dispatch (fast% 21.308 both arms, -7 events of 606 M) and flat wall;
    -- Q-infer byte-identical; E2E 1,706/1,706 both arms. Escape hatch
    -- `ECO_MONO_LSS_REG_IDENTITY=0`; hash token `lssRG=0` now rides the OFF
    -- arm.
    , regIdentity : Bool

    -- ROOT-MEMBER FOLD (plans/lss-root-member-fold.md): a top-level def
    -- carries TWO member ids — its body-root lambda's `l|` id and its
    -- standalone `g|` id — and wherever both flow to one position (which
    -- `regIdentity` made common at spec heads) the set is a sound but
    -- singleton-consumer-useless 2-set. Under this flag the def's ROOT
    -- lambda interns the GROUND STANDALONE key (`g|<global>|<layout>`)
    -- instead of `l|<raw>|<layout>` — the E9.2 identity fold applied to
    -- plain defs — and the `regIdentity` head stamp mints the same ground
    -- key directly. One string, one id, singletons at heads.
    --
    -- Kernel-alias roots are NEVER folded (that would re-create the g|/k|
    -- split E9.2 removes); deep-spine `{l|, p|}` pairs remain by design
    -- (`p|` is the declining class). Artifact-affecting (member-id
    -- allocation order moves).
    --
    -- DEFAULT-ON since 2026-08-28: k1 +25,209 / kN −25,792 (46,062 folded
    -- mints, coverage flat by construction) and the arc's FIRST dispatch
    -- win — sat 2,219,899,146 -> 2,194,042,291, i.e. 25,856,855 indirect
    -- dispatches eliminated (−1.165 %) against byte-identical workload
    -- output. Only 5,556,617 of those became stamped `$cap` calls; the other
    -- 20,300,238 became DIRECT calls, which the dispatch census does not
    -- count — so `fast %` (+0.353 pp) understates this ~4.7×. Escape hatch
    -- `ECO_MONO_LSS_ROOT_FOLD=0`; hash token `lssRF=0` now rides the OFF arm.
    , rootFold : Bool

    -- REFERENCE-SPINE PAP SUCCESSORS (plans/lss-ref-pap-spine.md): at every
    -- standalone-reference injection (VarGlobal plain + kernel-alias,
    -- VarCycle, VarEnum, VarBox — both Translate and LssInfer mint arms),
    -- after the head member, also write the PAP successors down the loaded
    -- type's result spine: depth d in 1..declaredArity-1 gets
    -- `p|<global>|<d>` — the SAME ids `injectPapMember` (papMembers) and
    -- `memberIdForDepth` (regIdentity) mint, so all three paths unify (the
    -- E9.2 one-identity rule). This is the paper's 𝒬 applied to the nested
    -- λs of the conceptually-curried global at its instantiation, with
    -- transport left to ordinary unification; LSS_013 stops the walk at
    -- declaredArity (beyond it the arrows belong to the body's result).
    -- Targets the largest surviving var population: /a0/r-shaped
    -- argument-spine PAPs, 58 % of all var (census 2026-08-28).
    --
    -- NOT `spineArity`: that dormant flag injects the SAME g| member at
    -- every depth — a conflated identity that papMembers rejected (g| is
    -- stampable; a PAP is not) and that would split against papMembers'
    -- p| producer mints. The two flags are mutually exclusive by intent.
    --
    -- Artifact-affecting (annotations and keyed spec keys move).
    -- DEFAULT-ON since 2026-08-28 (same-day build and flip, user decision):
    -- same-source coverage 79.85 % -> 83.10 % (+3.25 pp, var -4,104, top
    -- -134) at EXACTLY neutral dispatch (typed delta 0, sat +7,335 of
    -- 2.23 B = jitter, workload outputs byte-identical) and REDUCED spec
    -- fan-out (List.foldl created specs 2,540 -> 2,137 — concrete p| key
    -- fragments merge demands that per-type var numbering keyed apart).
    -- E2E 1,707/1,707 both arms; Q-infer diverge=0 both arms. Escape hatch
    -- `ECO_MONO_LSS_REF_PAP_SPINE=0`; hash token `lssRP=0` now rides the
    -- OFF arm.
    , refPapSpine : Bool

    -- INJECTION TOTALITY COMPLETION (plans/lss-coverage-four-levers.md):
    -- three levers finishing the paper's total-𝒬 under one flag —
    -- L1 completion-join head re-stamp (heals the kernel-ABI rebuild's
    -- hardcoded ⊤ and the slot-split LSet∪LVar=⊤ join at the ONE place the
    -- stored type is finalized; stampSelfSpine is idempotent and never
    -- overwrites an LSet), L2 deep-PAP successor completion (injectPapMember
    -- stops at the residual head; the papSuccGoC walk finishes depths
    -- supplied+1..arity-1 — the counted papInject|deep residue), L3 the
    -- missing Accessor and bare-VarKernel arms in injectArgLambdaMember
    -- (S.10 lockstep with the inference mints). Attribution via census
    -- counters restamp|*, papInject|deepDone, argArm|*.
    --
    -- Artifact-affecting. DEFAULT-ON since 2026-08-29 (user decision):
    -- coverage 83.10 % -> 88.07 % (+4.97 pp; top -62 %, its L1 lever healing
    -- ~2x its 2,997-head target) at EXACTLY neutral dispatch (typed -5,
    -- sat -69 of 2.24 B = jitter, workload outputs byte-identical), join
    -- rounds/retranslations unchanged. E2E 1,711/1,711 both arms; Q-infer
    -- diverge=0 both arms. Escape hatch `ECO_MONO_LSS_INJ_TOTAL=0`; hash
    -- token `lssIT=0` now rides the OFF arm.
    , injTotal : Bool

    -- M2 ARG-POINT TRANSPORT (plans/lss-coverage-four-levers.md §7.2-REVISED):
    -- walk call args first and unify the WALKED points with callee params
    -- (the A.1 leak), plus the ctor-call shape unify (H1). IMPLEMENTED but
    -- the micro-gate FAILED (probe /c0 rows unchanged; armEntered=3 but all
    -- walked points WpNone — partial ctor apps do not reach the Call arm in
    -- the expected form, and non-arrow-typed args carry no point). Kept
    -- DEFAULT-OFF pending the JS-loop diagnosis; separate from injTotal so
    -- the VALIDATED L1-L3 behavior ships without this unproven piece.
    -- Env `ECO_MONO_LSS_ARG_POINTS`; hash token `lssAP=1`.
    , argPoints : Bool

    -- P1 RESTATEMENT-⊤ RECOVERY (plans/lss-provenance-join-and-demand-sigs.md
    -- §4.3): at the completion join, for LICENSED kernel-alias nodes only
    -- (Define whose body is a bare VarKernel with a TypeFaithful row whose
    -- license applies at the alias's type), positions where the JOINED type
    -- reads ⊤ but the STORED type held a complete LSet recover the stored
    -- set. The actual side's ⊤s there are the kernel-ABI rebuild's
    -- placeholders, not observations; the license is the audited proof the
    -- kernel adds no function inhabitants, so the demands' set is complete
    -- (AR-P1-2). Targets the aTop|nested join-collision mass (P0: 1,516
    -- cells). Census counter `rsTop|recovered`.
    --
    -- Artifact-affecting (stored registry types move, hence retranslation
    -- demand keys and spec keys). DEFAULT-ON since 2026-08-29 (user
    -- decision): same-binary env A/B coverage 87.64 % -> 88.76 % (+1.12 pp),
    -- top 3,668 -> 2,153 (-1,515 = 99.9 % of the 1,516-cell P0 target,
    -- landing as k1 +1,454 / kN +61), var untouched by design. E2E
    -- 1,714/1,714 BOTH arms; elm-tests at the known-12 baseline. Escape
    -- hatch `ECO_MONO_LSS_RS_TOP=0`; hash token `lssRT=0` now rides the
    -- OFF arm.
    , rsTop : Bool

    -- DESTRUCTOR ANNOTATIONS (plans/lss-ctor-arrow-identity.md §9.5/§9.6):
    -- two paper-restoring repairs of the pattern-match path, one flag.
    -- FIX A: `specializeDestructor` merges the PROJECTED type's annotations
    -- (the root's varEnv type pushed down the path — the paper's TIU
    -- substitution through the ctor's instantiated scheme) into the
    -- storeless-classified bound type, precision-monotonically
    -- (`Mono.enrichAnnotations` — a set can never be downgraded, a ⊤ can
    -- never absorb one). Heals the type-argument-borne channel
    -- (`destranno top|k1` = 125 events + the downstream cascade).
    -- FIX B: at the final registry settle, a ctor entry's ⊤ field positions
    -- recover from the set-biased UNION of the same ctor's other specs'
    -- demands — the paper's single global-store solution reassembled from
    -- Eco's keyed shards; union-over-specs can only WIDEN, so the
    -- aggregation is conservative (AR-D2). Ceiling measured by the
    -- `destrBend:` census line.
    -- Artifact-affecting (varEnv-bound types move, hence demand keys).
    -- DEFAULT-ON since 2026-08-31 (user decision): same-binary env A/B
    -- top 2,133 -> 1,457 (-676, -32 % — the largest single ⊤ cut of the
    -- arc), Eerr k1 1515->2028 / ⊤ 264->2, Cerr k1 1196->1724 / ⊤ 264->4,
    -- conflict-⊤ EXACTLY unchanged, var untouched, coverage
    -- 88.99 % -> 89.61 %, wall +2.4 %. VALIDATE leg clean; E2E 1,717/1,717
    -- both arms; elm-tests at the known-12 baseline including the
    -- LssDestrAnnoTest differential — which also caught (and §9.8 fixed)
    -- the partial-union false-singleton window before this flip. Escape
    -- hatch `ECO_MONO_LSS_DESTR_ANNO=0`; hash token `lssDA=0` now rides
    -- the OFF arm.
    -- Env `ECO_MONO_LSS_DESTR_ANNO`; hash token `lssDA=`.
    , destrAnno : Bool

    -- Flow repair M1 (plans/lss-var-chain-roots.md §9.5-9.7): deep argument
    -- write-back for LAMBDA-LITERAL args. After the arg is translated (its
    -- MonoType then carries the body's solved sets), unify it into the
    -- callee's param STORE variable — the paper's App-rule σ-transport
    -- re-tied at the one edge Translate never rebuilt. Store unification,
    -- not annotation enrichment: both sides SHARE the slot, so the L7
    -- `unionAnno (LSet, LVar) → ⊤conflict` path cannot arise (AR-F2).
    -- DEFAULT-ON since 2026-09-01 under the COVERAGE metric
    -- (lss-lpartial §8): var −80 / ⊤ −1 / +0.02 pp on the LPartial
    -- lattice, where pre-LPartial it manufactured +703 ⊤. Wall +2.6 %
    -- accepted by user decision. Escape hatch `ECO_MONO_LSS_FLOW_CONNECT=0`;
    -- hash token `lssFC=0` rides the OFF arm.
    --
    -- Sub-record (`LssConfig` is at the 32-slot cap): `connect` is the
    -- flag above, unchanged in JSON key / env / token; `letOverlay` is F3-b.
    , flow : LssFlowConfig

    -- The post-drain settle-writer family (var chain-root arc), bundled
    -- into a sub-record because `LssConfig` sits AT the runtime's 32-slot
    -- record GC-scan cap (parent plan §9.13 trap: `lamStages` as field 33
    -- broke Stage 6 native lowering at BOOTSTRAP — same lesson as
    -- Engine.S). Per-flag docs live on `LssSettleConfig`; env vars, JSON
    -- keys and hash tokens (lssVS/lssVC/lssVL) are per-flag and UNCHANGED
    -- by the bundling (tokens are independent of record shape).
    , settle : LssSettleConfig

    -- Stage-anchor writers (plans/lss-stage-anchor-writers.md §3): the
    -- construction-anchored `l|` own-mid fill family — rowFill (post-drain
    -- settle over registry rows) and demandFill (demand + completion-join
    -- fill on the stampSelfSpine architecture). Per-flag docs on
    -- `LssStageAnchorConfig`. Env ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL /
    -- _DEMAND_FILL; hash tokens lssSAr= / lssSAd= ride the non-default arm.
    , stageAnchor : LssStageAnchorConfig

    -- Instance-qualified lambda members
    -- (plans/lss-instance-qualified-members.md). Sub-record, not a bare flag:
    -- `LssConfig` is at the 32-slot record GC-scan cap with this field, so the
    -- NEXT knob must go inside a sub-record too. Env
    -- ECO_MONO_LSS_INSTANCE_QUAL / _MAX; hash tokens lssIQ= / lssIQM= ride the
    -- non-default arm.
    , stamp : LssStampConfig
    }


{-| Post-drain settle writers (one flag per mechanism — the §8.4/§8.5
lesson: per-mechanism arms catch what combined arms pass).

  - `varSucc` — var chain-root writes, Phase 1 (plans/lss-var-chain-roots.md
    §3): post-drain settle sweep writing the PAP successor member into flex
    result slots of pap-able singleton/kN heads, strictly within declared
    arity. Sound unconditionally (type-level identity; beyond-arity results
    belong to the body, LSS\_013). DEFAULT-ON since 2026-08-31 (with
    varCtorRows: var −19.2 %, coverage +1.91 pp, ⊤ unchanged, accounting
    exact, all gates green — §4.4). Escape hatch `ECO_MONO_LSS_VAR_SUCC=0`;
    hash token `lssVS=0` rides the OFF arm.
  - `varCtorRows` — Phase 2b (§3): post-drain ctor-row var payload writes
    from the sibling-spec cell union, gated on the all-sets completeness
    rule (zero ⊤ contributors AND zero flex-marked construction vars at the
    cell — AR-V2/AR-V10; runs BEFORE the destrAnno ⊤-heal so the
    contamination evidence is still honest). DEFAULT-ON since 2026-08-31
    (§4.4; flex gate protected 1,563 positions). Escape hatch
    `ECO_MONO_LSS_VAR_CTOR_ROWS=0`; hash token `lssVC=0` rides the OFF arm.
  - `varLambda` — Phase 4v2 (§8.2): post-drain enrichment of `l|`-headed
    var positions from the LAMBDA-HOME table — each qualified lambda's
    settled result type, read off the closure NODES (`ClosureInfo.lssMember`
      - the body's type), which is the only place a lambda's result set
        exists. Strict cells (⊤ or var blocks), all-or-nothing across members,
        and an ARITY guard. DEFAULT-ON since 2026-09-01 (597 writes, 587 k1,
        andThen var −328; all gates green — §8.5). Escape hatch
        `ECO_MONO_LSS_VAR_LAMBDA=0`; hash token `lssVL=0` rides the OFF arm.

-}
type alias LssSettleConfig =
    { varSucc : Bool
    , varCtorRows : Bool
    , varLambda : Bool
    }


{-| Stage-anchor writers (plans/lss-stage-anchor-writers.md §3): both fill
`l|`-singleton-headed rows' var interior cells with the lambda's OWN mid
(LSS\_013), bounded by the alignment theorem r = T − s over the birth-time
qSpine fact.

  - `rowFill` — W2: the post-drain settle pass over registry rows.
  - `demandFill` — W1: the demand + completion-join fill (the
    stampSelfSpine architecture; keyed-routed globals decline).

Both DEFAULT-OFF until the ORDER 4 battery presents a flip decision.

-}
type alias LssStageAnchorConfig =
    { rowFill : Bool
    , demandFill : Bool
    }


{-| Translation-time flow repairs (the edges Translate re-ties in the store
or in the binding environment).

  - `connect` — M1 flowConnect, documented on `LssConfig.flow`.
  - `letOverlay` — F3-b (plans/lss-container-payload-transport.md §12.9.5):
    a plain `let` binding's `varEnv` type takes its ANNOTATIONS from the
    translated RHS (`Mono.overlayAnnotations classified bodyType`) instead of
    the storeless classify's ⊤ — the LSS_026 `leak\|letAnno` class — and a
    local tail-def's binding/param types take theirs from the zonk of the
    demand-seeded annotation var, exactly as the top-level `TailDef` already
    does (Translate.elm `specializeCycleFuncDef`). Structure stays the
    classify's (the ABI guard). Artifact-affecting (spec keys are
    annotation-sensitive); hash token `lssFLO=`; env
    `ECO_MONO_LSS_FLOW_LET_OVERLAY` (`=0` is the escape hatch). DEFAULT-ON since
    2026-09-16 (plan §12.10.3, last arm of the series): `leak|letAnno` 58 -> 0,
    ⊤ 698 -> 668 with `var` +30 — a ⊤-manufacturer removal, coverage-flat by the
    metric, wall flat.

-}
type alias LssFlowConfig =
    { connect : Bool
    , letOverlay : Bool

    -- `rowDefer` — F3-a (plans/lss-container-payload-transport.md §12.9.5):
    -- a destructured SYNTACTIC payload arrow (a constructor field, invisible
    -- to the scrutinee's type) binds as `LRow` — a reference to the
    -- constructor's row — instead of the storeless ⊤, and the post-drain
    -- `settleRowRefs` resolves every `LRow` from the COMPLETE union of the
    -- row's constructions (a translation-time read is unsound: partial
    -- union ⇒ false singleton). Artifact-affecting; hash token `lssFRD=`;
    -- env `ECO_MONO_LSS_FLOW_ROW_DEFER`. DEFAULT-OFF pending the A/B.
    , rowDefer : Bool

    -- `accessFlow` — E15 (plans/lss-container-payload-transport.md §12.10.1): a
    -- record-field ACCESS transports its field's set — `enrichFromEnv` projects
    -- a local record's bound type for `r.f` arguments and callees, an access-form
    -- argument takes the flowConnect write-back after translation, and
    -- `refineAccessType` overlays the record's field annotations onto the access
    -- node instead of keeping the storeless `clsMisc` ⊤. Also carries the
    -- list-literal element JOIN (a first-element-only set is a completeness
    -- claim the other elements falsify). Token `lssFAF=`; env
    -- `ECO_MONO_LSS_FLOW_ACCESS_FLOW` (`=0` is the escape hatch).
    --
    -- DEFAULT-ON since 2026-09-16 (plan §12.10.3): `enrich|access|ofLocal`
    -- 5,785 joins, `var` 852 -> 837, k1 +26, wall flat; the callee-form
    -- dispatch effect is owed a call-stats pair.
    , accessFlow : Bool

    -- `litFacts` — F4-sig (§12.10.1): the signature walk gives record/tuple/
    -- list/update literals a POINT (their loaded type, element slots joined
    -- with the elements' points) instead of `WpNone`, so a def returning or
    -- let-binding a literal of functions carries facts at the literal's
    -- interior arrows. Token `lssFLF=`; env `ECO_MONO_LSS_FLOW_LIT_FACTS`
    -- (`=0` is the escape hatch).
    --
    -- DEFAULT-ON since 2026-09-16 (plan §12.10.3): 13,443 literal points
    -- (tuple 6,858 / list 5,341 / record 1,244 honest, update 1,541 opaque),
    -- `var` 837 -> 821, k1 +133 / kN +87 — the largest gain of the series;
    -- wall flat.
    , litFacts : Bool
    }


{-| Instance-qualified lambda members (plans/lss-instance-qualified-members.md).

`enabled`: a lambda instance minted while re-translating the RHS of a
LOCAL-MULTI instance carries that instance's identity in its member id, on top
of LSS\_017's source lambda and LSS\_024's enclosing-spec widened key. Local-multi
instance keying is annotation-SENSITIVE (`Engine.recordMultiInstance`) while
member qualification was not, so two instances of one let-function shared ONE
member id — a singleton set indexing two different bodies, which AbiCloning
correctly refuses to stamp (`declinedBodyMismatch`) rather than miscompile.

`maxInstances`: the hard cap. The discriminator is the instance ORDINAL, not
its type — a type hash would put annotations back into member ids and reopen
the specs -> members -> keys spiral LSS\_018 exists to close. The ordinal keeps
that spiral bounded but not provably absent: an annotation split mints an
instance, whose new member id can drive a further split. Beyond the cap a mint
takes today's key (fence declines, status quo), so termination is structural.
0 means unlimited — do not ship it.

`flatPeel` (Fix A, §15.1 of the plan): at an OVER-APPLYING call site — the
site applies its args flat while the callee TYPE is curried, which
`Store.classifyGo` makes it for every arrow ("one arrow per MFunction") — peel
the type's stages until the accumulated parameter count EQUALS the site's arg
count, and match the instance against THAT list instead of against the type's
one-parameter first stage.

The type is representation-AGNOSTIC: an arrow is inhabited by a flat n-param
closure, by a curried chain and by PAPs alike, and `classifyGo` runs before any
closure has flowed there. The INSTANCE is the only representation authority, so
the comparison belongs against the instance. That is why this is a comparison
fix and not a representation change.

Measured at 33.2 % of the compiler's generic dispatch (plan §13).

-}



-- `census` — ABICLONING PER-SITE CENSUS (`AbiCloning.StampCtx.census`): the
-- String-keyed Dicts that attribute every consulted call site to its HOST
-- global and its outcome — `byHost`, `niGuard`, `shape`, `papSites`. These
-- are the join keys against the caller-attributed runtime dispatch census,
-- and they are how every plan in the LSS decline arc was sized.
--
-- SPLIT FROM `report` for `qCensus`'s reason, now twice paid: the
-- benchmark protocol MANDATES `ECO_MONO_LSS_REPORT=1`, so anything left
-- under `report` is billed to every timed run. This one builds a String
-- key and inserts a Dict node at ~43,000 AbiCloning sites per
-- self-compile.
--
-- The SCALAR counters beside them (`dispatchUpgraded`, `declined*`,
-- `stamped*`) are field increments with no allocation and stay
-- unconditional — they are the A/B gate numbers every benchmark reports,
-- so gating them would stop a timed run from stating its own result.
--
-- TRAP: with this off the census Dicts read EMPTY, so a census binary must
-- be BUILT AND RUN with it on. Joining a static census against a binary
-- compiled without it is the error recorded in
-- plans/lss-body-mismatch-declines.md §8.4.
--
-- DEFAULT-OFF. Hash token `lssCen=1`; env `ECO_MONO_LSS_CENSUS`.
--
-- Lives HERE and not on `LssConfig` because `LssConfig` is AT the 32-slot
-- record GC-scan cap: a 33rd top-level field lowers to
-- `eco.construct.record field_count (33)` and the backend verifier
-- rejects it. Every future LSS flag goes in a sub-record for this reason.


type alias LssStampConfig =
    { enabled : Bool
    , maxInstances : Int
    , flatPeel : Bool
    , census : Bool

    -- `papFast` — LSS_040 (plans/lss-pap-fast-stamp.md): FAST-stamp call sites
    -- whose callee is a `p|<global>|<k>` member, a k-applied partial
    -- application of a global. The `p|` fence (Translate.injectPapMember)
    -- forbids a DIRECT rewrite — it drops the bound arguments, the recorded
    -- traverseTuple miscompile. A FAST stamp keeps the heap object and loads
    -- the bound arguments out of it exactly as LSS_011 does for PAPs of
    -- closures; nothing is reconstructed, so nothing is dropped. Rides E9.5's
    -- indices, so it is inert unless `postSettleDevirt` is on.
    --
    -- Artifact-affecting (changes which sites are stamped, hence CallInfo,
    -- hence emitted MLIR). Hash token `lssPF=`; env `ECO_MONO_LSS_PAP_FAST`
    -- (`=0` is the escape hatch, riding `lssPF=0`).
    --
    -- DEFAULT-ON since 2026-09-07 (plan §10): 2,041 of 2,418 `p|` sites stamp
    -- on the self-compile, generic dispatch −164 M (−14.96 %) on identical
    -- input with byte-identical output; `.mlir` +0.13 %, RSS flat, protocol
    -- wall FLAT (benchmarks/lss-opt.md Run AP) — flipped on the dispatch
    -- counter, the same basis as LSS_025.
    , papFast : Bool

    -- `useInject` — F2, plans/lss-container-payload-transport.md §12.9.4: at a
    -- local-multi USE passed as an argument, mint the id the instance's RHS
    -- re-translation will mint for its lambda and write it into the stashed
    -- var's spine before the callee is zonked, so the callee's demand carries
    -- the singleton (GAP-9b's "no member, no stamp" closed). Also the
    -- self-reference inside an instance re-translation (F2.b). Sound by
    -- construction: the id is a deterministic function of the source lambda,
    -- the instance tag and the spec, and the RHS mint runs under the same
    -- three. Also skips `rootFold` for a local-multi instance RHS lambda
    -- (which `demandUnifyRoot` otherwise folds onto the ENCLOSING global's
    -- id, dropping the instance tag — the LSS_038 collapse, live for lambda
    -- RHSs). Artifact-affecting; hash token `lssIU=`; env
    -- `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT` (`=0` is the escape hatch).
    --
    -- DEFAULT-ON since 2026-09-15 (plan §12.9.4 A/B, self-compile): `var`
    -- 1,380 -> 873 (-36.7 %), `top` 938 -> 697 (`abi` 250 -> 6), `k1` +855,
    -- analysis coverage 98.44 % -> 98.94 %; unwritten local-multi argument
    -- positions 866 -> 254 and their downstream parameter chain 1,024 ->
    -- 454; wall and RSS flat.
    , useInject : Bool

    -- `useInjectPap` — F2.c (plans/lss-container-payload-transport.md §12.10.1):
    -- the same use-site write for a local-multi whose RHS is a PARTIAL
    -- APPLICATION of a global (`exprCompiler = bfExprCompiler (…)`): the id the
    -- RHS re-translation mints is `p|<global>|<supplied>` (`injectPapMember`),
    -- a function of the syntax alone and instance-blind by design, so the use
    -- site mints the same key and writes it HEAD-ONLY (the `p|` law). Own flag
    -- for its own A/B; token `lssIUP=`; env
    -- `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT_PAP` (`=0` is the escape hatch).
    --
    -- DEFAULT-ON since 2026-09-16 (plan §12.10.3, five-arm series): 46 uses
    -- inject, `var` 893 -> 852, k1 +39, wall flat, devirt unchanged.
    , useInjectPap : Bool

    -- `rootFoldDepth` — plans/lss-root-fold-depth-qualified-spine.md.
    -- Requires `lss.rootFold`. The translation-phase spine write
    -- (`LssInfer.injectLambdaMemberQualified` -> `spineGoC`) puts a
    -- root-folded lambda's GROUND `g|` id at EVERY depth 0..arity-1 of its
    -- own spine; the other two spine writers (`Translate.stampSelfSpine`,
    -- `LssInfer.injectPapSuccessors`) put `g|` at depth 0 and `p|g|d` at
    -- depth d>=1. A folded `g|` is the STAMPABLE class (E9.1 devirt), and
    -- `lss-root-member-fold.md` AR-1 requires depth>0 to stay `p|`. ON makes
    -- the third writer match the other two.
    --
    -- Lives HERE, beside `useInject`/`useInjectPap`, and not at `LssConfig`
    -- top level, because `LssConfig` is AT the runtime's 32-slot record
    -- GC-scan cap: a 33rd field makes the compiler's own config record
    -- unlowerable ('eco.construct.record' op field_count (33) exceeds
    -- Record's 32-slot GC scan limit). Artifact-affecting; hash token
    -- `lssRFD=`; env `ECO_MONO_LSS_ROOT_FOLD_DEPTH`.
    , rootFoldDepth : Bool
    }


{-| The built-in LSS defaults (budgets per the design doc).

`enabled = True` means **solver implies LSS** (H3, 2026-07-14): the solver
engine — now the `mono.engine` default (2026-07-22) — consults this block, so
default builds get lambda-set specialization without extra flags. The subst
engine never consults this block, so `ECO_MONO_ENGINE=subst` builds are
unaffected.

`keyed = True` (2026-07-20, post-Fix-B): ALL-GLOBALS keying is the default.
Sound since LSS\_017 fork-qualified members (`plans/lss-fork-qualified-members.md`
— the singleton-representative hijack is fixed by construction) and measured
free at run time (Run M, `benchmarks/runtime-calls.md`: coverage 6.81 % →
13.22 %, identical total events, wall parity). `ECO_MONO_LSS=unkeyed` restores
the selective-whitelist mode (`keyedGlobals`); `ECO_MONO_LSS=0` disables LSS
entirely. Watch item: the elm-aws-codegen pathological-workload class (§11.7
census note) — since the 2026-08-29 no-limits defaults the M4
`maxSpecsPerGlobal` budget no longer engages by default; if that class
regresses, `ECO_MONO_LSS_MAX_SPECS` restores a budget without a rebuild.

-}
defaultLss : LssConfig
defaultLss =
    { enabled = True
    , keyed = True
    , keyedGlobals = defaultKeyedGlobals
    , devirtFnGlobals = True
    , maxSetSize = 0
    , maxSpecsPerGlobal = 0
    , report = False
    , spineArity = False
    , muTie = True
    , groundStandalones = True
    , sigFlow = True
    , layoutQualMembers = True
    , postSettleDevirt = True
    , arrowIdentity = True
    , arrowSolverRoots = True
    , qSolve = False
    , refIdentity = True
    , qCensus = False
    , papMembers = True
    , sigRootIdentity = False
    , arrowCensus = False
    , regIdentity = True
    , rootFold = True
    , refPapSpine = True
    , injTotal = True
    , argPoints = False
    , rsTop = True
    , destrAnno = True
    , flow = { connect = True, letOverlay = True, rowDefer = False, accessFlow = True, litFacts = True }
    , settle = { varSucc = True, varCtorRows = True, varLambda = True }
    , stageAnchor = { rowFill = False, demandFill = False }
    , stamp = { enabled = True, maxInstances = 8, flatPeel = True, census = False, papFast = True, useInject = True, useInjectPap = True, rootFoldDepth = True }
    }


{-| The default selective-keying set (Tier 1, 2026-07-20): the elm/core List
fold chain. E5 shipped keying default-empty because Run F measured zero
payoff; E9.2's kernel devirt is what unlocked it — the hot cons dispatches
live inside these SHARED fold specs, and per-set keyed fan-out is what
mints their `{k|List.cons}` singletons. Measured: −143.7 M dispatch
events/run (Run J) at zero wall cost (Run J + the Tier-1 A/B: keyed ≈
unkeyed, equal major-GC counts). Chain-keyed per the Run-F selection rule
(an unkeyed middle like `foldrHelper` re-joins the sets).
`ECO_MONO_LSS_KEYED_GLOBALS` REPLACES this list — set it empty to unkey.
-}
defaultKeyedGlobals : List String
defaultKeyedGlobals =
    [ "elm/core:List.foldl"
    , "elm/core:List.foldr"
    , "elm/core:List.foldrHelper"
    , "elm/core:List.map"
    ]


{-| Inliner / simplifier knobs.

**Each pass has its OWN size budget and round count** (split 2026-09-15). One
`threshold` field used to drive THREE passes — `InlineSimplify` (pre-mono),
`MonoInlineSimplify` (post-mono) and `PreMono.EtaExpand`'s cheapness gate — so
`ECO_INLINE_THRESHOLD` moved all three at once and no A/B could attribute an
effect to one of them. The per-pass fields are `preMonoThreshold`,
`postMonoThreshold`, `etaThreshold` and `preMonoFixpointIterations` /
`postMonoFixpointIterations`; every default is the value the shared field had,
so the split is behaviour-preserving. `ECO_INLINE_THRESHOLD` / `ECO_INLINE_FPI`
are kept as BROADCAST setters (they write all of the corresponding fields, and
the per-pass env vars override them) so `ECO_INLINE_THRESHOLD=0` still means
"no inlining anywhere", which is a standing test leg.

  - `whitelist` is **additive**: appended to the built-in `defaultWhitelist`.
  - `blacklist` is subtracted from the effective whitelist afterward.
  - `hofThreshold` is the POST-mono cost budget for candidates with a CALLED
    function-typed parameter (HOFs whose lambda argument beta-reduces away
    at the call site — plan H2). The effective budget is
    `max postMonoThreshold hofThreshold`, so it can only widen eligibility.
    The pre-mono inliner has no HOF budget — it refuses HOF candidates
    outright (`hofParam`) — and no whitelist bypass.
  - `loopify` enables recursive-HOF loopification (plan H5): a saturated
    call of a tail-recursive function passing a lambda LITERAL is rewritten
    to a local specialized loop with the lambda beta-inlined — the closure
    allocation disappears (and EcoPAPSimplify elides the loop shell).
  - `raiseAppliedShareMin` (H6.2.5 Lever 2, percent 0–100): raise a staged
    spec only when at least this share of its saturated-call results are
    APPLIED (callee position, per the U0 site census). Escaping results
    (returned / let-bound / arg / stored) pay a PAP-extend per stage when
    raised, so escape-dominated specs are better left staged. `0` (the
    default) raises every qualifying spec — exactly the pre-H6.2.5
    behaviour. Only meaningful when `arityRaise` is on.
  - `report` renders the inline census to stderr after the pass
    (`ECO_INLINE_REPORT=1`); output-only, never affects `hash`.

-}
type alias InlineConfig =
    { preMonoThreshold : Int
    , postMonoThreshold : Int
    , etaThreshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , preMonoFixpointIterations : Int
    , postMonoFixpointIterations : Int
    , hofThreshold : Int
    , loopify : Bool
    , arityRaise : Bool
    , raiseAppliedShareMin : Int

    -- PARTIAL-HOF INLINING (2026-09-08). `exactOnly` refuses to inline a
    -- candidate admitted via `hofThreshold` at a STRICTLY-PARTIAL call site,
    -- because the partial rebuild's re-staged closure once tripped the runtime
    -- typed-apply arity assert when a caller over-applied it. That refusal is
    -- what keeps the IO monad's bind out of the inliner: `andThen f ma` is 2
    -- of 3 arguments at all 367 of its sites, so it is never an exact call and
    -- never inlines (/work/direct-call-decline-census.md; measured -8.77%
    -- generic dispatch when forced via the whitelist).
    --
    -- ON lifts the refusal for hof-admitted candidates ONLY (whitelisted and
    -- under-threshold candidates already inline partially). Artifact-affecting;
    -- hash token `phof=1`; env `ECO_INLINE_PARTIAL_HOF=1`. DEFAULT-OFF.
    , partialHof : Bool

    -- SET-PRESERVING POST-MONO INLINER
    -- (plans/pre-mono-lss-transforms-02-inline-preserve-sets.md). ON makes
    -- `MonoInlineSimplify` DECLINE the one reshape that clears LSS member
    -- identity: `tryInlineCall`'s strictly-partial arm, which mints a residual
    -- `MonoClosure` with `lssMember = Nothing` and a `topSynth` type. Declining
    -- leaves the callee's PAP in place, and a `p|<global>|k` PAP member is the
    -- best-served class in the compiler (LSS_040 stamps 2,041/2,418 sites),
    -- where the residual could not be stamped at all.
    --
    -- MEASURED: that arm is 863/65,949 inlines (1.31 %) on the 2026-09-10 tree
    -- and 924/48,819 (1.89 %) at today's defaults — the ONLY clearing site that
    -- fires on real code (`bySite=tryInline` in the reshape census; the mirror
    -- arm in `betaReduce` is measured dead). The stampable subset of what it
    -- costs is bounded at 0.245 % of generic dispatch, so the expectation is
    -- FLAT dispatch and one fewer PAP-elimination per declined site.
    --
    -- PRECEDENCE: beats `partialHof`, whose whole purpose is to FORCE that arm;
    -- with both on the partial branch declines before it mints. Applies to
    -- WHITELISTED candidates too — the whitelist grants budget privileges, not
    -- identity privileges. Does NOT gate `arityRaise`, a separate and larger
    -- clearing that is off by default. Artifact-affecting; hash token
    -- `psets=1`; env `ECO_INLINE_PRESERVE_SETS=0|1`. DEFAULT-ON since
    -- 2026-09-12: the A/B (benchmarks/call-stats.md Runs 7/8) is not the
    -- predicted FLAT but a win — `stampedPapGlobal` +491, 62,830,724 dispatches
    -- (−6.99 %) moved from generic/typed into `fast` at a population flat to
    -- 0.01 %, and `out.mlir` −0.93 % because a declined partial inline is a
    -- callee body not copied. The reference arm moves +0.01 %, so the win is
    -- the preserveSets-BUILT binary, not a cheaper workload.
    , preserveSets : Bool

    -- POST-INLINE DEAD-SPEC PRUNE
    -- (plans/post-inline-dead-spec-prune.md). `MonoInlineSimplify` leaves a
    -- specialization in the graph when it inlines the only reference to it,
    -- and nothing removed those: `Prune` runs once, at the END of
    -- monomorphization, and the inliner returns `callEdges = Array.empty`.
    -- MEASURED on the self-compile (2026-09-13): 6,608 unreferenced
    -- code-bearing functions, 4,508,040 B, 4.86 % of the emitted text, versus
    -- 921 / 1.27 % with the inliner off. They also account for all 1,758
    -- `g1absentl` AbiCloning declines — sites in dead specs whose callback
    -- member has no instance because the inliner consumed it — which
    -- misdirected two plans before the per-site trace found them
    -- (plans/pre-mono-lss-transforms-03-lift-closed-lambda-args.md §12.4).
    --
    -- ON runs `Prune.pruneAfterInline` immediately after the inliner, before
    -- `MonoGlobalOptimize`: at that point the only cross-spec references are
    -- `MonoVarGlobal`, so a `MonoTraverse.collectSpecEdges` reachability is
    -- exact. Everything that references a spec by another route — AbiCloning's
    -- `fastEvaluatorSpec` stamps, post-settle devirt targets, CafHoist's mints
    -- — comes after and therefore cannot dangle. Artifact-affecting (it
    -- removes functions); hash token `prune=`; env `ECO_INLINE_PRUNE_DEAD=0`.
    , pruneDead : Bool

    -- INLINER POSITION (plans/pre-mono-inline-simplify.md). `postMono` gates
    -- the existing `MonoInlineSimplify` (after monomorphization); `preMono`
    -- gates the new `InlineSimplify` (before it, on the TOpt IR). Both
    -- artifact-affecting; hash tokens `preInl=` / `postInl=`.
    --
    -- BOTH DEFAULT-ON since 2026-09-11, and ADDITIVELY: the position A/B this
    -- pair was built for has never been run. Its `postMono = False` arm
    -- segfaulted until 2026-09-09, and that was NOT the inliner — §13/§14 of
    -- the plan root-caused it to `JsArray.unsafeGet` reading its element kind
    -- from `resultType` because `arrayElementType` matched the constructor
    -- name "Array" when `Elm.JsArray` declares `type JsArray a`. Re-measured
    -- 2026-09-11: `ECO_INLINE_POST_MONO=0` gives E2E 1719/1725 and all six
    -- failures are MLIR-SHAPE checks (a PAP survives HOF elimination), no
    -- crashes and no wrong values — so the post-mono pass is an OPTIMIZATION
    -- those fixtures pin, not a correctness dependency.
    --
    -- `postMono` stays DEFAULT-ON. **`preMono` went DEFAULT-OFF on 2026-09-15**
    -- (`ECO_INLINE_PRE_MONO=1` turns it back on), reversing its 2026-09-11
    -- flip. Its Run-4 evidence — `out.mlir` −0.51 %, dispatch neutral —
    -- predates item 4: `aliasForward` (default-on 2026-09-14) retired the
    -- parameter-less alias wrappers that were this pass's main population, by
    -- REFERENCE SUBSTITUTION rather than body copying, so it grows no artifact
    -- and multiplies no arrow positions. The inliner's remaining inlines fell
    -- 13,175 → 5,485 the moment forwarding shipped (call-stats Runs 13/14), and
    -- Runs 17-20 price what is left: against `preMono=0`, those 5,497 inlines
    -- buy 484 BYTES of artifact (−0.0036 %) and 7 specs while costing
    -- +2,275,017 generic dispatches (+0.29 %) and 474 singleton positions
    -- (`k1` 101,246 → 100,772); `fast %` is flat to two decimals across the
    -- whole `preMonoThreshold` curve (0 / 10 / 25), so nothing changes tier
    -- anywhere on it. `MonoInlineSimplify` absorbs the work one-for-one
    -- (29,036 → 34,908 inlines) for the same 32,947 specs.
    , preMono : Bool
    , postMono : Bool

    -- PRE-MONO ETA EXPANSION
    -- (plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md).
    -- Rewrites a definition or a continuation lambda whose SYNTACTIC parameter
    -- count is below the arity its type declares once aliases are expanded
    -- (`IO a = State -> ( State, a )`) into the saturated spelling, then merges
    -- the freshly applied arguments into the under-applied call underneath.
    -- The target is `System.TypeCheck.IO`'s bind chain, 55.3 % of generic
    -- dispatch: `andThen`/`map` are already arity-3 in their definitions and
    -- every caller writes them at the alias arity, so the deficit is entirely
    -- caller-side. Gated on a CHEAPNESS test (plan §2.5) because expansion
    -- moves whatever sits left of the new binders from once-per-CAF to
    -- once-per-call. Artifact-affecting; hash token `eta=1`; env
    -- `ECO_INLINE_ETA_EXPAND=0|1`. DEFAULT-ON since 2026-09-11: the
    -- bootstrap fixed point for eta=1 was demonstrated (A == B, 15,681,792 B)
    -- once the LSS false-singleton it exposed was fixed
    -- (/work/eta-fixed-point-root-cause.md — `Translate`'s `Let`/`Destruct`
    -- arms now connect the body's type to the node's type).
    , etaExpand : Bool

    -- DIAGNOSTIC (2026-09-11 fixed-point bisect): when non-empty, η-expansion
    -- is applied ONLY to globals whose module name starts with one of these
    -- prefixes. Artifact-affecting; hash token `etaOnly=`; env
    -- `ECO_INLINE_ETA_ONLY=Mod.A,Mod.B`. DEFAULT [] (= every module).
    , etaOnly : List String
    , report : Bool
    , kernelFactsDce : Bool -- kernel-opt-11 (a): let the dead-binding gate drop a dead kernel call whose KernelFacts row is `droppable` (cseSafe AND totality == Total, and every argument pure). DEFAULT-ON since 2026-08-12 (realizable ceiling on the whole 261-module self-compile is FOUR sites, of which 2 realize -- it ships for the enabling value and for ending the isPureExpr/CafHoist contradiction, NOT for a measured win); env kill switch ECO_KERNEL_FACTS_DCE=0; artifact-affecting (hash token "kfdce=1"). Widens ONLY MonoInlineSimplify's dead-let gate -- the H2.5/H6.1 partial-forward guards keep the legacy all-calls-impure predicate
    , kernelCostClasses : Bool -- kernel-opt-11 (b): price a kernel call from its derived KernelFacts cost class (and from whether it lowers to an inline op) instead of the flat 6-per-call the inliner uses today. DEFAULT-ON since 2026-08-12 (changes real inlining decisions -- emitted .mlir +1,341 B, letDCE 498->441 -- wall FLAT at +0.56%); env kill switch ECO_KERNEL_COST_CLASSES=0; artifact-affecting (hash token "kcc=<i>/<g>/<a>/<h>", the whole vector, so every A/B leg is cache-disjoint). Independent of kernelFactsDce ON PURPOSE -- DCE deletes work, cost classes move inliner thresholds, and a shared flag would make per-constant attribution impossible
    , kernelCostInline : Int -- cost of a kernel call that lowers to an inline op (Intrinsics.kernelIntrinsic says Just); no call is emitted at all
    , kernelCostGcLeaf : Int -- cost of a CGcLeaf kernel call: no Elm GC, no C++ heap traffic, no callback
    , kernelCostAlloc : Int -- cost of a CAlloc kernel call: allocates on the Elm or C++ heap
    , kernelCostHof : Int -- cost of a CHof kernel call: re-enters Elm through a user closure

    -- PRE-MONO ALIAS FORWARDING
    -- (plans/pre-mono-lss-transforms-04-alias-forwarding.md). A reference to a
    -- parameter-less ALIAS definition (`Basics.add = Elm.Kernel.Basics.add`,
    -- `Doc.fromChars = P.text`) is rewritten to the same reference to its
    -- target, caller meta kept: reference substitution, no type reasoning, no
    -- minting. 53 % of the post-mono inliner's self-compile inlines are these
    -- wrappers, which the pre-mono inliner cannot see (`bodyOf` admits
    -- `Function` bodies only). Kernel-target CALLS forward only when exactly
    -- saturated (§3.2 amendment: an under-applied call is the `p|` producer
    -- site), kernel-target VALUES are kept in v1 (R6). Runs FIRST after
    -- `AssignMVarIds`, before η-expansion. Artifact-affecting; hash token
    -- `afwd=`; env `ECO_INLINE_ALIAS_FORWARD=0|1`. DEFAULT-ON since 2026-09-14:
    -- benchmarks/call-stats.md Run 14 vs 13 on the CGEN_080-fixed compiler —
    -- generic dispatch −0.16 %, `fast` +4.9 M, `typed` +1.6 M, `out.mlir`
    -- −0.36 %, 1,077 wrapper specs retired, wall flat; E2E 1727/1727 both arms.
    -- The `fast → typed` shift the first measurement showed (Runs 11/12) was
    -- an emission gap this pass surfaced, not caused (plan §7.1-7.2). `=0`
    -- turns it off.
    , aliasForward : Bool
    }


{-| Bytes-fusion master switch (consumed by MLIR codegen).
-}
type alias BytesFusionConfig =
    { enabled : Bool }


{-| CAF-memoization master switch (consumed by MLIR codegen —
plans/caf-memoization-implementation.md, design\_docs/caf-memoization-design.md).
`enabled = True` gives every qualifying nullary value thunk (`MonoDefine`
non-closure, `!eco.value` ABI result, non-trivial body) a lazy once-init
`eco.global` slot: the thunk body runs at most once per process and every
later reference returns the cached value. `ECO_CAF_MEMO=0` is the env escape.
Compile-time only: the guard is baked into generated code, so there is no
runtime toggle.
-}
type alias CafMemoConfig =
    { enabled : Bool
    , census : Bool -- env ECO_CAF_CENSUS=1: inner-CAF opportunity census over the final MonoGraph (CafCensus.elm); output-only, excluded from hash
    , dedupe : Bool -- env ECO_CAF_DEDUPE=1: merge structurally identical nullary specs onto one canonical spec (CafDedupe.elm); artifact-affecting → hash token cafd=1 when on
    , hoist : CafHoistConfig
    }


{-| CAF hoisting knobs (plans/caf-hoist-closed-expressions.md): closed
expressions inside function bodies are hoisted to fresh nullary specs and
memoized by the CGEN\_068 slot machinery.

  - `enabled`: master switch (env `ECO_CAF_HOIST=1|0`); artifact-affecting →
    hash token `cafh=1` when on.
  - `minNodes`: original-subtree size floor (DQ1; env
    `ECO_CAF_HOIST_MIN_NODES`); token `cafhN=` when non-default and on.
  - `maxHoists`: global mint budget safety valve (DQ1; env
    `ECO_CAF_HOIST_MAX`); token `cafhM=` when non-default and on.

-}
type alias CafHoistConfig =
    { enabled : Bool
    , minNodes : Int
    , maxHoists : Int
    }


{-| Logical-type codegen knobs.

  - `customMaxFields`: max fields a single-ctor custom may have to be eligible
    for unboxed-aggregate cross-spec. Clamped to `[1,24]` (24 is the heap ABI
    hard cap) by `clamp`.

-}
type alias LogicalTypesConfig =
    { customMaxFields : Int }


{-| The built-in defaults. These reproduce today's hardcoded behaviour.
-}
default : EcoConfig
default =
    { inline =
        { preMonoThreshold = 10
        , postMonoThreshold = 10
        , etaThreshold = 10
        , whitelist = []
        , blacklist = []
        , maxPerFunction = 1000
        , preMonoFixpointIterations = 4
        , postMonoFixpointIterations = 4

        -- H2 matrix (2026-07-13, self-compile workload): 25 gives +35%
        -- betaForwards over 10 at +2.7% code size and no measurable
        -- compile-time cost; 40 costs +9.6% size for the next step.
        , hofThreshold = 25
        , loopify = True

        -- H6.2 U2b (EXPERIMENTAL, ECO_ARITY_RAISE=1): uncurry staged
        -- specs whose stage-1 work is trivial/cheap so monadic-bind
        -- chains merge and beta away. Default OFF: delaying a cheap pure
        -- stage-1 body to application time is unobservable in Elm modulo
        -- ⊥-timing and Debug.log ordering.
        , arityRaise = False

        -- H6.2.5 Lever 2: 0 = raise everything (pre-Lever-2 behaviour).
        -- The M3 census sweep picks any nonzero default.
        , raiseAppliedShareMin = 0
        , partialHof = False
        , preserveSets = True
        , pruneDead = True
        , preMono = False
        , postMono = True
        , etaExpand = True
        , etaOnly = []
        , report = False
        , kernelFactsDce = True

        -- Starting vector. Today's uniform value is 6; these are the shape the
        -- audit implies, not a measured optimum -- each is A/B'd solo.
        , kernelCostClasses = True
        , kernelCostInline = 1
        , kernelCostGcLeaf = 4
        , kernelCostAlloc = 8
        , kernelCostHof = 20
        , aliasForward = True
        }
    , callPurityAttrs = True
    , cse = { enabled = False, report = False, minCost = 5, maxPerDef = 64 }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
    , cafMemo = { enabled = True, census = False, dedupe = False, hoist = { enabled = False, minNodes = 3, maxHoists = 8192 } }
    , mono = { engine = EngineSolver, diffDump = False, validate = False, lss = defaultLss, limits = defaultLimits }
    , borrow = { enabled = False, reify = ROff, report = False, validate = False, oracleOpt = False }
    , list = { chunks = True, consIntrinsic = True, mapTemplate = False, report = False }

    -- The ENTIRE tier-1 family DEFAULT-ON since 2026-08-04 (user
    -- decision, reversing the same-day default-off verdict). Ship config
    -- (aggp+ctori+sretr+psplit) measured −3.2/−3.3% wall same-day
    -- interleaved (Runs J/K); sretFresh measured neutral (Run M);
    -- sretTailFuncs carries a measured ~+4% wall self-compile regression
    -- (Runs J/K isolation A/B) — accepted by the same decision. Each
    -- flag's env var =0 disables individually.
    , aggPromote = True
    , ctorInline = True
    , sretResults = True
    , psplitParams = True
    , sretFresh = True
    , sretTailFuncs = True
    , stringLengthOp = True
    , appendSplit = True
    , stringOrderIntrinsic = True
    , valueEq = True
    , kernelGcLeaf = True
    }


{-| Decode an `eco-config.json` document. Every field is optional and merges
over `default`; unknown fields (including `version`) are ignored. Never emits
a custom failure, so the problem type is left polymorphic.
-}
decoder : D.Decoder x EcoConfig
decoder =
    D.pure EcoConfig
        |> D.apply (D.optionalField "inline" inlineDecoder default.inline)
        |> D.apply (D.optionalField "bytesFusion" bytesFusionDecoder default.bytesFusion)
        |> D.apply (D.optionalField "logicalTypes" logicalTypesDecoder default.logicalTypes)
        |> D.apply (D.optionalField "cafMemo" cafMemoDecoder default.cafMemo)
        |> D.apply (D.optionalField "mono" monoDecoder default.mono)
        |> D.apply (D.optionalField "borrow" borrowDecoder default.borrow)
        |> D.apply (D.optionalField "list" listDecoder default.list)
        |> D.apply (D.optionalField "aggPromote" D.bool default.aggPromote)
        |> D.apply (D.optionalField "ctorInline" D.bool default.ctorInline)
        |> D.apply (D.optionalField "sretResults" D.bool default.sretResults)
        |> D.apply (D.optionalField "psplitParams" D.bool default.psplitParams)
        |> D.apply (D.optionalField "sretFresh" D.bool default.sretFresh)
        |> D.apply (D.optionalField "sretTailFuncs" D.bool default.sretTailFuncs)
        |> D.apply (D.optionalField "stringLengthOp" D.bool default.stringLengthOp)
        |> D.apply (D.optionalField "appendSplit" D.bool default.appendSplit)
        |> D.apply (D.optionalField "stringOrderIntrinsic" D.bool default.stringOrderIntrinsic)
        |> D.apply (D.optionalField "valueEq" D.bool default.valueEq)
        |> D.apply (D.optionalField "kernelGcLeaf" D.bool default.kernelGcLeaf)
        |> D.apply (D.optionalField "callPurityAttrs" D.bool default.callPurityAttrs)
        |> D.apply (D.optionalField "cse" cseDecoder default.cse)


{-| Decode the `list` block. `chunks`, `consIntrinsic` and `mapTemplate` are
JSON-configurable; `report` is env-only (`ECO_LIST_REPORT=1`).
-}
listDecoder : D.Decoder x ListConfig
listDecoder =
    D.pure
        (\chunks consIntrinsic mapTemplate ->
            { chunks = chunks
            , consIntrinsic = consIntrinsic
            , mapTemplate = mapTemplate
            , report = default.list.report
            }
        )
        |> D.apply (D.optionalField "chunks" D.bool default.list.chunks)
        |> D.apply (D.optionalField "consIntrinsic" D.bool default.list.consIntrinsic)
        |> D.apply (D.optionalField "mapTemplate" D.bool default.list.mapTemplate)


{-| Decode the `inline` block. `report` is env-only in spirit but accepted
from JSON for convenience; it never affects `hash`.
-}
cseDecoder : D.Decoder x CseConfig
cseDecoder =
    -- `report` is deliberately NOT JSON-settable: it is env-only, so it can stay
    -- out of `hash` without a project config silently changing the cache key.
    D.pure (\enabled minCost maxPerDef -> CseConfig enabled default.cse.report minCost maxPerDef)
        |> D.apply (D.optionalField "enabled" D.bool default.cse.enabled)
        |> D.apply (D.optionalField "minCost" D.int default.cse.minCost)
        |> D.apply (D.optionalField "maxPerDef" D.int default.cse.maxPerDef)


inlineDecoder : D.Decoder x InlineConfig
inlineDecoder =
    D.pure InlineConfig
        |> D.apply (D.optionalField "preMonoThreshold" D.int default.inline.preMonoThreshold)
        |> D.apply (D.optionalField "postMonoThreshold" D.int default.inline.postMonoThreshold)
        |> D.apply (D.optionalField "etaThreshold" D.int default.inline.etaThreshold)
        |> D.apply (D.optionalField "whitelist" (D.list D.string) default.inline.whitelist)
        |> D.apply (D.optionalField "blacklist" (D.list D.string) default.inline.blacklist)
        |> D.apply (D.optionalField "maxPerFunction" D.int default.inline.maxPerFunction)
        |> D.apply (D.optionalField "preMonoFixpointIterations" D.int default.inline.preMonoFixpointIterations)
        |> D.apply (D.optionalField "postMonoFixpointIterations" D.int default.inline.postMonoFixpointIterations)
        |> D.apply (D.optionalField "hofThreshold" D.int default.inline.hofThreshold)
        |> D.apply (D.optionalField "loopify" D.bool default.inline.loopify)
        |> D.apply (D.optionalField "arityRaise" D.bool default.inline.arityRaise)
        |> D.apply (D.optionalField "raiseAppliedShareMin" D.int default.inline.raiseAppliedShareMin)
        |> D.apply (D.optionalField "partialHof" D.bool default.inline.partialHof)
        |> D.apply (D.optionalField "preserveSets" D.bool default.inline.preserveSets)
        |> D.apply (D.optionalField "pruneDead" D.bool default.inline.pruneDead)
        |> D.apply (D.optionalField "preMono" D.bool default.inline.preMono)
        |> D.apply (D.optionalField "postMono" D.bool default.inline.postMono)
        |> D.apply (D.optionalField "etaExpand" D.bool default.inline.etaExpand)
        |> D.apply (D.optionalField "etaOnly" (D.list D.string) default.inline.etaOnly)
        |> D.apply (D.optionalField "report" D.bool default.inline.report)
        |> D.apply (D.optionalField "kernelFactsDce" D.bool default.inline.kernelFactsDce)
        |> D.apply (D.optionalField "kernelCostClasses" D.bool default.inline.kernelCostClasses)
        |> D.apply (D.optionalField "kernelCostInline" D.int default.inline.kernelCostInline)
        |> D.apply (D.optionalField "kernelCostGcLeaf" D.int default.inline.kernelCostGcLeaf)
        |> D.apply (D.optionalField "kernelCostAlloc" D.int default.inline.kernelCostAlloc)
        |> D.apply (D.optionalField "kernelCostHof" D.int default.inline.kernelCostHof)
        |> D.apply (D.optionalField "aliasForward" D.bool default.inline.aliasForward)


bytesFusionDecoder : D.Decoder x BytesFusionConfig
bytesFusionDecoder =
    D.pure BytesFusionConfig
        |> D.apply (D.optionalField "enabled" D.bool default.bytesFusion.enabled)


cafMemoDecoder : D.Decoder x CafMemoConfig
cafMemoDecoder =
    D.pure CafMemoConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.enabled)
        |> D.apply (D.optionalField "census" D.bool default.cafMemo.census)
        |> D.apply (D.optionalField "dedupe" D.bool default.cafMemo.dedupe)
        |> D.apply (D.optionalField "hoist" cafHoistDecoder default.cafMemo.hoist)


cafHoistDecoder : D.Decoder x CafHoistConfig
cafHoistDecoder =
    D.pure CafHoistConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.hoist.enabled)
        |> D.apply (D.optionalField "minNodes" D.int default.cafMemo.hoist.minNodes)
        |> D.apply (D.optionalField "maxHoists" D.int default.cafMemo.hoist.maxHoists)


logicalTypesDecoder : D.Decoder x LogicalTypesConfig
logicalTypesDecoder =
    D.pure LogicalTypesConfig
        |> D.apply (D.optionalField "customMaxFields" D.int default.logicalTypes.customMaxFields)


{-| Decode the `borrow` block. `reify` is a string `"off"|"rc"`; `report`/
`validate` are accepted from JSON for convenience but never affect `hash`.
`oracleOpt` (OC0.1) is artifact-affecting (hash token `bopt=1`).
-}
borrowDecoder : D.Decoder x BorrowConfig
borrowDecoder =
    D.pure
        (\enabled reifyStr report validate oracleOpt ->
            { enabled = enabled
            , reify = Maybe.withDefault default.borrow.reify (borrowReifyFromString reifyStr)
            , report = report
            , validate = validate
            , oracleOpt = oracleOpt
            }
        )
        |> D.apply (D.optionalField "enabled" D.bool default.borrow.enabled)
        |> D.apply (D.optionalField "reify" D.string "off")
        |> D.apply (D.optionalField "report" D.bool default.borrow.report)
        |> D.apply (D.optionalField "validate" D.bool default.borrow.validate)
        |> D.apply (D.optionalField "oracleOpt" D.bool default.borrow.oracleOpt)


{-| Parse a borrow-reify mode name (case-insensitive). `Nothing` on unknown.
-}
borrowReifyFromString : String -> Maybe BorrowReify
borrowReifyFromString s =
    case String.toLower (String.trim s) of
        "off" ->
            Just ROff

        "rc" ->
            Just RRc

        _ ->
            Nothing


{-| Decode the `mono` block. Only `engine` is JSON-configurable; an unrecognized
string falls back to the default. `diffDump` is env-only (never from JSON).
-}
monoDecoder : D.Decoder x MonoConfig
monoDecoder =
    D.pure
        (\s lss limits ->
            { engine = Maybe.withDefault default.mono.engine (monoEngineFromString s)
            , diffDump = default.mono.diffDump
            , validate = default.mono.validate
            , lss = lss
            , limits = limits
            }
        )
        |> D.apply (D.optionalField "engine" D.string "subst")
        |> D.apply (D.optionalField "lss" lssDecoder defaultLss)
        |> D.apply (D.optionalField "limits" specLimitsDecoder defaultLimits)


{-| Decode the `mono.limits` block (MONO\_030 watchdogs). Never affects `hash`.
-}
specLimitsDecoder : D.Decoder x SpecLimits
specLimitsDecoder =
    D.pure SpecLimits
        |> D.apply (D.optionalField "specTypeNodes" D.int defaultLimits.specTypeNodes)
        |> D.apply (D.optionalField "specBreadth" D.int defaultLimits.specBreadth)


{-| Decode the `mono.lss` block. `report` is env-only in spirit but accepted
from JSON for convenience; it never affects `hash`.
-}
lssDecoder : D.Decoder x LssConfig
lssDecoder =
    D.pure LssConfig
        |> D.apply (D.optionalField "enabled" D.bool defaultLss.enabled)
        |> D.apply (D.optionalField "keyed" D.bool defaultLss.keyed)
        |> D.apply (D.optionalField "keyedGlobals" (D.list D.string) defaultLss.keyedGlobals)
        |> D.apply (D.optionalField "devirtFnGlobals" D.bool defaultLss.devirtFnGlobals)
        |> D.apply (D.optionalField "maxSetSize" D.int defaultLss.maxSetSize)
        |> D.apply (D.optionalField "maxSpecsPerGlobal" D.int defaultLss.maxSpecsPerGlobal)
        |> D.apply (D.optionalField "report" D.bool defaultLss.report)
        -- APPEND ONLY, and LAST: this apply chain is POSITIONAL, so an
        -- insertion anywhere above silently swaps two flags' values and still
        -- type-checks (every field above is a Bool or an Int).
        |> D.apply (D.optionalField "spineArity" D.bool defaultLss.spineArity)
        |> D.apply (D.optionalField "muTie" D.bool defaultLss.muTie)
        |> D.apply (D.optionalField "groundStandalones" D.bool defaultLss.groundStandalones)
        |> D.apply (D.optionalField "sigFlow" D.bool defaultLss.sigFlow)
        |> D.apply (D.optionalField "layoutQualMembers" D.bool defaultLss.layoutQualMembers)
        |> D.apply (D.optionalField "postSettleDevirt" D.bool defaultLss.postSettleDevirt)
        |> D.apply (D.optionalField "arrowIdentity" D.bool defaultLss.arrowIdentity)
        |> D.apply (D.optionalField "arrowSolverRoots" D.bool defaultLss.arrowSolverRoots)
        |> D.apply (D.optionalField "qSolve" D.bool defaultLss.qSolve)
        |> D.apply (D.optionalField "refIdentity" D.bool defaultLss.refIdentity)
        |> D.apply (D.optionalField "qCensus" D.bool defaultLss.qCensus)
        |> D.apply (D.optionalField "papMembers" D.bool defaultLss.papMembers)
        |> D.apply (D.optionalField "sigRootIdentity" D.bool defaultLss.sigRootIdentity)
        |> D.apply (D.optionalField "arrowCensus" D.bool defaultLss.arrowCensus)
        |> D.apply (D.optionalField "regIdentity" D.bool defaultLss.regIdentity)
        |> D.apply (D.optionalField "rootFold" D.bool defaultLss.rootFold)
        |> D.apply (D.optionalField "refPapSpine" D.bool defaultLss.refPapSpine)
        |> D.apply (D.optionalField "injTotal" D.bool defaultLss.injTotal)
        |> D.apply (D.optionalField "argPoints" D.bool defaultLss.argPoints)
        |> D.apply (D.optionalField "rsTop" D.bool defaultLss.rsTop)
        |> D.apply (D.optionalField "destrAnno" D.bool defaultLss.destrAnno)
        |> D.apply lssFlowDecoder
        |> D.apply lssSettleDecoder
        |> D.apply lssStageAnchorDecoder
        |> D.apply lssInstanceQualDecoder


{-| Decode the settle sub-record from the SAME flat JSON keys the fields had
before the sub-record bundling (2026-09-02, plans/lss-stage-anchor-writers.md
§3L ORDER 0) — the eco-config.json schema is unchanged by the restructure.
-}
lssSettleDecoder : D.Decoder x LssSettleConfig
lssSettleDecoder =
    D.pure LssSettleConfig
        |> D.apply (D.optionalField "varSucc" D.bool defaultLss.settle.varSucc)
        |> D.apply (D.optionalField "varCtorRows" D.bool defaultLss.settle.varCtorRows)
        |> D.apply (D.optionalField "varLambda" D.bool defaultLss.settle.varLambda)


{-| Flat keys, prefixed — new with the sub-record (no schema history to keep).
-}
lssStageAnchorDecoder : D.Decoder x LssStageAnchorConfig
lssStageAnchorDecoder =
    D.pure LssStageAnchorConfig
        |> D.apply (D.optionalField "stageAnchorRowFill" D.bool defaultLss.stageAnchor.rowFill)
        |> D.apply (D.optionalField "stageAnchorDemandFill" D.bool defaultLss.stageAnchor.demandFill)


{-| `flowConnect` keeps its historical flat key; `flowLetOverlay` is new.
-}
lssFlowDecoder : D.Decoder x LssFlowConfig
lssFlowDecoder =
    D.pure LssFlowConfig
        |> D.apply (D.optionalField "flowConnect" D.bool defaultLss.flow.connect)
        |> D.apply (D.optionalField "flowLetOverlay" D.bool defaultLss.flow.letOverlay)
        |> D.apply (D.optionalField "flowRowDefer" D.bool defaultLss.flow.rowDefer)
        |> D.apply (D.optionalField "flowAccessFlow" D.bool defaultLss.flow.accessFlow)
        |> D.apply (D.optionalField "flowLitFacts" D.bool defaultLss.flow.litFacts)


{-| Flat keys, prefixed — new with the sub-record (no schema history to keep).
-}
lssInstanceQualDecoder : D.Decoder x LssStampConfig
lssInstanceQualDecoder =
    D.pure LssStampConfig
        |> D.apply (D.optionalField "instanceQual" D.bool defaultLss.stamp.enabled)
        |> D.apply (D.optionalField "instanceQualMaxInstances" D.int defaultLss.stamp.maxInstances)
        |> D.apply (D.optionalField "flatPeel" D.bool defaultLss.stamp.flatPeel)
        |> D.apply (D.optionalField "census" D.bool defaultLss.stamp.census)
        |> D.apply (D.optionalField "papFast" D.bool defaultLss.stamp.papFast)
        |> D.apply (D.optionalField "instanceQualUseInject" D.bool defaultLss.stamp.useInject)
        |> D.apply (D.optionalField "instanceQualUseInjectPap" D.bool defaultLss.stamp.useInjectPap)
        |> D.apply (D.optionalField "rootFoldDepth" D.bool defaultLss.stamp.rootFoldDepth)


{-| Parse a monomorphizer-engine name (case-insensitive), used by both the JSON
decoder and the `ECO_MONO_ENGINE` env override. `Nothing` on an unknown value.
-}
monoEngineFromString : String -> Maybe MonoEngine
monoEngineFromString s =
    case String.toLower (String.trim s) of
        "subst" ->
            Just EngineSubst

        "solver" ->
            Just EngineSolver

        "diff" ->
            Just EngineDiff

        _ ->
            Nothing


{-| Clamp values that have hard bounds, returning the corrected config plus any
warning messages to surface to the user. Currently guards
`logicalTypes.customMaxFields` against the `[1,24]` heap ABI range.
-}
clamp : EcoConfig -> ( EcoConfig, List String )
clamp cfg =
    let
        cmf =
            cfg.logicalTypes.customMaxFields
    in
    if cmf < 1 || cmf > 24 then
        let
            clamped =
                Basics.clamp 1 24 cmf
        in
        ( { cfg | logicalTypes = { customMaxFields = clamped } }
        , [ "eco-config.json: logicalTypes.customMaxFields "
                ++ String.fromInt cmf
                ++ " is out of range [1,24]; clamped to "
                ++ String.fromInt clamped
                ++ "."
          ]
        )

    else
        ( cfg, [] )


{-| A stable, canonical key for the effective config, used to invalidate caches
when the config changes. Comparison is plain string equality; an absent file
(decoded as `default`) hashes identically to an explicit defaults file.
-}
hash : EcoConfig -> String
hash cfg =
    String.join "|"
        ([ "v1"
         , "preThr=" ++ String.fromInt cfg.inline.preMonoThreshold
         , "postThr=" ++ String.fromInt cfg.inline.postMonoThreshold
         , "etaThr=" ++ String.fromInt cfg.inline.etaThreshold
         , "phof="
            ++ (if cfg.inline.partialHof then
                    "1"

                else
                    "0"
               )
         , "psets="
            ++ (if cfg.inline.preserveSets then
                    "1"

                else
                    "0"
               )
         , "prune="
            ++ (if cfg.inline.pruneDead then
                    "1"

                else
                    "0"
               )
         , "preInl="
            ++ (if cfg.inline.preMono then
                    "1"

                else
                    "0"
               )
         , "postInl="
            ++ (if cfg.inline.postMono then
                    "1"

                else
                    "0"
               )
         , "eta="
            ++ (if cfg.inline.etaExpand then
                    "1"

                else
                    "0"
               )
         , "etaOnly=" ++ String.join "," cfg.inline.etaOnly
         , "afwd="
            ++ (if cfg.inline.aliasForward then
                    "1"

                else
                    "0"
               )
         , "wl=" ++ String.join "," cfg.inline.whitelist
         , "bl=" ++ String.join "," cfg.inline.blacklist
         , "mpf=" ++ String.fromInt cfg.inline.maxPerFunction
         , "preFpi=" ++ String.fromInt cfg.inline.preMonoFixpointIterations
         , "postFpi=" ++ String.fromInt cfg.inline.postMonoFixpointIterations
         , "hthr=" ++ String.fromInt cfg.inline.hofThreshold
         , "loop="
            ++ (if cfg.inline.loopify then
                    "1"

                else
                    "0"
               )
         , "bf="
            ++ (if cfg.bytesFusion.enabled then
                    "1"

                else
                    "0"
               )
         , "cmf=" ++ String.fromInt cfg.logicalTypes.customMaxFields
         ]
            -- CAF-memoization token appears when ENABLED (the default):
            -- enabling changes generated MLIR, so the new default must
            -- invalidate every pre-feature cache once. ECO_CAF_MEMO=0
            -- hashes like the pre-feature world and can share its caches.
            ++ (if cfg.cafMemo.enabled then
                    [ "cafm=1" ]

                else
                    []
               )
            -- CAF-dedupe token appears ONLY when enabled (default-off), so
            -- default configs hash exactly as before. Artifact-affecting:
            -- deduping rewrites spec references in generated MLIR.
            ++ (if cfg.cafMemo.dedupe then
                    [ "cafd=1" ]

                else
                    []
               )
            -- CAF-hoist tokens (plans/caf-hoist-closed-expressions.md DQ9):
            -- artifact-affecting, so they key caches when the pass is on;
            -- knob tokens only when non-default so default-on configs share.
            ++ (if cfg.cafMemo.hoist.enabled then
                    "cafh=1"
                        :: ((if cfg.cafMemo.hoist.minNodes /= default.cafMemo.hoist.minNodes then
                                [ "cafhN=" ++ String.fromInt cfg.cafMemo.hoist.minNodes ]

                             else
                                []
                            )
                                ++ (if cfg.cafMemo.hoist.maxHoists /= default.cafMemo.hoist.maxHoists then
                                        [ "cafhM=" ++ String.fromInt cfg.cafMemo.hoist.maxHoists ]

                                    else
                                        []
                                   )
                           )

                else
                    []
               )
            -- Arity-raise token appears ONLY when enabled, so default
            -- configs hash exactly as before (no global cache invalidation).
            -- The applied-share threshold (H6.2.5 Lever 2) joins only when
            -- nonzero AND raising is on — it changes which specs raise, so
            -- it must invalidate flag-on caches, and only those.
            ++ (if cfg.inline.arityRaise then
                    "ar=1"
                        :: (if cfg.inline.raiseAppliedShareMin > 0 then
                                [ "arm=" ++ String.fromInt cfg.inline.raiseAppliedShareMin ]

                            else
                                []
                           )

                else
                    []
               )
            ++ (if cfg.inline.kernelFactsDce then
                    [ "kfdce=1" ]

                else
                    []
               )
            ++ (if cfg.callPurityAttrs then
                    [ "cpur=1" ]

                else
                    []
               )
            -- `cse.report` contributes NO token: it is output-only.
            ++ (if cfg.cse.enabled then
                    "cse=1"
                        :: (if cfg.cse.minCost /= default.cse.minCost then
                                [ "cseMin=" ++ String.fromInt cfg.cse.minCost ]

                            else
                                []
                           )
                        ++ (if cfg.cse.maxPerDef /= default.cse.maxPerDef then
                                [ "cseMax=" ++ String.fromInt cfg.cse.maxPerDef ]

                            else
                                []
                           )

                else
                    []
               )
            -- The WHOLE vector, so each constant A/B leg is cache-disjoint.
            ++ (if cfg.inline.kernelCostClasses then
                    [ "kcc="
                        ++ String.fromInt cfg.inline.kernelCostInline
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostGcLeaf
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostAlloc
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostHof
                    ]

                else
                    []
               )
            -- Engine token appears ONLY for non-default engines, so a default
            -- config (or any absent eco-config.json) hashes exactly as before.
            ++ (case cfg.mono.engine of
                    EngineSubst ->
                        []

                    EngineSolver ->
                        [ "mono=solver" ]

                    EngineDiff ->
                        [ "mono=diff" ]
               )
            -- LSS tokens appear ONLY for non-default values (report excluded:
            -- output-only, never affects artifacts).
            ++ (let
                    lss =
                        cfg.mono.lss
                in
                List.concat
                    [ if lss.enabled then
                        [ "lss=1" ]

                      else
                        []
                    , if lss.keyed then
                        [ "lssK=1" ]

                      else
                        []
                    , if List.isEmpty lss.keyedGlobals then
                        []

                      else
                        -- E5 selective keying: sorted so equivalent configs
                        -- share artifacts regardless of listing order.
                        [ "lssKG=" ++ String.join "," (List.sort lss.keyedGlobals) ]
                    , if lss.devirtFnGlobals then
                        [ "lssDF=1" ]

                      else
                        []
                    , if lss.maxSetSize /= defaultLss.maxSetSize then
                        [ "lssS=" ++ String.fromInt lss.maxSetSize ]

                      else
                        []
                    , if lss.maxSpecsPerGlobal /= defaultLss.maxSpecsPerGlobal then
                        [ "lssB=" ++ String.fromInt lss.maxSpecsPerGlobal ]

                      else
                        []
                    , if lss.spineArity then
                        [ "lssSA=1" ]

                      else
                        []

                    -- LSS_018 μ-tie: artifact-affecting under keyed routing
                    -- (tied member ids change annotations → keys → fan-out).
                    -- Token when non-default so the default config's hash is
                    -- stable across the B1→B3 rollout of the default itself.
                    , if lss.muTie /= defaultLss.muTie then
                        [ "lssMU="
                            ++ (if lss.muTie then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- LSS_019 grounding: artifact-affecting under keyed
                    -- routing (ground member ids change annotations → keys →
                    -- fan-out). Token when non-default, muTie-style, so the
                    -- default config's hash is stable across the G1→G3
                    -- rollout of the default itself.
                    , if lss.groundStandalones /= defaultLss.groundStandalones then
                        [ "lssGS="
                            ++ (if lss.groundStandalones then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- LSS_020 signature set-flow: artifact-affecting under
                    -- keyed routing (signature members reach caller
                    -- instantiations → annotations → keys → fan-out). Token
                    -- when non-default, muTie-style, so the default config's
                    -- hash is stable across an eventual default flip.
                    , if lss.sigFlow /= defaultLss.sigFlow then
                        [ "lssSF="
                            ++ (if lss.sigFlow then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Instance-qualified members: artifact-affecting for
                    -- exactly the LSS_024 reason (member ids → annotations →
                    -- keyed spec keys → fan-out). Env vars are NOT ninja
                    -- inputs and the harness cache is env-blind, so without
                    -- these tokens an A/B serves stale artifacts and both arms
                    -- measure the same binary.
                    , if lss.stamp.enabled /= defaultLss.stamp.enabled then
                        [ "lssIQ="
                            ++ (if lss.stamp.enabled then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    , if lss.stamp.maxInstances /= defaultLss.stamp.maxInstances then
                        [ "lssIQM=" ++ String.fromInt lss.stamp.maxInstances ]

                      else
                        []

                    -- Fix A: artifact-affecting (it changes WHICH sites get
                    -- stamped, hence CallInfo, hence emitted MLIR). Env vars
                    -- are not ninja inputs and the harness cache is env-blind,
                    -- so without this token an A/B serves stale artifacts.
                    , if lss.stamp.flatPeel /= defaultLss.stamp.flatPeel then
                        [ "lssFP="
                            ++ (if lss.stamp.flatPeel then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- LSS_024 layout-qualified members: artifact-affecting
                    -- under keyed routing (member ids → annotations → keys →
                    -- fan-out). Token when non-default, muTie-style, so the
                    -- default config's hash is stable across an eventual
                    -- default flip.
                    , if lss.layoutQualMembers /= defaultLss.layoutQualMembers then
                        [ "lssLQ="
                            ++ (if lss.layoutQualMembers then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- E9.5 post-settle devirt: artifact-affecting (rewrites
                    -- call sites to direct form). Token when non-default,
                    -- layoutQual-style.
                    , if lss.postSettleDevirt /= defaultLss.postSettleDevirt then
                        [ "lssDP="
                            ++ (if lss.postSettleDevirt then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Phase 2a arrow identity: artifact-affecting when on
                    -- (shared set slots reach annotations and therefore keyed
                    -- spec keys). Token when non-default.
                    , if lss.arrowIdentity /= defaultLss.arrowIdentity then
                        [ "lssAI="
                            ++ (if lss.arrowIdentity then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Phase 2b solver-root arrow ids: artifact-affecting when
                    -- on (arrows the type checker unified share one set slot).
                    , if lss.arrowSolverRoots /= defaultLss.arrowSolverRoots then
                        [ "lssAR="
                            ++ (if lss.arrowSolverRoots then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- §5.2/§5.3 scheme instantiation: artifact-affecting when
                    -- on (it changes what a def's set variables resolve to).
                    , if lss.qSolve /= defaultLss.qSolve then
                        [ "lssQS="
                            ++ (if lss.qSolve then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    , if lss.refIdentity /= defaultLss.refIdentity then
                        [ "lssRI="
                            ++ (if lss.refIdentity then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- §5.1/§5.6 shadow Q: read-only, but it rides the config
                    -- hash so a verifier run cannot reuse a non-verifier cache.
                    , if lss.qCensus /= defaultLss.qCensus then
                        [ "lssQC="
                            ++ (if lss.qCensus then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Census collection changes no output, but it changes the
                    -- work done, so a census build must not reuse a
                    -- non-census cache entry (and vice versa).
                    , if lss.stamp.census /= defaultLss.stamp.census then
                        [ "lssCen="
                            ++ (if lss.stamp.census then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- LSS_040 p| fast stamp: artifact-affecting.
                    , if lss.stamp.papFast /= defaultLss.stamp.papFast then
                        [ "lssPF="
                            ++ (if lss.stamp.papFast then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- F2 local-multi use-site injection: artifact-affecting.
                    , if lss.stamp.useInject /= defaultLss.stamp.useInject then
                        [ "lssIU="
                            ++ (if lss.stamp.useInject then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- F2.c PAP-RHS use-site injection: artifact-affecting.
                    , if lss.stamp.useInjectPap /= defaultLss.stamp.useInjectPap then
                        [ "lssIUP="
                            ++ (if lss.stamp.useInjectPap then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Injection completeness: PAP residual members are
                    -- artifact-affecting (members → annotations → keys).
                    , if lss.papMembers /= defaultLss.papMembers then
                        [ "lssPM="
                            ++ (if lss.papMembers then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Solver-root signature identity: ties a def's annotation
                    -- arrows to its body's, so signatures carry facts they did
                    -- not before — annotations move, keys move.
                    , if lss.sigRootIdentity /= defaultLss.sigRootIdentity then
                        [ "lssSR="
                            ++ (if lss.sigRootIdentity then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Liveness census: read-only, but it rides the hash so a
                    -- census run cannot reuse a non-census cache (`qCensus`'s
                    -- rule).
                    , if lss.arrowCensus /= defaultLss.arrowCensus then
                        [ "lssAC="
                            ++ (if lss.arrowCensus then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Registration self-identity: artifact-affecting (stored
                    -- types and keyed spec keys move).
                    , if lss.regIdentity /= defaultLss.regIdentity then
                        [ "lssRG="
                            ++ (if lss.regIdentity then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Root-member fold: artifact-affecting (member-id
                    -- allocation order and set contents move).
                    , if lss.rootFold /= defaultLss.rootFold then
                        [ "lssRF="
                            ++ (if lss.rootFold then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Depth-qualified root-fold spine: artifact-affecting
                    -- (the def's own inner-arrow annotations move, and with
                    -- them keyed spec keys).
                    , if lss.stamp.rootFoldDepth /= defaultLss.stamp.rootFoldDepth then
                        [ "lssRFD="
                            ++ (if lss.stamp.rootFoldDepth then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Reference-spine PAP successors: artifact-affecting
                    -- (annotations and keyed spec keys move).
                    , if lss.refPapSpine /= defaultLss.refPapSpine then
                        [ "lssRP="
                            ++ (if lss.refPapSpine then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Injection-totality completion: artifact-affecting
                    -- (stored types and member allocation move).
                    , if lss.injTotal /= defaultLss.injTotal then
                        [ "lssIT="
                            ++ (if lss.injTotal then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- M2 arg-point transport: artifact-affecting when on.
                    , if lss.argPoints /= defaultLss.argPoints then
                        [ "lssAP="
                            ++ (if lss.argPoints then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- P1 restatement-⊤ recovery: artifact-affecting when on
                    -- (stored registry types move, hence retranslation
                    -- demand keys and spec keys).
                    , if lss.rsTop /= defaultLss.rsTop then
                        [ "lssRT="
                            ++ (if lss.rsTop then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Destructor annotations: artifact-affecting when on
                    -- (varEnv-bound types move, hence demand keys).
                    , if lss.destrAnno /= defaultLss.destrAnno then
                        [ "lssDA="
                            ++ (if lss.destrAnno then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Var successor writes: artifact-affecting when on
                    -- (registry row annotations move).
                    , if lss.settle.varSucc /= defaultLss.settle.varSucc then
                        [ "lssVS="
                            ++ (if lss.settle.varSucc then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Ctor-row var writes: artifact-affecting when on.
                    , if lss.settle.varCtorRows /= defaultLss.settle.varCtorRows then
                        [ "lssVC="
                            ++ (if lss.settle.varCtorRows then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Lambda-home var writes: artifact-affecting when on.
                    , if lss.settle.varLambda /= defaultLss.settle.varLambda then
                        [ "lssVL="
                            ++ (if lss.settle.varLambda then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Flow-connect write-back: artifact-affecting (demand
                    -- types move, hence SpecKeys — AR-F3).
                    , if lss.flow.connect /= defaultLss.flow.connect then
                        [ "lssFC="
                            ++ (if lss.flow.connect then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- F3-b let overlay: artifact-affecting (binding
                    -- annotations reach demands, hence SpecKeys).
                    , if lss.flow.letOverlay /= defaultLss.flow.letOverlay then
                        [ "lssFLO="
                            ++ (if lss.flow.letOverlay then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- F3-a row-deferred destructure sets: artifact-affecting.
                    , if lss.flow.rowDefer /= defaultLss.flow.rowDefer then
                        [ "lssFRD="
                            ++ (if lss.flow.rowDefer then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- E15 access flow: artifact-affecting.
                    , if lss.flow.accessFlow /= defaultLss.flow.accessFlow then
                        [ "lssFAF="
                            ++ (if lss.flow.accessFlow then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- F4-sig literal facts: artifact-affecting.
                    , if lss.flow.litFacts /= defaultLss.flow.litFacts then
                        [ "lssFLF="
                            ++ (if lss.flow.litFacts then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Stage-anchor rowFill: artifact-affecting when on
                    -- (registry row annotations move).
                    , if lss.stageAnchor.rowFill /= defaultLss.stageAnchor.rowFill then
                        [ "lssSAr="
                            ++ (if lss.stageAnchor.rowFill then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Stage-anchor demandFill: artifact-affecting when on
                    -- (demand/registry annotations move mid-drain).
                    , if lss.stageAnchor.demandFill /= defaultLss.stageAnchor.demandFill then
                        [ "lssSAd="
                            ++ (if lss.stageAnchor.demandFill then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    ]
               )
            -- Chunked-list token appears ONLY when enabled (the default since
            -- Aug 3 2026), so chunked and non-chunked artifacts key separate
            -- cache entries. Artifact-affecting: L1.2+ codegen consults it
            -- (plans/chunked-list-representation.md).
            ++ (if cfg.list.chunks then
                    [ "lchunks=1" ]

                else
                    []
               )
            -- kernel-opt-01: the cons intrinsic changes emitted code, so the
            -- token appears ONLY when enabled and flag-off builds keep every
            -- existing cache entry.
            ++ (if cfg.list.consIntrinsic then
                    [ "lcons=1" ]

                else
                    []
               )
            -- list-map template: replaces licensed List.map spec BODIES, so a
            -- flag-on artifact must never be served from a flag-off cache.
            -- Token appears only when enabled, so every existing (default-off)
            -- cache entry keys exactly as it did before this flag existed.
            ++ (if cfg.list.mapTemplate then
                    [ "lmapt=1" ]

                else
                    []
               )
            -- Aggregate-promotion token appears ONLY when enabled (the default
            -- since 2026-08-04, U-T1.3.1): promoting rewrites tuple constructs
            -- to eco.make.* in generated MLIR, so flag-on artifacts must never
            -- share flag-off caches; explicitly-disabled configs hash exactly
            -- like the historical default-off caches.
            ++ (if cfg.aggPromote then
                    [ "aggp=1" ]

                else
                    []
               )
            -- Ctor-inlining token, same posture as aggp: appears only when
            -- enabled (the default since 2026-08-04, U-T1.3.2c) — flag-on
            -- artifacts must never share flag-off caches; explicitly-disabled
            -- configs hash exactly like the historical default-off caches.
            ++ (if cfg.ctorInline then
                    [ "ctori=1" ]

                else
                    []
               )
            ++ (if cfg.sretResults then
                    [ "sretr=1" ]

                else
                    []
               )
            ++ (if cfg.psplitParams then
                    [ "psplit=1" ]

                else
                    []
               )
            ++ (if cfg.sretFresh then
                    [ "sretf=1" ]

                else
                    []
               )
            ++ (if cfg.sretTailFuncs then
                    [ "srtf=1" ]

                else
                    []
               )
            -- kernel-opt-04: eco.string.length emission rewrites the generated
            -- MLIR, so flag-on artifacts must never share flag-off caches;
            -- explicitly-disabled configs hash exactly like today's defaults.
            ++ (if cfg.stringLengthOp then
                    [ "strlen=1" ]

                else
                    []
               )
            -- kernel-opt-05: the typed append ops rewrite emitted MLIR, so
            -- flag-on artifacts must never share flag-off caches.
            ++ (if cfg.appendSplit then
                    [ "apsplit=1" ]

                else
                    []
               )
            -- kernel-opt-06: String ordering rewrites emitted MLIR.
            ++ (if cfg.stringOrderIntrinsic then
                    [ "strord=1" ]

                else
                    []
               )
            -- kernel-opt-03: eco.value.eq emission rewrites the generated MLIR.
            ++ (if cfg.valueEq then
                    [ "veq=1" ]

                else
                    []
               )
            -- kernel-opt-08: gc-leaf stamping rewrites the emitted kernel decls,
            -- so flag-on artifacts must never share flag-off caches.
            ++ (if cfg.kernelGcLeaf then
                    [ "kgcl=1" ]

                else
                    []
               )
            -- Borrow-oracle opt-in token (OC0.1, plans/borrow-oracle-
            -- consumers.md): the FIRST artifact-affecting borrow knob — the
            -- rest of the borrow block (enabled/reify/report/validate) stays
            -- hash-inert. Appears ONLY when enabled (default-off), so every
            -- existing config hashes exactly as before; opt builds must never
            -- share caches with default builds.
            ++ (if cfg.borrow.oracleOpt then
                    [ "bopt=1" ]

                else
                    []
               )
        )
