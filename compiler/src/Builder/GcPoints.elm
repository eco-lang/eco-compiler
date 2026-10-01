module Builder.GcPoints exposing (preLink, render)

{-| The explicit garbage collection before the native back end
(plans/frontend-heap-release.md §6.2-6.3).

`preLink` runs a full release (`Eco.GC.majorGC`) immediately before
`Eco.NativeDriver.lowerAndLink`; on by default, `ECO_GC_PRE_LINK=0` opts out.
The optional phase-boundary points were removed after measurement
(benchmarks/fhr-gc-points.md: no peak-memory benefit, +1 to +4 s wall each).

**The rooting rule (§10 trap 1):** a Task callback's argument stays rooted until
the callback returns, so the collection runs in its OWN `andThen` step after
the step that consumed the dead data.

With `report` (`ECO_GC_REPORT=1`) each collection prints one `[gc-report]` line
on stderr (`render`, §8.2). Report values are only logged: no control flow may
depend on them (HEAP\_076).

@docs preLink, render

-}

import Compiler.Eco.Config as Config
import Eco.GC
import System.IO as IO
import Task exposing (Task)
import Utils.Task.Extra as Task


{-| The mandatory full release before the native back end (unless disabled).
-}
preLink : Config.GcConfig -> Task x ()
preLink cfg =
    if cfg.preLink then
        collect cfg.report "pre-link"

    else
        Task.succeed ()


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


{-| The single-line `[gc-report]` format (§8.2): `key=value` pairs separated by
spaces; `A>B` is before>after and `rss_mb=A>B>C` is before, after the discard,
after the trim. Times are milliseconds and sizes MiB, both with one decimal.
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


{-| Nanoseconds as milliseconds with one decimal.
-}
ms : Int -> String
ms ns =
    tenths (ns // 100000)


{-| Bytes as MiB with one decimal.
-}
mb : Int -> String
mb bytes =
    tenths ((bytes * 10) // 1048576)


tenths : Int -> String
tenths t =
    if t < 0 then
        "-" ++ tenths (negate t)

    else
        String.fromInt (t // 10) ++ "." ++ String.fromInt (modBy 10 t)
