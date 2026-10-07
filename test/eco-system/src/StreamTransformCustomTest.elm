module StreamTransformCustomTest exposing (main)

{-| `customTransformation` and `nullTransformation`
(plans/eco-system-library.md §3.5, Phase 6 step 6.3): an upper-casing
transform with a running count in its state; `Send` with several values; a
transform over Ints (unboxed in the action's output list); a null
transformation drops everything and closes when its writable closes.
-}

-- CHECK: upper: 1:HELLO,2:WORLD
-- CHECK: split: a,b,c,d
-- CHECK: ints: 10,20,30
-- CHECK: null: [] closed
-- EXIT: 0

import Stream
import StreamCodecHelp exposing (readAll)
import StreamTestHelp
import System
import Task exposing (Task)


upper : Int -> String -> Stream.CustomTransformationAction Int String
upper count value =
    Stream.Send { state = count + 1, send = [ String.fromInt (count + 1) ++ ":" ++ String.toUpper value ] }


upperCase : Task Stream.Error String
upperCase =
    Stream.customTransformation upper 0
        |> Task.andThen
            (\t ->
                Stream.write "hello" (Stream.writable t)
                    |> Task.andThen (\_ -> Stream.read (Stream.readable t))
                    |> Task.andThen
                        (\a ->
                            Stream.write "world" (Stream.writable t)
                                |> Task.andThen Stream.closeWritable
                                |> Task.andThen (\_ -> readAll (Stream.readable t))
                                |> Task.map (\rest -> String.join "," (a :: rest))
                        )
            )


splitChars : () -> String -> Stream.CustomTransformationAction () String
splitChars state value =
    Stream.Send { state = state, send = String.split "" value }


split : Task Stream.Error String
split =
    Stream.customTransformationWithOptions splitChars { initialState = (), readCapacity = 10, writeCapacity = 1 }
        |> Task.andThen
            (\t ->
                Stream.write "abcd" (Stream.writable t)
                    |> Task.andThen Stream.closeWritable
                    |> Task.andThen (\_ -> readAll (Stream.readable t))
                    |> Task.map (String.join ",")
            )


times10 : () -> Int -> Stream.CustomTransformationAction () Int
times10 state value =
    Stream.Send { state = state, send = [ value * 10 ] }


ints : Task Stream.Error String
ints =
    Stream.fromList [ 1, 2, 3 ]
        |> Task.andThen (Stream.awaitAndPipeThrough (Stream.customTransformation times10 ()))
        |> Task.andThen readAll
        |> Task.map (List.map String.fromInt >> String.join ",")


null : Task Stream.Error String
null =
    Stream.nullTransformation "ignored"
        |> Task.andThen
            (\t ->
                Stream.write "x" (Stream.writable t)
                    |> Task.andThen (Stream.write "y")
                    |> Task.andThen Stream.closeWritable
                    |> Task.andThen (\_ -> readAll (Stream.readable t))
                    |> Task.map (\values -> "[" ++ String.join "," values ++ "] closed")
            )


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.sequence
                [ upperCase |> Task.map (\r -> "upper: " ++ r)
                , split |> Task.map (\r -> "split: " ++ r)
                , ints |> Task.map (\r -> "ints: " ++ r)
                , null |> Task.map (\r -> "null: " ++ r)
                ]
        )
