module MVarHoldingEmbeddedConstantsAcrossGC exposing (main)

{-| Put each embedded-constant HPointer kind into its own MVar, force
    multiple minor GCs by allocating garbage between put and take, then
    take each out and verify.

    Tests:
      - Nothing       (Const_Nothing)
      - []            (Const_Nil, empty list)
      - True / False  (Const_True / Const_False)
      - ""            (Const_EmptyString)

    Any mis-handling of the constant-tag bits during the MVar GC-root
    scanner's encode/decode roundtrip surfaces as a wrong value on
    take (or a crash in eco_resolve_hptr).
-}

-- CHECK: MVarHoldingEmbeddedConstantsAcrossGC: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import StressHarness exposing (StressFlags)
import Task


type alias Mvars =
    { nothing : MV.MVar (Maybe Int)
    , nil : MV.MVar (List Int)
    , vTrue : MV.MVar Bool
    , vFalse : MV.MVar Bool
    , emptyStr : MV.MVar String
    }


{-| Forces ≥ 1 minor GC by building a large throwaway list. -}
heavyAlloc : Int -> Task.Task Never Int
heavyAlloc size =
    Task.succeed (List.sum (List.range 1 size))


maybeEnc : Maybe Int -> BE.Encoder
maybeEnc _ =
    BE.unsignedInt8 0


maybeDec : BD.Decoder (Maybe Int)
maybeDec =
    BD.succeed Nothing


listEnc : List Int -> BE.Encoder
listEnc _ =
    BE.unsignedInt8 0


listDec : BD.Decoder (List Int)
listDec =
    BD.succeed []


boolEnc : Bool -> BE.Encoder
boolEnc _ =
    BE.unsignedInt8 0


boolDec : BD.Decoder Bool
boolDec =
    BD.succeed False


strEnc : String -> BE.Encoder
strEnc _ =
    BE.unsignedInt8 0


strDec : BD.Decoder String
strDec =
    BD.succeed ""


buildMvars : Task.Task Never Mvars
buildMvars =
    MV.new
        |> Task.andThen
            (\nv ->
                MV.new
                    |> Task.andThen
                        (\l ->
                            MV.new
                                |> Task.andThen
                                    (\t ->
                                        MV.new
                                            |> Task.andThen
                                                (\f ->
                                                    MV.new
                                                        |> Task.map
                                                            (\s ->
                                                                { nothing = nv, nil = l, vTrue = t, vFalse = f, emptyStr = s }
                                                            )
                                                )
                                    )
                        )
            )


cycle : Int -> Task.Task Never Bool
cycle size =
    buildMvars
        |> Task.andThen
            (\mv ->
                MV.put maybeEnc mv.nothing Nothing
                    |> Task.andThen (\_ -> MV.put listEnc mv.nil [])
                    |> Task.andThen (\_ -> MV.put boolEnc mv.vTrue True)
                    |> Task.andThen (\_ -> MV.put boolEnc mv.vFalse False)
                    |> Task.andThen (\_ -> MV.put strEnc mv.emptyStr "")
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen (\_ -> heavyAlloc size)
                    |> Task.andThen
                        (\_ ->
                            MV.take maybeDec mv.nothing
                                |> Task.andThen
                                    (\vNothing ->
                                        MV.take listDec mv.nil
                                            |> Task.andThen
                                                (\vNil ->
                                                    MV.take boolDec mv.vTrue
                                                        |> Task.andThen
                                                            (\vTrue ->
                                                                MV.take boolDec mv.vFalse
                                                                    |> Task.andThen
                                                                        (\vFalse ->
                                                                            MV.take strDec mv.emptyStr
                                                                                |> Task.map
                                                                                    (\vEmptyStr ->
                                                                                        vNothing == Nothing && vNil == [] && vTrue == True && vFalse == False && vEmptyStr == ""
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


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
        { label = "MVarHoldingEmbeddedConstantsAcrossGC"
        , run = run
        }
