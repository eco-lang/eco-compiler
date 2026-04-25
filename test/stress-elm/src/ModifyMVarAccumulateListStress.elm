module ModifyMVarAccumulateListStress exposing (main)

{-| Same take/put shape as `ModifyMVarCounterStress`, but the payload
    is a growing `List String`: each iteration takes the list out,
    prepends a freshly-allocated String, and puts it back. The stored
    graph expands linearly, so the scanner's re-encode/evacuate cost
    climbs across GCs.

    End state: list length == n, head is the last-pushed value.
-}

-- CHECK: ModifyMVarAccumulateListStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


listEnc : List String -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List String)
listDec =
    BD.succeed []


smallAlloc : Int -> Task.Task Never Int
smallAlloc size =
    Task.succeed (List.sum (List.range 1 size))


prependOne : Int -> MV.MVar (List String) -> Int -> Task.Task Never ()
prependOne size mvar i =
    MV.take listDec mvar
        |> Task.andThen
            (\xs ->
                let
                    s =
                        "v" ++ String.fromInt i
                in
                MV.put listEnc mvar (s :: xs)
                    |> Task.andThen (\_ -> smallAlloc size |> Task.map (\_ -> ()))
            )


loop : Int -> Int -> MV.MVar (List String) -> Int -> Task.Task Never ()
loop count size mvar i =
    if i > count then
        Task.succeed ()

    else
        prependOne size mvar i
            |> Task.andThen (\_ -> loop count size mvar (i + 1))


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        count =
            flags.numLoops

        size =
            flags.maxSize
    in
    MV.new
        |> Task.andThen
            (\mvar ->
                MV.put listEnc mvar []
                    |> Task.andThen (\_ -> loop count size mvar 1)
                    |> Task.andThen (\_ -> MV.take listDec mvar)
            )
        |> Task.map
            (\xs ->
                List.length xs == count && List.head xs == Just ("v" ++ String.fromInt count)
            )


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ModifyMVarAccumulateListStress"
        , run = run
        }
