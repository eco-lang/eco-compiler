module MVarBackgroundWriterLikeStress exposing (main)

{-| Reproduces `Builder.BackgroundWriter`'s `addMVarToWorkList` /
    `waitForAllWork` shape:

      workList : MVar (List (MVar ()))

    The loop creates a new inner MVar, takes the outer list, prepends
    the new MVar, puts the list back — the closest in-process match to
    the Stage 7 crash site. At the end we verify the list length
    matches the iteration count.

    This is the highest-value stress for reproducing the Stage 7 bug.
-}

-- CHECK: MVarBackgroundWriterLikeStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.IO.Error exposing (IOError)
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


unitEnc : () -> BE.Encoder
unitEnc _ =
    BE.unsignedInt8 0


unitDec : BD.Decoder ()
unitDec =
    BD.succeed ()


listEnc : List (MV.MVar ()) -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List (MV.MVar ()))
listDec =
    BD.succeed []


smallAlloc : Int -> Task.Task IOError Int
smallAlloc size =
    Task.succeed (List.sum (List.range 1 size))


addOne : MV.MVar (List (MV.MVar ())) -> Task.Task IOError ()
addOne workList =
    MV.new
        |> Task.andThen
            (\inner ->
                MV.take listDec workList
                    |> Task.andThen
                        (\xs -> MV.put listEnc workList (inner :: xs))
            )


loop : Int -> MV.MVar (List (MV.MVar ())) -> Int -> Task.Task IOError ()
loop size workList remaining =
    if remaining <= 0 then
        Task.succeed ()

    else
        addOne workList
            |> Task.andThen (\_ -> smallAlloc size)
            |> Task.andThen (\_ -> loop size workList (remaining - 1))


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
            (\workList ->
                MV.put listEnc workList []
                    |> Task.andThen (\_ -> loop size workList count)
                    |> Task.andThen (\_ -> MV.take listDec workList)
            )
        |> Task.map (\xs -> List.length xs == count)
        |> Task.onError (\_ -> Task.succeed False)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarBackgroundWriterLikeStress"
        , run = run
        }
