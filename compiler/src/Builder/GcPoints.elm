module Builder.GcPoints exposing (preLink)

{-| Lets the compiler release the memory its earlier phases no longer need
before the native back end, which lowers and links the program, starts.

The one thing here is the _pre-link collection_: a single major garbage
collection, asked for through `Eco.GC.majorGC`, that `preLink` requests when
the `Compiler.Eco.Config.GcConfig` settings ask for it. With the `report`
setting on, it also writes one line describing the collection to standard
error, in the format `render` produces. The report's values are only printed
here; what they mean, and why nothing should decide anything by them, is in
`Eco.GC`.

A collection can only release data that nothing still refers to. Data
captured by the closure of an `andThen` step that has not yet run is still
referred to, so a collection that `preLink` asks for does not release it.

@docs preLink

-}

import Compiler.Eco.Config as Config
import Eco.GC
import System.IO as IO
import Task exposing (Task)
import Utils.Task.Extra as Task


{-| Returns a task that asks for the pre-link collection when `cfg.preLink` is
on, reporting it on standard error when `cfg.report` is also on, and does
nothing when `cfg.preLink` is off.
-}
preLink : Config.GcConfig -> Task x ()
preLink cfg =
    if cfg.preLink then
        collect cfg.report "pre-link"

    else
        Task.succeed ()


{-| Returns a task that asks for a major collection through `Eco.GC.majorGC`
and, when `report` is on, writes the collection's report line, tagged with
`label`, to standard error.
-}
collect : Bool -> String -> Task x ()
collect report label =
    Task.io
        (Eco.GC.majorGC
            |> Task.andThen
                (\r ->
                    if report then
                        IO.writeLn IO.stderr (render label r)

                    else
                        Task.succeed ()
                )
        )


{-| Returns the one-line report of a collection, tagged with `label` as its
`point`.

The line starts with `[gc-report] v=1` and continues with `key=value` pairs
separated by single spaces. A value written `A>B` is the report's value before
and after the collection. `rss_mb=A>B>C` gives the resident set size before,
after the collector discarded released pages, and at the end. Keys ending in
`_ms` are milliseconds and keys ending in `_mb` are MiB, both with one decimal
that is truncated, not rounded. `collected`, `minors`, `majors`, `majors_run`
and `trim` are the report's integers as they are.

-}
render : String -> Eco.GC.GCReport -> String
render label r =
    String.join " "
        [ "[gc-report] v=1"
        , "point=" ++ label
        , "kind=" ++ r.kind
        , "collected=" ++ String.fromInt r.collected
        , "total_ms=" ++ ms r.totalNs
        , "gc_ms=" ++ ms r.gcNs
        , "sweep_ms=" ++ ms r.sweepNs
        , "shrink_ms=" ++ ms r.shrinkNs
        , "discard_ms=" ++ ms r.discardNs
        , "trim_ms=" ++ ms r.trimNs
        , "live_mb=" ++ mb r.liveAfterMark
        , "inuse_mb=" ++ mb r.oldInUseBefore ++ ">" ++ mb r.oldInUseAfter
        , "pending_mb=" ++ mb r.oldPendingBefore ++ ">" ++ mb r.oldPendingAfter
        , "highwater_mb=" ++ mb r.oldHighWater
        , "rss_mb=" ++ mb r.rssBefore ++ ">" ++ mb r.rssAfterDiscard ++ ">" ++ mb r.rssAfter
        , "released_mb=" ++ mb r.releasedBytes
        , "shrink_released_mb=" ++ mb r.shrinkReleasedBytes
        , "discarded_mb=" ++ mb r.discardedBytes
        , "nursery_mb=" ++ mb r.nurseryCommitted
        , "minors=" ++ String.fromInt r.minorCount
        , "majors=" ++ String.fromInt r.majorCount
        , "majors_run=" ++ String.fromInt r.majorsRun
        , "trim=" ++ String.fromInt r.trimResult
        ]


{-| Returns `ns` nanoseconds as milliseconds with one decimal, truncated
towards zero.
-}
ms : Int -> String
ms ns =
    tenths (ns // 100000)


{-| Returns `bytes` as MiB with one decimal, truncated towards zero.
-}
mb : Int -> String
mb bytes =
    tenths ((bytes * 10) // 1048576)


{-| Returns a count of tenths, `t`, as a decimal with one digit after the point,
so 37 gives `"3.7"` and -5 gives `"-0.5"`.
-}
tenths : Int -> String
tenths t =
    if t < 0 then
        "-" ++ tenths (negate t)

    else
        String.fromInt (t // 10) ++ "." ++ String.fromInt (modBy 10 t)
