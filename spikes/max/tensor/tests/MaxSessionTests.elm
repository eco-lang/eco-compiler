module MaxSessionTests exposing (suite)

{-| `Max.Session` talks to the MAX host in bytes whose layout the host reads independently, and runs
the same commands in Elm, where a wrong layout or a wrong buffer update would still give plausible
numbers. These tests pin the bytes of every request, the reading of every kind of reply, the
conversion between bytes and `Tensor.Eval` values for every dtype, and in-Elm sessions run end to
end; and `Max.Safetensors`' reading of a checkpoint header.

The graphs are `idGraph`, the identity on an `f32` vector of 3 labelled `x`, and the two graphs of a
small multi-layer perceptron (MLP) of 4 features, 8 hidden units and 3 classes: `mlpStep`, a
`Train.step` with SGD at rate 0.5, and `mlpMeasure`, a `Train.measure` of the same loss. Both take
the 12 `points` as their fed inputs `batch0` (`f32` 12 × 4) and `batch1` (`si64` 12). Host sessions
are made with ports that send and receive nothing, so what they would send is checked through
`Max.Internal.Session.hostRequests` and `Max.Internal.Protocol.encode`, and replies are handed to
`Max.Session.update` as bytes. In-Elm sessions are drained by handing `update` one `Next` message
for each queued reply.

The tests establish:

  - **Requests** (`requests`): the exact bytes of each of the eleven requests, padding of run
    inputs to 16 bytes, offsets and lengths of 2³² or more as two words, spec lines with resident
    roles and a scalar, one request sent as itself and several as a sequence of length-prefixed
    requests.
  - **Host sessions** (`hostSessions`): ids given in order from 2 after one compile, a run's fed
    inputs sent in graph order whatever order they are given in, inputs given as floats and ints
    encoded by the input's dtype, and a missing input, bytes of the wrong width and ints for a
    float input refused with `Failed` and nothing to send.
  - **Replies** (`replies`): `ran` read into named outputs (as floats, bytes and a value), a `ran`
    of the wrong width, `compiled` with status 0 and 1 (after which a run is refused), `got`
    matched to the name asked for, `loaded` matched to the path for `load` and for `loadRange`, a
    failed `loadRange` giving the host's message, and replies that match nothing or are shorter
    than a header giving `Failed`.
  - **Elements** (`elements`): the bytes of f16, bf16, si64, ui64 and bool elements, a round trip
    through bytes for each of the ten dtypes, NaN patterns read as NaN, a width that does not fit
    refused, and `check` refusing a value of the wrong dtype, shape, kind, count or range.
  - **In-Elm sessions** (`inElmSessions`): compile, puts and a run of `mlpMeasure` giving exactly
    what `Tensor.Eval.run` gives on the same buffers; five steps of `mlpStep` giving losses equal
    to a direct `Tensor.Eval.run` loop whose buffers are rounded to `f32` between steps, within
    1e-5 of one that keeps doubles, a fifth loss below the first, and every buffer changed; `put` then `get` in one send; save then
    loadInto; `load`, `loadRange`, `loadRangeInto` and an unsaved `loadInto` failing, with the
    commands after the first two still run and those after the others skipped; a run with a
    missing resident buffer failing; `finish` answered by `Finished` and later commands ignored;
    and a negative GPU refused at compile on both backends.
  - **Safetensors** (`safetensors`): the header length from 8 bytes, entries parsed in data order
    with `__metadata__` skipped, three malformed headers refused, and the commands `readLength`,
    `readHeader` and `loadAll` make.

Among what is not tested: what a host does with the bytes, the `Cmd`s a session returns, and the
GPU placement of a graph `Max` accepts.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as BE
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Graph exposing (Graph)
import Max
import Max.Internal.Elements as Elements
import Max.Internal.Protocol as Protocol exposing (Request(..))
import Max.Internal.Session as S
import Max.Safetensors as Safetensors
import Max.Session as Session exposing (Event(..))
import Nn
import Nn.Linear as Linear exposing (Linear)
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim)
import Tensor.Eval as Eval exposing (Data(..), Value)
import Test exposing (Test, describe, test)
import Train


suite : Test
suite =
    describe "Max.Session"
        [ requests
        , hostSessions
        , replies
        , elements
        , inElmSessions
        , safetensors
        ]



-- Bytes


{-| Returns the bytes as a list of their values.
-}
toList : Bytes -> List Int
toList b =
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


{-| Returns bytes with the given values.
-}
fromList : List Int -> Bytes
fromList l =
    BE.encode (BE.sequence (List.map BE.unsignedInt8 l))


{-| Returns the four little-endian bytes of `n`.
-}
le32 : Int -> List Int
le32 n =
    toList (BE.encode (BE.unsignedInt32 LE n))


{-| Returns a header's 16 bytes.
-}
hdr : Int -> Int -> Int -> List Int
hdr id code status =
    le32 id ++ le32 code ++ le32 status ++ le32 0


{-| Returns the UTF-8 bytes of `s`.
-}
str : String -> List Int
str s =
    toList (BE.encode (BE.string s))


{-| Returns the f32 bytes of the floats.
-}
f32s : List Float -> List Int
f32s l =
    toList (BE.encode (BE.sequence (List.map (BE.float32 LE) l)))


{-| Expects `actual` to hold exactly the values `expected`.
-}
bytesAre : List Int -> Bytes -> Expectation
bytesAre expected actual =
    Expect.equal expected (toList actual)



-- Fixtures


type B
    = B


type Hidden
    = Hidden


type Classes
    = Classes


type Pts
    = Pts


type Feat
    = Feat


{-| The axis of `idGraph`'s vector, of size 3.
-}
b3 : Dim B
b3 =
    T.dim B 3


{-| The identity on an `f32` vector of 3: input `x`, output `result`.
-}
idGraph : Result (List String) Graph
idGraph =
    Graph.function "id" (Sig.label "x" (Sig.f32 (T.r1 b3))) identity


{-| The MLP's 4 features, 8 hidden units, 3 classes and 12 points.
-}
feat : Dim Feat
feat =
    T.dim Feat 4


{-| The MLP's hidden width.
-}
hidden : Dim Hidden
hidden =
    T.dim Hidden 8


{-| The MLP's classes.
-}
classes : Dim Classes
classes =
    T.dim Classes 3


{-| The number of training points.
-}
pts : Dim Pts
pts =
    T.dim Pts 12


{-| The MLP's parameters: two dense layers.
-}
mlpParams : Param.Spec { l1 : Linear T.F32 Feat Hidden, l2 : Linear T.F32 Hidden Classes }
mlpParams =
    Param.record (\l1 l2 -> { l1 = l1, l2 = l2 })
        |> Param.sub .l1 (Linear.params T.float32 feat hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


{-| The MLP's batch: features and integer labels.
-}
mlpBatch : Sig.Sig ( T.Tensor Float T.F32 (T.R2 Pts Feat), T.Tensor Int T.I64 (T.R1 Pts) )
mlpBatch =
    Sig.pair (Sig.f32 (T.r2 pts feat)) (Sig.i64 (T.r1 pts))


{-| The MLP's loss: cross-entropy of the logits against the labels.
-}
mlpLoss : { l1 : Linear T.F32 Feat Hidden, l2 : Linear T.F32 Hidden Classes } -> ( T.Tensor Float T.F32 (T.R2 Pts Feat), T.Tensor Int T.I64 (T.R1 Pts) ) -> T.Tensor Float T.F32 T.R0
mlpLoss p ( x, y ) =
    x |> Linear.apply p.l1 |> T.tanh |> Linear.apply p.l2 |> Nn.crossEntropyIndices y


{-| The MLP's training step, SGD at 0.5.
-}
mlpStep : Result (List String) Graph
mlpStep =
    Train.step mlpParams (Optim.sgd 0.5) mlpBatch mlpLoss


{-| The MLP's loss without training.
-}
mlpMeasure : Result (List String) Graph
mlpMeasure =
    Train.measure mlpParams mlpBatch mlpLoss


{-| The 12 points: point `i` is in class `i` modulo 3, its feature at its class 1 + s and the others
s − 0.5, with s = (`i` // 3) / 4.
-}
points : ( List Float, List Int )
points =
    let
        one i =
            ( List.map
                (\j ->
                    if j == modBy 3 i then
                        1 + toFloat (i // 3) / 4

                    else
                        toFloat (i // 3) / 4 - 0.5
                )
                (List.range 0 3)
            , modBy 3 i
            )

        all =
            List.map one (List.range 0 11)
    in
    ( List.concatMap Tuple.first all, List.map Tuple.second all )


{-| The batch as fed inputs.
-}
batchInputs : List ( String, Session.Input )
batchInputs =
    [ ( "batch0", Session.fromFloats (Tuple.first points) ), ( "batch1", Session.fromInts (Tuple.second points) ) ]


{-| The batch as values keyed for `Tensor.Eval.run`.
-}
batchValues : Dict String Value
batchValues =
    Dict.fromList
        [ ( "batch0", { dtype = "f32", shape = [ 12, 4 ], data = Floats (Tuple.first points) } )
        , ( "batch1", { dtype = "si64", shape = [ 12 ], data = Ints (Tuple.second points) } )
        ]


{-| The first contents of the step's buffers, from seed 1.
-}
initial : List ( String, Bytes )
initial =
    Train.initial mlpParams (Optim.sgd 0.5) 1


{-| Returns the graph's resident inputs' buffers decoded from `buffers` by their specs.
-}
residentValues : Graph -> List ( String, Bytes ) -> Dict String Value
residentValues g buffers =
    Graph.inputs g
        |> List.filterMap
            (\spec ->
                case spec.role of
                    Graph.Resident n ->
                        List.filter (\( m, _ ) -> m == n) buffers
                            |> List.head
                            |> Maybe.andThen (\( _, b ) -> Result.toMaybe (Elements.decode spec b))
                            |> Maybe.map (Tuple.pair n)

                    Graph.Fed ->
                        Nothing
            )
        |> Dict.fromList


{-| Runs `body` on a graph that must have been built.
-}
withGraph : Result (List String) Graph -> (Graph -> Expectation) -> Expectation
withGraph r body =
    case r of
        Ok g ->
            body g

        Err e ->
            Expect.fail (String.join "; " e)


{-| A host session whose ports send and receive nothing.
-}
hostSession : Session.Session Session.Message
hostSession =
    Session.host { send = \_ -> Cmd.none, receive = \_ -> Sub.none } identity


{-| Hands an in-Elm or host session one `Next` for each queued reply, and returns the session and
the replies in order.
-}
drain : Session.Session msg -> ( Session.Session msg, List Event )
drain s =
    if S.queued s == 0 then
        ( s, [] )

    else
        let
            ( s1, e ) =
                Session.update S.Next s

            ( s2, es ) =
                drain s1
        in
        ( s2, e :: es )


{-| Sends commands and drains the replies.
-}
sendAll : List Session.Command -> Session.Session msg -> ( Session.Session msg, List Event )
sendAll commands s =
    drain (Tuple.first (Session.send commands s))


{-| Compiles a graph and drains the replies.
-}
compileAll : Graph -> Session.Session msg -> ( Session.Session msg, Session.Handle, List Event )
compileAll g s =
    let
        ( s1, h, _ ) =
            Session.compile g s

        ( s2, es ) =
            drain s1
    in
    ( s2, h, es )


{-| Returns the requests a host session would send for `commands`, or the refusal.
-}
requestsFor : List Session.Command -> Session.Session msg -> Result String (List Request)
requestsFor commands s =
    S.hostRequests commands s |> Result.map Tuple.second


{-| Describes an event briefly, for comparing lists of events.
-}
describeEvent : Event -> String
describeEvent e =
    case e of
        Compiled _ ->
            "Compiled"

        CompileFailed _ m ->
            "CompileFailed " ++ m

        Ran _ _ ->
            "Ran"

        Got n b ->
            "Got " ++ n ++ " " ++ String.fromInt (Bytes.width b)

        Loaded p b ->
            "Loaded " ++ p ++ " " ++ String.fromInt (Bytes.width b)

        Failed m ->
            "Failed " ++ m

        Finished c ->
            "Finished " ++ String.fromInt c



-- Requests


requests : Test
requests =
    describe "requests"
        [ test "run pads each input to 16 bytes" <|
            \_ ->
                Protocol.encode (Run 7 [ fromList [ 1, 2, 3 ], fromList (List.range 1 16) ])
                    |> bytesAre (hdr 7 1 0 ++ [ 1, 2, 3 ] ++ List.repeat 13 0 ++ List.range 1 16)
        , test "put" <|
            \_ -> Protocol.encode (Put "w" (fromList [ 9, 8 ])) |> bytesAre (hdr 0 2 0 ++ str "w" ++ [ 0, 9, 8 ])
        , test "get" <|
            \_ -> Protocol.encode (Get 5 "w") |> bytesAre (hdr 5 3 0 ++ str "w")
        , test "save" <|
            \_ -> Protocol.encode (Save "w" "a/b") |> bytesAre (hdr 0 4 0 ++ str "w" ++ [ 0 ] ++ str "a/b")
        , test "loadInto" <|
            \_ -> Protocol.encode (LoadInto "w" "a/b") |> bytesAre (hdr 0 5 0 ++ str "w" ++ [ 0 ] ++ str "a/b")
        , test "loadRangeInto writes offset and length as two words each" <|
            \_ ->
                Protocol.encode (LoadRangeInto "w" "p" (4294967296 + 5) 7)
                    |> bytesAre (hdr 0 7 0 ++ str "w" ++ [ 0 ] ++ le32 5 ++ le32 1 ++ le32 7 ++ le32 0 ++ str "p")
        , test "drop" <|
            \_ -> Protocol.encode (Drop "w") |> bytesAre (hdr 0 8 0 ++ str "w")
        , test "loadRange" <|
            \_ ->
                Protocol.encode (LoadRange 3 "p" 8 (2 * 4294967296 + 1))
                    |> bytesAre (hdr 3 9 0 ++ le32 8 ++ le32 0 ++ le32 1 ++ le32 2 ++ str "p")
        , test "compile: spec lines with a resident role and a scalar, then the MLIR" <|
            \_ ->
                Protocol.encode
                    (Compile 2
                        [ { name = "x", dtype = "ui8", shape = [ 2, 3 ], role = Graph.Fed }, { name = "w", dtype = "f32", shape = [ 3 ], role = Graph.Resident "p.w" } ]
                        [ { name = "loss", dtype = "f32", shape = [], role = Graph.Fed } ]
                        (fromList [ 77, 76 ])
                    )
                    |> bytesAre (hdr 2 10 0 ++ str "in x:ui8:2x3 w:f32:3:r=p.w\nout loss:f32:\n" ++ [ 77, 76 ])
        , test "load" <|
            \_ -> Protocol.encode (Load 4 "p") |> bytesAre (hdr 4 11 0 ++ str "p")
        , test "finish" <|
            \_ -> Protocol.encode (Finish 3) |> bytesAre (hdr 0 12 0 ++ le32 3)
        , test "one request is sent as itself" <|
            \_ -> Protocol.encodeAll [ Drop "w" ] |> bytesAre (hdr 0 8 0 ++ str "w")
        , test "several requests are sent as a sequence" <|
            \_ ->
                Protocol.encodeAll [ Drop "w", Get 1 "ab" ]
                    |> bytesAre (hdr 0 6 0 ++ le32 17 ++ hdr 0 8 0 ++ str "w" ++ le32 18 ++ hdr 1 3 0 ++ str "ab")
        ]



-- Host sessions


hostSessions : Test
hostSessions =
    describe "host sessions"
        [ test "ids follow the compile's, in order" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, _, _ ) =
                                Session.compile g hostSession
                        in
                        requestsFor [ Session.get "a", Session.load "p", Session.put "b" (fromList []), Session.loadRange "q" 0 8, Session.get "c" ] s
                            |> Result.map (List.map (Protocol.encode >> toList >> List.take 8))
                            |> Expect.equal (Ok [ le32 2 ++ le32 3, le32 3 ++ le32 11, le32 0 ++ le32 2, le32 4 ++ le32 9, le32 5 ++ le32 3 ])
        , test "a run sends its fed inputs in graph order, floats and ints encoded by dtype" <|
            \_ ->
                withGraph mlpStep <|
                    \g ->
                        let
                            ( s, (S.Handle id) as h, _ ) =
                                Session.compile g hostSession
                        in
                        requestsFor [ Session.run h (List.reverse batchInputs) ] s
                            |> Result.map (List.map (Protocol.encode >> toList))
                            |> Expect.equal
                                (Ok
                                    [ hdr id 1 0
                                        ++ f32s (Tuple.first points)
                                        ++ List.concatMap (\n -> le32 n ++ le32 0) (Tuple.second points)
                                    ]
                                )
        , test "bytes of the right width are sent as they are" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, (S.Handle id) as h, _ ) =
                                Session.compile g hostSession
                        in
                        requestsFor [ Session.run h [ ( "x", Session.fromBytes (fromList (List.range 1 12)) ) ] ] s
                            |> Result.map (List.map (Protocol.encode >> toList))
                            |> Expect.equal (Ok [ hdr id 1 0 ++ List.range 1 12 ++ List.repeat 4 0 ])
        , test "refusals: missing input, wrong width, ints for floats; nothing is sent" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, h, _ ) =
                                Session.compile g hostSession

                            refusal inputs =
                                ( requestsFor [ Session.put "a" (fromList []), Session.run h inputs ] s |> Result.map (always ())
                                , sendAll [ Session.run h inputs ] s |> Tuple.second |> List.map describeEvent
                                )
                        in
                        Expect.equal
                            [ ( Err "id: missing input x", [ "Failed id: missing input x" ] )
                            , ( Err "id: input x: 8 bytes, but f32 [3] takes 12", [ "Failed id: input x: 8 bytes, but f32 [3] takes 12" ] )
                            , ( Err "id: input x: Ints for a floating or mask input", [ "Failed id: input x: Ints for a floating or mask input" ] )
                            ]
                            [ refusal [ ( "y", Session.fromFloats [ 1, 2, 3 ] ) ]
                            , refusal [ ( "x", Session.fromBytes (fromList (List.repeat 8 0)) ) ]
                            , refusal [ ( "x", Session.fromInts [ 1, 2, 3 ] ) ]
                            ]
        ]



-- Replies


replies : Test
replies =
    describe "replies"
        [ test "ran: the fed outputs by name" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, (S.Handle id) as h, _ ) =
                                Session.compile g hostSession
                        in
                        case Session.update (S.Reply (fromList (hdr id 1 0 ++ f32s [ 1, 2, 3 ] ++ [ 0, 0, 0, 0 ]))) s of
                            ( _, Ran h2 outs ) ->
                                Expect.equal
                                    ( h2 == h, ( Session.floats "result" outs, Maybe.map toList (Session.bytes "result" outs) ), ( Session.value "result" outs, Session.ints "result" outs, Session.floats "x" outs ) )
                                    ( True, ( Just [ 1, 2, 3 ], Just (f32s [ 1, 2, 3 ]) ), ( Just { dtype = "f32", shape = [ 3 ], data = Floats [ 1, 2, 3 ] }, Nothing, Nothing ) )

                            ( _, other ) ->
                                Expect.fail (describeEvent other)
        , test "ran of the wrong width fails" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, S.Handle id, _ ) =
                                Session.compile g hostSession
                        in
                        Session.update (S.Reply (fromList (hdr id 1 0 ++ f32s [ 1, 2, 3 ]))) s
                            |> Tuple.second
                            |> describeEvent
                            |> Expect.equal "Failed Max.Session: id: a run reply of 12 bytes, which is not the graph's fed outputs"
        , test "compiled, and a failed compile, after which a run is refused" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            ( s, (S.Handle id) as h, _ ) =
                                Session.compile g hostSession

                            ( _, ok ) =
                                Session.update (S.Reply (fromList (hdr id 10 0))) s

                            ( s2, bad ) =
                                Session.update (S.Reply (fromList (hdr id 10 1 ++ str "no such op"))) s
                        in
                        Expect.equal
                            ( ok == Compiled h, describeEvent bad, sendAll [ Session.run h [ ( "x", Session.fromFloats [ 1, 2, 3 ] ) ] ] s2 |> Tuple.second |> List.map describeEvent )
                            ( True, "CompileFailed no such op", [ "Failed run: graph " ++ String.fromInt id ++ " is not compiled in this session" ] )
        , test "got, loaded and a failed loadRange are matched to what was asked" <|
            \_ ->
                case S.hostRequests [ Session.get "w", Session.load "a.bin", Session.loadRange "b.bin" 0 8 ] hostSession of
                    Ok ( s, [ Get g _, Load l _, LoadRange r _ _ _ ] ) ->
                        let
                            ( s1, e1 ) =
                                Session.update (S.Reply (fromList (hdr g 3 0 ++ [ 1, 2 ]))) s

                            ( s2, e2 ) =
                                Session.update (S.Reply (fromList (hdr l 11 0 ++ [ 5, 6, 7 ]))) s1

                            ( s3, e3 ) =
                                Session.update (S.Reply (fromList (hdr r 9 1 ++ str "loadRange: b.bin has 3 bytes, not [0, 8)"))) s2

                            ( _, e4 ) =
                                Session.update (S.Reply (fromList (hdr g 3 0))) s3
                        in
                        Expect.equal
                            [ "Got w 2", "Loaded a.bin 3", "Failed loadRange: b.bin has 3 bytes, not [0, 8)", "Failed Max.Session: a reply with code 3 and id " ++ String.fromInt g ++ ", which matches no request" ]
                            (List.map describeEvent [ e1, e2, e3, e4 ])

                    other ->
                        Expect.fail (Debug.toString (Result.map (Tuple.second >> List.length) other))
        , test "loadRange's bytes come back under its path" <|
            \_ ->
                case S.hostRequests [ Session.loadRange "b.bin" 0 8 ] hostSession of
                    Ok ( s, [ LoadRange r _ _ _ ] ) ->
                        Session.update (S.Reply (fromList (hdr r 9 0 ++ List.range 1 8))) s
                            |> Tuple.second
                            |> describeEvent
                            |> Expect.equal "Loaded b.bin 8"

                    _ ->
                        Expect.fail "no loadRange request"
        , test "a reply shorter than a header fails" <|
            \_ ->
                Session.update (S.Reply (fromList [ 1, 0, 0, 0 ])) hostSession
                    |> Tuple.second
                    |> describeEvent
                    |> Expect.equal "Failed Max.Session: a reply of 4 bytes, shorter than a header"
        ]



-- Elements


elements : Test
elements =
    let
        roundTrip v =
            Elements.encode v |> Result.andThen (Elements.decode v)

        bytesOf v =
            Elements.encode v |> Result.map toList

        cases =
            [ { dtype = "f16", shape = [ 6 ], data = Floats [ 1, -2, 65504, 1 / 0, 2 ^ -24, -0.5 ] }
            , { dtype = "bf16", shape = [ 3 ], data = Floats [ 1, -2.5, -1 / 0 ] }
            , { dtype = "f32", shape = [ 2 ], data = Floats [ 1.5, -2 ] }
            , { dtype = "f64", shape = [ 1 ], data = Floats [ 0.1 ] }
            , { dtype = "si8", shape = [ 2 ], data = Ints [ -128, 127 ] }
            , { dtype = "si32", shape = [ 2 ], data = Ints [ -5, 2147483647 ] }
            , { dtype = "si64", shape = [ 2 ], data = Ints [ -1, 1099511627776 ] }
            , { dtype = "ui8", shape = [ 2 ], data = Ints [ 0, 255 ] }
            , { dtype = "ui64", shape = [ 2 ], data = Ints [ -1, 5 ] }
            , { dtype = "bool", shape = [ 2, 1 ], data = Bools [ True, False ] }
            ]

        isNaNs v =
            case v of
                Ok { data } ->
                    case data of
                        Floats l ->
                            List.map isNaN l

                        _ ->
                            []

                Err _ ->
                    []
    in
    describe "elements"
        [ test "the bytes of f16, bf16, si64, ui64 and bool elements" <|
            \_ ->
                Expect.equal
                    [ Ok [ 0x00, 0x3C, 0x00, 0xC0 ], Ok [ 0x80, 0x3F ], Ok (List.repeat 8 255 ++ [ 2, 0, 0, 0, 1, 0, 0, 0 ]), Ok (List.repeat 8 255), Ok [ 1, 0 ] ]
                    [ bytesOf { dtype = "f16", shape = [ 2 ], data = Floats [ 1, -2 ] }
                    , bytesOf { dtype = "bf16", shape = [], data = Floats [ 1 ] }
                    , bytesOf { dtype = "si64", shape = [ 2 ], data = Ints [ -1, 4294967298 ] }
                    , bytesOf { dtype = "ui64", shape = [ 1 ], data = Ints [ -1 ] }
                    , bytesOf { dtype = "bool", shape = [ 2 ], data = Bools [ True, False ] }
                    ]
        , test "every dtype round-trips through bytes" <|
            \_ -> Expect.equal (List.map Ok cases) (List.map roundTrip cases)
        , test "NaN patterns are read as NaN" <|
            \_ ->
                Expect.equal [ [ True, True ], [ True ] ]
                    [ isNaNs (Elements.decode { dtype = "f16", shape = [ 2 ] } (fromList [ 0x00, 0x7E, 0x01, 0xFC ]))
                    , isNaNs (Elements.decode { dtype = "bf16", shape = [ 1 ] } (fromList [ 0xC0, 0x7F ]))
                    ]
        , test "a width that does not fit is refused" <|
            \_ ->
                Elements.decode { dtype = "si32", shape = [ 3 ] } (fromList (List.repeat 10 0))
                    |> Expect.equal (Err "10 bytes, but si32 [3] takes 12")
        , test "check refuses dtype, shape, kind, count and range" <|
            \_ ->
                Expect.equal
                    [ Err "dtype f64, but the graph takes f32"
                    , Err "shape [3], but the graph takes [2]"
                    , Err "Ints for a floating or mask input"
                    , Err "1 elements, but the shape has 2"
                    , Err "value 300 does not fit ui8"
                    , Ok ()
                    ]
                    [ Elements.check { dtype = "f32", shape = [ 2 ] } { dtype = "f64", shape = [ 2 ], data = Floats [ 1, 2 ] }
                    , Elements.check { dtype = "f32", shape = [ 2 ] } { dtype = "f32", shape = [ 3 ], data = Floats [ 1, 2, 3 ] }
                    , Elements.check { dtype = "f32", shape = [ 2 ] } { dtype = "f32", shape = [ 2 ], data = Ints [ 1, 2 ] }
                    , Elements.check { dtype = "f32", shape = [ 2 ] } { dtype = "f32", shape = [ 2 ], data = Floats [ 1 ] }
                    , Elements.check { dtype = "ui8", shape = [ 1 ] } { dtype = "ui8", shape = [ 1 ], data = Ints [ 300 ] }
                    , Elements.check { dtype = "bool", shape = [ 1 ] } { dtype = "bool", shape = [ 1 ], data = Bools [ True ] }
                    ]
        ]



-- In-Elm sessions


{-| An in-Elm session whose messages are themselves.
-}
elmSession : Session.Session Session.Message
elmSession =
    Session.inElm identity


{-| Returns the float elements of a run's output `name`, or an empty list.
-}
outFloats : String -> List Event -> List Float
outFloats name events =
    List.concatMap
        (\e ->
            case e of
                Ran _ outs ->
                    Session.floats name outs |> Maybe.withDefault []

                _ ->
                    []
        )
        events


{-| Returns the float elements of a value, or an empty list.
-}
floatsOf : Value -> List Float
floatsOf v =
    case v.data of
        Floats l ->
            l

        _ ->
            []


{-| The losses of `n` steps of the MLP run directly with `Tensor.Eval.run`, starting from `initial`;
with `rounded`, the resident values are rounded to `f32` after each step by a trip through bytes.
-}
directLosses : Bool -> Int -> Graph -> Result (List String) ( List Float, Dict String Value )
directLosses rounded n step =
    let
        round32 v =
            if rounded then
                Elements.encode v |> Result.andThen (Elements.decode v) |> Result.withDefault v

            else
                v
    in
    List.foldl
        (\_ acc ->
            acc
                |> Result.andThen
                    (\( losses, residents ) ->
                        Eval.run step (Dict.union batchValues residents)
                            |> Result.map
                                (\outs ->
                                    ( losses ++ (Dict.get "loss" outs |> Maybe.map floatsOf |> Maybe.withDefault [])
                                    , Dict.union (Dict.map (\_ v -> round32 v) (Dict.remove "loss" outs)) residents
                                    )
                                )
                    )
        )
        (Ok ( [], residentValues step initial ))
        (List.range 1 n)


inElmSessions : Test
inElmSessions =
    describe "in-Elm sessions"
        [ test "compile, put and run give what Tensor.Eval.run gives" <|
            \_ ->
                withGraph mlpMeasure <|
                    \g ->
                        let
                            ( s1, h, compiled ) =
                                compileAll g elmSession

                            params =
                                Param.initial mlpParams 1

                            ( _, ran ) =
                                sendAll (List.map (\( n, b ) -> Session.put n b) params ++ [ Session.run h batchInputs ]) s1

                            direct =
                                Eval.run g (Dict.union batchValues (residentValues g params))
                                    |> Result.toMaybe
                                    |> Maybe.andThen (Dict.get "result")
                                    |> Maybe.map floatsOf
                        in
                        Expect.equal ( List.map describeEvent compiled, Just (outFloats "result" ran) ) ( [ "Compiled" ], direct )
        , test "training steps change the parameters and match Tensor.Eval.run" <|
            \_ ->
                withGraph mlpStep <|
                    \g ->
                        let
                            ( s1, h, _ ) =
                                compileAll g elmSession

                            ( s2, puts ) =
                                sendAll (List.map (\( n, b ) -> Session.put n b) initial) s1

                            ( s3, ran ) =
                                sendAll (List.repeat 5 (Session.run h batchInputs)) s2

                            names =
                                List.map Tuple.first initial

                            ( _, got ) =
                                sendAll (List.map Session.get names) s3

                            changed =
                                List.map2
                                    (\( _, before ) e ->
                                        case e of
                                            Got _ after ->
                                                toList before /= toList after

                                            _ ->
                                                False
                                    )
                                    initial
                                    got

                            losses =
                                outFloats "loss" ran
                        in
                        case ( directLosses True 5 g, directLosses False 5 g ) of
                            ( Ok ( exact, _ ), Ok ( doubles, _ ) ) ->
                                Expect.all
                                    [ \_ -> Expect.equal [] puts
                                    , \_ -> Expect.equal 5 (List.length losses)
                                    , \_ -> Expect.equal exact losses
                                    , \_ -> Expect.equal True (List.all identity (List.map2 (\a b -> abs (a - b) <= 1.0e-5 * abs b) losses doubles))
                                    , \_ -> Expect.equal (List.repeat (List.length names) True) changed
                                    , \_ -> Expect.lessThan (List.head losses |> Maybe.withDefault 0) (List.drop 4 losses |> List.head |> Maybe.withDefault (1 / 0))
                                    ]
                                    ()

                            ( a, b ) ->
                                Expect.fail (Debug.toString ( Result.map Tuple.first a, Result.map Tuple.first b ))
        , test "put then get in one send" <|
            \_ ->
                sendAll [ Session.put "a" (fromList [ 1, 2, 3 ]), Session.get "a", Session.get "never" ] elmSession
                    |> Tuple.second
                    |> List.map describeEvent
                    |> Expect.equal [ "Got a 3", "Got never 0" ]
        , test "save, then loadInto restores the buffer" <|
            \_ ->
                let
                    ( _, events ) =
                        sendAll
                            [ Session.put "w" (fromList [ 4, 5 ])
                            , Session.save "w" "ck/w.bin"
                            , Session.put "w" (fromList [ 0 ])
                            , Session.loadInto "w" "ck/w.bin"
                            , Session.get "w"
                            ]
                            elmSession
                in
                Expect.equal [ Just [ 4, 5 ] ]
                    (List.map
                        (\e ->
                            case e of
                                Got _ b ->
                                    Just (toList b)

                                _ ->
                                    Nothing
                        )
                        events
                    )
        , test "real files fail; after load and loadRange the rest still runs" <|
            \_ ->
                Expect.equal
                    [ [ "Failed load: cannot open x.bin (an in-Elm session reads no files)", "Got a 0" ]
                    , [ "Failed loadRange: cannot open x.bin (an in-Elm session reads no files)", "Got a 0" ]
                    , [ "Failed loadRangeInto: cannot open x.bin (an in-Elm session reads no files)" ]
                    , [ "Failed loadInto: cannot open x.bin (an in-Elm session reads only files it saved)" ]
                    ]
                    (List.map (\c -> sendAll [ c, Session.get "a" ] elmSession |> Tuple.second |> List.map describeEvent)
                        [ Session.load "x.bin", Session.loadRange "x.bin" 0 8, Session.loadRangeInto "a" "x.bin" 0 8, Session.loadInto "a" "x.bin" ]
                    )
        , test "a run with a missing resident buffer fails" <|
            \_ ->
                withGraph mlpMeasure <|
                    \g ->
                        let
                            ( s1, h, _ ) =
                                compileAll g elmSession
                        in
                        sendAll [ Session.run h batchInputs, Session.get "a" ] s1
                            |> Tuple.second
                            |> List.map describeEvent
                            |> Expect.equal [ "Failed measure: no resident buffer param0" ]
        , test "finish gives Finished, and later commands are ignored" <|
            \_ ->
                let
                    ( s1, first ) =
                        sendAll [ Session.finish 3, Session.get "a" ] elmSession

                    ( _, second ) =
                        sendAll [ Session.get "a" ] s1
                in
                Expect.equal ( [ "Finished 3" ], [] ) ( List.map describeEvent first, List.map describeEvent second )
        , test "a negative GPU is refused at compile on both backends" <|
            \_ ->
                withGraph idGraph <|
                    \g ->
                        let
                            refused s =
                                let
                                    ( s1, _, _ ) =
                                        Session.compileWith { format = Session.Bytecode, device = Max.Gpu -1 } g s
                                in
                                drain s1 |> Tuple.second |> List.map describeEvent
                        in
                        Expect.equal
                            [ [ "CompileFailed Max: there is no GPU with the negative index -1" ], [ "CompileFailed Max: there is no GPU with the negative index -1" ] ]
                            [ refused elmSession, refused hostSession ]
        ]



-- Safetensors


safetensors : Test
safetensors =
    let
        header =
            BE.encode (BE.string """{"b":{"dtype":"F32","shape":[2],"data_offsets":[8,16]},"__metadata__":{"format":"pt"},"a":{"dtype":"BF16","shape":[2,2],"data_offsets":[0,8]}}""")
    in
    describe "safetensors"
        [ test "header length" <|
            \_ ->
                Expect.equal [ Just 16, Just (4294967296 + 3), Nothing ]
                    [ Safetensors.headerLength (fromList [ 16, 0, 0, 0, 0, 0, 0, 0 ])
                    , Safetensors.headerLength (fromList [ 3, 0, 0, 0, 1, 0, 0, 0 ])
                    , Safetensors.headerLength (fromList [ 1, 2 ])
                    ]
        , test "entries in data order, metadata skipped" <|
            \_ ->
                Safetensors.parse header
                    |> Expect.equal
                        (Ok
                            [ { name = "a", dtype = "BF16", shape = [ 2, 2 ], begin = 0, end = 8 }
                            , { name = "b", dtype = "F32", shape = [ 2 ], begin = 8, end = 16 }
                            ]
                        )
        , test "malformed headers are refused" <|
            \_ ->
                List.map (BE.string >> BE.encode >> Safetensors.parse >> Result.toMaybe)
                    [ "not json", """{"a":{"shape":[1],"data_offsets":[0,4]}}""", """{"a":{"dtype":"F32","shape":[1],"data_offsets":[0]}}""" ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "the commands readLength, readHeader and loadAll make" <|
            \_ ->
                case Safetensors.parse header of
                    Ok entries ->
                        Expect.equal
                            [ S.LoadRange "m.st" 0 8
                            , S.LoadRange "m.st" 8 100
                            , S.LoadRangeInto "raw.a" "m.st" 108 8
                            , S.LoadRangeInto "raw.b" "m.st" 116 8
                            ]
                            (Safetensors.readLength "m.st"
                                :: Safetensors.readHeader "m.st" 100
                                :: Safetensors.loadAll "m.st" (Safetensors.dataStart 100) (\e -> "raw." ++ e.name) entries
                            )

                    Err e ->
                        Expect.fail e
        ]
