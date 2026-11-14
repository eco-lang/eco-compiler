port module CharLm exposing (main)

{-| Trains `CharModel` on MAX: a byte-level language model over a text corpus (the repo's
`design_docs/theory`), 90% for training, 10% held out.

Flags: `corpus` (a file), `layers`, `shared` (layers as calls of one subgraph), `steps`, `trace`
(log the first n step losses), `validateEvery`.

It reports the held-out loss against the corpus's unigram entropy: a model that learnt nothing
about context cannot beat it.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import CharModel exposing (batchSize, seqLen)
import Json.Decode as D
import Max.Session as Session exposing (Event(..), Session)
import Platform
import Train


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
    , train : Session.Handle
    , valid : Session.Handle
    , corpus : Maybe Bytes
    , compiled : Int
    , steps : Int
    , step : Int
    , seed : Int
    , lossSum : Float
    , lossCount : Int
    , trace : Int
    , validateEvery : Int
    , entropy : Float
    }


type Msg
    = GotMax Session.Message


flag : String -> D.Decoder a -> a -> D.Value -> a
flag name decoder default flags =
    Result.withDefault default (D.decodeValue (D.field name decoder) flags)


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        cfg =
            { layers = flag "layers" D.int 2 flags, shared = flag "shared" D.bool False flags }

        session0 =
            Session.host { send = maxOut, receive = maxIn } GotMax
    in
    case ( CharModel.trainStep cfg, CharModel.validate cfg ) of
        ( Ok trainGraph, Ok validGraph ) ->
            let
                ( session1, train, compileTrain ) =
                    Session.compile trainGraph session0

                ( session2, valid, compileValid ) =
                    Session.compile validGraph session1

                ( session3, setUp ) =
                    Session.send
                        (List.map (\( n, b ) -> Session.put n b) (Train.initial (CharModel.params cfg) CharModel.optimizer 1)
                            ++ [ Session.load (flag "corpus" D.string "corpus.txt" flags) ]
                        )
                        session2
            in
            ( Running
                { session = session3
                , train = train
                , valid = valid
                , corpus = Nothing
                , compiled = 0
                , steps = flag "steps" D.int 1000 flags
                , step = 0
                , seed = 12345
                , lossSum = 0
                , lossCount = 0
                , trace = flag "trace" D.int 0 flags
                , validateEvery = flag "validateEvery" D.int 250 flags
                , entropy = 0
                }
            , Cmd.batch
                [ logOut
                    ("char model: "
                        ++ String.fromInt cfg.layers
                        ++ " layers"
                        ++ (if cfg.shared then
                                ", shared"

                            else
                                ""
                           )
                    )
                , compileTrain
                , compileValid
                , setUp
                ]
            )

        ( t, v ) ->
            ( Stopped
            , Cmd.batch
                [ logOut ("graph errors: " ++ String.join "; " (errs t ++ errs v))
                , Tuple.second (Session.send [ Session.finish 1 ] session0)
                ]
            )


errs : Result (List String) a -> List String
errs r =
    case r of
        Err e ->
            e

        Ok _ ->
            []


lcg : Int -> Int
lcg s =
    modBy 4294967296 (1664525 * s + 1013904223)


emptyBytes : Bytes
emptyBytes =
    Encode.encode (Encode.sequence [])


corpusBytes : State -> Bytes
corpusBytes state =
    Maybe.withDefault emptyBytes state.corpus


slice : Int -> Int -> Bytes -> Bytes
slice offset length b =
    Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.bytes length)) b
        |> Maybe.withDefault emptyBytes


trainLength : State -> Int
trainLength state =
    Bytes.width (corpusBytes state) * 9 // 10


windows : State -> List Int -> Session.Input
windows state offsets =
    Session.fromBytes (Encode.encode (Encode.sequence (List.map (\o -> Encode.bytes (slice o (seqLen + 1) (corpusBytes state))) offsets)))


send : List Session.Command -> State -> ( State, Cmd Msg )
send commands state =
    let
        ( session, cmd ) =
            Session.send commands state.session
    in
    ( { state | session = session }, cmd )


{-| A training step on 16 random windows of the training part, with a fresh dropout seed.
-}
trainStep : State -> ( State, Cmd Msg )
trainStep state =
    let
        span =
            trainLength state - seqLen - 1

        ( offsets, seed ) =
            List.foldl (\_ ( acc, s ) -> ( modBy span (lcg s) :: acc, lcg s )) ( [], state.seed ) (List.range 1 batchSize)
    in
    send [ Session.run state.train [ ( "batch0", windows state offsets ), ( "batch1", Session.fromInts [ state.step + 1 ] ) ] ] { state | seed = seed }


{-| The held-out loss on 16 fixed windows spread over the last 10%.
-}
validStep : State -> ( State, Cmd Msg )
validStep state =
    let
        start =
            trainLength state

        span =
            Bytes.width (corpusBytes state) - start - seqLen - 1
    in
    send [ Session.run state.valid [ ( "batch", windows state (List.map (\i -> start + i * span // batchSize) (List.range 0 (batchSize - 1))) ) ] ] state


byteList : Bytes -> List Int
byteList bytes =
    let
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Decode.Done acc)

            else
                Decode.map (\x -> Decode.Loop ( n - 1, x :: acc )) Decode.unsignedInt8
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes |> Maybe.withDefault []


{-| Once the corpus is in and both graphs are compiled, measures the untrained model first.
-}
begin : State -> ( State, Cmd Msg )
begin state =
    if state.corpus /= Nothing && state.compiled == 2 then
        let
            e =
                CharModel.unigramEntropy (byteList (slice 0 (trainLength state) (corpusBytes state)))

            ( s, cmd ) =
                validStep { state | entropy = e }
        in
        ( s
        , Cmd.batch [ logOut ("corpus " ++ String.fromInt (Bytes.width (corpusBytes state)) ++ " bytes; unigram entropy " ++ fmt e ++ " nats"), cmd ]
        )

    else
        ( state, Cmd.none )


fmt : Float -> String
fmt x =
    String.fromFloat (toFloat (round (x * 10000)) / 10000)


stop : Int -> List String -> State -> ( State, Cmd Msg )
stop code lines state =
    let
        ( s, cmd ) =
            send [ Session.finish code ] state
    in
    ( s, Cmd.batch (List.map logOut lines ++ [ cmd ]) )


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
        Loaded _ bytes ->
            begin { state | corpus = Just bytes }

        Compiled _ ->
            begin { state | compiled = state.compiled + 1 }

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
                validated (result "result") state

        Got _ _ ->
            ( state, Cmd.none )

        Finished _ ->
            ( state, Cmd.none )


trained : Float -> State -> ( State, Cmd Msg )
trained loss state =
    let
        s =
            { state | step = state.step + 1, lossSum = state.lossSum + loss, lossCount = state.lossCount + 1 }

        traceLog =
            if s.step <= s.trace then
                [ logOut ("step " ++ String.fromInt s.step ++ " loss " ++ String.fromFloat loss) ]

            else
                []

        ( next, cmd ) =
            if modBy s.validateEvery s.step == 0 || s.step >= s.steps then
                validStep s

            else
                trainStep s
    in
    ( next, Cmd.batch (traceLog ++ [ cmd ]) )


validated : Float -> State -> ( State, Cmd Msg )
validated valid state =
    let
        report =
            "step "
                ++ String.fromInt state.step
                ++ ": "
                ++ (if state.lossCount > 0 then
                        "mean train loss " ++ fmt (state.lossSum / toFloat state.lossCount) ++ ", "

                    else
                        ""
                   )
                ++ "held-out loss "
                ++ fmt valid

        s =
            { state | lossSum = 0, lossCount = 0 }
    in
    if state.step >= state.steps then
        if valid < state.entropy then
            stop 0 [ report, "held-out loss " ++ fmt valid ++ " < unigram entropy " ++ fmt state.entropy ] s

        else
            stop 1 [ report, "held-out loss " ++ fmt valid ++ " >= unigram entropy " ++ fmt state.entropy ] s

    else
        let
            ( next, cmd ) =
                trainStep s
        in
        ( next, Cmd.batch [ logOut report, cmd ] )


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
