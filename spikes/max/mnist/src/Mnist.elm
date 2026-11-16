port module Mnist exposing (main)

{-| Training a neural network on MNIST with Elm and MAX.

The network and its training step are `MnistNet`, written with the typed tensor package
(`the-sett/elm-max`); Elm derives the gradients itself (MAX has no autodiff). This module owns the data
and runs the training loop: a `Max.Session` on the host compiles the two graphs Elm writes, a
training step and an evaluation, and runs them.

The parameters live in the session's resident buffers: Elm puts their initial values once, then
sends only each batch, and gets back only the loss.

-}

import Array
import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Dict exposing (Dict)
import Json.Decode as D
import Max
import Max.Session as Session exposing (Event(..), Session)
import MnistModels exposing (Variant)
import MnistNet exposing (batchSize, testSize)
import Platform


port maxOut : Bytes -> Cmd msg


port maxIn : (Bytes -> msg) -> Sub msg


port logOut : String -> Cmd msg


{-| `Stopped` when the graphs could not be built: the program is ending.
-}
type Model
    = Running State
    | Stopped


type alias State =
    { session : Session Msg
    , variant : Variant
    , train : Session.Handle
    , measure : Session.Handle
    , dataDir : String
    , checkpoints : String
    , reload : Bool
    , reloaded : Bool
    , files : Dict String Bytes
    , compiled : Int
    , epoch : Int
    , batches : List Int
    , lossSum : Float
    , steps : Int
    , seed : Int
    , trace : Int
    }


type Msg
    = GotMax Session.Message


trainImages : String
trainImages =
    "train-images-idx3-ubyte"


trainLabels : String
trainLabels =
    "train-labels-idx1-ubyte"


testImages : String
testImages =
    "t10k-images-idx3-ubyte"


testLabels : String
testLabels =
    "t10k-labels-idx1-ubyte"


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
        string field default =
            Result.withDefault default (D.decodeValue (D.field field D.string) flags)

        ( format, formatName ) =
            if string "format" "bytecode" == "generic" then
                ( Session.GenericText, "generic" )

            else
                ( Session.Bytecode, "bytecode" )

        name =
            string "variant" "sgd"

        v =
            MnistModels.variant name

        session0 =
            Session.host { send = maxOut, receive = maxIn } GotMax
    in
    case ( v.train, v.measure ) of
        ( Ok trainGraph, Ok measureGraph ) ->
            let
                compile =
                    Session.compileWith { format = format, device = Max.Cpu }

                -- compiled first, so that the host writes them as graph-1 and graph-2
                ( session1, train, compileTrain ) =
                    compile trainGraph session0

                ( session2, measure, compileMeasure ) =
                    compile measureGraph session1

                state =
                    { session = session2
                    , variant = v
                    , train = train
                    , measure = measure
                    , dataDir = string "dataDir" "."
                    , checkpoints = string "checkpoints" "."
                    , reload = D.decodeValue (D.field "reload" D.bool) flags == Ok True
                    , reloaded = False
                    , files = Dict.empty
                    , compiled = 0
                    , epoch = 0
                    , batches = []
                    , lossSum = 0
                    , steps = 0
                    , seed = 7
                    , trace = Result.withDefault 0 (D.decodeValue (D.field "trace" D.int) flags)
                    }

                loaded =
                    List.map Tuple.first v.loads

                ( started, setUp ) =
                    send
                        (List.map (\( n, b ) -> Session.put n b) (List.filter (\( n, _ ) -> not (List.member n loaded)) v.initial)
                            ++ List.map (\( n, f ) -> Session.loadInto n (checkpoint state f)) v.loads
                            ++ List.map Session.load (wanted state)
                        )
                        state
            in
            ( Running started
            , Cmd.batch
                [ logOut ("model " ++ name)
                , logOut ("graphs built and checked in Elm, as " ++ formatName)
                , compileTrain
                , compileMeasure
                , setUp
                ]
            )

        ( train, measure ) ->
            ( Stopped
            , Cmd.batch
                [ logOut ("model " ++ name)
                , logOut ("graph errors: " ++ String.join "; " (errors train ++ errors measure))
                , Tuple.second (Session.send [ Session.finish 1 ] session0)
                ]
            )


errors : Result (List String) a -> List String
errors r =
    case r of
        Err e ->
            e

        Ok _ ->
            []


checkpoint : State -> String -> String
checkpoint state name =
    state.checkpoints ++ "/" ++ name ++ ".bin"


dataPath : State -> String -> String
dataPath state name =
    state.dataDir ++ "/" ++ name


{-| Every file the run reads into Elm: the data, and the saved network a `base` starts from.
-}
wanted : State -> List String
wanted state =
    List.map (dataPath state) [ trainImages, trainLabels, testImages, testLabels ]
        ++ (state.variant.base |> Maybe.map (.files >> List.map (checkpoint state)) |> Maybe.withDefault [])


file : String -> State -> Bytes
file path state =
    Maybe.withDefault (Encode.encode (Encode.sequence [])) (Dict.get path state.files)


{-| `length` bytes of a data file from `offset`.
-}
slice : String -> Int -> Int -> State -> Session.Input
slice name offset length state =
    file (dataPath state name) state
        |> Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.bytes length))
        |> Maybe.withDefault (Encode.encode (Encode.sequence []))
        |> Session.fromBytes


send : List Session.Command -> State -> ( State, Cmd Msg )
send commands state =
    let
        ( session, cmd ) =
            Session.send commands state.session
    in
    ( { state | session = session }, cmd )


{-| Logs `lines`, then ends the program with `code`.
-}
stop : Int -> List String -> State -> ( State, Cmd Msg )
stop code lines state =
    let
        ( s, cmd ) =
            send [ Session.finish code ] state
    in
    ( s, Cmd.batch (List.map logOut lines ++ [ cmd ]) )


{-| Images start after a 16-byte IDX header, labels after an 8-byte one. The seeded variants take
a different dropout seed every step, made from the epoch and step of `state`.
-}
trainRun : Int -> State -> Session.Command
trainRun index state =
    Session.run state.train
        (( "batch0", slice trainImages (16 + index * batchSize * 784) (batchSize * 784) state )
            :: ( "batch1", slice trainLabels (8 + index * batchSize) batchSize state )
            :: (if state.variant.seeded then
                    [ ( "batch2", Session.fromInts [ state.epoch * 100000 + state.steps + 1 ] ) ]

                else
                    []
               )
        )


evaluation : State -> Session.Command
evaluation state =
    Session.run state.measure
        [ ( "batch0", slice testImages 16 (testSize * 784) state )
        , ( "batch1", slice testLabels 8 testSize state )
        ]


{-| Starts epoch `state.epoch + 1` on a fresh shuffle of the 600 batches. Its first step's seed is
made from the epoch and step before it.
-}
startEpoch : State -> ( State, Cmd Msg )
startEpoch state =
    let
        ( order, seed ) =
            shuffle state.seed (List.range 0 (60000 // batchSize - 1))
    in
    case order of
        first :: rest ->
            send [ trainRun first state ] { state | epoch = state.epoch + 1, batches = rest, lossSum = 0, steps = 0, seed = seed }

        [] ->
            stop 1 [] state


update : Msg -> Model -> ( Model, Cmd Msg )
update (GotMax message) model =
    case model of
        Running state ->
            let
                ( session, event ) =
                    Session.update message state.session
            in
            Tuple.mapFirst Running (onEvent event { state | session = session })

        Stopped ->
            ( model, Cmd.none )


onEvent : Event -> State -> ( State, Cmd Msg )
onEvent event state =
    case event of
        Loaded path bytes ->
            whenReady { state | files = Dict.insert path bytes state.files }

        Compiled _ ->
            whenReady { state | compiled = state.compiled + 1 }

        CompileFailed _ why ->
            stop 1 [ "compile failed: " ++ why ] state

        Failed why ->
            stop 1 [ why ] state

        Ran graph outputs ->
            let
                result name =
                    Session.floats name outputs |> Maybe.andThen List.head |> Maybe.withDefault 0
            in
            if graph == state.train then
                trained (result "loss") state

            else
                measured (round (result "result")) state

        Got _ _ ->
            ( state, Cmd.none )

        Finished _ ->
            ( state, Cmd.none )


trained : Float -> State -> ( State, Cmd Msg )
trained loss state =
    let
        s =
            { state | lossSum = state.lossSum + loss, steps = state.steps + 1 }

        traceLog =
            if s.epoch == 1 && s.steps <= s.trace then
                [ logOut ("step " ++ String.fromInt s.steps ++ " loss " ++ String.fromFloat loss) ]

            else
                []

        ( next, cmd ) =
            case s.batches of
                index :: rest ->
                    send [ trainRun index s ] { s | batches = rest }

                [] ->
                    send [ evaluation s ] s
    in
    ( next, Cmd.batch (traceLog ++ [ cmd ]) )


measured : Int -> State -> ( State, Cmd Msg )
measured correct state =
    let
        accuracy =
            String.fromFloat (toFloat correct / 100)

        report =
            "epoch "
                ++ String.fromInt state.epoch
                ++ ": "
                ++ (if state.steps > 0 then
                        "mean train loss " ++ String.left 6 (String.fromFloat (state.lossSum / toFloat state.steps)) ++ ", "

                    else
                        "untrained, "
                   )
                ++ "test accuracy "
                ++ accuracy
                ++ "% ("
                ++ String.fromInt correct
                ++ "/10000)"

        withReport ( s, cmd ) =
            ( s, Cmd.batch [ logOut report, cmd ] )
    in
    if state.reloaded then
        stop 0 [ "after saving and reloading: test accuracy " ++ accuracy ++ "%" ] state

    else if state.epoch >= state.variant.epochs then
        let
            saves =
                List.map (\n -> Session.save n (checkpoint state n)) state.variant.saves

            reloads =
                List.map (\n -> Session.loadInto n (checkpoint state n)) state.variant.saves
        in
        if state.reload && not (List.isEmpty saves) then
            withReport (send (saves ++ reloads ++ [ evaluation state ]) { state | reloaded = True })

        else
            withReport (send (saves ++ [ Session.finish 0 ]) state)

    else
        withReport (startEpoch state)


{-| Once the data is in and both graphs are compiled, evaluates the untrained network first; a
variant with a `base` first puts the saved network's parameters, each read from its file.
-}
whenReady : State -> ( State, Cmd Msg )
whenReady state =
    if state.compiled == 2 && List.all (\p -> Dict.member p state.files) (wanted state) then
        case state.variant.base of
            Just b ->
                case b.residents (List.map (\f -> ( f, file (checkpoint state f) state )) b.files) of
                    Ok residents ->
                        send (List.map (\( n, bytes ) -> Session.put n bytes) residents ++ [ evaluation state ]) state

                    Err e ->
                        stop 1 [ "base: " ++ e ] state

            Nothing ->
                send [ evaluation state ] state

    else
        ( state, Cmd.none )


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions =
            \model ->
                case model of
                    Running state ->
                        Session.subscriptions state.session

                    Stopped ->
                        Sub.none
        }
