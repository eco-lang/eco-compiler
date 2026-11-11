module Mnist exposing (main)

{-| Training a neural network on MNIST with Elm and MAX.

The network and its training step are `MnistNet`, written with the typed tensor package
(`eco-lab/tensor`); Elm derives the gradients itself (MAX has no autodiff). This module owns the data
and runs the training loop: MAX compiles the two graphs Elm writes, a training step and an
evaluation, and executes them.

The parameters live on the host as resident buffers: Elm sends their initial values once, then
only each batch, and gets back only the loss.

-}

import Array
import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as Encode
import Dict exposing (Dict)
import Json.Decode as D
import MnistModels exposing (Variant)
import MnistNet as Net exposing (batchSize, testSize)
import Platform
import Train


trainId : Int
trainId =
    1


evalId : Int
evalId =
    2


type alias Model =
    { variant : Variant
    , name : String
    , checkpoints : String
    , reload : Bool
    , reloaded : Bool
    , files : Dict Int Bytes
    , baseFiles : Dict Int Bytes
    , compiled : List Int
    , epoch : Int
    , batches : List Int
    , lossSum : Float
    , steps : Int
    , seed : Int
    , trace : Int
    }


type Msg
    = Loaded Bytes
    | Compiled D.Value
    | Ran Bytes
    | Got Bytes


files : List ( Int, String )
files =
    [ ( 1, "train-images-idx3-ubyte" )
    , ( 2, "train-labels-idx1-ubyte" )
    , ( 3, "t10k-images-idx3-ubyte" )
    , ( 4, "t10k-labels-idx1-ubyte" )
    ]


lcg : Int -> Int
lcg seed =
    modBy 4294967296 (1664525 * seed + 1013904223)


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
                        lcg seed

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


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        dir =
            Result.withDefault "." (D.decodeValue (D.field "dataDir" D.string) flags)

        format =
            if D.decodeValue (D.field "format" D.string) flags == Ok "generic" then
                Bridge.GenericText

            else
                Bridge.Bytecode

        formatName =
            if format == Bridge.Bytecode then
                "bytecode"

            else
                "generic"

        name =
            Result.withDefault "sgd" (D.decodeValue (D.field "variant" D.string) flags)

        v =
            MnistModels.variant name

        checkpoints =
            Result.withDefault "." (D.decodeValue (D.field "checkpoints" D.string) flags)

        loaded =
            List.map Tuple.first v.loads

        compileBoth =
            case ( v.train, v.measure ) of
                ( Ok train, Ok eval ) ->
                    let
                        ( c1, n1 ) =
                            Bridge.compile format trainId train

                        ( c2, n2 ) =
                            Bridge.compile format evalId eval
                    in
                    [ Bridge.log
                        ("graphs built and checked in Elm, as "
                            ++ formatName
                            ++ ": train_step "
                            ++ String.fromInt n1
                            ++ " bytes, measure "
                            ++ String.fromInt n2
                            ++ " bytes"
                        )
                    , c1
                    , c2
                    ]

                ( train, eval ) ->
                    [ Bridge.log ("graph errors: " ++ String.join "; " (errors train ++ errors eval)), Bridge.done 1 ]
    in
    ( { variant = v
      , name = name
      , checkpoints = checkpoints
      , reload = D.decodeValue (D.field "reload" D.bool) flags == Ok True
      , reloaded = False
      , files = Dict.empty
      , baseFiles = Dict.empty
      , compiled = []
      , epoch = 0
      , batches = []
      , lossSum = 0
      , steps = 0
      , seed = 7
      , trace = Result.withDefault 0 (D.decodeValue (D.field "trace" D.int) flags)
      }
    , Cmd.batch
        (Bridge.log ("model " ++ name)
            :: Bridge.send
                (List.map (\( n, b ) -> Bridge.put n b) (List.filter (\( n, _ ) -> not (List.member n loaded)) v.initial)
                    ++ List.map (\( n, f ) -> Bridge.loadInto n (checkpoints ++ "/" ++ f ++ ".bin")) v.loads
                )
            :: compileBoth
            ++ List.map (\( id, f ) -> Bridge.load id (dir ++ "/" ++ f)) files
            ++ (case v.base of
                    Just b ->
                        List.indexedMap (\i f -> Bridge.load (baseId + i) (checkpoints ++ "/" ++ f ++ ".bin")) b.files

                    Nothing ->
                        []
               )
        )
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
    Bridge.send << List.singleton <| Bridge.run trainId
        ([ Bridge.packed (Bridge.slice (16 + index * batchSize * 784) (batchSize * 784) (file 1 model))
         , Bridge.packed (Bridge.slice (8 + index * batchSize) batchSize (file 2 model))
         ]
            ++ (if model.variant.seeded then
                    -- a ui64 [1] seed: a different one every step
                    [ Bridge.packed (Encode.encode (Encode.sequence [ Encode.unsignedInt32 LE (model.epoch * 100000 + model.steps + 1), Encode.unsignedInt32 LE 0 ])) ]

                else
                    []
               )
        )


evaluateTest : Model -> Cmd Msg
evaluateTest model =
    Bridge.send [ evalCommand model ]


evalCommand : Model -> Bridge.Command
evalCommand model =
    Bridge.run evalId
        [ Bridge.packed (Bridge.slice 16 (testSize * 784) (file 3 model))
        , Bridge.packed (Bridge.slice 8 testSize (file 4 model))
        ]


baseId : Int
baseId =
    100


baseCount : Model -> Int
baseCount model =
    model.variant.base |> Maybe.map (.files >> List.length) |> Maybe.withDefault 0


ready : Model -> Bool
ready model =
    Dict.size model.files == 4 && List.length model.compiled == 2 && Dict.size model.baseFiles == baseCount model


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
                id =
                    Bridge.headerId bytes

                m =
                    if id >= baseId then
                        { model | baseFiles = Dict.insert id (Bridge.payload bytes) model.baseFiles }

                    else
                        { model | files = Dict.insert id (Bridge.payload bytes) model.files }
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

        Got _ ->
            -- the reply to the `get` sent after the saves: they are done
            ( model, Bridge.done 0 )

        Ran bytes ->
            if Bridge.headerId bytes == trainId then
                let
                    loss =
                        Train.loss bytes

                    m =
                        { model | lossSum = model.lossSum + loss, steps = model.steps + 1 }

                    traceCmd =
                        if m.epoch == 1 && m.steps <= m.trace then
                            Bridge.log ("step " ++ String.fromInt m.steps ++ " loss " ++ String.fromFloat loss)

                        else
                            Cmd.none
                in
                case m.batches of
                    index :: rest ->
                        ( { m | batches = rest }, Cmd.batch [ traceCmd, trainBatch index m ] )

                    [] ->
                        ( m, Cmd.batch [ traceCmd, evaluateTest m ] )

            else
                let
                    correct =
                        round (Train.measured bytes)

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
                if model.reloaded then
                    ( model, Cmd.batch [ Bridge.log ("after saving and reloading: test accuracy " ++ String.fromFloat (toFloat correct / 100) ++ "%"), Bridge.done 0 ] )

                else if model.epoch >= model.variant.epochs then
                    let
                        saves =
                            List.map (\n -> Bridge.save n (model.checkpoints ++ "/" ++ n ++ ".bin")) model.variant.saves

                        reloads =
                            List.map (\n -> Bridge.loadInto n (model.checkpoints ++ "/" ++ n ++ ".bin")) model.variant.saves
                    in
                    if model.reload && not (List.isEmpty saves) then
                        ( { model | reloaded = True }
                        , Cmd.batch [ Bridge.log report, Bridge.send (saves ++ reloads ++ [ evalCommand model ]) ]
                        )

                    else
                        ( model, Cmd.batch [ Bridge.log report, Bridge.send (saves ++ [ Bridge.get 0 "none" ]) ] )

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
        case model.variant.base of
            Just b ->
                let
                    -- the saved parameters as one block in Param.initial's layout
                    block =
                        Encode.encode (Encode.sequence (List.map Bridge.packed (Dict.values model.baseFiles)))
                in
                Bridge.send (List.map (\( n, bytes ) -> Bridge.put n bytes) (b.residents block) ++ [ evalCommand model ])

            Nothing ->
                evaluateTest model

    else
        Cmd.none


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.batch [ Bridge.loadIn Loaded, Bridge.compiledIn Compiled, Bridge.runIn Ran, Bridge.getIn Got ]
        }
