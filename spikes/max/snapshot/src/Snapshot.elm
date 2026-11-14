port module Snapshot exposing (main)

{-| Writes, without MAX, every graph and every block of host bytes the spike's models make: the
MNIST variants (training step, evaluation and initial buffers), the char model (shared and
inlined), the parameter initialisation graphs and a QLoRA block. `make snapshot-graphs` keeps them
so that `make compare-graphs` can show a change to the tensor package leaves them byte-identical.
-}

import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode
import CharModel
import Finetune.Qlora as Qlora
import Graph exposing (Graph)
import Json.Encode as E
import Max
import MnistModels
import MnistNet
import Param
import Platform
import Tensor as T
import Train


port emit : E.Value -> Cmd msg


type Item
    = G String (Result (List String) Graph)
    | B String Bytes


items : List Item
items =
    List.concatMap mnist MnistModels.names
        ++ List.concatMap charlm [ { layers = 2, shared = True }, { layers = 2, shared = False } ]
        ++ [ G "param-initgraph" (Param.initGraph "init" MnistNet.params)
           , G "param-initinplace" (Param.initInPlace "init" MnistNet.params)
           , G "charlm-initinplace" (Param.initInPlace "init" (CharModel.params { layers = 2, shared = True }))
           , B "param-initial" (Param.initial MnistNet.params 42 |> List.map (Tuple.second >> padded) |> concat)
           , B "charlm-initial" (Train.initial (CharModel.params { layers = 1, shared = False }) CharModel.optimizer 1 |> List.map Tuple.second |> concat)
           , B "qlora-quantize"
                (Qlora.quantize T.float32
                    4
                    (T.dim () 2)
                    (T.dim () 4)
                    [ 0.5, -0.25, 0.125, 1.5, -2, 0, 0.75, 0.3 ]
                    |> Result.map (\q -> concat [ padded q.codes, padded q.scales ])
                    |> Result.withDefault (concat [])
                )
           ]


mnist : String -> List Item
mnist name =
    let
        v =
            MnistModels.variant name
    in
    [ G ("mnist-" ++ name ++ "-train") v.train
    , G ("mnist-" ++ name ++ "-measure") v.measure
    ]
        ++ List.map (\( n, b ) -> B ("mnist-" ++ name ++ "-initial-" ++ n) b) v.initial


charlm : { layers : Int, shared : Bool } -> List Item
charlm cfg =
    let
        tag =
            "charlm-"
                ++ (if cfg.shared then
                        "shared"

                    else
                        "inline"
                   )
    in
    [ G (tag ++ "-train") (CharModel.trainStep cfg), G (tag ++ "-validate") (CharModel.validate cfg) ]


{-| A tensor's bytes padded to 16, as the old packed blocks were, so these files stay comparable with
earlier snapshots.
-}
padded : Bytes -> Bytes
padded b =
    let
        w =
            Bytes.width b
    in
    Bytes.Encode.encode (Bytes.Encode.sequence (Bytes.Encode.bytes b :: List.repeat (modBy 16 (16 - modBy 16 w)) (Bytes.Encode.unsignedInt8 0)))


concat : List Bytes -> Bytes
concat bs =
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.bytes bs))


byteList : Bytes -> List Int
byteList b =
    BD.decode
        (BD.loop ( Bytes.width b, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    BD.succeed (BD.Done (List.reverse acc))

                else
                    BD.map (\x -> BD.Loop ( n - 1, x :: acc )) BD.unsignedInt8
            )
        )
        b
        |> Maybe.withDefault []


encode : Item -> E.Value
encode item =
    case item of
        G name (Ok g) ->
            E.object
                [ ( "name", E.string name )
                , ( "mlir", E.string (Max.toGenericText g) )
                , ( "bytecode", E.list E.int (byteList (Max.toBytecode g)) )
                ]

        G name (Err es) ->
            E.object [ ( "name", E.string name ), ( "errors", E.list E.string es ) ]

        B name b ->
            E.object [ ( "name", E.string name ), ( "bytes", E.list E.int (byteList b) ) ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.batch (List.map (encode >> emit) items) )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
