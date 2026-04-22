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
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


type alias Mvars =
    { nothing : MV.MVar (Maybe Int)
    , nil : MV.MVar (List Int)
    , vTrue : MV.MVar Bool
    , vFalse : MV.MVar Bool
    , emptyStr : MV.MVar String
    }


{-| Forces ≥ 1 minor GC by building a large throwaway list. -}
heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 8000))


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
            (\n ->
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
                                                                { nothing = n, nil = l, vTrue = t, vFalse = f, emptyStr = s }
                                                            )
                                                )
                                    )
                        )
            )


init : () -> ( Model, Cmd Msg )
init _ =
    let
        task =
            buildMvars
                |> Task.andThen
                    (\m ->
                        MV.put maybeEnc m.nothing Nothing
                            |> Task.andThen (\_ -> MV.put listEnc m.nil [])
                            |> Task.andThen (\_ -> MV.put boolEnc m.vTrue True)
                            |> Task.andThen (\_ -> MV.put boolEnc m.vFalse False)
                            |> Task.andThen (\_ -> MV.put strEnc m.emptyStr "")
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen (\_ -> heavyAlloc)
                            |> Task.andThen
                                (\_ ->
                                    MV.take maybeDec m.nothing
                                        |> Task.andThen
                                            (\vNothing ->
                                                MV.take listDec m.nil
                                                    |> Task.andThen
                                                        (\vNil ->
                                                            MV.take boolDec m.vTrue
                                                                |> Task.andThen
                                                                    (\vTrue ->
                                                                        MV.take boolDec m.vFalse
                                                                            |> Task.andThen
                                                                                (\vFalse ->
                                                                                    MV.take strDec m.emptyStr
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
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingEmbeddedConstantsAcrossGC" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
