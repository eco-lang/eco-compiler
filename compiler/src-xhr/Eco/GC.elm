module Eco.GC exposing (GCReport, minorGC, majorGC)

{-| Explicit garbage collections via XHR (plans/frontend-heap-release.md §5.1).

This is the XHR-based bootstrap implementation (stage 1). The kernel variant
(in eco-kernel-cpp) has identical type signatures and the same `GCReport`
record and decoder, but delegates to Eco.Kernel.GC. Here the eco-io handler
(`compiler/bin/eco-io-handler.js`) returns the report object itself as
`value`, so the decoder is applied directly. Without node `--expose-gc` no
collection runs and `collected` is 0.

Report values are observations for logging only: no code may branch on them
(HEAP\_076).


# Collections

@docs GCReport, minorGC, majorGC

-}

import Eco.XHR
import Json.Decode as D
import Json.Encode as Encode
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
    Eco.XHR.jsonTask "GC.minor" Encode.null lenientDecoder
        |> Eco.XHR.orCrash


{-| Run a full release (a full collection in JS).
-}
majorGC : Task Never GCReport
majorGC =
    Eco.XHR.jsonTask "GC.major" Encode.null lenientDecoder
        |> Eco.XHR.orCrash


{-| A GC report must never crash the compile: an undecodable reply becomes the
zero record with `kind = "error"`, as in the kernel variant.
-}
lenientDecoder : D.Decoder GCReport
lenientDecoder =
    D.oneOf [ reportDecoder, D.succeed zero ]



-- DECODING (identical in eco-kernel-cpp/src/Eco/GC.elm)


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
