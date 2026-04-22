module MVarHoldingClosureDirectTest exposing (main)

{-| Put a heap-allocated closure (a partial application with captures)
    into an MVar, take it back, apply it, and verify the result. The
    value stored is a `Tag_Closure` object with its own unboxed bitmap;
    a regression that mis-handled closure shapes through the kernel's
    HPointer storage would either crash on apply or return the wrong
    value.

    Closure under test: `\x y -> x + y + captured` with `captured = 100`.
    We apply it as 3 + 4 + 100 = 107.
-}

-- CHECK: MVarHoldingClosureDirectTest: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


{-| The payload closure. The `captured` binding forces it to be heap
    allocated with a real environment slot (not a compile-time constant
    reduction). -}
makeAdder : Int -> (Int -> Int -> Int)
makeAdder captured =
    \x y -> x + y + captured


fnEnc : (Int -> Int -> Int) -> BE.Encoder
fnEnc _ =
    BE.unsignedInt8 0


fnDec : BD.Decoder (Int -> Int -> Int)
fnDec =
    BD.succeed (\_ _ -> 0)


init : () -> ( Model, Cmd Msg )
init _ =
    let
        f =
            makeAdder 100

        task =
            MV.new
                |> Task.andThen
                    (\m ->
                        MV.put fnEnc m f
                            |> Task.andThen (\_ -> MV.take fnDec m)
                    )
                |> Task.map (\g -> g 3 4 == 107)
    in
    ( Nothing, Task.perform GotResult task )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingClosureDirectTest" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
