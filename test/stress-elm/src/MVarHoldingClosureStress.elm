module MVarHoldingClosureStress exposing (main)

{-| Put a partial-applied closure with heap captures into an MVar, force
    multiple minor GCs, take the closure back, and apply it. Verifies
    that the closure's unboxed bitmap and captured values survive the
    MVar scanner's encode→evacuate→decode cycle — a bitmap bug on a
    captured slot is precisely the failure shape surfaced in Stage 7.

    Closure: `\x y -> x + y + captured` with `captured = 100`, applied
    as `3 + 4 + 100 = 107`.
-}

-- CHECK: MVarHoldingClosureStress: True

import Bytes.Decode as BD
import Bytes.Encode as BE
import Eco.MVar as MV
import Platform
import Task


type Msg
    = GotResult Bool


type alias Model =
    Maybe Bool


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 100


makeAdder : Int -> (Int -> Int -> Int)
makeAdder captured =
    \x y -> x + y + captured


fnEnc : (Int -> Int -> Int) -> BE.Encoder
fnEnc _ =
    BE.unsignedInt8 0


fnDec : BD.Decoder (Int -> Int -> Int)
fnDec =
    BD.succeed (\_ _ -> 0)


heavyAlloc : Task.Task Never Int
heavyAlloc =
    Task.succeed (List.sum (List.range 1 m))


singleCycle : Task.Task Never Bool
singleCycle =
    let
        f =
            makeAdder 100
    in
    MV.new
        |> Task.andThen
            (\mv ->
                MV.put fnEnc mv f
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> heavyAlloc)
                    |> Task.andThen (\_ -> MV.take fnDec mv)
            )
        |> Task.map (\g -> g 3 4 == 107)


repeatCycle : Int -> Task.Task Never Bool
repeatCycle remaining =
    if remaining <= 0 then
        Task.succeed True

    else
        singleCycle
            |> Task.andThen
                (\ok ->
                    if ok then
                        repeatCycle (remaining - 1)

                    else
                        Task.succeed False
                )


init : () -> ( Model, Cmd Msg )
init _ =
    ( Nothing, Task.perform GotResult (repeatCycle loopCount) )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        GotResult ok ->
            let
                _ =
                    Debug.log "MVarHoldingClosureStress" ok
            in
            ( Just ok, Cmd.none )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
