module Builder.Eco.Config exposing (load)

{-| Read the project's `eco-config.json` (tunable compiler settings) from disk.

The pure data, decoder, and defaults live in `Compiler.Eco.Config`; this module
only adds the IO: locate the file, read it, decode it, clamp out-of-range
values (emitting warnings), and surface errors as `Exit.Make`.

@docs load

-}

import Builder.Reporting.Exit as Exit
import Compiler.Eco.Config as Config exposing (EcoConfig)
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
  - `ECO_INLINE_HOF_THRESHOLD=<n>` overrides `inline.hofThreshold` (the H2
    called-function-param inlining budget); experiment/tuning knob.
  - `ECO_INLINE_FPI=<n>` overrides `inline.fixpointIterations`;
    experiment/tuning knob (deep chains need extra passes to cascade).
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


{-| `ECO_MONO_VALIDATE=1`: run the MONO_029 layout-agreement validator
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
(the keyed-mode spec budget, design §8.5). Test/tuning knob — a tiny value
forces the budget-exhausted widened-key + LSS_010-join fallback so the
mixed-mode path can be exercised deliberately. Non-numeric values are
ignored. Participates in the config hash via the `lssB=` token, so
eco-stuff artifacts never alias across budgets.
-}
applyLssBudgetOverride : Maybe String -> EcoConfig -> EcoConfig
applyLssBudgetOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            updateLss (\lss -> { lss | maxSpecsPerGlobal = n }) cfg

        Nothing ->
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


{-| `ECO_INLINE_FPI=<n>`: override `inline.fixpointIterations`. Participates
in the config hash via the `fpi=` token. Non-numeric values are ignored.
-}
applyFpiOverride : Maybe String -> EcoConfig -> EcoConfig
applyFpiOverride maybeVal cfg =
    case Maybe.andThen (String.trim >> String.toInt) maybeVal of
        Just n ->
            let
                inline =
                    cfg.inline
            in
            { cfg | inline = { inline | fixpointIterations = n } }

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
