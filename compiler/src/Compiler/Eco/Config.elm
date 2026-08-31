module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash, clamp
    , BorrowConfig, BorrowReify(..), CafHoistConfig, CafMemoConfig, CseConfig, ListConfig, LssConfig, MonoConfig, MonoEngine(..), SpecLimits, borrowReifyFromString, defaultLimits, defaultLss, monoEngineFromString
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


{-| MONO_030 spec watchdogs (`plans/lss-fidelity-1-watchdogs-budget-accounting.md`
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
    -- DEFAULT-OFF, and it should stay off until Phase 3: §10.9 measured that
    -- slot sharing WITHOUT a per-use set variable trades the context
    -- sensitivity that manufactures usable singletons (−0.50 pp fast dispatch,
    -- 99% of it one de-stamped site), and 2b shares strictly MORE contexts
    -- than 2a. Hash token `lssAR=1`; env `ECO_MONO_LSS_ARROW_ROOTS`.
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
    -- Artifact-affecting. DEFAULT-ON since 2026-08-27. Escape hatch
    -- `ECO_MONO_LSS_SIG_ROOT_ID=0`; hash token `lssSR=0` now rides the OFF
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

    -- Var chain-root writes, Phase 1 (plans/lss-var-chain-roots.md §3):
    -- post-drain settle sweep writing the PAP successor member into flex
    -- result slots of pap-able singleton/kN heads, strictly within
    -- declared arity. Sound unconditionally (type-level identity;
    -- beyond-arity results belong to the body, LSS_013). DEFAULT-ON since
    -- 2026-08-31 (with varCtorRows: var −19.2 %, coverage +1.91 pp, ⊤
    -- unchanged, accounting exact, all gates green — §4.4). Escape hatch
    -- `ECO_MONO_LSS_VAR_SUCC=0`; hash token `lssVS=0` rides the OFF arm.
    , varSucc : Bool

    -- Var chain-root writes, Phase 2b (plans/lss-var-chain-roots.md §3):
    -- post-drain ctor-row var payload writes from the sibling-spec cell
    -- union, gated on the all-sets completeness rule (zero ⊤ contributors
    -- AND zero flex-marked construction vars at the cell — AR-V2/AR-V10;
    -- runs BEFORE the destrAnno ⊤-heal so the contamination evidence is
    -- still honest). DEFAULT-ON since 2026-08-31 (§4.4; flex gate
    -- protected 1,563 positions). Escape hatch
    -- `ECO_MONO_LSS_VAR_CTOR_ROWS=0`; hash token `lssVC=0` rides the OFF
    -- arm.
    , varCtorRows : Bool
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
    , arrowSolverRoots = False
    , qSolve = False
    , refIdentity = True
    , qCensus = False
    , papMembers = True
    , sigRootIdentity = True
    , arrowCensus = False
    , regIdentity = True
    , rootFold = True
    , refPapSpine = True
    , injTotal = True
    , argPoints = False
    , rsTop = True
    , destrAnno = True
    , varSucc = True
    , varCtorRows = True
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


{-| Inliner / simplifier knobs (consumed by `Compiler.GlobalOpt.MonoInlineSimplify`).

  - `whitelist` is **additive**: appended to the built-in `defaultWhitelist`.
  - `blacklist` is subtracted from the effective whitelist afterward.
  - `hofThreshold` is the cost budget for candidates with a CALLED
    function-typed parameter (HOFs whose lambda argument beta-reduces away
    at the call site — plan H2). The effective budget is
    `max threshold hofThreshold`, so it can only widen eligibility.
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
    { threshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , fixpointIterations : Int
    , hofThreshold : Int
    , loopify : Bool
    , arityRaise : Bool
    , raiseAppliedShareMin : Int
    , report : Bool
    , kernelFactsDce : Bool -- kernel-opt-11 (a): let the dead-binding gate drop a dead kernel call whose KernelFacts row is `droppable` (cseSafe AND totality == Total, and every argument pure). DEFAULT-ON since 2026-08-12 (realizable ceiling on the whole 261-module self-compile is FOUR sites, of which 2 realize -- it ships for the enabling value and for ending the isPureExpr/CafHoist contradiction, NOT for a measured win); env kill switch ECO_KERNEL_FACTS_DCE=0; artifact-affecting (hash token "kfdce=1"). Widens ONLY MonoInlineSimplify's dead-let gate -- the H2.5/H6.1 partial-forward guards keep the legacy all-calls-impure predicate
    , kernelCostClasses : Bool -- kernel-opt-11 (b): price a kernel call from its derived KernelFacts cost class (and from whether it lowers to an inline op) instead of the flat 6-per-call the inliner uses today. DEFAULT-ON since 2026-08-12 (changes real inlining decisions -- emitted .mlir +1,341 B, letDCE 498->441 -- wall FLAT at +0.56%); env kill switch ECO_KERNEL_COST_CLASSES=0; artifact-affecting (hash token "kcc=<i>/<g>/<a>/<h>", the whole vector, so every A/B leg is cache-disjoint). Independent of kernelFactsDce ON PURPOSE -- DCE deletes work, cost classes move inliner thresholds, and a shared flag would make per-constant attribution impossible
    , kernelCostInline : Int -- cost of a kernel call that lowers to an inline op (Intrinsics.kernelIntrinsic says Just); no call is emitted at all
    , kernelCostGcLeaf : Int -- cost of a CGcLeaf kernel call: no Elm GC, no C++ heap traffic, no callback
    , kernelCostAlloc : Int -- cost of a CAlloc kernel call: allocates on the Elm or C++ heap
    , kernelCostHof : Int -- cost of a CHof kernel call: re-enters Elm through a user closure
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
        { threshold = 10
        , whitelist = []
        , blacklist = []
        , maxPerFunction = 1000
        , fixpointIterations = 4

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
        , report = False
        , kernelFactsDce = True

        -- Starting vector. Today's uniform value is 6; these are the shape the
        -- audit implies, not a measured optimum -- each is A/B'd solo.
        , kernelCostClasses = True
        , kernelCostInline = 1
        , kernelCostGcLeaf = 4
        , kernelCostAlloc = 8
        , kernelCostHof = 20
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
        |> D.apply (D.optionalField "threshold" D.int default.inline.threshold)
        |> D.apply (D.optionalField "whitelist" (D.list D.string) default.inline.whitelist)
        |> D.apply (D.optionalField "blacklist" (D.list D.string) default.inline.blacklist)
        |> D.apply (D.optionalField "maxPerFunction" D.int default.inline.maxPerFunction)
        |> D.apply (D.optionalField "fixpointIterations" D.int default.inline.fixpointIterations)
        |> D.apply (D.optionalField "hofThreshold" D.int default.inline.hofThreshold)
        |> D.apply (D.optionalField "loopify" D.bool default.inline.loopify)
        |> D.apply (D.optionalField "arityRaise" D.bool default.inline.arityRaise)
        |> D.apply (D.optionalField "raiseAppliedShareMin" D.int default.inline.raiseAppliedShareMin)
        |> D.apply (D.optionalField "report" D.bool default.inline.report)
        |> D.apply (D.optionalField "kernelFactsDce" D.bool default.inline.kernelFactsDce)
        |> D.apply (D.optionalField "kernelCostClasses" D.bool default.inline.kernelCostClasses)
        |> D.apply (D.optionalField "kernelCostInline" D.int default.inline.kernelCostInline)
        |> D.apply (D.optionalField "kernelCostGcLeaf" D.int default.inline.kernelCostGcLeaf)
        |> D.apply (D.optionalField "kernelCostAlloc" D.int default.inline.kernelCostAlloc)
        |> D.apply (D.optionalField "kernelCostHof" D.int default.inline.kernelCostHof)


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


{-| Decode the `mono.limits` block (MONO_030 watchdogs). Never affects `hash`.
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
        |> D.apply (D.optionalField "varSucc" D.bool defaultLss.varSucc)
        |> D.apply (D.optionalField "varCtorRows" D.bool defaultLss.varCtorRows)


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
         , "thr=" ++ String.fromInt cfg.inline.threshold
         , "wl=" ++ String.join "," cfg.inline.whitelist
         , "bl=" ++ String.join "," cfg.inline.blacklist
         , "mpf=" ++ String.fromInt cfg.inline.maxPerFunction
         , "fpi=" ++ String.fromInt cfg.inline.fixpointIterations
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
                    , if lss.varSucc /= defaultLss.varSucc then
                        [ "lssVS="
                            ++ (if lss.varSucc then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []

                    -- Ctor-row var writes: artifact-affecting when on.
                    , if lss.varCtorRows /= defaultLss.varCtorRows then
                        [ "lssVC="
                            ++ (if lss.varCtorRows then
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
