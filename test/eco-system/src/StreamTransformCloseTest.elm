module StreamTransformCloseTest exposing (main)

{-| A custom `Close` (plans/eco-system-library.md §3.5, WHATWG terminate): the
write that triggered it succeeds and its values are still readable, then the
readable reports `Closed`; later writes fail with "TransformStream has been
terminated", and so does closing the writable.
-}

-- CHECK: write a: ok
-- CHECK: write stop: ok
-- CHECK: reads: A,last,Closed
-- CHECK: write after close: err Cancelled: TransformStream has been terminated
-- CHECK: close after close: err Cancelled: TransformStream has been terminated
-- EXIT: 0

import Stream
import StreamTestHelp exposing (describe)
import System
import Task exposing (Task)


action : () -> String -> Stream.CustomTransformationAction () String
action state value =
    if value == "stop" then
        Stream.Close [ "last" ]

    else
        Stream.Send { state = state, send = [ String.toUpper value ] }


showRead : Stream.Readable String -> Task x String
showRead r =
    Stream.read r |> Task.onError (\err -> Task.succeed (Stream.errorToString err))


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Stream.customTransformationWithOptions action { initialState = (), readCapacity = 5, writeCapacity = 1 }
                |> Task.andThen
                    (\t ->
                        let
                            w =
                                Stream.writable t

                            r =
                                Stream.readable t
                        in
                        Task.map2 Tuple.pair (describe (Stream.write "a" w)) (describe (Stream.write "stop" w))
                            |> Task.andThen
                                (\( wa, wstop ) ->
                                    Task.map3 (\x y z -> [ x, y, z ]) (showRead r) (showRead r) (showRead r)
                                        |> Task.andThen
                                            (\reads ->
                                                Task.map2
                                                    (\late closed ->
                                                        [ "write a: " ++ wa
                                                        , "write stop: " ++ wstop
                                                        , "reads: " ++ String.join "," reads
                                                        , "write after close: " ++ late
                                                        , "close after close: " ++ closed
                                                        ]
                                                    )
                                                    (describe (Stream.write "c" w))
                                                    (describe (Stream.closeWritable w))
                                            )
                                )
                    )
        )
