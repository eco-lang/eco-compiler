module StreamIdentityRoundTripTest exposing (main)

{-| Values written into an identity transformation come out of its readable
side unchanged and in order (plans/eco-system-library.md §3.5), for boxed and
unboxed element types.
-}

-- CHECK: ints: 1,2,3
-- CHECK: strings: <a>,<bc>,<>
-- CHECK: records: 3x,7y
-- CHECK: default capacity: 42
-- EXIT: 0

import Stream
import StreamTestHelp
import System
import Task exposing (Task)


roundTrip : List a -> Task Stream.Error (List a)
roundTrip values =
    Stream.identityTransformationWithOptions { readCapacity = 8, writeCapacity = 8 }
        |> Task.andThen
            (\t ->
                List.foldl (\v acc -> acc |> Task.andThen (Stream.write v)) (Task.succeed (Stream.writable t)) values
                    |> Task.andThen (\_ -> readN (List.length values) (Stream.readable t) [])
            )


readN : Int -> Stream.Readable a -> List a -> Task Stream.Error (List a)
readN n r acc =
    if n <= 0 then
        Task.succeed (List.reverse acc)

    else
        Stream.read r |> Task.andThen (\v -> readN (n - 1) r (v :: acc))


main : System.SimpleProgram ()
main =
    StreamTestHelp.program
        (\_ ->
            Task.map4
                (\ints strings records single ->
                    [ "ints: " ++ String.join "," (List.map String.fromInt ints)
                    , "strings: " ++ String.join "," (List.map (\s -> "<" ++ s ++ ">") strings)
                    , "records: " ++ String.join "," (List.map (\r -> String.fromInt r.n ++ r.s) records)
                    , "default capacity: " ++ String.fromInt single
                    ]
                )
                (roundTrip [ 1, 2, 3 ])
                (roundTrip [ "a", "bc", "" ])
                (roundTrip [ { n = 3, s = "x" }, { n = 7, s = "y" } ])
                (Stream.identityTransformation
                    |> Task.andThen
                        (\t ->
                            Stream.write 42 (Stream.writable t)
                                |> Task.andThen (\_ -> Stream.read (Stream.readable t))
                        )
                )
        )
