module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash, clamp
    , BorrowConfig, BorrowReify(..), CafHoistConfig, CafMemoConfig, CseConfig, GcConfig, ListConfig, LssConfig, LssStampConfig, MonoConfig, MonoEngine(..), SpecLimits, borrowReifyFromString, defaultLimits, defaultLss, monoEngineFromString
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
    , constThunks : Int -- plans/mlir-split-backend-04-constant-thunks.md (CGEN_082): fold references to arity-0 constant thunks at codegen — 0 off, 1 literal/Unit/kernel-constant/alias chains, 2 (DEFAULT) also closed pure-arithmetic bodies (2A). Replaces the cgu IPSCCP prologue's thunk-return propagation and deletes the calls. Env ECO_CONST_THUNKS=0|1|2; artifact-affecting (hash token "cthk=N" when N > 0)
    , constThunksReport : Bool -- env ECO_CONST_THUNK_REPORT=1: constant-thunk census on stderr (ConstThunks.report); output-only, excluded from hash
    , cse : CseConfig
    , gc : GcConfig -- plans/frontend-heap-release.md §6.1: the explicit Eco.GC release before the native back end. EXCLUDED from `hash`: a collection never changes output. Env ECO_GC_PRE_LINK / ECO_GC_REPORT
    }


{-| Explicit-collection knobs (plans/frontend-heap-release.md §6.1).

`preLink` runs a full release immediately before `Eco.NativeDriver.lowerAndLink`
(default on; `ECO_GC_PRE_LINK=0` is an A/B opt-out); `report` prints one
`[gc-report]` line per collection on stderr (`ECO_GC_REPORT=1`). The optional
phase-boundary points were removed after measurement (benchmarks/fhr-gc-points.md). **Excluded from `hash`**:
a collection never changes the compiler's output.

-}
type alias GcConfig =
    { preLink : Bool
    , report : Bool
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

THE FLAGS ARE GONE (2026-09-18, plans/fix-lss-flags-at-defaults.md). 31 of
the 32 LSS flags were fixed at their defaults and removed WITH the branch each
one gated, so every mechanism they used to select is unconditional under
`enabled`. What is left is one switch, three numeric CAPS — policy values read
at one site, which impose no boundary and so unlock no merge — and four
censuses. There is no per-mechanism bisection any more; the gate that replaced
it is `benchmarks/mlir-workload-rail.sh`.

  - `enabled`: master switch (M2+). Also selects ALL-GLOBALS keying, which was
    `lss.keyed` until the removal.
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
    , maxSetSize : Int
    , maxSpecsPerGlobal : Int
    , report : Bool

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

    -- The instance-qualification cap and the stamping census
    -- (plans/lss-instance-qualified-members.md). A sub-record because
    -- `LssConfig` used to sit AT the runtime's 32-slot record GC-scan cap —
    -- it is 7 fields now, so that pressure is gone, but the grouping is worth
    -- keeping on its own terms. Env ECO_MONO_LSS_INSTANCE_QUAL_MAX /
    -- ECO_MONO_LSS_CENSUS; hash token lssIQM= rides the non-default cap.
    , stamp : LssStampConfig
    }


{-| The instance-qualification cap and the stamping census
(plans/lss-instance-qualified-members.md).

INSTANCE QUALIFICATION itself is unconditional (it was `lss.stamp.enabled`,
fixed at its default and removed 2026-09-18): a lambda instance minted while
re-translating the RHS of a LOCAL-MULTI instance carries that instance's
identity in its member id, on top of LSS\_017's source lambda and LSS\_024's
enclosing-spec widened key. Local-multi instance keying is
annotation-SENSITIVE (`Engine.recordMultiInstance`) while member qualification
was not, so two instances of one let-function shared ONE member id — a
singleton set indexing two different bodies, which AbiCloning correctly
refuses to stamp (`declinedBodyMismatch`) rather than miscompile.

`maxInstances`: the hard cap, and — since the flag went — the only way to
collapse the qualification back. `maxInstances = 1` tags nothing and
reproduces the pre-qualification behaviour exactly, which is what
`LssInstanceQualTest` now uses as its collapsed arm. The discriminator is the instance ORDINAL, not
its type — a type hash would put annotations back into member ids and reopen
the specs -> members -> keys spiral LSS\_018 exists to close. The ordinal keeps
that spiral bounded but not provably absent: an annotation split mints an
instance, whose new member id can drive a further split. Beyond the cap a mint
takes today's key (fence declines, status quo), so termination is structural.
0 means unlimited — do not ship it.

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
-- Lived HERE and not on `LssConfig` because `LssConfig` was AT the 32-slot
-- record GC-scan cap: a 33rd top-level field lowers to
-- `eco.construct.record field_count (33)` and the backend verifier rejects
-- it. `LssConfig` is 7 fields since the 2026-09-18 flag removal, so that
-- pressure is gone — but the cap itself has not moved, and it is what made
-- `flow`/`settle`/`stamp` sub-records in the first place.


type alias LssStampConfig =
    { maxInstances : Int
    , census : Bool
    }


{-| The built-in LSS defaults (budgets per the design doc).

`enabled = True` means **solver implies LSS** (H3, 2026-07-14): the solver
engine — now the `mono.engine` default (2026-07-22) — consults this block, so
default builds get lambda-set specialization without extra flags. The subst
engine never consults this block, so `ECO_MONO_ENGINE=subst` builds are
unaffected.

ALL-GLOBALS KEYING is unconditional under LSS (it was `lss.keyed`,
default-ON since 2026-07-20 post-Fix-B, fixed at that default and removed
2026-09-18). Sound since LSS\_017 fork-qualified members
(`plans/lss-fork-qualified-members.md` — the singleton-representative hijack
is fixed by construction) and measured free at run time (Run M,
`benchmarks/runtime-calls.md`: coverage 6.81 % → 13.22 %, identical total
events, wall parity). Solo census with it OFF: `k1` −44,575, `kN` +20,161,
artifact −1.13 MB. `ECO_MONO_LSS=0` disables LSS entirely. Watch item: the elm-aws-codegen pathological-workload class (§11.7
census note) — since the 2026-08-29 no-limits defaults the M4
`maxSpecsPerGlobal` budget no longer engages by default; if that class
regresses, `ECO_MONO_LSS_MAX_SPECS` restores a budget without a rebuild.

-}
defaultLss : LssConfig
defaultLss =
    { enabled = True
    , maxSetSize = 0
    , maxSpecsPerGlobal = 0
    , report = False
    , qCensus = False
    , arrowCensus = False
    , stamp = { maxInstances = 8, census = False }
    }


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
    , gc = { preLink = True, report = False }
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
    , constThunks = 2
    , constThunksReport = False
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
        |> D.apply (D.optionalField "constThunks" D.int default.constThunks)
        |> D.apply (D.optionalField "constThunksReport" D.bool default.constThunksReport)
        |> D.apply (D.optionalField "cse" cseDecoder default.cse)
        |> D.apply (D.optionalField "gc" gcDecoder default.gc)


{-| Decode the `gc` block.
-}
gcDecoder : D.Decoder x GcConfig
gcDecoder =
    D.pure GcConfig
        |> D.apply (D.optionalField "preLink" D.bool default.gc.preLink)
        |> D.apply (D.optionalField "report" D.bool default.gc.report)


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
        |> D.apply (D.optionalField "maxSetSize" D.int defaultLss.maxSetSize)
        |> D.apply (D.optionalField "maxSpecsPerGlobal" D.int defaultLss.maxSpecsPerGlobal)
        |> D.apply (D.optionalField "report" D.bool defaultLss.report)
        -- APPEND ONLY, and LAST: this apply chain is POSITIONAL, so an
        -- insertion anywhere above silently swaps two flags' values and still
        -- type-checks (every field above is a Bool or an Int).
        |> D.apply (D.optionalField "qCensus" D.bool defaultLss.qCensus)
        |> D.apply (D.optionalField "arrowCensus" D.bool defaultLss.arrowCensus)
        |> D.apply lssInstanceQualDecoder


{-| Flat keys, prefixed — new with the sub-record (no schema history to keep).
-}
lssInstanceQualDecoder : D.Decoder x LssStampConfig
lssInstanceQualDecoder =
    D.pure LssStampConfig
        |> D.apply (D.optionalField "instanceQualMaxInstances" D.int defaultLss.stamp.maxInstances)
        |> D.apply (D.optionalField "census" D.bool defaultLss.stamp.census)


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
    -- `cfg.gc` is deliberately NOT hashed: an explicit collection never
    -- changes the output (plans/frontend-heap-release.md §0.4).
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
                    , if lss.maxSetSize /= defaultLss.maxSetSize then
                        [ "lssS=" ++ String.fromInt lss.maxSetSize ]

                      else
                        []
                    , if lss.maxSpecsPerGlobal /= defaultLss.maxSpecsPerGlobal then
                        [ "lssB=" ++ String.fromInt lss.maxSpecsPerGlobal ]

                      else
                        []
                    , if lss.stamp.maxInstances /= defaultLss.stamp.maxInstances then
                        [ "lssIQM=" ++ String.fromInt lss.stamp.maxInstances ]

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
            -- CGEN_082: constant-thunk folding rewrites every reference site.
            ++ (if cfg.constThunks > 0 then
                    [ "cthk=" ++ String.fromInt cfg.constThunks ]

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
