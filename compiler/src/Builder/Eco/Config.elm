module Builder.Eco.Config exposing (load)

{-| Read the project's `eco-config.json` (tunable compiler settings) from disk.

The pure data, decoder, and defaults live in `Compiler.Eco.Config`; this module
only adds the IO: locate the file, read it, decode it, clamp out-of-range
values (emitting warnings), and surface errors as `Exit.Make`.

@docs load

-}

import Builder.Reporting.Exit as Exit
import Compiler.Eco.Config as Config exposing (EcoConfig, InlineConfig)
import Compiler.Json.Decode as D
import Eco.File
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task


{-| Load the effective config.

  - `maybeExplicit` is the `--config <path>` override, if any.
  - Otherwise the default location `<root>/eco-config.json` is used.

Rules:

  - Default location absent → `Config.default` (silent; the common case).
  - Explicit path absent → hard error (`Exit.MakeConfigNotFound`).
  - Present but malformed → hard error (`Exit.MakeBadConfig`).
  - Out-of-range values are clamped, with a warning printed to stderr.

-}
load : Maybe FilePath -> FilePath -> Task Exit.Make EcoConfig
load maybeExplicit root =
    loadBase maybeExplicit root
        |> Task.andThen applyEnvOverrides


{-| Load the effective config from the file (or defaults), before env overrides.
-}
loadBase : Maybe FilePath -> FilePath -> Task Exit.Make EcoConfig
loadBase maybeExplicit root =
    let
        path : FilePath
        path =
            Maybe.withDefault (root ++ "/eco-config.json") maybeExplicit
    in
    (Utils.dirDoesFileExist path |> Task.mapError never)
        |> Task.andThen
            (\exists ->
                if not exists then
                    case maybeExplicit of
                        Just explicitPath ->
                            Task.throw (Exit.MakeConfigNotFound explicitPath)

                        Nothing ->
                            Task.succeed Config.default

                else
                    (Eco.File.readString path |> Task.mapError Exit.MakeFileIO)
                        |> Task.andThen
                            (\contents ->
                                case D.fromByteString Config.decoder contents of
                                    Ok cfg ->
                                        finishWithWarnings cfg

                                    Err err ->
                                        Task.throw (Exit.MakeBadConfig path err)
                            )
            )


{-| Apply developer env overrides on top of the file/default config:

  - `ECO_MONO_ENGINE=subst|solver|diff` selects the monomorphizer engine.
  - `ECO_MONO_DIFF_DUMP=1` makes `EngineDiff` embed full renderings on mismatch.
  - `ECO_MONO_LSS=0|1|keyed` toggles lambda-set specialization (solver engine).
  - `ECO_MONO_LSS_KEYED_GLOBALS=g1,g2` keys ONLY these globals (E5 selective
    fan-out; user format `author/project:Module.Name.value`); participates in
    the hash via the `lssKG=` token.
  - `ECO_MONO_LSS_REPORT=1` renders the LSS census to stderr after mono.
  - `ECO_INLINE_REPORT=1` renders the inline census to stderr after
    inline+simplify (HOF-elimination plan H0.2).
  - `ECO_INLINE_PRESERVE_SETS=1` makes the post-mono inliner decline the
    strictly-partial inline, the only reshape that clears an LSS member
    (plans/pre-mono-lss-transforms-02-inline-preserve-sets.md); participates in
    the hash via the `psets=` token.
  - `ECO_INLINE_PRUNE_DEAD=0` skips the post-inline dead-spec prune
    (plans/post-inline-dead-spec-prune.md); default-on, participates in the
    hash via the `prune=` token.
  - `ECO_INLINE_HOF_THRESHOLD=<n>` overrides `inline.hofThreshold` (the H2
    called-function-param inlining budget); experiment/tuning knob.
  - `ECO_INLINE_FPI=<n>` BROADCASTS to both passes' round counts;
    `ECO_INLINE_PRE_MONO_FPI` / `ECO_INLINE_POST_MONO_FPI` set one each
    (deep chains need extra passes to cascade).
  - `ECO_INLINE_THRESHOLD=<n>` BROADCASTS to all three size budgets;
    `ECO_INLINE_PRE_MONO_THRESHOLD`, `ECO_INLINE_POST_MONO_THRESHOLD` and
    `ECO_ETA_THRESHOLD` set one each. Before the 2026-09-15 split one field
    drove `InlineSimplify`, `MonoInlineSimplify` AND `EtaExpand`, so no A/B
    could attribute an effect to one pass.
  - `ECO_INLINE_LOOPIFY=0` disables recursive-HOF loopification (plan H5);
    escape hatch, participates in the hash via the `loop=` token.
  - `ECO_ARITY_RAISE_MIN_APPLIED=<0..100>` overrides
    `inline.raiseAppliedShareMin` (H6.2.5 Lever 2 selective raising);
    participates in the hash via the `arm=` token when nonzero.
  - `ECO_CAF_MEMO=0` disables CAF memoization (default-on; per-SpecId lazy
    once-init `eco.global` slots for nullary value thunks); participates in
    the hash via the `cafm=` token.
  - `ECO_CAF_HOIST=1|0`, `ECO_CAF_HOIST_MIN_NODES=<n>`, `ECO_CAF_HOIST_MAX=<n>`:
    CAF hoisting of closed inner expressions (default-off; hash tokens
    `cafh=`/`cafhN=`/`cafhM=` when enabled).
  - `ECO_CAF_DEDUPE=1|0`: merge structurally identical nullary specs onto one
    canonical spec (default-off; hash token `cafd=` when enabled).

Applied here (not further downstream) so the override participates in
`Config.hash`, which keys the Details cache. An unrecognized engine value is a
loud stderr warning that keeps the current engine (rather than a hard failure)
— this is a dev-only knob.

-}
applyEnvOverrides : EcoConfig -> Task Exit.Make EcoConfig
applyEnvOverrides cfg =
    (Utils.envLookupEnv "ECO_MONO_ENGINE" |> Task.mapError never)
        |> Task.andThen (\engVal -> applyEngineOverride engVal cfg)
        |> Task.andThen
            (\cfg1 ->
                (Utils.envLookupEnv "ECO_MONO_DIFF_DUMP" |> Task.mapError never)
                    |> Task.map (\dumpVal -> applyDumpOverride dumpVal cfg1)
            )
        |> Task.andThen
            (\cfg2 ->
                (Utils.envLookupEnv "ECO_MONO_LSS" |> Task.mapError never)
                    |> Task.map (\lssVal -> applyLssOverride lssVal cfg2)
            )
        |> Task.andThen
            (\cfg3 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_REPORT" |> Task.mapError never)
                    |> Task.map (\repVal -> applyLssReportOverride repVal cfg3)
            )
        |> Task.andThen
            (\cfg4 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_MAX_SPECS" |> Task.mapError never)
                    |> Task.map (\budgetVal -> applyLssBudgetOverride budgetVal cfg4)
            )
        |> Task.andThen
            (\cfg4a ->
                (Utils.envLookupEnv "ECO_MONO_LSS_MAX_SET_SIZE" |> Task.mapError never)
                    |> Task.map (\setVal -> applyLssMaxSetSizeOverride setVal cfg4a)
            )
        |> Task.andThen
            (\cfg4b ->
                (Utils.envLookupEnv "ECO_MONO_LSS_KEYED_GLOBALS" |> Task.mapError never)
                    |> Task.andThen (\kgVal -> applyLssKeyedGlobalsOverride kgVal cfg4b)
            )
        |> Task.andThen
            (\cfg4c ->
                (Utils.envLookupEnv "ECO_MONO_LSS_DEVIRT_FN" |> Task.mapError never)
                    |> Task.map (\dfVal -> applyLssDevirtFnOverride dfVal cfg4c)
            )
        |> Task.andThen
            (\cfg4d ->
                (Utils.envLookupEnv "ECO_MONO_LSS_SPINE_ARITY" |> Task.mapError never)
                    |> Task.map (\saVal -> applyLssSpineArityOverride saVal cfg4d)
            )
        |> Task.andThen
            (\cfg4e ->
                (Utils.envLookupEnv "ECO_MONO_LSS_MU_TIE" |> Task.mapError never)
                    |> Task.map (\mtVal -> applyLssMuTieOverride mtVal cfg4e)
            )
        |> Task.andThen
            (\cfg4e2 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_GROUND" |> Task.mapError never)
                    |> Task.map (\gsVal -> applyLssGroundOverride gsVal cfg4e2)
            )
        |> Task.andThen
            (\cfg4e3 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_SIG_FLOW" |> Task.mapError never)
                    |> Task.map (\sfVal -> applyLssSigFlowOverride sfVal cfg4e3)
            )
        |> Task.andThen
            (\cfg4e4 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_LAYOUT_QUAL" |> Task.mapError never)
                    |> Task.map (\lqVal -> applyLssLayoutQualOverride lqVal cfg4e4)
            )
        |> Task.andThen
            (\cfg4e4b ->
                (Utils.envLookupEnv "ECO_MONO_LSS_INSTANCE_QUAL" |> Task.mapError never)
                    |> Task.map (\iqVal -> applyLssInstanceQualOverride iqVal cfg4e4b)
            )
        |> Task.andThen
            (\cfg4e4c ->
                (Utils.envLookupEnv "ECO_MONO_LSS_INSTANCE_QUAL_MAX" |> Task.mapError never)
                    |> Task.map (\iqmVal -> applyLssInstanceQualMaxOverride iqmVal cfg4e4c)
            )
        |> Task.andThen
            (\cfgIU ->
                (Utils.envLookupEnv "ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT" |> Task.mapError never)
                    |> Task.map (\iuVal -> applyLssInstanceQualUseInjectOverride iuVal cfgIU)
            )
        |> Task.andThen
            (\cfg4e4d ->
                (Utils.envLookupEnv "ECO_MONO_LSS_FLAT_PEEL" |> Task.mapError never)
                    |> Task.map (\fpVal -> applyLssFlatPeelOverride fpVal cfg4e4d)
            )
        |> Task.andThen
            (\cfg4e5 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_DEVIRT_POST" |> Task.mapError never)
                    |> Task.map (\dpVal -> applyLssDevirtPostOverride dpVal cfg4e5)
            )
        |> Task.andThen
            (\cfg4e6 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ARROW_ID" |> Task.mapError never)
                    |> Task.map (\aiVal -> applyLssArrowIdOverride aiVal cfg4e6)
            )
        |> Task.andThen
            (\cfg4e7 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ARROW_ROOTS" |> Task.mapError never)
                    |> Task.map (\arVal -> applyLssArrowRootsOverride arVal cfg4e7)
            )
        |> Task.andThen
            (\cfg4e8 ->
                (Utils.envLookupEnv "ECO_MONO_LSS_QSOLVE" |> Task.mapError never)
                    |> Task.map (\qsVal -> applyLssQSolveOverride qsVal cfg4e8)
            )
        |> Task.andThen
            (\cfg4eb ->
                (Utils.envLookupEnv "ECO_MONO_LSS_REF_IDENTITY" |> Task.mapError never)
                    |> Task.map (\riVal -> applyLssRefIdentityOverride riVal cfg4eb)
            )
        |> Task.andThen
            (\cfg4ec ->
                (Utils.envLookupEnv "ECO_MONO_LSS_QCENSUS" |> Task.mapError never)
                    |> Task.map (\qcVal -> applyLssQCensusOverride qcVal cfg4ec)
            )
        |> Task.andThen
            (\cfg4ecc ->
                (Utils.envLookupEnv "ECO_MONO_LSS_CENSUS" |> Task.mapError never)
                    |> Task.map (\cenVal -> applyLssCensusOverride cenVal cfg4ecc)
            )
        |> Task.andThen
            (\cfg4ecd ->
                (Utils.envLookupEnv "ECO_MONO_LSS_PAP_FAST" |> Task.mapError never)
                    |> Task.map (\pfVal -> applyLssPapFastOverride pfVal cfg4ecd)
            )
        |> Task.andThen
            (\cfg4ed ->
                (Utils.envLookupEnv "ECO_MONO_LSS_PAP_MEMBERS" |> Task.mapError never)
                    |> Task.map (\pmVal -> applyLssPapMembersOverride pmVal cfg4ed)
            )
        |> Task.andThen
            (\cfg4ee ->
                (Utils.envLookupEnv "ECO_MONO_LSS_SIG_ROOT_ID" |> Task.mapError never)
                    |> Task.map (\srVal -> applyLssSigRootIdentityOverride srVal cfg4ee)
            )
        |> Task.andThen
            (\cfg4ef ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ARROW_CENSUS" |> Task.mapError never)
                    |> Task.map (\acVal -> applyLssArrowCensusOverride acVal cfg4ef)
            )
        |> Task.andThen
            (\cfg4eg ->
                (Utils.envLookupEnv "ECO_MONO_LSS_REG_IDENTITY" |> Task.mapError never)
                    |> Task.map (\rgVal -> applyLssRegIdentityOverride rgVal cfg4eg)
            )
        |> Task.andThen
            (\cfg4eh ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ROOT_FOLD" |> Task.mapError never)
                    |> Task.map (\rfVal -> applyLssRootFoldOverride rfVal cfg4eh)
            )
        |> Task.andThen
            (\cfg4ei ->
                (Utils.envLookupEnv "ECO_MONO_LSS_REF_PAP_SPINE" |> Task.mapError never)
                    |> Task.map (\rpVal -> applyLssRefPapSpineOverride rpVal cfg4ei)
            )
        |> Task.andThen
            (\cfg4ej ->
                (Utils.envLookupEnv "ECO_MONO_LSS_INJ_TOTAL" |> Task.mapError never)
                    |> Task.map (\itVal -> applyLssInjTotalOverride itVal cfg4ej)
            )
        |> Task.andThen
            (\cfg4ek ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ARG_POINTS" |> Task.mapError never)
                    |> Task.map (\apVal -> applyLssArgPointsOverride apVal cfg4ek)
            )
        |> Task.andThen
            (\cfg4el ->
                (Utils.envLookupEnv "ECO_MONO_LSS_RS_TOP" |> Task.mapError never)
                    |> Task.map (\rtVal -> applyLssRsTopOverride rtVal cfg4el)
            )
        |> Task.andThen
            (\cfg4en ->
                (Utils.envLookupEnv "ECO_MONO_LSS_DESTR_ANNO" |> Task.mapError never)
                    |> Task.map (\daVal -> applyLssDestrAnnoOverride daVal cfg4en)
            )
        |> Task.andThen
            (\cfg4eo ->
                (Utils.envLookupEnv "ECO_MONO_LSS_VAR_SUCC" |> Task.mapError never)
                    |> Task.map (\vsVal -> applyLssVarSuccOverride vsVal cfg4eo)
            )
        |> Task.andThen
            (\cfg4ep ->
                (Utils.envLookupEnv "ECO_MONO_LSS_VAR_CTOR_ROWS" |> Task.mapError never)
                    |> Task.map (\vcVal -> applyLssVarCtorRowsOverride vcVal cfg4ep)
            )
        |> Task.andThen
            (\cfg4eq ->
                (Utils.envLookupEnv "ECO_MONO_LSS_VAR_LAMBDA" |> Task.mapError never)
                    |> Task.map (\vlVal -> applyLssVarLambdaOverride vlVal cfg4eq)
            )
        |> Task.andThen
            (\cfg4es ->
                (Utils.envLookupEnv "ECO_MONO_LSS_FLOW_CONNECT" |> Task.mapError never)
                    |> Task.map (\fcVal -> applyLssFlowConnectOverride fcVal cfg4es)
            )
        |> Task.andThen
            (\cfgFLO ->
                (Utils.envLookupEnv "ECO_MONO_LSS_FLOW_LET_OVERLAY" |> Task.mapError never)
                    |> Task.map (\floVal -> applyLssFlowLetOverlayOverride floVal cfgFLO)
            )
        |> Task.andThen
            (\cfgFRD ->
                (Utils.envLookupEnv "ECO_MONO_LSS_FLOW_ROW_DEFER" |> Task.mapError never)
                    |> Task.map (\frdVal -> applyLssFlowRowDeferOverride frdVal cfgFRD)
            )
        |> Task.andThen
            (\cfg4et ->
                (Utils.envLookupEnv "ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL" |> Task.mapError never)
                    |> Task.map (\srVal -> applyLssStageAnchorRowFillOverride srVal cfg4et)
            )
        |> Task.andThen
            (\cfg4eu ->
                (Utils.envLookupEnv "ECO_MONO_LSS_STAGE_ANCHOR_DEMAND_FILL" |> Task.mapError never)
                    |> Task.map (\sdVal -> applyLssStageAnchorDemandFillOverride sdVal cfg4eu)
            )
        |> Task.andThen
            (\cfg4f ->
                (Utils.envLookupEnv "ECO_SPEC_TYPE_NODE_LIMIT" |> Task.mapError never)
                    |> Task.map (\tnVal -> applySpecTypeNodeLimitOverride tnVal cfg4f)
            )
        |> Task.andThen
            (\cfg4g ->
                (Utils.envLookupEnv "ECO_SPEC_BREADTH_LIMIT" |> Task.mapError never)
                    |> Task.map (\brVal -> applySpecBreadthLimitOverride brVal cfg4g)
            )
        |> Task.andThen
            (\cfg5 ->
                (Utils.envLookupEnv "ECO_MONO_VALIDATE" |> Task.mapError never)
                    |> Task.map (\valVal -> applyValidateOverride valVal cfg5)
            )
        |> Task.andThen
            (\cfg6 ->
                (Utils.envLookupEnv "ECO_INLINE_REPORT" |> Task.mapError never)
                    |> Task.map (\repVal -> applyInlineReportOverride repVal cfg6)
            )
        |> Task.andThen
            (\cfg7 ->
                (Utils.envLookupEnv "ECO_INLINE_HOF_THRESHOLD" |> Task.mapError never)
                    |> Task.map (\hofVal -> applyHofThresholdOverride hofVal cfg7)
            )
        |> Task.andThen
            (\cfg8 ->
                (Utils.envLookupEnv "ECO_INLINE_FPI" |> Task.mapError never)
                    |> Task.map (\fpiVal -> applyFpiOverride fpiVal cfg8)
            )
        |> Task.andThen
            (\cfg9 ->
                (Utils.envLookupEnv "ECO_INLINE_LOOPIFY" |> Task.mapError never)
                    |> Task.map (\loopVal -> applyLoopifyOverride loopVal cfg9)
            )
        |> Task.andThen
            (\cfg10 ->
                (Utils.envLookupEnv "ECO_ARITY_RAISE" |> Task.mapError never)
                    |> Task.map (\arVal -> applyArityRaiseOverride arVal cfg10)
            )
        |> Task.andThen
            (\cfg11 ->
                (Utils.envLookupEnv "ECO_ARITY_RAISE_MIN_APPLIED" |> Task.mapError never)
                    |> Task.map (\armVal -> applyRaiseMinAppliedOverride armVal cfg11)
            )
        |> Task.andThen
            (\cfgPh ->
                (Utils.envLookupEnv "ECO_INLINE_PARTIAL_HOF" |> Task.mapError never)
                    |> Task.map (\phVal -> applyInlinePartialHofOverride phVal cfgPh)
            )
        |> Task.andThen
            (\cfgPs ->
                (Utils.envLookupEnv "ECO_INLINE_PRESERVE_SETS" |> Task.mapError never)
                    |> Task.map (\psVal -> applyInlinePreserveSetsOverride psVal cfgPs)
            )
        |> Task.andThen
            (\cfgPd ->
                (Utils.envLookupEnv "ECO_INLINE_PRUNE_DEAD" |> Task.mapError never)
                    |> Task.map (\pdVal -> applyInlinePruneDeadOverride pdVal cfgPd)
            )
        |> Task.andThen
            (\cfgThr ->
                (Utils.envLookupEnv "ECO_INLINE_THRESHOLD" |> Task.mapError never)
                    |> Task.map (\thrVal -> applyInlineThresholdOverride thrVal cfgThr)
            )
        |> Task.andThen
            (\cfgPre ->
                (Utils.envLookupEnv "ECO_INLINE_PRE_MONO" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePreMonoOverride v cfgPre)
            )
        |> Task.andThen
            (\cfgPost ->
                (Utils.envLookupEnv "ECO_INLINE_POST_MONO" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePostMonoOverride v cfgPost)
            )
        |> Task.andThen
            (\cfgEta ->
                (Utils.envLookupEnv "ECO_INLINE_ETA_EXPAND" |> Task.mapError never)
                    |> Task.map (\v -> applyInlineEtaExpandOverride v cfgEta)
            )
        |> Task.andThen
            (\cfgEtaOnly ->
                (Utils.envLookupEnv "ECO_INLINE_ETA_ONLY" |> Task.mapError never)
                    |> Task.map (\v -> applyInlineEtaOnlyOverride v cfgEtaOnly)
            )
        |> Task.andThen
            (\cfgAfwd ->
                (Utils.envLookupEnv "ECO_INLINE_ALIAS_FORWARD" |> Task.mapError never)
                    |> Task.map (\v -> applyInlineAliasForwardOverride v cfgAfwd)
            )
        |> Task.andThen
            (\c ->
                (Utils.envLookupEnv "ECO_INLINE_PRE_MONO_THRESHOLD" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePreMonoThresholdOverride v c)
            )
        |> Task.andThen
            (\c ->
                (Utils.envLookupEnv "ECO_INLINE_POST_MONO_THRESHOLD" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePostMonoThresholdOverride v c)
            )
        |> Task.andThen
            (\c ->
                (Utils.envLookupEnv "ECO_ETA_THRESHOLD" |> Task.mapError never)
                    |> Task.map (\v -> applyEtaThresholdOverride v c)
            )
        |> Task.andThen
            (\c ->
                (Utils.envLookupEnv "ECO_INLINE_PRE_MONO_FPI" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePreMonoFpiOverride v c)
            )
        |> Task.andThen
            (\c ->
                (Utils.envLookupEnv "ECO_INLINE_POST_MONO_FPI" |> Task.mapError never)
                    |> Task.map (\v -> applyInlinePostMonoFpiOverride v c)
            )
        |> Task.andThen
            (\cfg12 ->
                (Utils.envLookupEnv "ECO_CAF_MEMO" |> Task.mapError never)
                    |> Task.map (\cmVal -> applyCafMemoOverride cmVal cfg12)
            )
        |> Task.andThen
            (\cfg13 ->
                (Utils.envLookupEnv "ECO_CAF_CENSUS" |> Task.mapError never)
                    |> Task.map (\ccVal -> applyCafCensusOverride ccVal cfg13)
            )
        |> Task.andThen
            (\cfg14 ->
                (Utils.envLookupEnv "ECO_CAF_HOIST" |> Task.mapError never)
                    |> Task.map (\chVal -> applyCafHoistOverride chVal cfg14)
            )
        |> Task.andThen
            (\cfg15 ->
                (Utils.envLookupEnv "ECO_CAF_HOIST_MIN_NODES" |> Task.mapError never)
                    |> Task.map (\mnVal -> applyCafHoistMinNodesOverride mnVal cfg15)
            )
        |> Task.andThen
            (\cfg16 ->
                (Utils.envLookupEnv "ECO_CAF_HOIST_MAX" |> Task.mapError never)
                    |> Task.map (\mxVal -> applyCafHoistMaxOverride mxVal cfg16)
            )
        |> Task.andThen
            (\cfg17 ->
                (Utils.envLookupEnv "ECO_CAF_DEDUPE" |> Task.mapError never)
                    |> Task.map (\cdVal -> applyCafDedupeOverride cdVal cfg17)
            )
        |> Task.andThen
            (\cfg19 ->
                (Utils.envLookupEnv "ECO_BORROW" |> Task.mapError never)
                    |> Task.map (\bVal -> applyBorrowOverride bVal cfg19)
            )
        |> Task.andThen
            (\cfg20 ->
                (Utils.envLookupEnv "ECO_BORROW_REPORT" |> Task.mapError never)
                    |> Task.map (\brVal -> applyBorrowReportOverride brVal cfg20)
            )
        |> Task.andThen
            (\cfg21 ->
                (Utils.envLookupEnv "ECO_LIST_CHUNKS" |> Task.mapError never)
                    |> Task.map (\lcVal -> applyListChunksOverride lcVal cfg21)
            )
        |> Task.andThen
            (\cfg22 ->
                (Utils.envLookupEnv "ECO_LIST_REPORT" |> Task.mapError never)
                    |> Task.map (\lrVal -> applyListReportOverride lrVal cfg22)
            )
        |> Task.andThen
            (\cfg22b ->
                (Utils.envLookupEnv "ECO_LIST_CONS_INTRINSIC" |> Task.mapError never)
                    |> Task.map (\lciVal -> applyListConsIntrinsicOverride lciVal cfg22b)
            )
        |> Task.andThen
            (\cfg22c ->
                (Utils.envLookupEnv "ECO_LIST_MAP_TEMPLATE" |> Task.mapError never)
                    |> Task.map (\lmtVal -> applyListMapTemplateOverride lmtVal cfg22c)
            )
        |> Task.andThen
            (\cfg23 ->
                (Utils.envLookupEnv "ECO_AGG_PROMOTE" |> Task.mapError never)
                    |> Task.map (\apVal -> applyAggPromoteOverride apVal cfg23)
            )
        |> Task.andThen
            (\cfg24 ->
                (Utils.envLookupEnv "ECO_CTOR_INLINE" |> Task.mapError never)
                    |> Task.map (\ciVal -> applyCtorInlineOverride ciVal cfg24)
            )
        |> Task.andThen
            (\cfg25 ->
                (Utils.envLookupEnv "ECO_SRET_RESULTS" |> Task.mapError never)
                    |> Task.map (\srVal -> applySretResultsOverride srVal cfg25)
            )
        |> Task.andThen
            (\cfg26 ->
                (Utils.envLookupEnv "ECO_PSPLIT_PARAMS" |> Task.mapError never)
                    |> Task.map (\ppVal -> applyPsplitParamsOverride ppVal cfg26)
            )
        |> Task.andThen
            (\cfg27 ->
                (Utils.envLookupEnv "ECO_SRET_TAILFUNC" |> Task.mapError never)
                    |> Task.map (\stVal -> applySretTailFuncOverride stVal cfg27)
            )
        |> Task.andThen
            (\cfg26 ->
                (Utils.envLookupEnv "ECO_SRET_FRESH" |> Task.mapError never)
                    |> Task.map (\sfVal -> applySretFreshOverride sfVal cfg26)
            )
        |> Task.andThen
            (\cfg29 ->
                (Utils.envLookupEnv "ECO_BORROW_OPT" |> Task.mapError never)
                    |> Task.map (\boVal -> applyBorrowOptOverride boVal cfg29)
            )
        |> Task.andThen
            (\cfg30 ->
                (Utils.envLookupEnv "ECO_STRING_LENGTH_OP" |> Task.mapError never)
                    |> Task.map (\slVal -> applyStringLengthOpOverride slVal cfg30)
            )
        |> Task.andThen
            (\cfg31 ->
                (Utils.envLookupEnv "ECO_APPEND_SPLIT" |> Task.mapError never)
                    |> Task.map (\asVal -> applyAppendSplitOverride asVal cfg31)
            )
        |> Task.andThen
            (\cfg32 ->
                (Utils.envLookupEnv "ECO_STRING_ORDER_INTRINSIC" |> Task.mapError never)
                    |> Task.map (\soVal -> applyStringOrderIntrinsicOverride soVal cfg32)
            )
        |> Task.andThen
            (\cfg33 ->
                (Utils.envLookupEnv "ECO_VALUE_EQ" |> Task.mapError never)
                    |> Task.map (\veVal -> applyValueEqOverride veVal cfg33)
            )
        |> Task.andThen
            (\cfgKgcl ->
                (Utils.envLookupEnv "ECO_KERNEL_GCLEAF_EMIT" |> Task.mapError never)
                    |> Task.map (\kgVal -> applyKernelGcLeafEmitOverride kgVal cfgKgcl)
            )
        |> Task.andThen
            (\cfgKfdce ->
                (Utils.envLookupEnv "ECO_KERNEL_FACTS_DCE" |> Task.mapError never)
                    |> Task.map (\kdVal -> applyKernelFactsDceOverride kdVal cfgKfdce)
            )
        |> Task.andThen
            (\cfgkernel_cost_classes ->
                (Utils.envLookupEnv "ECO_KERNEL_COST_CLASSES" |> Task.mapError never)
                    |> Task.map (\v -> applyKernelCostClassesOverride v cfgkernel_cost_classes)
            )
        |> Task.andThen
            (\cfgkernel_cost_inline ->
                (Utils.envLookupEnv "ECO_KERNEL_COST_INLINE" |> Task.mapError never)
                    |> Task.map (\v -> applyKernelCostInlineOverride v cfgkernel_cost_inline)
            )
        |> Task.andThen
            (\cfgkernel_cost_gcleaf ->
                (Utils.envLookupEnv "ECO_KERNEL_COST_GCLEAF" |> Task.mapError never)
                    |> Task.map (\v -> applyKernelCostGcLeafOverride v cfgkernel_cost_gcleaf)
            )
        |> Task.andThen
            (\cfgkernel_cost_alloc ->
                (Utils.envLookupEnv "ECO_KERNEL_COST_ALLOC" |> Task.mapError never)
                    |> Task.map (\v -> applyKernelCostAllocOverride v cfgkernel_cost_alloc)
            )
        |> Task.andThen
            (\cfgkernel_cost_hof ->
                (Utils.envLookupEnv "ECO_KERNEL_COST_HOF" |> Task.mapError never)
                    |> Task.map (\v -> applyKernelCostHofOverride v cfgkernel_cost_hof)
            )
        |> Task.andThen
            (\cfgeco_cse ->
                (Utils.envLookupEnv "ECO_CSE" |> Task.mapError never)
                    |> Task.map (\v -> applyCseEnabledOverride v cfgeco_cse)
            )
        |> Task.andThen
            (\cfgeco_cse_report ->
                (Utils.envLookupEnv "ECO_CSE_REPORT" |> Task.mapError never)
                    |> Task.map (\v -> applyCseReportOverride v cfgeco_cse_report)
            )
        |> Task.andThen
            (\cfgeco_cse_min_cost ->
                (Utils.envLookupEnv "ECO_CSE_MIN_COST" |> Task.mapError never)
                    |> Task.map (\v -> applyCseMinCostOverride v cfgeco_cse_min_cost)
            )
        |> Task.andThen
            (\cfgeco_cse_max_per_def ->
                (Utils.envLookupEnv "ECO_CSE_MAX_PER_DEF" |> Task.mapError never)
                    |> Task.map (\v -> applyCseMaxPerDefOverride v cfgeco_cse_max_per_def)
            )
        |> Task.andThen
            (\cfgCpur ->
                (Utils.envLookupEnv "ECO_CALL_PURITY" |> Task.mapError never)
                    |> Task.map (\v -> applyCallPurityOverride v cfgCpur)
            )


{-| `ECO_AGG_PROMOTE=1|true|yes`: U-T1.3.1 aggregate promotion — emit
`eco.make.tuple2/3` for let-bound tuples the per-def use walk proves
non-escaping. Artifact-affecting (folded into `Config.hash` as `aggp`), so
flag-on builds never share flag-off caches. `0`/`off` disables.
-}
applyAggPromoteOverride : Maybe String -> EcoConfig -> EcoConfig
applyAggPromoteOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | aggPromote = True }

            else if t == "0" || t == "off" then
                { cfg | aggPromote = False }

            else
                cfg


{-| `ECO_KERNEL_COST_CLASSES=1|0`: price kernel calls from their derived
KernelFacts cost class instead of the flat 6 (kernel-opt-11 (b)).
Artifact-affecting (hash token `kcc=<i>/<g>/<a>/<h>`). Unknown values ignored.
-}
applyKernelCostClassesOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostClassesOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                inline =
                    cfg.inline
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | inline = { inline | kernelCostClasses = True } }

            else if t == "0" || t == "off" then
                { cfg | inline = { inline | kernelCostClasses = False } }

            else
                cfg


{-| The four cost constants (kernel-opt-11 (b)). Each is A/B'd solo, which is
why they are config knobs rather than source constants: `Config.hash` keys the
Details cache, and a source-constant change is invisible to it, so two legs
would silently share `~/.eco` artifacts. A non-numeric or negative value is
ignored.
-}
applyKernelCostIntOverride : (Int -> InlineConfig -> InlineConfig) -> Maybe String -> EcoConfig -> EcoConfig
applyKernelCostIntOverride set maybeVal cfg =
    case maybeVal |> Maybe.andThen (String.trim >> String.toInt) of
        Just n ->
            if n >= 0 then
                { cfg | inline = set n cfg.inline }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_KERNEL_COST_INLINE=<n>`: cost of a kernel call that lowers to an op.
-}
applyKernelCostInlineOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostInlineOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostInline = n })


{-| `ECO_KERNEL_COST_GCLEAF=<n>`: cost of a CGcLeaf kernel call.
-}
applyKernelCostGcLeafOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostGcLeafOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostGcLeaf = n })


{-| `ECO_KERNEL_COST_ALLOC=<n>`: cost of a CAlloc kernel call.
-}
applyKernelCostAllocOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostAllocOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostAlloc = n })


{-| `ECO_KERNEL_COST_HOF=<n>`: cost of a CHof kernel call.
-}
applyKernelCostHofOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostHofOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostHof = n })


{-| `ECO_CALL_PURITY=1|0`: stamp `eco.cse_safe` on droppable direct kernel
calls (kernel-opt-12). Artifact-affecting (hash token `cpur=1`), so flag-on
builds never share flag-off caches. Unknown values are ignored.
-}
applyCallPurityOverride : Maybe String -> EcoConfig -> EcoConfig
applyCallPurityOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | callPurityAttrs = True }

            else if t == "0" || t == "off" then
                { cfg | callPurityAttrs = False }

            else
                cfg


{-| `ECO_CSE=1|0`: run the Mono-level CSE pass (kernel-opt-13).
Artifact-affecting (hash token `cse=1`). Unknown values are ignored.
-}
applyCseEnabledOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseEnabledOverride =
    applyCseBoolOverride (\b c -> { c | enabled = b })


{-| `ECO_CSE_REPORT=1|0`: emit the C1 census to stderr. **Output-only** — it
contributes no hash token, so a census run shares the flag-off caches.
-}
applyCseReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseReportOverride =
    applyCseBoolOverride (\b c -> { c | report = b })


applyCseBoolOverride : (Bool -> Config.CseConfig -> Config.CseConfig) -> Maybe String -> EcoConfig -> EcoConfig
applyCseBoolOverride set maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | cse = set True cfg.cse }

            else if t == "0" || t == "false" || t == "no" || t == "off" then
                { cfg | cse = set False cfg.cse }

            else
                cfg


applyCseIntOverride : (Int -> Config.CseConfig -> Config.CseConfig) -> Maybe String -> EcoConfig -> EcoConfig
applyCseIntOverride set maybeVal cfg =
    case maybeVal |> Maybe.andThen (String.trim >> String.toInt) of
        Just n ->
            if n >= 0 then
                { cfg | cse = set n cfg.cse }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_CSE_MIN_COST=<n>`: cost floor for a CSE candidate.
-}
applyCseMinCostOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseMinCostOverride =
    applyCseIntOverride (\n c -> { c | minCost = n })


{-| `ECO_CSE_MAX_PER_DEF=<n>`: cap on merge groups per definition body.
-}
applyCseMaxPerDefOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseMaxPerDefOverride =
    applyCseIntOverride (\n c -> { c | maxPerDef = n })


{-| `ECO_KERNEL_FACTS_DCE=1|0`: let the dead-binding gate in
`MonoInlineSimplify` drop a dead kernel call whose KernelFacts row is
`droppable` (kernel-opt-11 (a)). Artifact-affecting (hash token `kfdce=1`), so
flag-on builds never share flag-off caches. Unknown values are ignored.
-}
applyKernelFactsDceOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelFactsDceOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                inline =
                    cfg.inline
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | inline = { inline | kernelFactsDce = True } }

            else if t == "0" || t == "off" then
                { cfg | inline = { inline | kernelFactsDce = False } }

            else
                cfg


{-| `ECO_KERNEL_GCLEAF_EMIT=1|0`: force kernel gc-leaf attr emission on/off
(kernel-opt-08; artifact-affecting, hash token `kgcl=1`). NOTE: this is the
FRONT-END switch. The backend's independent kill switch is
`ECO_KERNEL_GCLEAF=0`, which ignores an attr that is already in the `.mlir`.
Unknown values are ignored.
-}
applyKernelGcLeafEmitOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelGcLeafEmitOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | kernelGcLeaf = True }

            else if t == "0" || t == "off" then
                { cfg | kernelGcLeaf = False }

            else
                cfg


{-| `ECO_VALUE_EQ=1|true|yes|on` (`0|off` disables): kernel-opt-03 -- lower boxed
structural equality to `eco.value.eq`. Artifact-affecting (hash token `veq=1`).
Bool `==` is deliberately NOT gated by this: it lowers to one `arith.xori` and is
unconditionally better than the boxed kernel call.
-}
applyValueEqOverride : Maybe String -> EcoConfig -> EcoConfig
applyValueEqOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | valueEq = True }

            else if t == "0" || t == "off" then
                { cfg | valueEq = False }

            else
                cfg


{-| `ECO_STRING_ORDER_INTRINSIC=1|true|yes|on` (`0|off` disables): kernel-opt-06
-- lower `Utils.lt/le/gt/ge` on two Strings to `eco.string.cmp3` plus a signed
test against 0, instead of a boxed kernel call whose Bool is immediately
unboxed. Artifact-affecting (hash token `strord=1` when enabled).
-}
applyStringOrderIntrinsicOverride : Maybe String -> EcoConfig -> EcoConfig
applyStringOrderIntrinsicOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | stringOrderIntrinsic = True }

            else if t == "0" || t == "off" then
                { cfg | stringOrderIntrinsic = False }

            else
                cfg


{-| `ECO_APPEND_SPLIT=1|true|yes|on` (`0|off` disables): kernel-opt-05 -- emit
typed `eco.string.append` / `eco.list.append` at mono sites that statically know
the operand type, instead of the polymorphic `Elm_Kernel_Utils_append` call.
Artifact-affecting (hash token `apsplit=1` when enabled).
-}
applyAppendSplitOverride : Maybe String -> EcoConfig -> EcoConfig
applyAppendSplitOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | appendSplit = True }

            else if t == "0" || t == "off" then
                { cfg | appendSplit = False }

            else
                cfg


{-| `ECO_STRING_LENGTH_OP=1|true|yes|on` (`0|off` disables): kernel-opt-04 —
emit `eco.string.length` (an inline `header.size` load) instead of calling
`Elm_Kernel_String_length`. Artifact-affecting (hash token `strlen=1` when
enabled), so flag-on builds never share flag-off caches. The separate BACKEND
knob `ECO_STRING_LEN_INLINE=0` chooses a plain kernel call as the lowering and
needs no compiler rebuild.
-}
applyStringLengthOpOverride : Maybe String -> EcoConfig -> EcoConfig
applyStringLengthOpOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | stringLengthOp = True }

            else if t == "0" || t == "off" then
                { cfg | stringLengthOp = False }

            else
                cfg


{-| `ECO_CTOR_INLINE=1|true|yes`: U-T1.3.2c ctor-call inlining — saturated
direct constructor calls emit `eco.construct.custom` in the caller instead
of calling the ctor function. Hash-relevant ("ctori"), so flag-on builds
never share flag-off caches. `0`/`off` disables.
-}
applyCtorInlineOverride : Maybe String -> EcoConfig -> EcoConfig
applyCtorInlineOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | ctorInline = True }

            else if t == "0" || t == "off" then
                { cfg | ctorInline = False }

            else
                cfg


{-| `ECO_SRET_RESULTS=1|true|yes`: U-T1.3.3 result promotion — eligible
tuple-returning functions gain a multi-result `$sret` worker and
destructuring call sites migrate to it. Hash-relevant ("sretr").
`0`/`off` disables.
-}
applySretResultsOverride : Maybe String -> EcoConfig -> EcoConfig
applySretResultsOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | sretResults = True }

            else if t == "0" || t == "off" then
                { cfg | sretResults = False }

            else
                cfg


{-| `ECO_SRET_FRESH=0|off`: U-T1.3.8 — disable the helper-mediated-result
widening of sret selection (leaf = direct call to a promoted callee with
identical slots). DEFAULT-ON since 2026-08-04. Hash-relevant when enabled
("sretf=1").
-}
applySretFreshOverride : Maybe String -> EcoConfig -> EcoConfig
applySretFreshOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | sretFresh = True }

            else if t == "0" || t == "off" then
                { cfg | sretFresh = False }

            else
                cfg


{-| `ECO_SRET_TAILFUNC=0|off`: U-T1.3.6 — disable the tail-func widening of
sret result promotion. DEFAULT-ON since 2026-08-04 by user decision,
accepting the measured ~+4% self-compile wall regression that cancels
T1.3.3's win (see the tier-1 plan's T1.3.6 as-built). Hash-relevant when
enabled ("srtf=1").
-}
applySretTailFuncOverride : Maybe String -> EcoConfig -> EcoConfig
applySretTailFuncOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | sretTailFuncs = True }

            else if t == "0" || t == "off" then
                { cfg | sretTailFuncs = False }

            else
                cfg


{-| `ECO_PSPLIT_PARAMS=1|true|yes`: U-T1.3.5 param-side promotion —
projection-only aggregate params gain a `$psplit` scalar-params worker;
free-slot call sites migrate. Hash-relevant ("psplit"). `0`/`off`
disables.
-}
applyPsplitParamsOverride : Maybe String -> EcoConfig -> EcoConfig
applyPsplitParamsOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | psplitParams = True }

            else if t == "0" || t == "off" then
                { cfg | psplitParams = False }

            else
                cfg


{-| `ECO_BORROW=off|1|rc`: run the borrow-inference analysis (GlobalOpt
Phase 6). `1`/`true`/`yes`/`on` ⇒ census oracle (enabled, reify=ROff, graph
unchanged); `rc` ⇒ enabled + reify=RRc (RRc is a no-op until B4); `off`/`0` ⇒
disabled. Unknown values are ignored.
-}
applyBorrowOverride : Maybe String -> EcoConfig -> EcoConfig
applyBorrowOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                borrow =
                    cfg.borrow
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | borrow = { borrow | enabled = True, reify = Config.ROff } }

            else if t == "rc" then
                { cfg | borrow = { borrow | enabled = True, reify = Config.RRc } }

            else if t == "0" || t == "off" then
                { cfg | borrow = { borrow | enabled = False } }

            else
                cfg


{-| `ECO_BORROW_REPORT=1|true|yes`: emit the borrow census to stderr after
GlobalOpt. Also enables the pass (so the census actually runs even if
`ECO_BORROW` was not set). Output-only, excluded from `Config.hash`.
-}
applyBorrowReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyBorrowReportOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            borrow =
                cfg.borrow
        in
        { cfg | borrow = { borrow | enabled = True, report = True } }

    else
        cfg


{-| `ECO_LIST_CHUNKS=1|0`: force chunked-list codegen on/off
(plans/chunked-list-representation.md; artifact-affecting, hash token
`lchunks=1`). Unknown values are ignored.
-}
applyListChunksOverride : Maybe String -> EcoConfig -> EcoConfig
applyListChunksOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                listCfg =
                    cfg.list
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | list = { listCfg | chunks = True } }

            else if t == "0" || t == "off" then
                { cfg | list = { listCfg | chunks = False } }

            else
                cfg


{-| `ECO_LIST_CONS_INTRINSIC=1|true|yes|on` (`0|off` disables): lower saturated
`x :: xs` to `eco.construct.list` instead of `Elm_Kernel_List_cons*`
(kernel-opt-01). Artifact-affecting — hash token `lcons=1` when enabled.
-}
applyListConsIntrinsicOverride : Maybe String -> EcoConfig -> EcoConfig
applyListConsIntrinsicOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                listCfg =
                    cfg.list
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | list = { listCfg | consIntrinsic = True } }

            else if t == "0" || t == "off" then
                { cfg | list = { listCfg | consIntrinsic = False } }

            else
                cfg


{-| `ECO_LIST_MAP_TEMPLATE=1|true|yes|on` (`0|off` disables): replace the body
of a licensed `List.map` specialization with a forward-iterating
`eco.list.map` op (plans/list-map-mlir-template.md). DEFAULT OFF.
Artifact-affecting — hash token `lmapt=1` when enabled. Inert unless
`list.chunks` is also on.
-}
applyListMapTemplateOverride : Maybe String -> EcoConfig -> EcoConfig
applyListMapTemplateOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                listCfg =
                    cfg.list
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | list = { listCfg | mapTemplate = True } }

            else if t == "0" || t == "off" then
                { cfg | list = { listCfg | mapTemplate = False } }

            else
                cfg


{-| `ECO_LIST_REPORT=1|true|yes`: emit the List-combinator recognition
census to stderr after GlobalOpt (output-only, excluded from `hash`).
-}
applyListReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyListReportOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            listCfg =
                cfg.list
        in
        { cfg | list = { listCfg | report = True } }

    else
        cfg


applyEngineOverride : Maybe String -> EcoConfig -> Task Exit.Make EcoConfig
applyEngineOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            Task.succeed cfg

        Just raw ->
            if String.trim raw == "" then
                Task.succeed cfg

            else
                case Config.monoEngineFromString raw of
                    Just engine ->
                        let
                            mono =
                                cfg.mono
                        in
                        Task.succeed { cfg | mono = { mono | engine = engine } }

                    Nothing ->
                        Task.io (IO.writeLn IO.stderr ("eco: unrecognized ECO_MONO_ENGINE=" ++ raw ++ " (expected subst|solver|diff); keeping current engine"))
                            |> Task.map (\_ -> cfg)


applyDumpOverride : Maybe String -> EcoConfig -> EcoConfig
applyDumpOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            mono =
                cfg.mono
        in
        { cfg | mono = { mono | diffDump = True } }

    else
        cfg


{-| `ECO_MONO_VALIDATE=1`: run the MONO\_029 layout-agreement validator
(Compiler.Monomorphize.ValidateLayout) after monomorphization and fail the
compile on violations. Output-only debug/CI knob, never from JSON.
-}
applyValidateOverride : Maybe String -> EcoConfig -> EcoConfig
applyValidateOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            mono =
                cfg.mono
        in
        { cfg | mono = { mono | validate = True } }

    else
        cfg


{-| `ECO_BORROW_OPT=1|true|yes|on`: OC0.1 (plans/borrow-oracle-consumers.md) —
opt this build into the oracle-coupled transforms. Enables the borrow pass and
sets `borrow.oracleOpt`; the distilled facts are derived at MLIR-emission time
from the final post-CafHoist graph (`Borrow.deriveFacts`). ARTIFACT-AFFECTING
(folded into `Config.hash` as `bopt=1`), so opt builds never share caches with
default builds. `0`/`off` disables `oracleOpt` only. Applied AFTER
`ECO_BORROW`, so an explicit opt-in wins over `ECO_BORROW=0`'s disable.
-}
applyBorrowOptOverride : Maybe String -> EcoConfig -> EcoConfig
applyBorrowOptOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)

                borrow =
                    cfg.borrow
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | borrow = { borrow | enabled = True, oracleOpt = True } }

            else if t == "0" || t == "off" then
                { cfg | borrow = { borrow | oracleOpt = False } }

            else
                cfg


{-| `ECO_MONO_LSS=0|1|keyed|unkeyed`: toggle lambda-set specialization. Unknown
values are ignored (dev-only knob; silence beats failure here since `0` must
always be a safe escape hatch). With `keyed = True` the default (post-Fix-B),
`unkeyed` is the bidirectional escape to the selective-whitelist mode
(`keyedGlobals` routing only); `keyed` is kept as an explicit no-op for
existing scripts.
-}
applyLssOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssOverride maybeVal cfg =
    case Maybe.map (String.trim >> String.toLower) maybeVal of
        Just "0" ->
            updateLss (\lss -> { lss | enabled = False, keyed = False }) cfg

        Just "1" ->
            updateLss (\lss -> { lss | enabled = True }) cfg

        Just "keyed" ->
            updateLss (\lss -> { lss | enabled = True, keyed = True }) cfg

        Just "unkeyed" ->
            updateLss (\lss -> { lss | enabled = True, keyed = False }) cfg

        _ ->
            cfg


{-| `ECO_MONO_LSS_MAX_SPECS=<n>`: override `mono.lss.maxSpecsPerGlobal`
(the keyed-mode spec budget, design §8.5). **0 = UNLIMITED — the default
since 2026-08-29.** Test/tuning knob — a tiny value (1, not 0) forces the
budget-exhausted widened-key + LSS\_010-join fallback so the mixed-mode
path can be exercised deliberately. Non-numeric values are ignored.
Participates in the config hash via the `lssB=` token, so eco-stuff
artifacts never alias across budgets.
-}
applyLssBudgetOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssBudgetOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLss (\lss -> { lss | maxSpecsPerGlobal = n }) cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_MAX_SET_SIZE=<n>`: override `mono.lss.maxSetSize` (a zonked
set larger than this widens to `LTop`). **0 = UNLIMITED — the default since
2026-08-29** (plans/lss-provenance-join-and-demand-sigs.md §4.7). Non-numeric
values are ignored. Participates in the config hash via the existing
non-default `maxSetSize` token, so eco-stuff artifacts never alias.
-}
applyLssMaxSetSizeOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssMaxSetSizeOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLss (\lss -> { lss | maxSetSize = n }) cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_SPINE_ARITY=1|0` (S.10, F-5C): inject standalone members
through the first `declaredArity` arrows rather than the head arrow only, so
partially-applied globals and ctors carry a resolvable member at the callback
position. Default off. Artifact-affecting when enabled — participates in
`Config.hash` via the `lssSA=` token, so eco-stuff artifacts never alias
across the two modes.
-}
applyLssSpineArityOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssSpineArityOverride maybeVal cfg =
    case Maybe.map String.trim maybeVal of
        Just "1" ->
            updateLss (\lss -> { lss | spineArity = True }) cfg

        Just "0" ->
            updateLss (\lss -> { lss | spineArity = False }) cfg

        _ ->
            cfg


{-| `ECO_MONO_LSS_KEYED_GLOBALS=g1,g2` (E5 selective keying): key ONLY these
globals. User format `author/project:Module.Name.value`; REPLACES the config
list. Malformed entries are warned to stderr and dropped (dev knob — mirror
the unrecognized-`ECO_MONO_ENGINE` handling). Participates in `Config.hash`
via the `lssKG=` token.
-}
applyLssKeyedGlobalsOverride : Maybe String -> EcoConfig -> Task Exit.Make EcoConfig
applyLssKeyedGlobalsOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            Task.succeed cfg

        Just raw ->
            let
                entries =
                    String.split "," raw
                        |> List.map String.trim
                        |> List.filter (\e -> e /= "")

                ( good, bad ) =
                    List.partition wellFormedKeyedGlobal entries

                cfg1 =
                    updateLss (\lss -> { lss | keyedGlobals = good }) cfg
            in
            if List.isEmpty bad then
                Task.succeed cfg1

            else
                Task.io (IO.writeLn IO.stderr ("eco: dropping malformed ECO_MONO_LSS_KEYED_GLOBALS entries (expected author/project:Module.Name.value): " ++ String.join ", " bad))
                    |> Task.map (\_ -> cfg1)


{-| `ECO_MONO_LSS_DEVIRT_FN=1|true|yes / 0|false|no` (E9.1): devirtualize
singleton FUNCTION-global dispatch sites too (not just ctors). DEFAULT-ON
since Tier 1 (2026-07-20; the deciding uninstrumented A/B retired Run I's
instrumented "+35%" workload read — see Run L), so the override is
bidirectional: `0|false|no` is the escape hatch. Unset or unrecognized
leaves the config/default value. Participates in the hash via the
`lssDF=` token.
-}
applyLssDevirtFnOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssDevirtFnOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | devirtFnGlobals = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | devirtFnGlobals = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_CAF_MEMO=1|true|yes / 0|false|no`: CAF memoization — per-SpecId
lazy once-init `eco.global` slots for nullary value thunks
(plans/caf-memoization-implementation.md). DEFAULT-ON, so the override is
bidirectional: `0|false|no` is the escape hatch (compile-time only — the
guard is baked into generated code). Unset or unrecognized leaves the
config/default value. Participates in the hash via the `cafm=` token.
-}
applyCafMemoOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafMemoOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                { cfg | cafMemo = { enabled = True, census = cfg.cafMemo.census, dedupe = cfg.cafMemo.dedupe, hoist = cfg.cafMemo.hoist } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | cafMemo = { enabled = False, census = cfg.cafMemo.census, dedupe = cfg.cafMemo.dedupe, hoist = cfg.cafMemo.hoist } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_CAF_CENSUS=1|true|yes`: render the inner-CAF opportunity census
(Compiler.GlobalOpt.CafCensus) over the final MonoGraph to stderr after
GlobalOpt. Output-only debug knob, never affects artifacts or the hash.
-}
applyCafCensusOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafCensusOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        { cfg | cafMemo = { enabled = cfg.cafMemo.enabled, census = True, dedupe = cfg.cafMemo.dedupe, hoist = cfg.cafMemo.hoist } }

    else
        cfg


{-| `ECO_CAF_DEDUPE=1|true|yes / 0|false|no`: CAF spec dedupe — merge
structurally identical nullary `MonoDefine` specs onto one canonical spec
(Compiler.GlobalOpt.CafDedupe). Default-off pending Run Y. Artifact-affecting;
participates in the hash via the `cafd=` token.
-}
applyCafDedupeOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafDedupeOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                { cfg | cafMemo = { enabled = cfg.cafMemo.enabled, census = cfg.cafMemo.census, dedupe = True, hoist = cfg.cafMemo.hoist } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | cafMemo = { enabled = cfg.cafMemo.enabled, census = cfg.cafMemo.census, dedupe = False, hoist = cfg.cafMemo.hoist } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_CAF_HOIST=1|true|yes / 0|false|no`: CAF hoisting — closed
expressions inside function bodies get per-SpecId slots
(plans/caf-hoist-closed-expressions.md). Default-off during bring-up.
Participates in the hash via the `cafh=` token.
-}
applyCafHoistOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafHoistOverride maybeVal cfg =
    let
        setEnabled b =
            updateCafHoist (\h -> { h | enabled = b }) cfg
    in
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                setEnabled True

            else if List.member v [ "0", "false", "no" ] then
                setEnabled False

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_CAF_HOIST_MIN_NODES=<n>`: original-subtree size floor for hoisting
(plan DQ1). Tuning/sweep knob; hash token `cafhN=` when non-default.
-}
applyCafHoistMinNodesOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafHoistMinNodesOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateCafHoist (\h -> { h | minNodes = n }) cfg

        Nothing ->
            cfg


{-| `ECO_CAF_HOIST_MAX=<n>`: global mint budget safety valve (plan DQ1).
Tuning/sweep knob; hash token `cafhM=` when non-default.
-}
applyCafHoistMaxOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafHoistMaxOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateCafHoist (\h -> { h | maxHoists = n }) cfg

        Nothing ->
            cfg


updateCafHoist : (Config.CafHoistConfig -> Config.CafHoistConfig) -> EcoConfig -> EcoConfig
updateCafHoist f cfg =
    let
        cafMemo =
            cfg.cafMemo
    in
    { cfg | cafMemo = { cafMemo | hoist = f cafMemo.hoist } }


{-| `author/project:Module.Name.value` — a `:` separating a `/`-bearing
package from a dot-qualified value (module segments + value name).
-}
wellFormedKeyedGlobal : String -> Bool
wellFormedKeyedGlobal entry =
    case String.split ":" entry of
        [ pkg, def ] ->
            List.length (String.split "/" pkg) == 2 && List.length (String.split "." def) >= 2

        _ ->
            False


{-| `ECO_MONO_LSS_REPORT=1|true|yes`: render the LSS census after mono.
-}
applyLssReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssReportOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        updateLss (\lss -> { lss | report = True }) cfg

    else
        cfg


{-| `ECO_INLINE_HOF_THRESHOLD=<n>`: override `inline.hofThreshold` (the H2
called-function-param budget). Participates in the config hash via the
`hthr=` token, so eco-stuff artifacts never alias across budgets.
Non-numeric values are ignored.
-}
applyHofThresholdOverride : Maybe String -> EcoConfig -> EcoConfig
applyHofThresholdOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | hofThreshold = n } }

        Nothing ->
            cfg


{-| `ECO_INLINE_LOOPIFY=0|false|no`: disable recursive-HOF loopification
(plan H5 escape hatch). Any other value leaves the config untouched.
-}
applyLoopifyOverride : Maybe String -> EcoConfig -> EcoConfig
applyLoopifyOverride maybeVal cfg =
    let
        off =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "0" || t == "false" || t == "no"

                Nothing ->
                    False
    in
    if off then
        let
            inline =
                cfg.inline
        in
        { cfg | inline = { inline | loopify = False } }

    else
        cfg


{-| `ECO_ARITY_RAISE=1|true|yes`: enable H6.2 U2b staged-spec arity
raising (experimental, default off). Participates in the config hash via
the `ar=` token (present only when enabled).
-}
applyArityRaiseOverride : Maybe String -> EcoConfig -> EcoConfig
applyArityRaiseOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            inline =
                cfg.inline
        in
        { cfg | inline = { inline | arityRaise = True } }

    else
        cfg


{-| `ECO_ARITY_RAISE_MIN_APPLIED=<0..100>`: override
`inline.raiseAppliedShareMin` (H6.2.5 Lever 2 — raise a staged spec only
when at least this percent of its saturated-call results are applied).
Participates in the config hash via the `arm=` token (present only when
nonzero and raising is enabled). Non-numeric values are ignored; values
are clamped to [0,100].
-}
applyRaiseMinAppliedOverride : Maybe String -> EcoConfig -> EcoConfig
applyRaiseMinAppliedOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | raiseAppliedShareMin = clamp 0 100 n } }

        Nothing ->
            cfg


{-| `ECO_INLINE_PRESERVE_SETS=1|true|yes`: make `MonoInlineSimplify` decline
the strictly-partial inline — the one reshape that clears an LSS member
identity — so the callee's PAP (a stampable `p|` member) is left in place
(plans/pre-mono-lss-transforms-02-inline-preserve-sets.md). Beats
`ECO_INLINE_PARTIAL_HOF`, which exists to force that same arm, and applies to
whitelisted candidates too. Artifact-affecting; hash token `psets=`. DEFAULT-ON
since 2026-09-12 (`=0` turns it off; benchmarks/call-stats.md Runs 7/8).
-}
applyInlinePreserveSetsOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePreserveSetsOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | preserveSets = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | preserveSets = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_PRUNE_DEAD=0|false|no`: skip the post-inline dead-spec prune
(plans/post-inline-dead-spec-prune.md).

`MonoInlineSimplify` orphans a specialization whenever it inlines the only
reference to it; nothing removed those before this pass, because `Prune` runs
at the end of monomorphization and the inliner returns empty `callEdges`.
MEASURED: 6,608 unreferenced code-bearing functions on the self-compile,
4.86 % of the emitted text, and every `g1absentl` AbiCloning decline. ON by
default; `=0` is for the byte-identity gate and for bisecting a dangling
reference if a later pass ever introduces one. Artifact-affecting; hash token
`prune=`.

-}
applyInlinePruneDeadOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePruneDeadOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | pruneDead = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | pruneDead = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_PARTIAL_HOF=1|true|yes`: let a candidate admitted via
`inline.hofThreshold` inline at a STRICTLY-PARTIAL call site too, instead of
only at exact (saturated) ones.

This is the single gate keeping the IO monad's bind out of the inliner:
`andThen f ma` supplies 2 of 3 arguments at all 367 of its sites, so it is
never an exact call. Forcing it in via the whitelist measured **-8.77 %**
generic dispatch (/work/direct-call-decline-census.md), and this is the
general, non-codebase-specific form of that.

The refusal it lifts exists because a partial rebuild's re-staged closure once
tripped the runtime typed-apply arity assert when a caller over-applied it —
so treat a crash or a wrong answer under this flag as that class, not as a new
bug. Artifact-affecting; hash token `phof=`. DEFAULT-OFF.

-}
applyInlinePartialHofOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePartialHofOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | partialHof = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | partialHof = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_THRESHOLD=<n>`: BROADCAST — sets `preMonoThreshold`,
`postMonoThreshold` AND `etaThreshold` together. Kept because
`ECO_INLINE_THRESHOLD=0` ("no inlining anywhere") is a standing test leg; the
per-pass variables below are read AFTER it in the chain, so each one overrides
the broadcast for its own pass. Was the only knob for all three passes until
the 2026-09-15 split.

Legacy note — the general
inlining cost budget (default 10).

Raising it past a spec's cost flips that spec out of `exactOnly`, which
permits PARTIAL inlining — so this is the blunt instrument whose targeted
sibling is `ECO_INLINE_PARTIAL_HOF`. Already in the config hash as `thr=`, so
each value is cache-disjoint without a new token. Experiment/tuning knob.

-}
applyInlineThresholdOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlineThresholdOverride maybeVal cfg =
    case Maybe.andThen (String.toInt << String.trim) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg
                | inline =
                    { inline
                        | preMonoThreshold = max 0 n
                        , postMonoThreshold = max 0 n
                        , etaThreshold = max 0 n
                    }
            }

        Nothing ->
            cfg


{-| `ECO_INLINE_PRE_MONO=0|1`: run `InlineSimplify` BEFORE monomorphization
(plans/pre-mono-inline-simplify.md). Artifact-affecting; hash token `preInl=`.
**DEFAULT-OFF since 2026-09-15** (`=1` turns it on), reversing the 2026-09-11
flip: `aliasForward` took over the alias-wrapper population this pass served,
and call-stats Runs 17-20 price the remainder at +0.29 % generic dispatch for
484 bytes of artifact. Gates ONLY `InlineSimplify` — `AliasForward` and
`EtaExpand` are separate passes with their own flags and still run.
-}
applyInlinePreMonoOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePreMonoOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | preMono = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | preMono = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_ETA_ONLY=Mod.A,Mod.B`: DIAGNOSTIC — restrict `PreMono.EtaExpand`
to globals whose module name starts with one of the listed prefixes (the
2026-09-11 bootstrap fixed-point bisect). Empty/unset = every module.
-}
applyInlineEtaOnlyOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlineEtaOnlyOverride maybeVal cfg =
    case maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline

                mods =
                    String.split "," v
                        |> List.map String.trim
                        |> List.filter (\m -> m /= "")
            in
            { cfg | inline = { inline | etaOnly = mods } }

        Nothing ->
            cfg


{-| Per-pass size budgets and round counts (2026-09-15 split). Each reads its
own environment variable and is applied AFTER the `ECO_INLINE_THRESHOLD` /
`ECO_INLINE_FPI` broadcasts, so a per-pass value always wins.

`ECO_INLINE_PRE_MONO_THRESHOLD` — `InlineSimplify`'s candidate size gate
(`cost body > preMonoThreshold` refuses the DEFINITION, so none of its call
sites is considered). Hash token `preThr=`.

`ECO_INLINE_POST_MONO_THRESHOLD` — `MonoInlineSimplify`'s budget; the effective
HOF budget is `max postMonoThreshold hofThreshold`. Hash token `postThr=`.

`ECO_ETA_THRESHOLD` — `PreMono.EtaExpand`'s CHEAPNESS gate, which is not an
inlining budget at all: it decides whether the work left of a new binder is
cheap enough to move from once-per-CAF to once-per-call. Hash token `etaThr=`.

`ECO_INLINE_PRE_MONO_FPI` / `ECO_INLINE_POST_MONO_FPI` — per-pass round counts.
Hash tokens `preFpi=` / `postFpi=`.

-}
applyInlinePreMonoThresholdOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePreMonoThresholdOverride maybeVal cfg =
    case Maybe.andThen (String.toInt << String.trim) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | preMonoThreshold = max 0 n } }

        Nothing ->
            cfg


applyInlinePostMonoThresholdOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePostMonoThresholdOverride maybeVal cfg =
    case Maybe.andThen (String.toInt << String.trim) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | postMonoThreshold = max 0 n } }

        Nothing ->
            cfg


applyEtaThresholdOverride : Maybe String -> EcoConfig -> EcoConfig
applyEtaThresholdOverride maybeVal cfg =
    case Maybe.andThen (String.toInt << String.trim) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | etaThreshold = max 0 n } }

        Nothing ->
            cfg


applyInlinePreMonoFpiOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePreMonoFpiOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | preMonoFixpointIterations = n } }

        Nothing ->
            cfg


applyInlinePostMonoFpiOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePostMonoFpiOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | postMonoFixpointIterations = n } }

        Nothing ->
            cfg


{-| `ECO_INLINE_ALIAS_FORWARD=1|true|yes`: run `PreMono.AliasForward` before
monomorphization (plans/pre-mono-lss-transforms-04-alias-forwarding.md).
Artifact-affecting; hash token `afwd=`. DEFAULT-ON since 2026-09-14 (`=0` turns
it off).
-}
applyInlineAliasForwardOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlineAliasForwardOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | aliasForward = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | aliasForward = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_ETA_EXPAND=1|true|yes`: run `PreMono.EtaExpand` before
monomorphization
(plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md).
Artifact-affecting; hash token `eta=`. DEFAULT-ON since 2026-09-11 (`=0`
turns it off).
-}
applyInlineEtaExpandOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlineEtaExpandOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | etaExpand = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | etaExpand = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_POST_MONO=0|false|no`: skip `MonoInlineSimplify`, the existing
inliner that runs AFTER monomorphization. Artifact-affecting; hash token
`postInl=`. DEFAULT-ON, so `=0` is the interesting setting — it is the EARLY arm
of the position A/B (plans/pre-mono-inline-simplify.md §7).
-}
applyInlinePostMonoOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlinePostMonoOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            let
                inline =
                    cfg.inline
            in
            if List.member v [ "1", "true", "yes" ] then
                { cfg | inline = { inline | postMono = True } }

            else if List.member v [ "0", "false", "no" ] then
                { cfg | inline = { inline | postMono = False } }

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_INLINE_FPI=<n>`: BROADCAST — sets `preMonoFixpointIterations` AND
`postMonoFixpointIterations`. The per-pass variables are read after it and
override it. Participates in the config hash via the `preFpi=`/`postFpi=`
tokens. Non-numeric values are ignored.
-}
applyFpiOverride : Maybe String -> EcoConfig -> EcoConfig
applyFpiOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg
                | inline =
                    { inline
                        | preMonoFixpointIterations = n
                        , postMonoFixpointIterations = n
                    }
            }

        Nothing ->
            cfg


{-| `ECO_INLINE_REPORT=1|true|yes`: render the inline census after
inline+simplify. Output-only, never affects `Config.hash`.
-}
applyInlineReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyInlineReportOverride maybeVal cfg =
    let
        on =
            case maybeVal of
                Just v ->
                    let
                        t =
                            String.toLower (String.trim v)
                    in
                    t == "1" || t == "true" || t == "yes"

                Nothing ->
                    False
    in
    if on then
        let
            inline =
                cfg.inline
        in
        { cfg | inline = { inline | report = True } }

    else
        cfg


updateLss : (Config.LssConfig -> Config.LssConfig) -> EcoConfig -> EcoConfig
updateLss f cfg =
    let
        mono =
            cfg.mono
    in
    { cfg | mono = { mono | lss = f mono.lss } }


updateLssSettle : (Config.LssSettleConfig -> Config.LssSettleConfig) -> EcoConfig -> EcoConfig
updateLssSettle f =
    updateLss (\lss -> { lss | settle = f lss.settle })


updateLssStageAnchor : (Config.LssStageAnchorConfig -> Config.LssStageAnchorConfig) -> EcoConfig -> EcoConfig
updateLssStageAnchor f =
    updateLss (\lss -> { lss | stageAnchor = f lss.stageAnchor })


updateLimits : (Config.SpecLimits -> Config.SpecLimits) -> EcoConfig -> EcoConfig
updateLimits f cfg =
    let
        mono =
            cfg.mono
    in
    { cfg | mono = { mono | limits = f mono.limits } }


{-| `ECO_SPEC_TYPE_NODE_LIMIT=<n>` / `ECO_SPEC_BREADTH_LIMIT=<n>` (MONO\_030
watchdogs): override the spec key-size / per-global breadth limits. `0`
disables the check. Non-numeric values are ignored (dev knob). Failure-only —
never participates in `Config.hash` (a failed compile is never cached; a
passing compile is limit-invisible).
-}
applySpecTypeNodeLimitOverride : Maybe String -> EcoConfig -> EcoConfig
applySpecTypeNodeLimitOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLimits (\l -> { l | specTypeNodes = n }) cfg

        Nothing ->
            cfg


applySpecBreadthLimitOverride : Maybe String -> EcoConfig -> EcoConfig
applySpecBreadthLimitOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLimits (\l -> { l | specBreadth = n }) cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_MU_TIE=1|true|yes / 0|false|no` (LSS\_018): μ-tie the
qualification spiral's self-similar member family. Unset or unrecognized
leaves the config/default value. Artifact-affecting when it differs from the
default — participates in the hash via the `lssMU=` token.
-}
applyLssMuTieOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssMuTieOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | muTie = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | muTie = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_GROUND=1|true|yes / 0|false|no` (LSS\_019): ground
provisional `g|`/`c|` standalone members to `g|<global>|<arrow-typeKey>` at
zonk (plans/lss-fidelity-2-standalone-member-grounding.md). Unset or
unrecognized leaves the config/default value. Artifact-affecting when it
differs from the default — participates in the hash via the `lssGS=` token.
-}
applyLssGroundOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssGroundOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | groundStandalones = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | groundStandalones = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_SIG_FLOW=1|true|yes / 0|false|no` (LSS\_020): signature
set-flow completion — the inference walk connects ground-typed intra-def
flow to signature slots (plans/lss-fidelity-3-signature-flow-completion.md
§B). Unset or unrecognized leaves the config/default value.
Artifact-affecting when it differs from the default — participates in the
hash via the `lssSF=` token.
-}
applyLssSigFlowOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssSigFlowOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | sigFlow = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | sigFlow = False }) cfg

            else
                cfg

        Nothing ->
            cfg


setStampEnabled : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampEnabled v c =
    { c | enabled = v }


setStampMax : Int -> Config.LssStampConfig -> Config.LssStampConfig
setStampMax n c =
    { c | maxInstances = n }


setStampFlatPeel : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampFlatPeel v c =
    { c | flatPeel = v }


{-| Record UPDATE, never a literal: a literal here silently stops compiling the
moment `LssStampConfig` gains a field, and `elm-test-rs` will NOT catch it
because nothing under `TestLogic` imports `Builder.*`.
-}
setStampCensus : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampCensus v c =
    { c | census = v }


setStampPapFast : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampPapFast v c =
    { c | papFast = v }


setStampUseInject : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampUseInject v c =
    { c | useInject = v }


{-| `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT=1|true|yes / 0|false|no`: F2
local-multi use-site member injection
(plans/lss-container-payload-transport.md §12.9.4). Artifact-affecting;
hash token `lssIU=`.
-}
applyLssInstanceQualUseInjectOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssInstanceQualUseInjectOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | stamp = setStampUseInject True lss.stamp }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | stamp = setStampUseInject False lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_PAP_FAST=1|true|yes / 0|false|no` (LSS\_040,
plans/lss-pap-fast-stamp.md): FAST-stamp call sites whose callee is a
`p|<global>|<k>` partial-application member, loading the k bound arguments
out of the PAP object as LSS\_011 does for closures. Artifact-affecting; hash
token `lssPF=`. DEFAULT-ON since 2026-09-07; `=0` is the escape hatch.
-}
applyLssPapFastOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssPapFastOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | stamp = setStampPapFast True lss.stamp }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | stamp = setStampPapFast False lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_FLAT_PEEL=1|true|yes / 0|false|no` (Fix A, plan §15.1): at an
OVER-APPLYING call site, peel the curried callee type to the site's own arg
count and match the instance against that, instead of against the type's
one-parameter first stage. Artifact-affecting; hash token `lssFP=`.
-}
applyLssFlatPeelOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssFlatPeelOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | stamp = setStampFlatPeel True lss.stamp }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | stamp = setStampFlatPeel False lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_INSTANCE_QUAL=1|true|yes / 0|false|no`: instance-qualified
lambda members (plans/lss-instance-qualified-members.md). Artifact-affecting;
participates in the hash via `lssIQ=`.
-}
applyLssInstanceQualOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssInstanceQualOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | stamp = setStampEnabled True lss.stamp }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | stamp = setStampEnabled False lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_INSTANCE_QUAL_MAX=<int>`: the §3.3 hard cap on how many
local-multi instances of one let-function get distinct member ids. 0 =
unlimited (unbounded fan-out risk — measurement only). Hash token `lssIQM=`.
-}
applyLssInstanceQualMaxOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssInstanceQualMaxOverride maybeVal cfg =
    case Maybe.andThen (String.toInt << String.trim) maybeVal of
        Just n ->
            if n >= 0 then
                updateLss (\lss -> { lss | stamp = setStampMax n lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_LAYOUT_QUAL=1|true|yes / 0|false|no` (LSS\_024): layout-
qualified lambda-instance members + the AbiCloning fingerprint fence
(plans/lss-layout-qualified-members.md). Unset or unrecognized leaves the
config/default value. Artifact-affecting when it differs from the default —
participates in the hash via the `lssLQ=` token.
-}
applyLssLayoutQualOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssLayoutQualOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | layoutQualMembers = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | layoutQualMembers = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_REF_IDENTITY=1|true|yes / 0|false|no` (§5.4 GAP-A): classify a
bare global reference store-aware when its type mentions an arrow, instead of
with the storeless classifier that stamps LTop on every arrow. DEFAULT-OFF.
Hash token `lssRI=`.
-}
applyLssRefIdentityOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssRefIdentityOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | refIdentity = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | refIdentity = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_QCENSUS=1|true|yes / 0|false|no` (§5.1/§5.6 shadow `Q`): record
every inclusion constraint the solver emits, solve it at the inference boundary
and score it against the store. Split from `lss.report` because the benchmark
protocol mandates the latter and this is not free. DEFAULT-OFF. Hash token
`lssQC=`.
-}
applyLssQCensusOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssQCensusOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | qCensus = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | qCensus = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_CENSUS=1|true|yes / 0|false|no`: collect the AbiCloning
per-site census Dicts (`byHost`, `niGuard`, `shape`, `papSites`) — the join
keys against the caller-attributed runtime dispatch census.

Split from `lss.report` for `qCensus`'s reason: the benchmark protocol mandates
`ECO_MONO_LSS_REPORT=1`, so anything under `report` is billed to every timed
run, and this one builds a String key plus a Dict insert at ~43,000 sites per
self-compile. The scalar counters are unaffected and stay on.

With this OFF the census Dicts read empty, so a census binary must be built and
run with it ON — see plans/lss-body-mismatch-declines.md §8.4 for the join
error this prevents. DEFAULT-OFF. Hash token `lssCen=`.

-}
applyLssCensusOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssCensusOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | stamp = setStampCensus True lss.stamp }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | stamp = setStampCensus False lss.stamp }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_PAP_MEMBERS=1|true|yes / 0|false|no`
(plans/lss-injection-completeness.md): inject the callee's member on the
RESIDUAL arrows of a partial application of a known global — the one producer
form that injected nothing before it (P0 census: 3,624 self-compile positions).
DEFAULT-ON since 2026-08-27, flipped together with `sigRootIdentity`; setting
this to 0 while `ECO_MONO_LSS_SIG_ROOT_ID` stays on re-creates the recorded
identity-map miscompile, so turn off BOTH or neither. Hash token `lssPM=`.
-}
applyLssPapMembersOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssPapMembersOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | papMembers = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | papMembers = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_SIG_ROOT_ID=1|true|yes / 0|false|no`
(plans/lss-solver-root-signature-identity.md): inside the INFERENCE scratch
store only, key an arrow's set slot by the type checker's union-find ROOT
instead of by syntactic occurrence — tying a def's annotation arrows to its
body's, so its signature carries the facts its body proves. REQUIRES
`papMembers` (root-shared classes export through signatures; an
injection-incomplete class publishes a false singleton to every caller).
DEFAULT-ON since 2026-08-27. Hash token `lssSR=`.
-}
applyLssSigRootIdentityOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssSigRootIdentityOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | sigRootIdentity = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | sigRootIdentity = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_ARROW_CENSUS=1|true|yes / 0|false|no`
(plans/lss-provenance-ratio-census.md §7): mark every arrow peeled by an
argument, so `var`/`set` arrows split into applied and never-applied. Costs a
union-find `repr` and two counter bumps PER APPLICATION, which is why it is not
under `report` — the benchmark protocol mandates `report`, and `qCensus` was
split out for exactly this reason. REQUIRES `report` as well: the `ArrowId`
comes from `arrowOfSlot`, which only exists under `report`. DEFAULT-OFF. Hash
token `lssAC=`.
-}
applyLssArrowCensusOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssArrowCensusOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | arrowCensus = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | arrowCensus = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_REG_IDENTITY=1|true|yes / 0|false|no`
(plans/lss-registration-self-identity.md): stamp tautological self/PAP members
onto the leading spine of every solver demand at spec registration. The member
ids are the same ones the reference paths mint, the depth is bounded by
declared arity (LSS\_013), and the stamp rides EVERY demand because the LSS\_010
join collapses LSet-vs-LVar to ⊤ (AR-11). Artifact-affecting. DEFAULT-ON
since 2026-08-28 (+51.66 pp analysis coverage, dispatch exactly neutral).
Hash token `lssRG=`.
-}
applyLssRegIdentityOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssRegIdentityOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | regIdentity = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | regIdentity = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_ROOT_FOLD=1|true|yes / 0|false|no`
(plans/lss-root-member-fold.md): intern a def's ROOT lambda member under its
global's GROUND STANDALONE key, so the `{l|, g|}` split-identity pairs the
`regIdentity` stamp exposed collapse to singletons at heads. Kernel-alias
roots never fold. Artifact-affecting. DEFAULT-ON since 2026-08-28 (25.86 M
indirect dispatches eliminated, −1.165 %). Hash token `lssRF=`.
-}
applyLssRootFoldOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssRootFoldOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | rootFold = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | rootFold = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_REF_PAP_SPINE=1|true|yes / 0|false|no`
(plans/lss-ref-pap-spine.md): at standalone-reference injections, also write
the PAP successors `p|<global>|<d>` down the loaded type's result spine
(d in 1..declaredArity-1) — the same ids papMembers' producer injection and
regIdentity's registration stamp mint, so the three paths unify. Targets the
/a0/r argument-spine var population (58 % of all var, census 2026-08-28).
Artifact-affecting. DEFAULT-ON since 2026-08-28 (+3.25 pp coverage,
dispatch exactly neutral). Hash token `lssRP=`.
-}
applyLssRefPapSpineOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssRefPapSpineOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | refPapSpine = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | refPapSpine = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_INJ_TOTAL=1|true|yes / 0|false|no`
(plans/lss-coverage-four-levers.md): the three injection-totality completion
levers — completion-join head re-stamp, deep-PAP successor completion, and the
Accessor/bare-VarKernel argument arms. Artifact-affecting. DEFAULT-ON since
2026-08-29 (+4.97 pp coverage, dispatch exactly neutral). Hash token `lssIT=`.
-}
applyLssInjTotalOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssInjTotalOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | injTotal = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | injTotal = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_DESTR_ANNO=1|true|yes / 0|false|no`
(plans/lss-ctor-arrow-identity.md §9.5): destructor-bound types take the
projection's annotations (Fix A) and ctor registry entries recover from the
sibling-spec demand union at settle (Fix B). DEFAULT-ON since 2026-08-31
(top −32 %, Eerr/Cerr healed, all gates green). Hash token `lssDA=`.
-}
applyLssDestrAnnoOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssDestrAnnoOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | destrAnno = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | destrAnno = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_VAR_SUCC=1|true|yes / 0|false|no`
(plans/lss-var-chain-roots.md §3 Phase 1): post-drain PAP-successor writes
into flex result slots, within declared arity. DEFAULT-ON since 2026-08-31.
Hash token `lssVS=`. Lives in the `settle` sub-record since 2026-09-02
(the 32-slot bundling — plans/lss-stage-anchor-writers.md §3L ORDER 0).
-}
applyLssVarSuccOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssVarSuccOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLssSettle (\st -> { st | varSucc = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLssSettle (\st -> { st | varSucc = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_VAR_CTOR_ROWS=1|true|yes / 0|false|no`
(plans/lss-var-chain-roots.md §3 Phase 2b): ctor-row var payload writes from
the sibling-spec cell union under the all-sets completeness rule.
DEFAULT-ON since 2026-08-31. Hash token `lssVC=`. In the `settle`
sub-record since 2026-09-02.
-}
applyLssVarCtorRowsOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssVarCtorRowsOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLssSettle (\st -> { st | varCtorRows = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLssSettle (\st -> { st | varCtorRows = False }) cfg

            else
                cfg

        Nothing ->
            cfg


setFlowConnect : Bool -> Config.LssFlowConfig -> Config.LssFlowConfig
setFlowConnect v c =
    { c | connect = v }


setFlowLetOverlay : Bool -> Config.LssFlowConfig -> Config.LssFlowConfig
setFlowLetOverlay v c =
    { c | letOverlay = v }


setFlowRowDefer : Bool -> Config.LssFlowConfig -> Config.LssFlowConfig
setFlowRowDefer v c =
    { c | rowDefer = v }


{-| `ECO_MONO_LSS_FLOW_ROW_DEFER=1|true|yes / 0|false|no`: F3-a row-deferred
destructure sets (plans/lss-container-payload-transport.md §12.9.5).
Artifact-affecting; hash token `lssFRD=`.
-}
applyLssFlowRowDeferOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssFlowRowDeferOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | flow = setFlowRowDefer True lss.flow }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | flow = setFlowRowDefer False lss.flow }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_FLOW_LET_OVERLAY=1|true|yes / 0|false|no`: F3-b let/tail-def
binding overlay (plans/lss-container-payload-transport.md §12.9.5).
Artifact-affecting; hash token `lssFLO=`.
-}
applyLssFlowLetOverlayOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssFlowLetOverlayOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | flow = setFlowLetOverlay True lss.flow }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | flow = setFlowLetOverlay False lss.flow }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_FLOW_CONNECT=1|true|yes / 0|false|no`
(plans/lss-var-chain-roots.md §9.5 M1): deep write-back of translated
lambda-literal argument types into the callee's param store variable.
DEFAULT-OFF. Hash token `lssFC=`.
-}
applyLssFlowConnectOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssFlowConnectOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | flow = setFlowConnect True lss.flow }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | flow = setFlowConnect False lss.flow }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_VAR_LAMBDA=1|true|yes / 0|false|no`
(plans/lss-var-chain-roots.md §8.2 Phase 4v2): enrich `l|`-headed var
positions from the lambda-home table. DEFAULT-ON since 2026-09-01. Hash
token `lssVL=`. In the `settle` sub-record since 2026-09-02.
-}
applyLssVarLambdaOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssVarLambdaOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLssSettle (\st -> { st | varLambda = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLssSettle (\st -> { st | varLambda = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL=1|true|yes / 0|false|no`
(plans/lss-stage-anchor-writers.md §3 W2): post-drain settle fill of var
interior cells under `l|`-singleton heads, bounded by r = T − s over the
birth-time qSpine fact. DEFAULT-OFF. Hash token `lssSAr=`.
-}
applyLssStageAnchorRowFillOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssStageAnchorRowFillOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLssStageAnchor (\sa -> { sa | rowFill = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLssStageAnchor (\sa -> { sa | rowFill = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_STAGE_ANCHOR_DEMAND_FILL=1|true|yes / 0|false|no`
(plans/lss-stage-anchor-writers.md §3 W1): the same fill applied to every
demand pre-registry and at the completion join (the stampSelfSpine
architecture; keyed-routed globals decline). DEFAULT-OFF. Hash token
`lssSAd=`.
-}
applyLssStageAnchorDemandFillOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssStageAnchorDemandFillOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLssStageAnchor (\sa -> { sa | demandFill = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLssStageAnchor (\sa -> { sa | demandFill = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_RS_TOP=1|true|yes / 0|false|no` (P1,
plans/lss-provenance-join-and-demand-sigs.md §4.3): restatement-⊤ recovery at
the completion join for licensed kernel-alias nodes. DEFAULT-ON since
2026-08-29 (+1.12 pp coverage, dispatch-safe class). Hash token `lssRT=`.
-}
applyLssRsTopOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssRsTopOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | rsTop = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | rsTop = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_ARG_POINTS=1|true|yes / 0|false|no` (M2,
plans/lss-coverage-four-levers.md §7.2-REVISED): arg-point transport +
ctor-call shape unify. DEFAULT-OFF (micro-gate failed; under diagnosis).
Hash token `lssAP=`.
-}
applyLssArgPointsOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssArgPointsOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | argPoints = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | argPoints = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_QSOLVE=1|true|yes / 0|false|no` (§5.2/§5.3,
plans/lss-paper-inclusion-constraints.md): consume the signature as the paper's
scheme `d⟨ᾱ⟩ : (Q ⇒ τ)` — instantiate `ᾱ` per use and re-emit `Q` against it,
and internalize the def's non-reaching set variables to `S(Q,α)` — instead of
copying a pre-solved member set out of the signature. DEFAULT-OFF. Hash token
`lssQS=`.
-}
applyLssQSolveOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssQSolveOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | qSolve = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | qSolve = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_ARROW_ROOTS=1|true|yes / 0|false|no` (Phase 2b solver-root
arrow ids, plans/lss-unknown-elimination.md §4.9): take each arrow's identity
from its union-find ROOT, so two arrows the type checker unified share a
lambda-set slot. Requires arrow identity to have any effect — it changes WHICH
id an arrow gets, not whether slots are memoised at all — and that is now the
default, so this flag alone is enough to select 2b. DEFAULT-OFF. Hash token
`lssAR=`.
-}
applyLssArrowRootsOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssArrowRootsOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | arrowSolverRoots = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | arrowSolverRoots = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_ARROW_ID=1|true|yes / 0|false|no` (Phase 2a arrow identity,
plans/lss-unknown-elimination.md §4): memoise one lambda-set SLOT per
`Can.TLambda` occurrence id per item, so repeated loads of the same stamped
type object share their sets. DEFAULT-ON since 2026-08-25
(plans/lss-paper-inclusion-constraints.md §5.A3), so the override is
bidirectional and `0|false|no` is the escape hatch — which still reproduces the
pre-2a bytes, since flag-off gates the memo rather than the id minting.
Participates in the hash via the `lssAI=` token when non-default.
-}
applyLssArrowIdOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssArrowIdOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | arrowIdentity = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | arrowIdentity = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| `ECO_MONO_LSS_DEVIRT_POST=1|true|yes / 0|false|no` (E9.5 / LSS\_025,
plans/lss-post-settle-fn-global-devirt.md): post-settle devirt of singleton
g|/c| noInstance sites at AbiCloning. DEFAULT-ON since 2026-08-22, so the
override is bidirectional and `0|false|no` is the escape hatch. Participates
in the hash via the `lssDP=` token when non-default.
-}
applyLssDevirtPostOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssDevirtPostOverride maybeVal cfg =
    case Maybe.map (String.toLower << String.trim) maybeVal of
        Just v ->
            if List.member v [ "1", "true", "yes" ] then
                updateLss (\lss -> { lss | postSettleDevirt = True }) cfg

            else if List.member v [ "0", "false", "no" ] then
                updateLss (\lss -> { lss | postSettleDevirt = False }) cfg

            else
                cfg

        Nothing ->
            cfg


{-| Clamp out-of-range values and print any resulting warnings to stderr.
-}
finishWithWarnings : EcoConfig -> Task Exit.Make EcoConfig
finishWithWarnings cfg =
    let
        ( clamped, warnings ) =
            Config.clamp cfg
    in
    List.foldl
        (\msg acc -> acc |> Task.andThen (\_ -> Task.io (IO.writeLn IO.stderr msg)))
        (Task.succeed ())
        warnings
        |> Task.map (\_ -> clamped)
