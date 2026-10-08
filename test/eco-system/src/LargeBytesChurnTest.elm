module LargeBytesChurnTest exposing (main)

{-| Large `Bytes` that are dropped as they arrive are reclaimed
(plans/large-body-gc-trigger.md Phase 0.2): 2 GiB read from `/dev/zero` with
`readFileStream` is 32 768 fresh 64 KiB `Bytes`, each a split body in the old
generation (HEAP_026) whose header costs the nursery 16 bytes. Each chunk is
counted and dropped. Without the direct-allocation debt (D1-D3) almost no minor
GC runs, no body is freed, and the process grows by about 2 GiB (or aborts at
the old-gen cap); with it, the resident set stays bounded. RSS is sampled
after the first 64 MiB, so warming up is not counted.
-}

-- CHECK: read: 2147483648 bytes
-- CHECK: rss growth under 512 MiB: True
-- EXIT: 0

import Bytes
import FileTestHelp exposing (file)
import Stream
import System
import System.File as File
import System.File.Path as Path
import Task exposing (Task)
import WebSocketTestHelp as W


warmupBytes : Int
warmupBytes =
    64 * 1024 * 1024


limitKiB : Int
limitKiB =
    512 * 1024


{-| Reads until the stream closes, counting bytes; samples RSS once the count
first passes `warmupBytes`.
-}
drain : Stream.Readable Bytes.Bytes -> Int -> Maybe Int -> Task String ( Int, Maybe Int )
drain r n rss0 =
    Stream.read r
        |> Task.map Just
        |> Task.onError
            (\e ->
                case e of
                    Stream.Closed ->
                        Task.succeed Nothing

                    _ ->
                        Task.fail (Stream.errorToString e)
            )
        |> Task.andThen
            (\chunk ->
                case chunk of
                    Nothing ->
                        Task.succeed ( n, rss0 )

                    Just b ->
                        let
                            n2 =
                                n + Bytes.width b
                        in
                        if rss0 == Nothing && n2 >= warmupBytes then
                            W.rssKiB |> Task.andThen (\rss -> drain r n2 (Just rss))

                        else
                            drain r n2 rss0
            )


run : a -> Task String (List String)
run _ =
    file (File.readFileStream (File.Between { start = 0, end = 2147483647 }) (Path.fromPosixString "/dev/zero"))
        |> Task.andThen (\r -> drain r 0 Nothing)
        |> Task.andThen
            (\( n, rss0 ) ->
                W.rssKiB
                    |> Task.map
                        (\rss1 ->
                            let
                                growth =
                                    rss1 - Maybe.withDefault rss1 rss0
                            in
                            [ "read: " ++ String.fromInt n ++ " bytes"
                            , "rss growth under 512 MiB: "
                                ++ (if growth < limitKiB then
                                        "True"

                                    else
                                        "False"
                                   )
                            , "rss growth KiB: " ++ String.fromInt growth
                            ]
                    )
            )


main : System.SimpleProgram ()
main =
    FileTestHelp.program run
