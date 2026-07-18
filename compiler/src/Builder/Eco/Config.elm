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


{-| `ECO_MONO_LSS=0|1|keyed`: toggle lambda-set specialization. Unknown values
are ignored (dev-only knob; silence beats failure here since `0` must always
be a safe escape hatch).
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
