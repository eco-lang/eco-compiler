module StreamFromListTest exposing (main)

{-| `Stream.fromList` (plans/eco-system-library.md §3.5): the values are
delivered in order and the stream is then closed; the empty list gives a
stream that is closed at once.
-}

-- CHECK: ints: 10,20,30
-- CHECK: empty: []
-- CHECK: strings: x-y
-- CHECK: after close: err Closed
-- EXIT: 0

import Stream
import StreamTestHelp
import System
import Task exposing (Task)


collect : Stream.Readable a -> Task Stream.Error (List a)
collect r =
    Stream.readUntilClosed (\v acc -> Ok (v :: acc)) [] r
        |> Task.map List.reverse


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map4
                (\ints empty strings afterClose ->
                    [ "ints: " ++ String.join "," (List.map String.fromInt ints)
                    , "empty: [" ++ String.join "," (List.map String.fromInt empty) ++ "]"
                    , "strings: " ++ String.join "-" strings
                    , "after close: " ++ afterClose
                    ]
                )
                (Stream.fromList [ 10, 20, 30 ] |> Task.andThen collect)
                (Stream.fromList [] |> Task.andThen collect |> Task.map (List.map (\() -> 0)))
                (Stream.fromList [ "x", "y" ] |> Task.andThen collect)
                (Stream.fromList [ 1 ]
                    |> Task.andThen
                        (\r ->
                            Stream.read r
                                |> Task.andThen (\_ -> StreamTestHelp.describe (Stream.read r))
                        )
                )
        )
