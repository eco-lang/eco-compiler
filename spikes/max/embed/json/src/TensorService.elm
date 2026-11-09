port module TensorService exposing (main)

{-| Spike fixture: Elm builds the inputs of relu(x @ w + b), the host runs them through MAX and
sends y back, and Elm checks y against its own reference. Batches 1, 7 and 1024, then "done".
-}

import Array exposing (Array)
import Json.Decode as D
import Json.Encode as E
import Platform


port xOut : E.Value -> Cmd msg


port yIn : (D.Value -> msg) -> Sub msg


port resultOut : String -> Cmd msg


type Msg
    = Got D.Value


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
    xOut
        (E.object
            [ ( "batch", E.int batch )
            , ( "x", E.list E.float (xs batch) )
            , ( "w", E.list E.float ws )
            , ( "b", E.list E.float bs )
            ]
        )


type alias Model =
    List Int


init : () -> ( Model, Cmd Msg )
init _ =
    ( [ 7, 1024 ], send 1 )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Got v) pending =
    let
        reply =
            D.decodeValue (D.map2 Tuple.pair (D.field "batch" D.int) (D.field "y" (D.list D.float))) v

        report =
            case reply of
                Ok ( batch, y ) ->
                    let
                        ref =
                            reference batch

                        err =
                            List.foldl max 0 (List.map2 (\a e -> abs (a - e)) y ref)
                    in
                    "ELM batch="
                        ++ String.fromInt batch
                        ++ " len="
                        ++ String.fromInt (List.length y)
                        ++ (if List.length y == List.length ref && err < 1.0e-4 then
                                " OK"

                            else
                                " BAD"
                           )
                        ++ " maxErr="
                        ++ String.fromFloat err

                Err e ->
                    "ELM decode error: " ++ D.errorToString e
    in
    case pending of
        next :: rest ->
            ( rest, Cmd.batch [ resultOut report, send next ] )

        [] ->
            ( [], Cmd.batch [ resultOut report, resultOut "done" ] )


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> yIn Got
        }
