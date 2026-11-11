module Mnist exposing (main)

{-| Training a neural network on MNIST with Elm and MAX.

Elm describes the network as a compute graph, derives the training step's gradients itself (MAX
has no autodiff), owns the parameters and the data, and runs the training loop. MAX compiles the
two graphs Elm prints, a training step and an evaluation, and executes them.

-}

import Array exposing (Array)
import Bridge exposing (TensorSpec)
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Dict exposing (Dict)
import Graph exposing (DType(..), Graph, Ref)
import Json.Decode as D
import MlirBc
import Platform



-- THE NETWORK


hidden : Int
hidden =
    128


batchSize : Int
batchSize =
    100


testSize : Int
testSize =
    10000


learningRate : Float
learningRate =
    0.1


epochs : Int
epochs =
    5


type alias Params a =
    { w1 : a, b1 : a, w2 : a, b2 : a }


paramSpecs : List TensorSpec
paramSpecs =
    [ { name = "w1", dtype = F32, shape = [ 784, hidden ] }
    , { name = "b1", dtype = F32, shape = [ hidden ] }
    , { name = "w2", dtype = F32, shape = [ hidden, 10 ] }
    , { name = "b2", dtype = F32, shape = [ 10 ] }
    ]


{-| The parameters as graph inputs.
-}
paramInputs : Graph -> ( Graph, Params Ref )
paramInputs g0 =
    let
        ( g1, w1 ) =
            Graph.input "w1" F32 [ 784, hidden ] g0

        ( g2, b1 ) =
            Graph.input "b1" F32 [ hidden ] g1

        ( g3, w2 ) =
            Graph.input "w2" F32 [ hidden, 10 ] g2

        ( g4, b2 ) =
            Graph.input "b2" F32 [ 10 ] g3
    in
    ( g4, { w1 = w1, b1 = b1, w2 = w2, b2 = b2 } )


{-| 784 pixels (bytes 0-255) → 128 ReLU units → 10 class scores.
-}
forward : Params Ref -> Ref -> Graph -> ( Graph, Ref )
forward p pixels g0 =
    let
        ( g1, x ) =
            Graph.cast F32 pixels g0

        ( g2, scale ) =
            Graph.constF (1 / 255) g1

        ( g3, xs ) =
            Graph.mul x scale g2

        ( g4, z1 ) =
            Graph.matmul xs p.w1 g3

        ( g5, a1 ) =
            Graph.add z1 p.b1 g4

        ( g6, h ) =
            Graph.relu a1 g5

        ( g7, z2 ) =
            Graph.matmul h p.w2 g6
    in
    Graph.add z2 p.b2 g7


{-| Labels (bytes 0-9) as one-hot f32 rows.
-}
oneHot : Int -> Ref -> Graph -> ( Graph, Ref )
oneHot n labels g0 =
    let
        ( g1, l ) =
            Graph.cast SI64 labels g0

        ( g2, column ) =
            Graph.reshape [ n, 1 ] l g1

        ( g3, classes ) =
            Graph.range 10 g2

        ( g4, hit ) =
            Graph.equal column classes g3
    in
    Graph.cast F32 hit g4


{-| One step of stochastic gradient descent: the parameters and a batch in, the updated
parameters and the batch's loss out.
-}
trainStep : Built
trainStep =
    let
        ( g1, p ) =
            paramInputs Graph.empty

        ( g2, x ) =
            Graph.input "x" UI8 [ batchSize, 784 ] g1

        ( g3, y ) =
            Graph.input "y" UI8 [ batchSize ] g2

        ( g4, logits ) =
            forward p x g3

        ( g5, target ) =
            oneHot batchSize y g4

        ( g6, loss ) =
            Graph.softmaxXentLoss logits target g5

        ( g7, grads ) =
            Graph.grad loss [ p.w1, p.b1, p.w2, p.b2 ] g6

        ( g8, lr ) =
            Graph.constF learningRate g7

        descend ( param, gradient ) ( g, acc ) =
            let
                ( ga, s ) =
                    Graph.mul gradient lr g

                ( gb, new ) =
                    Graph.sub param s ga
            in
            ( gb, acc ++ [ new ] )

        ( g9, updated ) =
            List.foldl descend ( g8, [] ) (List.map2 Tuple.pair [ p.w1, p.b1, p.w2, p.b2 ] grads)
    in
    { name = "train_step"
    , inputs = [ ( "w1", p.w1 ), ( "b1", p.b1 ), ( "w2", p.w2 ), ( "b2", p.b2 ), ( "x", x ), ( "y", y ) ]
    , outputs = List.map2 Tuple.pair [ "w1_next", "b1_next", "w2_next", "b2_next" ] updated ++ [ ( "loss", loss ) ]
    , graph = g9
    }


{-| How many of the test images the network classifies correctly.
-}
evaluate : Built
evaluate =
    let
        ( g1, p ) =
            paramInputs Graph.empty

        ( g2, x ) =
            Graph.input "x" UI8 [ testSize, 784 ] g1

        ( g3, y ) =
            Graph.input "y" UI8 [ testSize ] g2

        ( g4, logits ) =
            forward p x g3

        ( g5, guess ) =
            Graph.argMax 1 logits g4

        ( g6, l ) =
            Graph.cast SI64 y g5

        ( g7, truth ) =
            Graph.reshape [ testSize, 1 ] l g6

        ( g8, right ) =
            Graph.equal guess truth g7

        ( g9, ones ) =
            Graph.cast F32 right g8

        ( g10, correct ) =
            Graph.reduceAdd 0 ones g9
    in
    { name = "evaluate"
    , inputs = [ ( "w1", p.w1 ), ( "b1", p.b1 ), ( "w2", p.w2 ), ( "b2", p.b2 ), ( "x", x ), ( "y", y ) ]
    , outputs = [ ( "correct", correct ) ]
    , graph = g10
    }



-- WRITING THE GRAPHS


{-| A finished graph with its named inputs and outputs, before it is written out.
-}
type alias Built =
    { name : String, inputs : List ( String, Ref ), outputs : List ( String, Ref ), graph : Graph }


{-| How graphs go to MAX: MLIR bytecode written in Elm (`MlirBc`), the same ops as MLIR generic
text, or MAX's custom `mo` syntax (`Graph.print`).
-}
type Format
    = Bytecode
    | GenericText
    | MoText


formatName : Format -> String
formatName format =
    case format of
        Bytecode ->
            "bytecode"

        GenericText ->
            "generic"

        MoText ->
            "text"


render : Format -> Built -> Result (List String) Bytes
render format b =
    let
        text s =
            Encode.encode (Encode.string s)
    in
    case format of
        Bytecode ->
            Graph.toModule b.name b.inputs b.outputs b.graph |> Result.map (\op -> MlirBc.encode [ op ])

        GenericText ->
            Graph.toModule b.name b.inputs b.outputs b.graph |> Result.map (\op -> text (MlirBc.printGeneric [ op ]))

        MoText ->
            Graph.print b.name b.inputs b.outputs b.graph |> Result.map text



-- INITIAL PARAMETERS


{-| A 32-bit linear congruential generator: enough randomness for weight init and shuffling.
-}
next : Int -> Int
next seed =
    modBy 4294967296 (1664525 * seed + 1013904223)


{-| He-uniform weights for a layer with `fanIn` inputs, as f32 bytes, and the seed after them.
-}
uniformWeights : Int -> Int -> Int -> ( Bytes, Int )
uniformWeights fanIn count seed0 =
    let
        bound =
            sqrt (6 / toFloat fanIn)

        go k seed acc =
            if k == 0 then
                ( acc, seed )

            else
                let
                    s =
                        next seed

                    u =
                        toFloat s / 4294967296
                in
                go (k - 1) s (Encode.float32 LE ((2 * u - 1) * bound) :: acc)

        ( encoders, seedOut ) =
            go count seed0 []
    in
    ( Encode.encode (Encode.sequence encoders), seedOut )


zeros : Int -> Bytes
zeros count =
    Encode.encode (Encode.sequence (List.repeat count (Encode.float32 LE 0)))


{-| The packed parameter block: w1, b1, w2, b2, each padded to 16 bytes.
-}
initialParams : Int -> Bytes
initialParams seed0 =
    let
        ( w1, seed1 ) =
            uniformWeights 784 (784 * hidden) seed0

        ( w2, _ ) =
            uniformWeights hidden (hidden * 10) seed1
    in
    Encode.encode (Encode.sequence (List.map Bridge.packed [ w1, zeros hidden, w2, zeros 10 ]))


paramBlockSize : Int
paramBlockSize =
    List.sum (List.map (\s -> Bridge.paddedSize (4 * List.product s.shape)) paramSpecs)


{-| `list` in a random order (Fisher-Yates), and the seed after it.
-}
shuffle : Int -> List Int -> ( List Int, Int )
shuffle seed0 list =
    let
        go i seed arr =
            if i <= 0 then
                ( Array.toList arr, seed )

            else
                let
                    s =
                        next seed

                    j =
                        modBy (i + 1) s

                    vi =
                        Maybe.withDefault 0 (Array.get i arr)

                    vj =
                        Maybe.withDefault 0 (Array.get j arr)
                in
                go (i - 1) s (Array.set j vi (Array.set i vj arr))
    in
    go (List.length list - 1) seed0 (Array.fromList list)



-- THE TRAINING LOOP


trainId : Int
trainId =
    1


evalId : Int
evalId =
    2


type alias Model =
    { files : Dict Int Bytes
    , compiled : List Int
    , params : Bytes
    , epoch : Int
    , batches : List Int
    , lossSum : Float
    , steps : Int
    , seed : Int
    }


type Msg
    = Loaded Bytes
    | Compiled D.Value
    | Ran Bytes


files : List ( Int, String )
files =
    [ ( 1, "train-images-idx3-ubyte" )
    , ( 2, "train-labels-idx1-ubyte" )
    , ( 3, "t10k-images-idx3-ubyte" )
    , ( 4, "t10k-labels-idx1-ubyte" )
    ]


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        dir =
            Result.withDefault "." (D.decodeValue (D.field "dataDir" D.string) flags)

        format =
            List.filter (\f -> D.decodeValue (D.field "format" D.string) flags == Ok (formatName f)) [ GenericText, MoText ]
                |> List.head
                |> Maybe.withDefault Bytecode

        compileBoth =
            case ( render format trainStep, render format evaluate ) of
                ( Ok train, Ok eval ) ->
                    [ Bridge.log
                        ("graphs built and checked in Elm, as "
                            ++ formatName format
                            ++ ": train_step "
                            ++ String.fromInt (Bytes.width train)
                            ++ " bytes, evaluate "
                            ++ String.fromInt (Bytes.width eval)
                            ++ " bytes"
                        )
                    , Bridge.compile trainId
                        (paramSpecs ++ [ { name = "x", dtype = UI8, shape = [ batchSize, 784 ] }, { name = "y", dtype = UI8, shape = [ batchSize ] } ])
                        (List.map (\s -> { s | name = s.name ++ "_next" }) paramSpecs ++ [ { name = "loss", dtype = F32, shape = [ 1, 1 ] } ])
                        train
                    , Bridge.compile evalId
                        (paramSpecs ++ [ { name = "x", dtype = UI8, shape = [ testSize, 784 ] }, { name = "y", dtype = UI8, shape = [ testSize ] } ])
                        [ { name = "correct", dtype = F32, shape = [ 1, 1 ] } ]
                        eval
                    ]

                ( train, eval ) ->
                    [ Bridge.log ("graph errors: " ++ String.join "; " (errors train ++ errors eval)), Bridge.done 1 ]
    in
    ( { files = Dict.empty
      , compiled = []
      , params = initialParams 42
      , epoch = 0
      , batches = []
      , lossSum = 0
      , steps = 0
      , seed = 7
      }
    , Cmd.batch (compileBoth ++ List.map (\( id, f ) -> Bridge.load id (dir ++ "/" ++ f)) files)
    )


errors : Result (List String) a -> List String
errors r =
    case r of
        Err e ->
            e

        Ok _ ->
            []


file : Int -> Model -> Bytes
file id model =
    Maybe.withDefault (Encode.encode (Encode.sequence [])) (Dict.get id model.files)


{-| Images start after a 16-byte IDX header, labels after an 8-byte one.
-}
trainBatch : Int -> Model -> Cmd Msg
trainBatch index model =
    Bridge.run trainId
        [ Encode.bytes model.params
        , Bridge.packed (Bridge.slice (16 + index * batchSize * 784) (batchSize * 784) (file 1 model))
        , Bridge.packed (Bridge.slice (8 + index * batchSize) batchSize (file 2 model))
        ]


evaluateTest : Model -> Cmd Msg
evaluateTest model =
    Bridge.run evalId
        [ Encode.bytes model.params
        , Bridge.packed (Bridge.slice 16 (testSize * 784) (file 3 model))
        , Bridge.packed (Bridge.slice 8 testSize (file 4 model))
        ]


ready : Model -> Bool
ready model =
    Dict.size model.files == 4 && List.length model.compiled == 2


{-| Starts epoch `model.epoch + 1` on a fresh shuffle of the 600 batches.
-}
startEpoch : Model -> ( Model, Cmd Msg )
startEpoch model =
    let
        ( order, seed ) =
            shuffle model.seed (List.range 0 (60000 // batchSize - 1))
    in
    case order of
        first :: rest ->
            ( { model | epoch = model.epoch + 1, batches = rest, lossSum = 0, steps = 0, seed = seed }
            , trainBatch first model
            )

        [] ->
            ( model, Bridge.done 1 )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Loaded bytes ->
            let
                m =
                    { model | files = Dict.insert (Bridge.headerId bytes) (Bridge.slice 16 (Bytes.width bytes - 16) bytes) model.files }
            in
            ( m, whenReady m )

        Compiled v ->
            case D.decodeValue (D.map2 Tuple.pair (D.field "id" D.int) (D.field "ok" D.bool)) v of
                Ok ( id, True ) ->
                    let
                        m =
                            { model | compiled = id :: model.compiled }
                    in
                    ( m, whenReady m )

                _ ->
                    ( model, Cmd.batch [ Bridge.log "compile failed", Bridge.done 1 ] )

        Ran bytes ->
            if Bridge.headerId bytes == trainId then
                let
                    loss =
                        Maybe.withDefault 0 (Decode.decode (Decode.float32 LE) (Bridge.slice (16 + paramBlockSize) 4 bytes))

                    m =
                        { model
                            | params = Bridge.slice 16 paramBlockSize bytes
                            , lossSum = model.lossSum + loss
                            , steps = model.steps + 1
                        }
                in
                case m.batches of
                    index :: rest ->
                        ( { m | batches = rest }, trainBatch index m )

                    [] ->
                        ( m, evaluateTest m )

            else
                let
                    correct =
                        round (Maybe.withDefault 0 (Decode.decode (Decode.float32 LE) (Bridge.slice 16 4 bytes)))

                    report =
                        "epoch "
                            ++ String.fromInt model.epoch
                            ++ ": "
                            ++ (if model.steps > 0 then
                                    "mean train loss " ++ String.left 6 (String.fromFloat (model.lossSum / toFloat model.steps)) ++ ", "

                                else
                                    "untrained, "
                               )
                            ++ "test accuracy "
                            ++ String.fromFloat (toFloat correct / 100)
                            ++ "% ("
                            ++ String.fromInt correct
                            ++ "/10000)"
                in
                if model.epoch >= epochs then
                    ( model, Cmd.batch [ Bridge.log report, Bridge.done 0 ] )

                else
                    let
                        ( m, cmd ) =
                            startEpoch model
                    in
                    ( m, Cmd.batch [ Bridge.log report, cmd ] )


{-| Once the data is in and both graphs are compiled, evaluate the untrained network first.
-}
whenReady : Model -> Cmd Msg
whenReady model =
    if ready model then
        evaluateTest model

    else
        Cmd.none


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.batch [ Bridge.loadIn Loaded, Bridge.compiledIn Compiled, Bridge.runIn Ran ]
        }
