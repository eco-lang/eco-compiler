module Mnist exposing (main)

{-| Training a neural network on MNIST with Elm and MAX.

The network and its training step are `MnistNet`, written with tensors (`Tensor`); Elm derives the
gradients itself (MAX has no autodiff). This module owns the parameters and the data and runs the
training loop: MAX compiles the two graphs Elm writes, a training step and an evaluation, and
executes them.

-}

import Array exposing (Array)
import Bridge
import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Dict exposing (Dict)
import Graph
import Json.Decode as D
import MlirBc
import MnistNet as Net exposing (batchSize, epochs, testSize)
import Param
import Platform
import Tensor as T
import Train



-- WRITING THE GRAPHS


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


render : Format -> T.Graph -> Result (List String) Bytes
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
                        Param.lcg seed

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
            case ( Result.andThen (render format) Net.trainStep, Result.andThen (render format) Net.evaluate ) of
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
                    , compileGraph trainId Net.trainStep train
                    , compileGraph evalId Net.evaluate eval
                    ]

                ( train, eval ) ->
                    [ Bridge.log ("graph errors: " ++ String.join "; " (errors train ++ errors eval)), Bridge.done 1 ]
    in
    ( { files = Dict.empty
      , compiled = []
      , params = Param.initial Net.params 42
      , epoch = 0
      , batches = []
      , lossSum = 0
      , steps = 0
      , seed = 7
      }
    , Cmd.batch (compileBoth ++ List.map (\( id, f ) -> Bridge.load id (dir ++ "/" ++ f)) files)
    )


{-| Sends a checked graph's bytes with the input and output specs it carries.
-}
compileGraph : Int -> Result (List String) T.Graph -> Bytes -> Cmd Msg
compileGraph id built bytes =
    case built of
        Ok g ->
            Bridge.compile id g.inputSpecs g.outputSpecs bytes

        Err _ ->
            Cmd.none


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
                    ( newParams, loss ) =
                        Train.stepReply Net.params bytes

                    m =
                        { model
                            | params = newParams
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
                        round (Train.measureReply bytes)

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
