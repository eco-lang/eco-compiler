port module TensorBytes exposing (main)

{-| Spike fixture, bytes-port version of TensorService: Elm sends one Bytes laid out as
[ w (k*n f32) | b (n f32) | x (batch*k f32) ], little-endian; the host runs relu(x @ w + b) on
those bytes in place and emits y (batch*n f32) back on yIn; Elm checks y against its reference.
-}

import Array
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Platform


port xOut : Bytes -> Cmd msg


port yIn : (Bytes -> msg) -> Sub msg


port resultOut : String -> Cmd msg


type Msg
    = Got Bytes


k : Int
k =
    4


n : Int
n =
    3


xs : Int -> List Float
xs batch =
    List.map (\i -> toFloat (modBy 17 (i * 37) - 8) / 4) (List.range 0 (batch * k - 1))


ws : List Float
ws =
    List.map (\i -> toFloat (modBy 7 (i * 11) - 3) / 2) (List.range 0 (k * n - 1))


bs : List Float
bs =
    List.map (\i -> toFloat i - 1) (List.range 0 (n - 1))


reference : Int -> List Float
reference batch =
    let
        x =
            Array.fromList (xs batch)

        w =
            Array.fromList ws

        b =
            Array.fromList bs

        get a i =
            Maybe.withDefault 0 (Array.get i a)

        cell r c =
            max 0 (List.foldl (\kk acc -> acc + get x (r * k + kk) * get w (kk * n + c)) (get b c) (List.range 0 (k - 1)))
    in
    List.concatMap (\r -> List.map (cell r) (List.range 0 (n - 1))) (List.range 0 (batch - 1))


send : Int -> Cmd Msg
send batch =
    xOut (Encode.encode (Encode.sequence (List.map (Encode.float32 LE) (ws ++ bs ++ xs batch))))


floats : Int -> Decode.Decoder (List Float)
floats count =
    Decode.loop ( count, [] )
        (\( left, acc ) ->
            if left <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.map (\f -> Decode.Loop ( left - 1, f :: acc )) (Decode.float32 LE)
        )


type alias Model =
    { batch : Int, pending : List Int }


init : () -> ( Model, Cmd Msg )
init _ =
    case batches of
        first :: rest ->
            ( { batch = first, pending = rest }, send first )

        [] ->
            ( { batch = 0, pending = [] }, resultOut "done" )


batches : List Int
batches =
    [ 1, 7, 1024, 4096 ]


update : Msg -> Model -> ( Model, Cmd Msg )
update (Got bytes) model =
    let
        count =
            Bytes.width bytes // 4

        report =
            case Decode.decode (floats count) bytes of
                Just y ->
                    let
                        ref =
                            reference model.batch

                        err =
                            List.foldl max 0 (List.map2 (\a e -> abs (a - e)) y ref)
                    in
                    "ELM batch="
                        ++ String.fromInt model.batch
                        ++ " len="
                        ++ String.fromInt (List.length y)
                        ++ (if List.length y == List.length ref && err < 1.0e-4 then
                                " OK"

                            else
                                " BAD"
                           )
                        ++ " maxErr="
                        ++ String.fromFloat err

                Nothing ->
                    "ELM decode failed for " ++ String.fromInt (Bytes.width bytes) ++ " bytes"
    in
    case model.pending of
        next :: rest ->
            ( { batch = next, pending = rest }, Cmd.batch [ resultOut report, send next ] )

        [] ->
            ( model, Cmd.batch [ resultOut report, resultOut "done" ] )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> yIn Got
        }
