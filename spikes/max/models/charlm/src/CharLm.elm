module CharLm exposing (main)

{-| Trains `CharModel` on MAX: a byte-level language model over a text corpus (the repo's
`design_docs/theory`), 90% for training, 10% held out.

Flags: `corpus` (a file), `layers`, `shared` (layers as calls of one subgraph), `steps`, `trace`
(log the first n step losses), `validateEvery`.

It reports the held-out loss against the corpus's unigram entropy: a model that learnt nothing
about context cannot beat it.

-}

import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import CharModel exposing (batchSize, seqLen)
import Json.Decode as D
import Platform
import Train


trainId : Int
trainId =
    1


validId : Int
validId =
    2


type alias Model =
    { corpus : Maybe Bytes
    , compiled : Int
    , cfg : CharModel.Config
    , steps : Int
    , step : Int
    , seed : Int
    , lossSum : Float
    , lossCount : Int
    , trace : Int
    , validateEvery : Int
    , lastValid : Float
    , entropy : Float
    }


type Msg
    = Loaded Bytes
    | Compiled D.Value
    | Ran Bytes


flag : String -> D.Decoder a -> a -> D.Value -> a
flag name decoder default flags =
    Result.withDefault default (D.decodeValue (D.field name decoder) flags)


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        cfg =
            { layers = flag "layers" D.int 2 flags, shared = flag "shared" D.bool False flags }

        initial =
            Train.initial (CharModel.params cfg) CharModel.optimizer 1

        graphs =
            case ( CharModel.trainStep cfg, CharModel.validate cfg ) of
                ( Ok t, Ok v ) ->
                    let
                        ( c1, n1 ) =
                            Bridge.compile Bridge.Bytecode trainId t

                        ( c2, n2 ) =
                            Bridge.compile Bridge.Bytecode validId v
                    in
                    [ Bridge.log ("char model: " ++ String.fromInt cfg.layers ++ " layers" ++ (if cfg.shared then ", shared" else "") ++ "; train_step " ++ String.fromInt n1 ++ " bytes, measure " ++ String.fromInt n2 ++ " bytes")
                    , c1
                    , c2
                    ]

                ( t, v ) ->
                    [ Bridge.log ("graph errors: " ++ String.join "; " (errs t ++ errs v)), Bridge.done 1 ]
    in
    ( { corpus = Nothing
      , compiled = 0
      , cfg = cfg
      , steps = flag "steps" D.int 1000 flags
      , step = 0
      , seed = 12345
      , lossSum = 0
      , lossCount = 0
      , trace = flag "trace" D.int 0 flags
      , validateEvery = flag "validateEvery" D.int 250 flags
      , lastValid = 0
      , entropy = 0
      }
    , Cmd.batch (Bridge.send (List.map (\( n, b ) -> Bridge.put n b) initial) :: Bridge.load 1 (flag "corpus" D.string "corpus.txt" flags) :: graphs)
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


corpusBytes : Model -> Bytes
corpusBytes model =
    Maybe.withDefault (Encode.encode (Encode.sequence [])) model.corpus


trainLength : Model -> Int
trainLength model =
    Bytes.width (corpusBytes model) * 9 // 10


windows : Model -> List Int -> Encode.Encoder
windows model offsets =
    Bridge.packed (Encode.encode (Encode.sequence (List.map (\o -> Encode.bytes (Bridge.slice o (seqLen + 1) (corpusBytes model))) offsets)))


{-| A training step on 16 random windows of the training part, with a fresh dropout seed.
-}
trainCommand : Model -> ( Model, Cmd Msg )
trainCommand model =
    let
        span =
            trainLength model - seqLen - 1

        ( offsets, seed ) =
            List.foldl (\_ ( acc, s ) -> ( modBy span (lcg s) :: acc, lcg s )) ( [], model.seed ) (List.range 1 batchSize)

        seedBytes =
            Bridge.packed (Encode.encode (Encode.sequence [ Encode.unsignedInt32 LE (model.step + 1), Encode.unsignedInt32 LE 0 ]))
    in
    ( { model | seed = seed }, Bridge.send [ Bridge.run trainId [ windows model offsets, seedBytes ] ] )


{-| The held-out loss on 16 fixed windows spread over the last 10%.
-}
validCommand : Model -> Cmd Msg
validCommand model =
    let
        start =
            trainLength model

        span =
            Bytes.width (corpusBytes model) - start - seqLen - 1
    in
    Bridge.send [ Bridge.run validId [ windows model (List.map (\i -> start + i * span // batchSize) (List.range 0 (batchSize - 1))) ] ]


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


ready : Model -> Bool
ready model =
    model.corpus /= Nothing && model.compiled == 2


begin : Model -> ( Model, Cmd Msg )
begin model =
    if ready model then
        let
            e =
                CharModel.unigramEntropy (byteList (Bridge.slice 0 (trainLength model) (corpusBytes model)))
        in
        ( { model | entropy = e }
        , Cmd.batch [ Bridge.log ("corpus " ++ String.fromInt (Bytes.width (corpusBytes model)) ++ " bytes; unigram entropy " ++ fmt e ++ " nats"), validCommand model ]
        )

    else
        ( model, Cmd.none )


fmt : Float -> String
fmt x =
    String.fromFloat (toFloat (round (x * 10000)) / 10000)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Loaded bytes ->
            begin { model | corpus = Just (Bridge.payload bytes) }

        Compiled v ->
            case D.decodeValue (D.field "ok" D.bool) v of
                Ok True ->
                    begin { model | compiled = model.compiled + 1 }

                _ ->
                    ( model, Cmd.batch [ Bridge.log "compile failed", Bridge.done 1 ] )

        Ran bytes ->
            if Bridge.headerId bytes == trainId then
                let
                    loss =
                        Train.loss bytes

                    m =
                        { model | step = model.step + 1, lossSum = model.lossSum + loss, lossCount = model.lossCount + 1 }

                    traceCmd =
                        if m.step <= m.trace then
                            Bridge.log ("step " ++ String.fromInt m.step ++ " loss " ++ String.fromFloat loss)

                        else
                            Cmd.none
                in
                if modBy m.validateEvery m.step == 0 || m.step >= m.steps then
                    ( m, Cmd.batch [ traceCmd, validCommand m ] )

                else
                    let
                        ( m2, cmd ) =
                            trainCommand m
                    in
                    ( m2, Cmd.batch [ traceCmd, cmd ] )

            else
                let
                    valid =
                        Train.measured bytes

                    report =
                        "step "
                            ++ String.fromInt model.step
                            ++ ": "
                            ++ (if model.lossCount > 0 then
                                    "mean train loss " ++ fmt (model.lossSum / toFloat model.lossCount) ++ ", "

                                else
                                    ""
                               )
                            ++ "held-out loss "
                            ++ fmt valid
                    m =
                        { model | lastValid = valid, lossSum = 0, lossCount = 0 }
                in
                if model.step >= model.steps then
                    ( m
                    , Cmd.batch
                        [ Bridge.log report
                        , Bridge.log
                            ("held-out loss "
                                ++ fmt valid
                                ++ (if valid < model.entropy then
                                        " < "

                                    else
                                        " >= "
                                   )
                                ++ "unigram entropy "
                                ++ fmt model.entropy
                            )
                        , Bridge.done
                            (if valid < model.entropy then
                                0

                             else
                                1
                            )
                        ]
                    )

                else
                    let
                        ( m2, cmd ) =
                            trainCommand m
                    in
                    ( m2, Cmd.batch [ Bridge.log report, cmd ] )


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.batch [ Bridge.loadIn Loaded, Bridge.compiledIn Compiled, Bridge.runIn Ran ]
        }
