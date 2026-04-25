module MVarChanPipelineStress exposing (main)

{-| Build an unbounded channel out of two MVars (the read-end and the
    write-end), both holding a "tail pointer" into a lazy Cons stream
    realised via MVars. Push N items, then pull N items, verify the
    pulled sequence matches the pushed sequence.

    The `Chan` primitive that `Utils.Main.newChan` constructs has this
    exact shape; exercising it directly stresses the MVar-of-MVar
    interaction at scale.

    Simplification vs the compiler's `Chan`: here we encode the stream
    as a plain queue built from `MVar (List Int)` so the write-end and
    read-end are explicit. This keeps the test focused on the kernel
    semantics without the extra Stream ADT.
-}

-- CHECK: MVarChanPipelineStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


listEnc : List Int -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List Int)
listDec =
    BD.succeed []


smallAlloc : Int -> Task.Task Never Int
smallAlloc size =
    Task.succeed (List.sum (List.range 1 (size // 8)))


push : MV.MVar (List Int) -> Int -> Task.Task Never ()
push chan v =
    MV.take listDec chan
        |> Task.andThen (\xs -> MV.put listEnc chan (xs ++ [ v ]))


pushMany : Int -> MV.MVar (List Int) -> Int -> Task.Task Never ()
pushMany size chan i =
    if i > size then
        Task.succeed ()

    else
        push chan i
            |> Task.andThen (\_ -> smallAlloc size)
            |> Task.andThen (\_ -> pushMany size chan (i + 1))


cycle : Int -> Task.Task Never Bool
cycle size =
    MV.new
        |> Task.andThen
            (\chan ->
                MV.put listEnc chan []
                    |> Task.andThen (\_ -> pushMany size chan 1)
                    |> Task.andThen (\_ -> MV.take listDec chan)
            )
        |> Task.map (\xs -> xs == List.range 1 size)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> cycle flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MVarChanPipelineStress"
        , run = run
        }
