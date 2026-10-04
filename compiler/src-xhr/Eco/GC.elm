module Eco.GC exposing (GCReport, minorGC, majorGC)

{-| Lets the compiler ask for a garbage collection at a point of its choosing,
and learn what the collection did, in the build that runs on stock Elm.

This is the XHR twin of `Eco.GC`. The native build uses a kernel module with
the same exposed names and the same `GCReport` record, so a caller compiles
against either. Here a collection is a request to eco-io, as `Eco.XHR`
describes: `minorGC` sends the op `"GC.minor"` and `majorGC` sends
`"GC.major"`, both with no arguments, and the report is read from the `value`
field of the reply. Which collection actually runs, if any, is up to eco-io.

The report has the shape the native collector fills in, and several of its
fields name steps of that collector. In this build its values need not be
measurements. The two builds therefore fill a report differently, and its
values are for logging: nothing should decide what to do by them.

A `value` that does not have the report's shape is not a failure: it is read as
the zero record, whose `kind` is `"error"`. The program still crashes when the
request itself fails, through `Eco.XHR.orCrash`, and when a 2xx reply is not
JSON or has no `value` field, as `Eco.XHR.jsonTask` describes.


# Collections

@docs GCReport, minorGC, majorGC

-}

import Eco.XHR
import Json.Decode as D
import Json.Encode as Encode
import Task exposing (Task)


{-| What one collection did, as the reply to a GC request reports it.

`kind` is `"error"` for a reply whose `value` could not be read as a report,
and then every other field is 0. Otherwise it is the kind of collection the
reply names, such as `"minor"` or `"major"`, and `collected` is 1 when a
collection ran and 0 when none did. The fields ending in `Ns` are times in
nanoseconds, and the other numbers, apart from `collected`, the counts
(`minorCount`, `majorCount`, `majorsRun`) and `trimResult`, are sizes in bytes.
`rssAfterDiscard` and `rssAfter` are the resident set size after the collector
has discarded released pages and at the end.

These are the conventions the record carries between the two builds. Decoding
checks only that each field is present with the right JSON type (a string for
`kind`, an integer for the rest), so nothing enforces a unit, and a placeholder
decodes like a measurement.

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


{-| Asks eco-io for a minor collection and returns its report.
-}
minorGC : Task Never GCReport
minorGC =
    Eco.XHR.jsonTask "GC.minor" Encode.null lenientDecoder
        |> Eco.XHR.orCrash


{-| Asks eco-io for a major collection and returns its report.
-}
majorGC : Task Never GCReport
majorGC =
    Eco.XHR.jsonTask "GC.major" Encode.null lenientDecoder
        |> Eco.XHR.orCrash


{-| A decoder for a report that never fails: a value that `reportDecoder`
cannot read is read as `zero`.
-}
lenientDecoder : D.Decoder GCReport
lenientDecoder =
    D.oneOf [ reportDecoder, D.succeed zero ]


{-| Returns a decoder that reads the same value with both decoders and applies
the function the second produces to the value the first produces. The argument
order lets a record constructor be given its fields one decoder at a time, in a
pipeline.
-}
andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap =
    D.map2 (|>)


{-| A decoder for a `GCReport` from a JSON object with a string `kind` and an
integer for every other field of the record, each under the field's own name.
Other keys are ignored. A missing field, or a number that is not an integer,
makes it fail.
-}
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


{-| The report that stands in for one that could not be read: `kind` is
`"error"` and every number is 0.
-}
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
