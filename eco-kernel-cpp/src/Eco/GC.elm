module Eco.GC exposing (GCReport, minorGC, majorGC)

{-| Explicit garbage collections (plans/frontend-heap-release.md §4).

`majorGC` is a full release: a stop-the-world major collection, the sweep run
to completion, a forced shrink of the old generation, an immediate discard of
the released pages and a `malloc_trim`. `minorGC` collects the nursery.

Both return a `GCReport`. Its values are observations for logging only: no
code may branch on them (HEAP_076).

The kernel returns the report as a JSON string whose keys are the field names
below and whose values are integers (`kind` is `"minor"` or `"major"`). The
same API exists in `compiler/src-xhr/Eco/GC.elm` (bootstrap stage 1).


# Collections

@docs GCReport, minorGC, majorGC

-}

import Eco.Kernel.GC
import Json.Decode as D
import Task exposing (Task)


{-| What a collection did. `kind` is `"minor"`, `"major"` or `"error"` (an
undecodable kernel reply); `collected` is 1 when a collection ran and 0 when
none could (JS without `--expose-gc`). Times are nanoseconds and sizes bytes;
`rssAfterDiscard` and `rssAfter` are the resident set after the page discard
and after `malloc_trim`.
-}
type alias GCReport =
    { kind : String
    , collected : Int
    , totalNs : Int
    , gcNs : Int
    , sweepNs : Int
    , shrinkNs : Int
    , discardNs : Int
    , trimNs : Int
    , rssBefore : Int
    , rssAfterDiscard : Int
    , rssAfter : Int
    , oldInUseBefore : Int
    , oldInUseAfter : Int
    , oldPendingBefore : Int
    , oldPendingAfter : Int
    , oldHighWater : Int
    , liveAfterMark : Int
    , releasedBytes : Int
    , shrinkReleasedBytes : Int
    , discardedBytes : Int
    , nurseryCommitted : Int
    , minorCount : Int
    , majorCount : Int
    , majorsRun : Int
    , trimResult : Int
    }


{-| Run a minor collection.
-}
minorGC : Task Never GCReport
minorGC =
    Task.map decode minorRaw


{-| Run a full release (major collection, sweep, shrink, discard, trim).
-}
majorGC : Task Never GCReport
majorGC =
    Task.map decode majorRaw


minorRaw : Task Never String
minorRaw =
    Eco.Kernel.GC.minorGC


majorRaw : Task Never String
majorRaw =
    Eco.Kernel.GC.majorGC



-- DECODING (identical in compiler/src-xhr/Eco/GC.elm)


decode : String -> GCReport
decode json =
    case D.decodeString reportDecoder json of
        Ok report ->
            report

        Err _ ->
            zero


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap =
    D.map2 (|>)


reportDecoder : D.Decoder GCReport
reportDecoder =
    D.succeed GCReport
        |> andMap (D.field "kind" D.string)
        |> andMap (D.field "collected" D.int)
        |> andMap (D.field "totalNs" D.int)
        |> andMap (D.field "gcNs" D.int)
        |> andMap (D.field "sweepNs" D.int)
        |> andMap (D.field "shrinkNs" D.int)
        |> andMap (D.field "discardNs" D.int)
        |> andMap (D.field "trimNs" D.int)
        |> andMap (D.field "rssBefore" D.int)
        |> andMap (D.field "rssAfterDiscard" D.int)
        |> andMap (D.field "rssAfter" D.int)
        |> andMap (D.field "oldInUseBefore" D.int)
        |> andMap (D.field "oldInUseAfter" D.int)
        |> andMap (D.field "oldPendingBefore" D.int)
        |> andMap (D.field "oldPendingAfter" D.int)
        |> andMap (D.field "oldHighWater" D.int)
        |> andMap (D.field "liveAfterMark" D.int)
        |> andMap (D.field "releasedBytes" D.int)
        |> andMap (D.field "shrinkReleasedBytes" D.int)
        |> andMap (D.field "discardedBytes" D.int)
        |> andMap (D.field "nurseryCommitted" D.int)
        |> andMap (D.field "minorCount" D.int)
        |> andMap (D.field "majorCount" D.int)
        |> andMap (D.field "majorsRun" D.int)
        |> andMap (D.field "trimResult" D.int)


zero : GCReport
zero =
    { kind = "error"
    , collected = 0
    , totalNs = 0
    , gcNs = 0
    , sweepNs = 0
    , shrinkNs = 0
    , discardNs = 0
    , trimNs = 0
    , rssBefore = 0
    , rssAfterDiscard = 0
    , rssAfter = 0
    , oldInUseBefore = 0
    , oldInUseAfter = 0
    , oldPendingBefore = 0
    , oldPendingAfter = 0
    , oldHighWater = 0
    , liveAfterMark = 0
    , releasedBytes = 0
    , shrinkReleasedBytes = 0
    , discardedBytes = 0
    , nurseryCommitted = 0
    , minorCount = 0
    , majorCount = 0
    , majorsRun = 0
    , trimResult = 0
    }
