module Builder.Eco.FEStats exposing
    ( Handle
    , PhaseName(..), ModuleStage(..)
    , init, finalize, disabled
    , withPhase, withModuleStage
    , prettyPrint
    )

{-| Front-end timing stats: phase wall-clocks, per-module crawl/check/build
histograms, and the slowest-N modules per stage.

Gated by a runtime flag (`eco make --stats`). When disabled, every entry point
in this module is a no-op so the unobserved path costs nothing.

The handle is a `Maybe (MVar State)`: per-module workers run inside forked
threads (`Build.dictForkWithKey`), so updates take/put through an MVar for
thread safety. Phase-level updates run single-threaded.

@docs Handle
@docs PhaseName, ModuleStage
@docs init, finalize, disabled
@docs withPhase, withModuleStage
@docs prettyPrint

-}

import Array exposing (Array)
import Bytes.Decode
import Bytes.Encode
import Dict exposing (Dict)
import System.IO as IO exposing (MVar)
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== PUBLIC TYPES ======


{-| Stats handle. `Disabled` means the `--stats` flag was off; every public
operation short-circuits without touching the MVar.
-}
type Handle
    = Disabled
    | Enabled (MVar State)


{-| A handle in the off position. All operations are no-ops.
-}
disabled : Handle
disabled =
    Disabled


{-| The six front-end phases timed individually.
-}
type PhaseName
    = PhaseDeps
    | PhaseLocal
    | PhaseMono
    | PhaseInlineSimplify
    | PhaseGlobalOpt
    | PhaseMlir


{-| The three per-module stages inside the local-build phase.
-}
type ModuleStage
    = Crawl
    | Check
    | Build



-- ====== INTERNAL STATE ======


type alias State =
    { startMs : Int
    , endMs : Int
    , phases : Dict Int PhaseStats
    , modules : Dict Int Histogram
    }


type alias PhaseStats =
    { startMs : Int
    , endMs : Int
    }


type alias Histogram =
    { buckets : Array Int
    , count : Int
    , sumMs : Int
    , minMs : Int
    , maxMs : Int
    , topSlow : List ( String, Int )
    }


emptyHistogram : Histogram
emptyHistogram =
    { buckets = Array.repeat numBuckets 0
    , count = 0
    , sumMs = 0
    , minMs = 0
    , maxMs = 0
    , topSlow = []
    }


numBuckets : Int
numBuckets =
    13


{-| Upper edges in ms for the 12 bounded buckets. Bucket 12 is the overflow
catch-all for samples above `bucketUpperEdge 11` (= 20480 ms).

Boundaries are 10·2^k ms for k = 0..11: 10, 20, 40, 80, 160, 320, 640, 1280,
2560, 5120, 10240, 20480.

-}
bucketUpperEdge : Int -> Int
bucketUpperEdge idx =
    -- 10 ms times 2^idx
    10 * (2 ^ idx)


{-| Map a millisecond sample to its bucket index in `[0, numBuckets - 1]`.
Anything ≤ 10 ms lands in bucket 0; anything > 20480 ms lands in bucket 12.
-}
bucketOf : Int -> Int
bucketOf ms =
    bucketOfHelp ms 0


bucketOfHelp : Int -> Int -> Int
bucketOfHelp ms idx =
    if idx >= numBuckets - 1 then
        numBuckets - 1

    else if ms <= bucketUpperEdge idx then
        idx

    else
        bucketOfHelp ms (idx + 1)


topSlowCap : Int
topSlowCap =
    5



-- ====== INIT / FINALIZE ======


{-| Create a stats handle. When `enabled` is `False`, returns `Disabled` and
later operations are no-ops. When `True`, allocates an MVar with an empty
State stamped with the current wall-clock millis.
-}
init : Bool -> Task Never Handle
init enabled =
    if enabled then
        Time.now
            |> Task.andThen
                (\now ->
                    let
                        startMs =
                            Time.posixToMillis now

                        state =
                            { startMs = startMs
                            , endMs = startMs
                            , phases = Dict.empty
                            , modules = Dict.empty
                            }
                    in
                    Utils.newMVar stateEncoder state
                        |> Task.map Enabled
                )

    else
        Task.succeed Disabled


{-| Stamp the end-of-run wall clock onto the stats. No-op when disabled.
-}
finalize : Handle -> Task Never ()
finalize handle =
    case handle of
        Disabled ->
            Task.succeed ()

        Enabled mvar ->
            Time.now
                |> Task.andThen
                    (\now ->
                        modifyState mvar
                            (\state ->
                                { state | endMs = Time.posixToMillis now }
                            )
                    )



-- ====== PHASE WRAPPER ======


{-| Time a phase: emit `Starting <phase>...` to stderr (when enabled), run the
task, and record its wall-clock duration. When disabled, just runs the task.
-}
withPhase : Handle -> PhaseName -> Task x a -> Task x a
withPhase handle phase task =
    case handle of
        Disabled ->
            task

        Enabled mvar ->
            Task.io (IO.writeLn IO.stderr ("Starting " ++ phaseLabel phase ++ "..."))
                |> Task.andThen (\_ -> Task.io Time.now)
                |> Task.andThen
                    (\beforePosix ->
                        task
                            |> Task.andThen
                                (\result ->
                                    Task.io Time.now
                                        |> Task.andThen
                                            (\afterPosix ->
                                                Task.io
                                                    (modifyState mvar
                                                        (recordPhase phase
                                                            (Time.posixToMillis beforePosix)
                                                            (Time.posixToMillis afterPosix)
                                                        )
                                                    )
                                                    |> Task.map (\_ -> result)
                                            )
                                )
                    )


recordPhase : PhaseName -> Int -> Int -> State -> State
recordPhase phase startMs endMs state =
    { state
        | phases =
            Dict.insert (phaseOrd phase)
                { startMs = startMs, endMs = endMs }
                state.phases
    }



-- ====== PER-MODULE RECORDING ======


{-| Time a per-module stage. No-op when disabled (the task is invoked directly
with no timestamp overhead).
-}
withModuleStage : Handle -> ModuleStage -> String -> Task x a -> Task x a
withModuleStage handle stage name task =
    case handle of
        Disabled ->
            task

        Enabled _ ->
            Task.io Time.now
                |> Task.andThen
                    (\startPosix ->
                        task
                            |> Task.andThen
                                (\result ->
                                    Task.io Time.now
                                        |> Task.andThen
                                            (\endPosix ->
                                                Task.io (recordModule handle stage name startPosix endPosix)
                                                    |> Task.map (\_ -> result)
                                            )
                                )
                    )


{-| Record a single (start, end) measurement for a module stage. No-op when
disabled.
-}
recordModule : Handle -> ModuleStage -> String -> Time.Posix -> Time.Posix -> Task Never ()
recordModule handle stage name startPosix endPosix =
    case handle of
        Disabled ->
            Task.succeed ()

        Enabled mvar ->
            let
                dtMs =
                    max 0 (Time.posixToMillis endPosix - Time.posixToMillis startPosix)
            in
            modifyState mvar (addModuleSample stage name dtMs)


addModuleSample : ModuleStage -> String -> Int -> State -> State
addModuleSample stage name dtMs state =
    let
        key =
            stageOrd stage

        prior =
            Maybe.withDefault emptyHistogram (Dict.get key state.modules)

        bucket =
            bucketOf dtMs

        updatedBuckets =
            Array.set bucket (1 + Maybe.withDefault 0 (Array.get bucket prior.buckets)) prior.buckets

        updated =
            { buckets = updatedBuckets
            , count = prior.count + 1
            , sumMs = prior.sumMs + dtMs
            , minMs =
                if prior.count == 0 then
                    dtMs

                else
                    min prior.minMs dtMs
            , maxMs =
                if prior.count == 0 then
                    dtMs

                else
                    max prior.maxMs dtMs
            , topSlow = insertTopSlow ( name, dtMs ) prior.topSlow
            }
    in
    { state | modules = Dict.insert key updated state.modules }


insertTopSlow : ( String, Int ) -> List ( String, Int ) -> List ( String, Int )
insertTopSlow entry existing =
    List.take topSlowCap (insertDescending entry existing)


insertDescending : ( String, Int ) -> List ( String, Int ) -> List ( String, Int )
insertDescending (( _, ms ) as entry) list =
    case list of
        [] ->
            [ entry ]

        (( _, existingMs ) as head) :: rest ->
            if ms >= existingMs then
                entry :: list

            else
                head :: insertDescending entry rest



-- ====== PRETTY-PRINT ======


{-| Render the stats to stderr. No-op when disabled.
-}
prettyPrint : Handle -> Task Never ()
prettyPrint handle =
    case handle of
        Disabled ->
            Task.succeed ()

        Enabled mvar ->
            Utils.readMVar stateDecoder mvar
                |> Task.andThen (IO.writeLn IO.stderr << formatState)


formatState : State -> String
formatState state =
    let
        totalMs =
            max 0 (state.endMs - state.startMs)

        phaseLines =
            List.map (formatPhaseRow state) allPhases

        moduleLines =
            List.concatMap (formatStageBlock state) allStages

        expandedLines =
            List.concatMap (expandedStageBlock state) allStages
    in
    String.join "\n"
        ([ ""
         , "Front-end timing"
         , "================="
         ]
            ++ phaseLines
            ++ moduleLines
            ++ [ "  ---------------------------"
               , "  " ++ padRight 22 "Total (wall clock)" ++ formatMs totalMs
               ]
            ++ expandedLines
            ++ [ "" ]
        )


formatPhaseRow : State -> PhaseName -> String
formatPhaseRow state phase =
    let
        label =
            "  " ++ padRight 22 (phaseLabel phase)

        body =
            case Dict.get (phaseOrd phase) state.phases of
                Nothing ->
                    "(not run)"

                Just ps ->
                    formatMs (max 0 (ps.endMs - ps.startMs))
    in
    label ++ body


formatStageBlock : State -> ModuleStage -> List String
formatStageBlock state stage =
    case Dict.get (stageOrd stage) state.modules of
        Nothing ->
            []

        Just hist ->
            [ "      "
                ++ padRight 8 (stageLabel stage)
                ++ "n="
                ++ padRight 6 (String.fromInt hist.count)
                ++ "  sum="
                ++ padRight 10 (formatMs hist.sumMs)
                ++ "  min="
                ++ padRight 8 (formatMs hist.minMs)
                ++ "  max="
                ++ padRight 10 (formatMs hist.maxMs)
                ++ "  ["
                ++ renderBuckets hist.buckets
                ++ "]"
            ]


expandedStageBlock : State -> ModuleStage -> List String
expandedStageBlock state stage =
    case Dict.get (stageOrd stage) state.modules of
        Nothing ->
            []

        Just hist ->
            let
                title : String
                title =
                    capitalize (stageLabel stage) ++ " per-module histogram"

                maxBucketCount : Int
                maxBucketCount =
                    Array.foldl max 0 hist.buckets

                bucketLines : List String
                bucketLines =
                    List.indexedMap (renderBucketLine maxBucketCount)
                        (Array.toList hist.buckets)

                slowestHeader : String
                slowestHeader =
                    "  Slowest " ++ stageLabel stage ++ " modules:"

                slowestLines : List String
                slowestLines =
                    List.map renderSlowLine hist.topSlow
            in
            [ "", title, String.repeat (String.length title) "-" ]
                ++ bucketLines
                ++ ("" :: slowestHeader :: slowestLines)


{-| One row of the expanded histogram: range label, count, and a horizontal
bar scaled against the busiest bucket.
-}
renderBucketLine : Int -> Int -> Int -> String
renderBucketLine maxCount idx count =
    let
        barWidthMax : Int
        barWidthMax =
            40

        bar : String
        bar =
            if count == 0 || maxCount == 0 then
                ""

            else
                String.repeat (max 1 ((count * barWidthMax) // maxCount)) "█"
    in
    "  "
        ++ padLeft 20 (formatBucketRange idx)
        ++ "  "
        ++ padLeft 5 (String.fromInt count)
        ++ "  "
        ++ bar


{-| Human-readable bucket range. Bucket 0 is `0 ms – 10 ms`; bucket N (the
overflow) is `> 20.48 s`.
-}
formatBucketRange : Int -> String
formatBucketRange idx =
    if idx == numBuckets - 1 then
        "> " ++ formatMs (bucketUpperEdge (idx - 1))

    else
        let
            lo : Int
            lo =
                if idx == 0 then
                    0

                else
                    bucketUpperEdge (idx - 1)

            hi : Int
            hi =
                bucketUpperEdge idx
        in
        padLeft 7 (formatMs lo) ++ " – " ++ padLeft 7 (formatMs hi)


renderSlowLine : ( String, Int ) -> String
renderSlowLine ( name, ms ) =
    "    " ++ padLeft 8 (formatMs ms) ++ "   " ++ name


capitalize : String -> String
capitalize s =
    String.toUpper (String.left 1 s) ++ String.dropLeft 1 s


renderBuckets : Array Int -> String
renderBuckets buckets =
    let
        maxCount =
            Array.foldl max 0 buckets

        glyphFor count =
            if count == 0 then
                '.'

            else if maxCount == 0 then
                '.'

            else
                bucketGlyph (toFloat count / toFloat maxCount)
    in
    Array.foldr (\c acc -> String.cons (glyphFor c) acc) "" buckets


bucketGlyph : Float -> Char
bucketGlyph ratio =
    let
        glyphs =
            [ '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' ]

        idx =
            min 7 (max 0 (floor (ratio * 8) - 1))
                |> max 0
    in
    Maybe.withDefault '▁'
        (List.head (List.drop idx glyphs))


{-| Format a millisecond duration. Under 1000 ms shows as `<n> ms`; 1000 ms and
above shows as decimal seconds with one fractional digit (e.g. `1.6 s`,
`47.2 s`). Keeps wide histograms readable without losing precision on the
small samples that dominate per-module timings.
-}
formatMs : Int -> String
formatMs ms =
    if ms < 1000 then
        String.fromInt ms ++ " ms"

    else
        let
            tenths : Int
            tenths =
                (ms + 50) // 100

            whole : Int
            whole =
                tenths // 10

            frac : Int
            frac =
                modBy 10 tenths
        in
        String.fromInt whole ++ "." ++ String.fromInt frac ++ " s"


padRight : Int -> String -> String
padRight n s =
    if String.length s >= n then
        s

    else
        s ++ String.repeat (n - String.length s) " "


padLeft : Int -> String -> String
padLeft n s =
    if String.length s >= n then
        s

    else
        String.repeat (n - String.length s) " " ++ s



-- ====== LABELS / ORDINALS ======


phaseLabel : PhaseName -> String
phaseLabel phase =
    case phase of
        PhaseDeps ->
            "dependency check"

        PhaseLocal ->
            "parse / check / build"

        PhaseMono ->
            "monomorphization"

        PhaseInlineSimplify ->
            "inline + simplify"

        PhaseGlobalOpt ->
            "global optimization"

        PhaseMlir ->
            "MLIR codegen"


stageLabel : ModuleStage -> String
stageLabel stage =
    case stage of
        Crawl ->
            "crawl"

        Check ->
            "check"

        Build ->
            "build"


phaseOrd : PhaseName -> Int
phaseOrd phase =
    case phase of
        PhaseDeps ->
            0

        PhaseLocal ->
            1

        PhaseMono ->
            2

        PhaseInlineSimplify ->
            3

        PhaseGlobalOpt ->
            4

        PhaseMlir ->
            5


stageOrd : ModuleStage -> Int
stageOrd stage =
    case stage of
        Crawl ->
            0

        Check ->
            1

        Build ->
            2


allPhases : List PhaseName
allPhases =
    [ PhaseDeps, PhaseLocal, PhaseMono, PhaseInlineSimplify, PhaseGlobalOpt, PhaseMlir ]


allStages : List ModuleStage
allStages =
    [ Crawl, Check, Build ]



-- ====== MVAR HELPERS ======


modifyState : MVar State -> (State -> State) -> Task Never ()
modifyState mvar f =
    Utils.takeMVar stateDecoder mvar
        |> Task.andThen (\s -> Utils.putMVar stateEncoder mvar (f s))



-- ====== ENCODERS / DECODERS ======


stateEncoder : State -> Bytes.Encode.Encoder
stateEncoder s =
    Bytes.Encode.sequence
        [ BE.int s.startMs
        , BE.int s.endMs
        , BE.stdDict BE.int phaseStatsEncoder s.phases
        , BE.stdDict BE.int histogramEncoder s.modules
        ]


stateDecoder : Bytes.Decode.Decoder State
stateDecoder =
    Bytes.Decode.map State BD.int
        |> bdApply BD.int
        |> bdApply (BD.stdDict BD.int phaseStatsDecoder)
        |> bdApply (BD.stdDict BD.int histogramDecoder)


bdApply : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (a -> b) -> Bytes.Decode.Decoder b
bdApply da df =
    Bytes.Decode.andThen (\f -> Bytes.Decode.map f da) df


phaseStatsEncoder : PhaseStats -> Bytes.Encode.Encoder
phaseStatsEncoder ps =
    Bytes.Encode.sequence [ BE.int ps.startMs, BE.int ps.endMs ]


phaseStatsDecoder : Bytes.Decode.Decoder PhaseStats
phaseStatsDecoder =
    Bytes.Decode.map PhaseStats BD.int
        |> bdApply BD.int


histogramEncoder : Histogram -> Bytes.Encode.Encoder
histogramEncoder h =
    Bytes.Encode.sequence
        [ BE.list BE.int (Array.toList h.buckets)
        , BE.int h.count
        , BE.int h.sumMs
        , BE.int h.minMs
        , BE.int h.maxMs
        , BE.list (BE.jsonPair BE.string BE.int) h.topSlow
        ]


histogramDecoder : Bytes.Decode.Decoder Histogram
histogramDecoder =
    BD.map6 Histogram
        (Bytes.Decode.map Array.fromList (BD.list BD.int))
        BD.int
        BD.int
        BD.int
        BD.int
        (BD.list (BD.jsonPair BD.string BD.int))
