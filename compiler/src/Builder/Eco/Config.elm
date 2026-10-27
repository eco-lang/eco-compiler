module Builder.Eco.Config exposing (load)

{-| The compiler's tuning settings can be set per project, in a file, and per
run, in the environment, and this module gathers both into one `EcoConfig`.
`Compiler.Eco.Config` owns that type: what each setting means, its default, and
which settings put a token in the `Config.hash` cache key.

The settings come from two places, applied in this order. The first is a JSON
file, `eco-config.json` in the project root or a file named explicitly. Values
read from the file go through `Config.clamp`, which brings out-of-range values
back within bounds, and a warning is printed for each value it changed. The
second is a set of `ECO_*` environment variables, each overriding one setting,
or a few related ones, of whatever the file gave. Because they are applied
here, an override is part of the returned configuration; `Config.hash` decides
which of its settings reach the cache key. They are not passed through
`Config.clamp`; the few that guard their own values say so.

Most of the module is the overrides: one small function per variable. A
function returns the configuration unchanged when its variable is unset, and
nearly all of them also when the value is not one they recognize; the
exceptions say so. Words are matched after trimming whitespace and ignoring
case, and numbers after trimming. The accepted words are not uniform, so each
function's docstring lists its own. Where a setting has both a broadcast
variable that sets several fields and per-field variables, the broadcast is
read first, so a per-field value wins.

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


{-| Returns the configuration for a project rooted at `root`: the settings read from
a configuration file, with the `ECO_*` environment overrides applied on top.

The file is `maybeExplicit` when given, and `root/eco-config.json` otherwise. If
the default file does not exist, the built-in `Config.default` is used without
comment, but a missing explicit file fails with `Exit.MakeConfigNotFound`. A
file that cannot be read fails with `Exit.MakeFileIO`, and one that cannot be
decoded with `Exit.MakeBadConfig`. A decoded file has its out-of-range values
clamped, with a warning on stderr for each. An unrecognized `ECO_MONO_ENGINE`
prints a warning on stderr and leaves the engine as it was; no other override
prints anything.

-}
load : Maybe FilePath -> FilePath -> Task Exit.Make EcoConfig
load maybeExplicit root =
    loadBase maybeExplicit root
        |> Task.andThen applyEnvOverrides


{-| Returns the configuration read from the file `load` describes, or
`Config.default` when the default file does not exist, before any environment
override.
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


{-| Returns `cfg` with every `ECO_*` environment override applied, one variable
after another in a fixed order. Each variable's own function says what it
accepts and sets.
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
            (\cfgS ->
                (Utils.envLookupEnv "ECO_STAGING_REPORT" |> Task.mapError never)
                    |> Task.map (\v -> applyStagingReportOverride v cfgS)
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
            (\cfg4e4c ->
                (Utils.envLookupEnv "ECO_MONO_LSS_INSTANCE_QUAL_MAX" |> Task.mapError never)
                    |> Task.map (\iqmVal -> applyLssInstanceQualMaxOverride iqmVal cfg4e4c)
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
            (\cfg4ef ->
                (Utils.envLookupEnv "ECO_MONO_LSS_ARROW_CENSUS" |> Task.mapError never)
                    |> Task.map (\acVal -> applyLssArrowCensusOverride acVal cfg4ef)
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
            (\cfg33b ->
                (Utils.envLookupEnv "ECO_CONST_THUNKS" |> Task.mapError never)
                    |> Task.map (\ctVal -> applyConstThunksOverride ctVal cfg33b)
            )
        |> Task.andThen
            (\cfg33c ->
                (Utils.envLookupEnv "ECO_CONST_THUNK_REPORT" |> Task.mapError never)
                    |> Task.map (\crVal -> applyConstThunksReportOverride crVal cfg33c)
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
        |> Task.andThen
            (\cfgGcPreLink ->
                (Utils.envLookupEnv "ECO_GC_PRE_LINK" |> Task.mapError never)
                    |> Task.map (\v -> applyGcBoolOverride (\b g -> { g | preLink = b }) v cfgGcPreLink)
            )
        |> Task.andThen
            (\cfgGcReport ->
                (Utils.envLookupEnv "ECO_GC_REPORT" |> Task.mapError never)
                    |> Task.map (\v -> applyGcBoolOverride (\b g -> { g | report = b }) v cfgGcReport)
            )


{-| Returns `cfg` with `aggPromote` switched on when `ECO_AGG_PROMOTE` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `inline.kernelCostClasses` switched on when
`ECO_KERNEL_COST_CLASSES` is `1`, `true`, `yes` or `on`, and off when it is `0`
or `off`.
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


{-| Returns `cfg` with one of the inliner's kernel-call costs, chosen by `set`, set
to the integer value of the variable. A value that is not an integer, or is
negative, is ignored.
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


{-| Returns `cfg` with `inline.kernelCostInline` set from `ECO_KERNEL_COST_INLINE`,
a non-negative integer.
-}
applyKernelCostInlineOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostInlineOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostInline = n })


{-| Returns `cfg` with `inline.kernelCostGcLeaf` set from `ECO_KERNEL_COST_GCLEAF`,
a non-negative integer.
-}
applyKernelCostGcLeafOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostGcLeafOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostGcLeaf = n })


{-| Returns `cfg` with `inline.kernelCostAlloc` set from `ECO_KERNEL_COST_ALLOC`, a
non-negative integer.
-}
applyKernelCostAllocOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostAllocOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostAlloc = n })


{-| Returns `cfg` with `inline.kernelCostHof` set from `ECO_KERNEL_COST_HOF`,
a non-negative integer.
-}
applyKernelCostHofOverride : Maybe String -> EcoConfig -> EcoConfig
applyKernelCostHofOverride =
    applyKernelCostIntOverride (\n i -> { i | kernelCostHof = n })


{-| Returns `cfg` with `callPurityAttrs` switched on when `ECO_CALL_PURITY` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with the `gc` setting chosen by `set` switched on when the
variable is `1`, `true`, `yes` or `on`, and off when it is `0`, `false`, `no` or
`off`. `ECO_GC_PRE_LINK` and `ECO_GC_REPORT` are read through it.
-}
applyGcBoolOverride : (Bool -> Config.GcConfig -> Config.GcConfig) -> Maybe String -> EcoConfig -> EcoConfig
applyGcBoolOverride set maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "1" || t == "true" || t == "yes" || t == "on" then
                { cfg | gc = set True cfg.gc }

            else if t == "0" || t == "false" || t == "no" || t == "off" then
                { cfg | gc = set False cfg.gc }

            else
                cfg


{-| Returns `cfg` with `cse.enabled` set from `ECO_CSE`, which accepts what
`applyCseBoolOverride` describes.
-}
applyCseEnabledOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseEnabledOverride =
    applyCseBoolOverride (\b c -> { c | enabled = b })


{-| Returns `cfg` with `cse.report` set from `ECO_CSE_REPORT`, which accepts what
`applyCseBoolOverride` describes.
-}
applyCseReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseReportOverride =
    applyCseBoolOverride (\b c -> { c | report = b })


{-| Returns `cfg` with the `cse` setting chosen by `set` switched on when the
variable is `1`, `true`, `yes` or `on`, and off when it is `0`, `false`, `no` or
`off`.
-}
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


{-| Returns `cfg` with the `cse` limit chosen by `set` set to the integer value of
the variable. A value that is not an integer, or is negative, is ignored.
-}
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


{-| Returns `cfg` with `cse.minCost` set from `ECO_CSE_MIN_COST`, a non-negative
integer.
-}
applyCseMinCostOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseMinCostOverride =
    applyCseIntOverride (\n c -> { c | minCost = n })


{-| Returns `cfg` with `cse.maxPerDef` set from `ECO_CSE_MAX_PER_DEF`,
a non-negative integer.
-}
applyCseMaxPerDefOverride : Maybe String -> EcoConfig -> EcoConfig
applyCseMaxPerDefOverride =
    applyCseIntOverride (\n c -> { c | maxPerDef = n })


{-| Returns `cfg` with `inline.kernelFactsDce` switched on when
`ECO_KERNEL_FACTS_DCE` is `1`, `true`, `yes` or `on`, and off when it is `0` or
`off`.
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


{-| Returns `cfg` with `kernelGcLeaf` switched on when `ECO_KERNEL_GCLEAF_EMIT` is
`1`, `true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with the `constThunks` level set from `ECO_CONST_THUNKS`: `0` or
`off` gives 0, `1` gives 1, and `2`, `on`, `true` or `yes` gives 2.
-}
applyConstThunksOverride : Maybe String -> EcoConfig -> EcoConfig
applyConstThunksOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            if t == "0" || t == "off" then
                { cfg | constThunks = 0 }

            else if t == "1" then
                { cfg | constThunks = 1 }

            else if t == "2" || t == "on" || t == "true" || t == "yes" then
                { cfg | constThunks = 2 }

            else
                cfg


{-| Returns `cfg` with `constThunksReport` set from `ECO_CONST_THUNK_REPORT`. Unlike
the other report variables, any value that is set decides it: `1`, `true`, `yes`
or `on` switches it on, and anything else switches it off.
-}
applyConstThunksReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyConstThunksReportOverride maybeVal cfg =
    case maybeVal of
        Nothing ->
            cfg

        Just raw ->
            let
                t =
                    String.toLower (String.trim raw)
            in
            { cfg | constThunksReport = t == "1" || t == "true" || t == "yes" || t == "on" }


{-| Returns `cfg` with `valueEq` switched on when `ECO_VALUE_EQ` is `1`, `true`,
`yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `stringOrderIntrinsic` switched on when
`ECO_STRING_ORDER_INTRINSIC` is `1`, `true`, `yes` or `on`, and off when it is
`0` or `off`.
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


{-| Returns `cfg` with `appendSplit` switched on when `ECO_APPEND_SPLIT` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `stringLengthOp` switched on when `ECO_STRING_LENGTH_OP` is
`1`, `true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `ctorInline` switched on when `ECO_CTOR_INLINE` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `sretResults` switched on when `ECO_SRET_RESULTS` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `sretFresh` switched on when `ECO_SRET_FRESH` is `1`, `true`,
`yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `sretTailFuncs` switched on when `ECO_SRET_TAILFUNC` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `psplitParams` switched on when `ECO_PSPLIT_PARAMS` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with borrow inference set from `ECO_BORROW`. `1`, `true`, `yes` or
`on` enables it with `reify` set to `ROff`, and `rc` enables it with `reify` set
to `RRc`. `0` or `off` disables it and leaves `reify` as it was.
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


{-| Returns `cfg` with `borrow.report` switched on when `ECO_BORROW_REPORT` is `1`,
`true` or `yes`. It also switches on `borrow.enabled`, and since it is read
after `ECO_BORROW`, it does so even when `ECO_BORROW` disabled the analysis. No
value turns either off.
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


{-| Returns `cfg` with `list.chunks` switched on when `ECO_LIST_CHUNKS` is `1`,
`true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `list.consIntrinsic` switched on when
`ECO_LIST_CONS_INTRINSIC` is `1`, `true`, `yes` or `on`, and off when it is `0`
or `off`.
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


{-| Returns `cfg` with `list.mapTemplate` switched on when `ECO_LIST_MAP_TEMPLATE`
is `1`, `true`, `yes` or `on`, and off when it is `0` or `off`.
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


{-| Returns `cfg` with `list.report` switched on when `ECO_LIST_REPORT` is `1`,
`true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with the monomorphizer engine that `ECO_MONO_ENGINE` names, as
`Config.monoEngineFromString` reads it. A blank value is ignored, and any other
value it does not recognize prints a warning on stderr and keeps the engine.
-}
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


{-| Returns `cfg` with `mono.diffDump` switched on when `ECO_MONO_DIFF_DUMP` is `1`,
`true` or `yes`. No value turns it off.
-}
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


{-| Returns `cfg` with `mono.validate` switched on when `ECO_MONO_VALIDATE` is `1`,
`true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with lambda-set specialization switched off when `ECO_MONO_LSS` is
`0`, and on when it is `1`, `keyed` or `unkeyed`. The last two mean the same as
`1`.
-}
applyLssOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssOverride maybeVal cfg =
    case Maybe.map (String.trim >> String.toLower) maybeVal of
        Just "0" ->
            updateLss (\lss -> { lss | enabled = False }) cfg

        Just "1" ->
            updateLss (\lss -> { lss | enabled = True }) cfg

        Just "keyed" ->
            updateLss (\lss -> { lss | enabled = True }) cfg

        Just "unkeyed" ->
            updateLss (\lss -> { lss | enabled = True }) cfg

        _ ->
            cfg


{-| Returns `cfg` with `mono.lss.maxSpecsPerGlobal` set from
`ECO_MONO_LSS_MAX_SPECS`. Any integer is taken, including zero or a negative
number, which mean no limit.
-}
applyLssBudgetOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssBudgetOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLss (\lss -> { lss | maxSpecsPerGlobal = n }) cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `mono.lss.maxSetSize` set from `ECO_MONO_LSS_MAX_SET_SIZE`.
Any integer is taken, including zero or a negative number, which mean no limit.
-}
applyLssMaxSetSizeOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssMaxSetSizeOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLss (\lss -> { lss | maxSetSize = n }) cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `cafMemo.enabled` switched on when `ECO_CAF_MEMO` is `1`,
`true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `cafMemo.census` switched on when `ECO_CAF_CENSUS` is `1`,
`true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with `cafMemo.dedupe` switched on when `ECO_CAF_DEDUPE` is `1`,
`true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `cafMemo.hoist.enabled` switched on when `ECO_CAF_HOIST` is
`1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `cafMemo.hoist.minNodes` set from `ECO_CAF_HOIST_MIN_NODES`.
Any integer is taken, including a negative one.
-}
applyCafHoistMinNodesOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafHoistMinNodesOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateCafHoist (\h -> { h | minNodes = n }) cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `cafMemo.hoist.maxHoists` set from `ECO_CAF_HOIST_MAX`. Any
integer is taken, including a negative one.
-}
applyCafHoistMaxOverride : Maybe String -> EcoConfig -> EcoConfig
applyCafHoistMaxOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateCafHoist (\h -> { h | maxHoists = n }) cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `f` applied to its CAF hoisting settings.
-}
updateCafHoist : (Config.CafHoistConfig -> Config.CafHoistConfig) -> EcoConfig -> EcoConfig
updateCafHoist f cfg =
    let
        cafMemo =
            cfg.cafMemo
    in
    { cfg | cafMemo = { cafMemo | hoist = f cafMemo.hoist } }


{-| Returns `cfg` with `mono.stagingReport` switched on when `ECO_STAGING_REPORT` is
`1`, `true` or `yes`. No value turns it off.
-}
applyStagingReportOverride : Maybe String -> EcoConfig -> EcoConfig
applyStagingReportOverride maybeVal cfg =
    case Maybe.map (String.trim >> String.toLower) maybeVal of
        Just t ->
            if t == "1" || t == "true" || t == "yes" then
                let
                    mono =
                        cfg.mono
                in
                { cfg | mono = { mono | stagingReport = True } }

            else
                cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `mono.lss.report` switched on when `ECO_MONO_LSS_REPORT` is
`1`, `true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with `inline.hofThreshold` set from `ECO_INLINE_HOF_THRESHOLD`.
Any integer is taken, including a negative one.
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


{-| Returns `cfg` with `inline.loopify` switched off when `ECO_INLINE_LOOPIFY` is
`0`, `false` or `no`. No value turns it on.
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


{-| Returns `cfg` with `inline.arityRaise` switched on when `ECO_ARITY_RAISE` is
`1`, `true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with `inline.raiseAppliedShareMin` set from
`ECO_ARITY_RAISE_MIN_APPLIED`, an integer brought within 0 to 100 without a
warning.
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


{-| Returns `cfg` with `inline.preserveSets` switched on when
`ECO_INLINE_PRESERVE_SETS` is `1`, `true` or `yes`, and off when it is `0`,
`false` or `no`.
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


{-| Returns `cfg` with `inline.pruneDead` switched on when `ECO_INLINE_PRUNE_DEAD`
is `1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `inline.partialHof` switched on when `ECO_INLINE_PARTIAL_HOF`
is `1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with all three size budgets, `inline.preMonoThreshold`,
`inline.postMonoThreshold` and `inline.etaThreshold`, set from
`ECO_INLINE_THRESHOLD`. A negative integer is taken as 0. The per-budget
variables are read after this one, so each overrides it for its own budget.
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


{-| Returns `cfg` with `inline.preMono` switched on when `ECO_INLINE_PRE_MONO` is
`1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `inline.etaOnly` set from `ECO_INLINE_ETA_ONLY`,
a comma-separated list of module-name prefixes, trimmed, with empty entries
dropped. Whenever the variable is set, its list replaces the file's, so an empty value
clears the restriction.
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


{-| Returns `cfg` with `inline.preMonoThreshold` set from
`ECO_INLINE_PRE_MONO_THRESHOLD`. A negative integer is taken as 0.
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


{-| Returns `cfg` with `inline.postMonoThreshold` set from
`ECO_INLINE_POST_MONO_THRESHOLD`. A negative integer is taken as 0.
-}
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


{-| Returns `cfg` with `inline.etaThreshold` set from `ECO_ETA_THRESHOLD`. A
negative integer is taken as 0.
-}
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


{-| Returns `cfg` with `inline.preMonoFixpointIterations` set from
`ECO_INLINE_PRE_MONO_FPI`. Any integer is taken, including a negative one.
-}
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


{-| Returns `cfg` with `inline.postMonoFixpointIterations` set from
`ECO_INLINE_POST_MONO_FPI`. Any integer is taken, including a negative one.
-}
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


{-| Returns `cfg` with `inline.aliasForward` switched on when
`ECO_INLINE_ALIAS_FORWARD` is `1`, `true` or `yes`, and off when it is `0`,
`false` or `no`.
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


{-| Returns `cfg` with `inline.etaExpand` switched on when `ECO_INLINE_ETA_EXPAND`
is `1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `inline.postMono` switched on when `ECO_INLINE_POST_MONO` is
`1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with both inliners' round counts,
`inline.preMonoFixpointIterations` and `inline.postMonoFixpointIterations`, set
from `ECO_INLINE_FPI`. Any integer is taken, including a negative one.
The per-pass variables are read after this one, so each overrides it for its
own pass.
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


{-| Returns `cfg` with `inline.report` switched on when `ECO_INLINE_REPORT` is `1`,
`true` or `yes`. No value turns it off.
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


{-| Returns `cfg` with `f` applied to its lambda-set specialization settings.
-}
updateLss : (Config.LssConfig -> Config.LssConfig) -> EcoConfig -> EcoConfig
updateLss f cfg =
    let
        mono =
            cfg.mono
    in
    { cfg | mono = { mono | lss = f mono.lss } }


{-| Returns `cfg` with `f` applied to its monomorphization watchdog limits.
-}
updateLimits : (Config.SpecLimits -> Config.SpecLimits) -> EcoConfig -> EcoConfig
updateLimits f cfg =
    let
        mono =
            cfg.mono
    in
    { cfg | mono = { mono | limits = f mono.limits } }


{-| Returns `cfg` with `mono.limits.specTypeNodes` set from
`ECO_SPEC_TYPE_NODE_LIMIT`. Any integer is taken; zero or less means no limit.
-}
applySpecTypeNodeLimitOverride : Maybe String -> EcoConfig -> EcoConfig
applySpecTypeNodeLimitOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLimits (\l -> { l | specTypeNodes = n }) cfg

        Nothing ->
            cfg


{-| Returns `cfg` with `mono.limits.specBreadth` set from `ECO_SPEC_BREADTH_LIMIT`.
Any integer is taken; zero or less means no limit.
-}
applySpecBreadthLimitOverride : Maybe String -> EcoConfig -> EcoConfig
applySpecBreadthLimitOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLimits (\l -> { l | specBreadth = n }) cfg

        Nothing ->
            cfg


{-| Returns `c` with its instance-qualification cap set to `n`.
-}
setStampMax : Int -> Config.LssStampConfig -> Config.LssStampConfig
setStampMax n c =
    { c | maxInstances = n }


{-| Returns `c` with its census switch set to `v`. Being a record update, it keeps
compiling if `LssStampConfig` gains fields.
-}
setStampCensus : Bool -> Config.LssStampConfig -> Config.LssStampConfig
setStampCensus v c =
    { c | census = v }


{-| Returns `cfg` with `mono.lss.stamp.maxInstances` set from
`ECO_MONO_LSS_INSTANCE_QUAL_MAX`. A negative integer is ignored; zero means no
cap.
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


{-| Returns `cfg` with `mono.lss.qCensus` switched on when `ECO_MONO_LSS_QCENSUS` is
`1`, `true` or `yes`, and off when it is `0`, `false` or `no`.
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


{-| Returns `cfg` with `mono.lss.stamp.census` switched on when
`ECO_MONO_LSS_CENSUS` is `1`, `true` or `yes`, and off when it is `0`, `false`
or `no`.
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


{-| Returns `cfg` with `mono.lss.arrowCensus` switched on when
`ECO_MONO_LSS_ARROW_CENSUS` is `1`, `true` or `yes`, and off when it is `0`,
`false` or `no`.
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


{-| Returns `cfg` after `Config.clamp`, printing each of its warnings on stderr.
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
