module Builder.Eco.FEStats exposing
    ( Handle
    , PhaseName(..), ModuleStage(..)
    , init, finalize, disabled
    , withPhase, withPhaseLazy, withModuleStage
    , prettyPrint
    )

{-| `eco make --stats` reports where the front end spent its time, and this
module collects and prints those figures.

Two kinds of measurement are kept. A _phase_ is one of six whole steps of the
pipeline, from the dependency check to MLIR generation, and gets one wall-clock
duration each. A _module stage_ is one of three per-module steps (crawl, check,
build), and gets a histogram over the modules it ran for: how many
samples fell in each duration bucket, their count, sum, minimum and maximum, and
the five slowest modules. Each phase and module-stage measurement is wall-clock
time between the start and the end of its task, so it includes any time the
task spent waiting.

A `Handle` is either disabled, in which case every function here runs the given
task unchanged and records nothing, or enabled, in which case the figures are
kept in an `MVar` that each recording takes and puts back, so recordings made
from concurrent threads do not overwrite one another. `prettyPrint` writes the
report to stderr.

@docs Handle
@docs PhaseName, ModuleStage
@docs init, finalize, disabled
@docs withPhase, withPhaseLazy, withModuleStage
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


{-| Where the timing figures of one run go, if anywhere.

`Disabled` records and prints nothing; the wrappers run their task without
timing it.
`Enabled` holds the figures recorded so far.

-}
type Handle
    = Disabled
    | Enabled (MVar State)


{-| A handle that records nothing.
-}
disabled : Handle
disabled =
    Disabled


{-| One of the six front-end phases that are each timed as a whole. A phase
appears in the report under the label it is given here: dependency check,
parse / check / build, monomorphization, inline + simplify, global optimization
and MLIR codegen.
-}
type PhaseName
    = PhaseDeps
    | PhaseLocal
    | PhaseMono
    | PhaseInlineSimplify
    | PhaseGlobalOpt
    | PhaseMlir


{-| One of the three per-module steps, each of which gets its own per-module
histogram. In `Builder.Build`, `Crawl` times finding and crawling a module's
source file, `Check` times checking a module from its crawl status, and `Build`
times compiling a module, which happens only for modules not reused from the
cache.
-}
type ModuleStage
    = Crawl
    | Check
    | Build



-- ====== INTERNAL STATE ======


{-| Everything an enabled handle has recorded: the run's start and end times, one
duration per phase that has run, and one histogram per module stage that has
had a sample. Times are milliseconds since the epoch. `phases` and `modules`
are keyed by `phaseOrd` and `stageOrd`.

`endMs` equals `startMs` until `finalize` is called.

-}
type alias State =
    { startMs : Int
    , endMs : Int
    , phases : Dict Int PhaseStats
    , modules : Dict Int Histogram
    }


{-| The start and end of one phase, in milliseconds since the epoch.
-}
type alias PhaseStats =
    { startMs : Int
    , endMs : Int
    }


{-| A summary of the samples of one module stage, with durations in
milliseconds.

`buckets` holds `numBuckets` counts, indexed as `bucketOf` describes. `minMs`
and `maxMs` are 0 while `count` is 0. `topSlow` is at most `topSlowCap` module
names with their durations, slowest first.

-}
type alias Histogram =
    { buckets : Array Int
    , count : Int
    , sumMs : Int
    , minMs : Int
    , maxMs : Int
    , topSlow : List ( String, Int )
    }


{-| A histogram with no samples.
-}
emptyHistogram : Histogram
emptyHistogram =
    { buckets = Array.repeat numBuckets 0
    , count = 0
    , sumMs = 0
    , minMs = 0
    , maxMs = 0
    , topSlow = []
    }


{-| The number of histogram buckets: twelve bounded by `bucketUpperEdge` and one
for everything longer.
-}
numBuckets : Int
numBuckets =
    13


{-| Returns the inclusive upper edge, in milliseconds, of bounded bucket `idx`:
10 times 2 to the power `idx`, so 10, 20, 40 up to 20480 for bucket 11. Bucket
12 has no upper edge.
-}
bucketUpperEdge : Int -> Int
bucketUpperEdge idx =
    10 * (2 ^ idx)


{-| Returns the bucket a duration of `ms` milliseconds falls in: the first
bucket whose upper edge is at least `ms`, so 10 ms or less (negative included)
is bucket 0, and more than 20480 ms is the last bucket, 12.
-}
bucketOf : Int -> Int
bucketOf ms =
    bucketOfHelp ms 0


{-| Returns the first bucket from `idx` onwards that `ms` falls in, or the last
bucket.
-}
bucketOfHelp : Int -> Int -> Int
bucketOfHelp ms idx =
    if idx >= numBuckets - 1 then
        numBuckets - 1

    else if ms <= bucketUpperEdge idx then
        idx

    else
        bucketOfHelp ms (idx + 1)


{-| The number of slowest modules each stage histogram keeps.
-}
topSlowCap : Int
topSlowCap =
    5



-- ====== INIT / FINALIZE ======


{-| Creates a handle: one that records nothing when `enabled` is `False`, and
otherwise one with nothing recorded yet whose run starts now.
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


{-| Records now as the end of the run, which is what the report's total is
measured to. A later call replaces the earlier end.
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


{-| Runs `task` as `phase`. With an enabled handle it first writes
`Starting <phase label>...` to stderr, and records the time from just after
that line to the task's success as the phase's duration, replacing any earlier
duration for the same phase. A task that fails records nothing.

Any work done while building `task` happens before the call and is not timed;
`withPhaseLazy` times it too.

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


{-| Runs the task `thunk` builds as `phase`, as `withPhase` does, except that
`thunk` is called inside the timed step, so the work of building the task is
billed to the phase.

`thunk` is called in a task step of its own even when the handle is disabled.

-}
withPhaseLazy : Handle -> PhaseName -> (() -> Task x a) -> Task x a
withPhaseLazy handle phase thunk =
    case handle of
        Disabled ->
            Task.succeed () |> Task.andThen thunk

        Enabled mvar ->
            Task.io (IO.writeLn IO.stderr ("Starting " ++ phaseLabel phase ++ "..."))
                |> Task.andThen (\_ -> Task.io Time.now)
                |> Task.andThen
                    (\beforePosix ->
                        thunk ()
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


{-| Records a phase as running from `startMs` to `endMs`, replacing any earlier
record for it.
-}
recordPhase : PhaseName -> Int -> Int -> State -> State
recordPhase phase startMs endMs state =
    { state
        | phases =
            Dict.insert (phaseOrd phase)
                { startMs = startMs, endMs = endMs }
                state.phases
    }



-- ====== PER-MODULE RECORDING ======


{-| Runs `task` as module stage `stage` of module `name`. With an enabled handle
the time to the task's success is added as one sample to that stage's
histogram; a task that fails records nothing.
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


{-| Adds one sample for module `name` to `stage`'s histogram, lasting from
`startPosix` to `endPosix`, or 0 ms if the end is before the start. Does
nothing with a disabled handle.
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


{-| Returns `state` with a sample of `dtMs` milliseconds for module `name` added
to `stage`'s histogram.
-}
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


{-| Returns `existing`, a slowest-first list, with `entry` added and cut to
`topSlowCap` entries.
-}
insertTopSlow : ( String, Int ) -> List ( String, Int ) -> List ( String, Int )
insertTopSlow entry existing =
    List.take topSlowCap (insertDescending entry existing)


{-| Returns the slowest-first `list` with `entry` inserted ahead of the first entry
no slower than it, so it goes before entries of equal duration.
-}
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


{-| Writes the report to stderr: each phase's duration, or `(not run)`, then a
one-line summary of each module stage that has samples, the total from `init`
to the last `finalize`, and then each stage's histogram in full with its
slowest modules. Writes nothing with a disabled handle.
-}
prettyPrint : Handle -> Task Never ()
prettyPrint handle =
    case handle of
        Disabled ->
            Task.succeed ()

        Enabled mvar ->
            Utils.readMVar stateDecoder mvar
                |> Task.andThen (IO.writeLn IO.stderr << formatState)


{-| Returns the whole report for `state` as text.
-}
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


{-| Returns the report line for `phase`: its label and duration, or `(not run)`.
-}
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


{-| Returns the one-line summary of `stage`'s histogram, with the buckets as a
sparkline, or nothing if it has no samples.
-}
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


{-| Returns the full histogram of `stage`, one line per bucket, followed by its
slowest modules, or nothing if it has no samples.
-}
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


{-| Returns the line for bucket `idx` of a full histogram: its range, `count`,
and a bar of up to 40 characters scaled against `maxCount`, at least one
character long when `count` is not 0.
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


{-| Returns the range of bucket `idx` as text, from the previous bucket's upper
edge (0 for bucket 0) to its own, formatted by `formatMs`. The last bucket
reads `> 20.5 s`, because `formatMs` rounds 20480 ms to tenths of a second.
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


{-| Returns the report line for one of the slowest modules.
-}
renderSlowLine : ( String, Int ) -> String
renderSlowLine ( name, ms ) =
    "    " ++ padLeft 8 (formatMs ms) ++ "   " ++ name


{-| Returns `s` with its first character in upper case.
-}
capitalize : String -> String
capitalize s =
    String.toUpper (String.left 1 s) ++ String.dropLeft 1 s


{-| Returns a sparkline of `buckets`, one character per bucket: `.` for an empty
bucket, otherwise a block whose height is the count relative to the largest.
-}
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


{-| Returns the block character for a count that is `ratio` of the largest count,
from the lowest block up to the full block at `ratio` 1.
-}
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


{-| Returns `ms` milliseconds as text: below 1000 as whole milliseconds
(`640 ms`), from 1000 as seconds rounded to the nearest tenth (`1.6 s`).
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


{-| Returns `s` padded with spaces on the right to `n` characters, or unchanged if
already that long.
-}
padRight : Int -> String -> String
padRight n s =
    if String.length s >= n then
        s

    else
        s ++ String.repeat (n - String.length s) " "


{-| Returns `s` padded with spaces on the left to `n` characters, or unchanged if
already that long.
-}
padLeft : Int -> String -> String
padLeft n s =
    if String.length s >= n then
        s

    else
        String.repeat (n - String.length s) " " ++ s



-- ====== LABELS / ORDINALS ======


{-| Returns the name `phase` is reported under.
-}
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


{-| Returns the name `stage` is reported under.
-}
stageLabel : ModuleStage -> String
stageLabel stage =
    case stage of
        Crawl ->
            "crawl"

        Check ->
            "check"

        Build ->
            "build"


{-| Returns the key `phase` is stored under, which is also its place in the report.
-}
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


{-| Returns the key `stage` is stored under.
-}
stageOrd : ModuleStage -> Int
stageOrd stage =
    case stage of
        Crawl ->
            0

        Check ->
            1

        Build ->
            2


{-| Every phase, in report order.
-}
allPhases : List PhaseName
allPhases =
    [ PhaseDeps, PhaseLocal, PhaseMono, PhaseInlineSimplify, PhaseGlobalOpt, PhaseMlir ]


{-| Every module stage, in report order.
-}
allStages : List ModuleStage
allStages =
    [ Crawl, Check, Build ]



-- ====== MVAR HELPERS ======


{-| Replaces the state in `mvar` with `f` applied to it, holding the MVar empty in
between so that no other update can interleave.
-}
modifyState : MVar State -> (State -> State) -> Task Never ()
modifyState mvar f =
    Utils.takeMVar stateDecoder mvar
        |> Task.andThen (\s -> Utils.putMVar stateEncoder mvar (f s))



-- ====== ENCODERS / DECODERS ======


{-| Produces the encoder that writes `s` into the MVar.
-}
stateEncoder : State -> Bytes.Encode.Encoder
stateEncoder s =
    Bytes.Encode.sequence
        [ BE.int s.startMs
        , BE.int s.endMs
        , BE.stdDict BE.int phaseStatsEncoder s.phases
        , BE.stdDict BE.int histogramEncoder s.modules
        ]


{-| A decoder for the state, as `stateEncoder` writes it.
-}
stateDecoder : Bytes.Decode.Decoder State
stateDecoder =
    Bytes.Decode.map State BD.int
        |> bdApply BD.int
        |> bdApply (BD.stdDict BD.int phaseStatsDecoder)
        |> bdApply (BD.stdDict BD.int histogramDecoder)


{-| Produces a decoder that applies the function `df` decodes to the value `da`
decodes next.
-}
bdApply : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (a -> b) -> Bytes.Decode.Decoder b
bdApply da df =
    Bytes.Decode.andThen (\f -> Bytes.Decode.map f da) df


{-| Produces the encoder for one phase's record.
-}
phaseStatsEncoder : PhaseStats -> Bytes.Encode.Encoder
phaseStatsEncoder ps =
    Bytes.Encode.sequence [ BE.int ps.startMs, BE.int ps.endMs ]


{-| A decoder for one phase's record, as `phaseStatsEncoder` writes it.
-}
phaseStatsDecoder : Bytes.Decode.Decoder PhaseStats
phaseStatsDecoder =
    Bytes.Decode.map PhaseStats BD.int
        |> bdApply BD.int


{-| Produces the encoder for one histogram.
-}
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


{-| A decoder for one histogram, as `histogramEncoder` writes it.
-}
histogramDecoder : Bytes.Decode.Decoder Histogram
histogramDecoder =
    BD.map6 Histogram
        (Bytes.Decode.map Array.fromList (BD.list BD.int))
        BD.int
        BD.int
        BD.int
        BD.int
        (BD.list (BD.jsonPair BD.string BD.int))
