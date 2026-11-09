module LargeBytesHoldChurnTest exposing (main)

{-| A running mark cycle's deferred large bodies stay bounded
(plans/large-body-deferral-pacing.md, HEAP_084): one 64 MiB `Bytes` is held for
the whole run while 2 GiB from `/dev/zero` streams through as fresh 64 KiB
`Bytes`, each dropped (as `LargeBytesChurnTest`). The live body makes a major
trigger fire, and while the cycle runs every dead young body is deferred to the
handoff instead of freed (HEAP_063). Before the deferred-bytes finish the cycle
ran its full schedule and held a whole cycle's churn, gigabytes; with it, the
cycle ends once it has deferred about as much as the live heap. RSS is sampled
after the held body is built and 64 MiB more has streamed.
-}

-- CHECK: held: 67108864 bytes
-- CHECK: read: 2147483648 bytes
-- CHECK: rss growth under 512 MiB: True
-- EXIT: 0

import Bytes exposing (Bytes)
import Bytes.Encode as E
import FileTestHelp exposing (file)
import Stream
import System
import FileSystem as File
import Path
import Task exposing (Task)
import WebSocketTestHelp as W


heldBytes : Int
heldBytes =
    64 * 1024 * 1024


warmupBytes : Int
warmupBytes =
    64 * 1024 * 1024


limitKiB : Int
limitKiB =
    512 * 1024


{-| `heldBytes` of copies of `b`, built in one allocation: doubling would leave
the intermediate bodies' blocks committed, and the major trigger compares the
bytes in use with the committed bytes.
-}
grow : Bytes -> Bytes
grow b =
    E.encode (E.sequence (List.repeat (heldBytes // Bytes.width b) (E.bytes b)))


{-| Reads until the stream closes, counting bytes. The first chunk seeds the held
`Bytes`, which is passed along so it stays live; RSS is sampled once the count
first passes `warmupBytes` after that.
-}
drain : Stream.Readable Bytes -> Int -> Maybe Bytes -> Maybe Int -> Task String ( Int, Int, Maybe Int )
drain r n held rss0 =
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
                        Task.succeed ( n, Maybe.withDefault 0 (Maybe.map Bytes.width held), rss0 )

                    Just b ->
                        let
                            n2 =
                                n + Bytes.width b
                        in
                        case held of
                            Nothing ->
                                drain r n2 (Just (grow b)) rss0

                            Just _ ->
                                if rss0 == Nothing && n2 >= warmupBytes then
                                    W.rssKiB |> Task.andThen (\rss -> drain r n2 held (Just rss))

                                else
                                    drain r n2 held rss0
            )


run : a -> Task String (List String)
run _ =
    file (File.readFileStream (File.Between { start = 0, end = 2147483647 }) (Path.fromPosixString "/dev/zero"))
        |> Task.andThen (\r -> drain r 0 Nothing Nothing)
        |> Task.andThen
            (\( n, h, rss0 ) ->
                W.rssKiB
                    |> Task.map
                        (\rss1 ->
                            let
                                growth =
                                    rss1 - Maybe.withDefault rss1 rss0
                            in
                            [ "held: " ++ String.fromInt h ++ " bytes"
                            , "read: " ++ String.fromInt n ++ " bytes"
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


main : Platform.Program System.Environment () ()
main =
    FileTestHelp.program run
