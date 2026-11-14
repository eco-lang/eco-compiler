module MaxSessionTests exposing (suite)

{-| `Max.Session` sends a C++ host program its requests as bytes that the host parses with code of
its own, and it runs the same commands in Elm, where a wrong byte layout or a wrong update of a
buffer would still give plausible numbers. Without these tests a request the host would misread, a
reply read into the wrong event, or an in-Elm run that drifts from `Tensor.Eval` could go
unnoticed.

There are three graphs. `idGraph`, named `id`, is the identity on an `f32` vector of 3, with the
input `x` and the output `result`. The other two are a small multi-layer perceptron (MLP) with 4
features, 8 hidden units and 3 classes: `mlpStep`, a `Train.step` with SGD at rate 0.5, and
`mlpMeasure`, a `Train.measure` of the same loss, named `measure`, whose one output is `result`.
Both take the 12 `points` as the fed inputs `batch0` (`f32`, 12 × 4) and `batch1` (`si64`, 12).
Where a test fills their resident buffers, it fills them from `Param.initial` or `Train.initial`
with seed 1.

A host session here (`hostSession`) has ports that send and receive nothing. The requests it would
send for commands are read from `Max.Internal.Session.hostRequests` and
`Max.Internal.Protocol.encode`; the compile request `Max.Session.compile` builds is not read, as
its `Cmd` is dropped. Replies are handed to `Max.Session.update` as bytes the tests write. The answers a session makes itself are
collected by handing `update` one `Next` message for each queued reply (`drain`). Many tests
compare events through `describeEvent`, which keeps of the bytes of `Got` and `Loaded` only their
number, so there the bytes' contents are not checked.

The tests establish:

  - **Requests** (`requests`):
      - `run` pads an input of 3 bytes with 13 zero bytes and leaves one of 16 bytes as it is.
      - `put`, `get`, `save`, `loadInto`, `drop`, `load` and `finish` are each written as exact
        bytes: the 16-byte header with the request's id and code, then what the request carries.
      - `loadRangeInto` with an offset of 2³² + 5, and `loadRange` with a length of
        2 × 2³² + 1, write their offset and length as two words each, low word first.
      - `compile` writes the spec lines of a fed `ui8` input, a resident `f32` input and a scalar
        output, then the MLIR bytes.
      - `encodeAll` writes one request as itself, and two as a sequence in which each request is
        preceded by its length.
  - **Host sessions** (`hostSessions`):
      - After one compile, `get`, `load`, `put`, `loadRange` and `get` are given the ids 2, 3, 0,
        4 and 5; only each request's id and code are compared.
      - A run of `mlpStep` given its inputs in reverse order sends them in the graph's order, under
        the graph's id: `batch0`'s floats as `f32` and `batch1`'s ints as `si64`.
      - Bytes for `x` of the right width, 12, are sent as they are, followed by 4 zero bytes.
      - A missing input, bytes of the wrong width, and ints for the float input `x` are each
        refused: `hostRequests` refuses the whole list, a `put` before the run included, with a
        message naming the graph and the input, and a `send` of the run alone gives one event,
        `Failed` with that message.
  - **Replies** (`replies`):
      - A run reply holding one padded `f32` output gives `Ran` with the handle `compile` gave;
        `floats`, `bytes` (without the padding) and `value` read the output `result`, `ints`
        gives `Nothing` for it, and `floats` gives `Nothing` for `x`, which is an input.
      - A run reply whose payload lacks the padding gives `Failed`, naming the graph.
      - A compile reply with status 0 gives `Compiled` with the handle. One with status 1 gives
        `CompileFailed` with its payload as text, after which a `send` of a run of the handle
        gives `Failed`: the graph is not compiled in this session.
      - A `get` reply gives `Got` with the name asked for, a `load` reply `Loaded` with the path,
        and a `loadRange` reply with status 1 `Failed` with its payload as text; a second reply to
        the answered `get` gives `Failed`, as matching no request.
      - A `loadRange` reply with status 0 gives `Loaded` with the path asked for.
      - A reply of 4 bytes, shorter than a header, gives `Failed`.
  - **Elements** (`elements`):
      - `encode` writes the exact bytes expected for the `f16` elements 1 and −2, the `bf16`
        element 1, the `si64` elements −1 and 2³² + 2, the `ui64` element −1, and the `bool`
        elements `True` and `False`.
      - For each of the ten dtypes, the one to six values listed for it decode equal to
        themselves after `encode`. Among them are `f16`'s 65504, ∞ and 2⁻²⁴, `bf16`'s −∞,
        the limits of `si8` and `ui8`, and the `ui64` element −1.
      - The `f16` patterns `0x7E00` and `0xFC01` and the `bf16` pattern `0x7FC0` decode to
        NaN.
      - `decode` refuses 10 bytes for an `si32` tensor of shape `[3]`, which takes 12.
      - `check` refuses a value of another dtype, one of another shape, `Ints` for `f32`, too few
        elements, and 300 for `ui8`, each with its message, and accepts `Bools` for `bool`.
  - **In-Elm sessions** (`inElmSessions`):
      - Compiling `mlpMeasure` gives one `Compiled`, and after `put`s of `Param.initial`'s buffers
        a run gives exactly the `result` floats that `Tensor.Eval.run` gives on those buffers
        decoded by their specs.
      - For `mlpStep` from `Train.initial`'s buffers, the `put`s give no event, and five runs give
        five losses. These equal the losses of a direct `Tensor.Eval.run` loop that encodes and
        decodes the resident values in their dtype after each step, and each is within a relative
        1e-5 of the loss of a loop that does not. The fifth loss is below the first, and a `get` of
        each buffer afterwards gives bytes other than its first contents.
      - A `put` of 3 bytes, a `get` of it and a `get` of a name never set, in one `send`, give
        `Got` with 3 bytes and then `Got` with none.
      - A `put`, a `save`, another `put`, a `loadInto` from the saved path and a `get` give one
        event, `Got` with the first bytes.
      - A `load`, a `loadRange`, a `loadRangeInto`, and a `loadInto` of a path never saved, each
        followed by a `get`, each give `Failed` with its own message; the `get` is answered after
        the `load` and the `loadRange`, and skipped after the other two.
      - A run of `mlpMeasure` with no buffers put gives `Failed` naming the buffer `param0`, and
        the `get` after it is skipped.
      - `finish 3` gives `Finished 3`, and a `get` after it gives no event, in the same `send` or
        in a later one.
      - `compileWith` for the GPU −1 gives `CompileFailed` with `Max`'s message on both backends.
  - **Safetensors** (`safetensors`):
      - `headerLength` reads 16 and 2³² + 3 from 8 little-endian bytes, and `Nothing` from 2
        bytes.
      - `parse` of a header listing `b`, `__metadata__` and `a` gives the entries `a` then `b`,
        without the metadata.
      - `parse` refuses text that is not JSON, an entry with no `dtype`, and an entry whose
        `data_offsets` holds one integer.
      - `readLength`, `readHeader` for a header of 100 bytes, and `loadAll` give a `loadRange` of
        8 bytes at 0, one of 100 bytes at 8, and a `loadRangeInto` of each entry's bytes counted
        from 108, under the name given for it.

Among what is not tested: what the host does with any of these bytes, and whether it sends the
replies written here; the `Cmd`s a session returns, and so the order in which a program receives
answers; `subscriptions`; a `Message` handed to another session; `drop` through a session, and a
`save` or `drop` of a missing buffer; `fromValue`; `value` and `bytes` of an in-Elm run's outputs;
`compileWith` with `GenericText` or a GPU index that is not negative.

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


{-| Every test in this module, in six groups.
-}
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


{-| Returns the values of the bytes, in order.
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


{-| Returns the four bytes of `n` written as an unsigned 32-bit little-endian integer.
-}
le32 : Int -> List Int
le32 n =
    toList (BE.encode (BE.unsignedInt32 LE n))


{-| Returns the 16 bytes of a message header: `id`, `code`, `status` and a zero word, each as
`le32` writes it.
-}
hdr : Int -> Int -> Int -> List Int
hdr id code status =
    le32 id ++ le32 code ++ le32 status ++ le32 0


{-| Returns the UTF-8 bytes of `s`.
-}
str : String -> List Int
str s =
    toList (BE.encode (BE.string s))


{-| Returns the little-endian `f32` bytes of the floats, one after another.
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


{-| The tag in the type of `idGraph`'s axis.
-}
type B
    = B


{-| The tag in the type of the MLP's hidden axis.
-}
type Hidden
    = Hidden


{-| The tag in the type of the MLP's class axis.
-}
type Classes
    = Classes


{-| The tag in the type of the axis of the training points.
-}
type Pts
    = Pts


{-| The tag in the type of the MLP's feature axis.
-}
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


{-| The axis of the features of one point, which the MLP takes as its input.
-}
feat : Dim Feat
feat =
    T.dim Feat 4


{-| The axis of the MLP's hidden units.
-}
hidden : Dim Hidden
hidden =
    T.dim Hidden 8


{-| The axis of the classes the MLP tells apart.
-}
classes : Dim Classes
classes =
    T.dim Classes 3


{-| The axis of the training points.
-}
pts : Dim Pts
pts =
    T.dim Pts 12


{-| The description of the MLP's parameters: an `f32` dense layer from the features to the hidden
units, and one from the hidden units to the classes.
-}
mlpParams : Param.Spec { l1 : Linear T.F32 Feat Hidden, l2 : Linear T.F32 Hidden Classes }
mlpParams =
    Param.record (\l1 l2 -> { l1 = l1, l2 = l2 })
        |> Param.sub .l1 (Linear.params T.float32 feat hidden)
        |> Param.sub .l2 (Linear.params T.float32 hidden classes)


{-| The signature of the MLP's batch: the features, one row per point, and each point's class as
an `si64` label.
-}
mlpBatch : Sig.Sig ( T.Tensor Float T.F32 (T.R2 Pts Feat), T.Tensor Int T.I64 (T.R1 Pts) )
mlpBatch =
    Sig.pair (Sig.f32 (T.r2 pts feat)) (Sig.i64 (T.r1 pts))


{-| Returns the cross-entropy of the MLP's logits for the features `x` against the labels `y`. The
logits are `x` through the first layer, `tanh` and the second layer.
-}
mlpLoss : { l1 : Linear T.F32 Feat Hidden, l2 : Linear T.F32 Hidden Classes } -> ( T.Tensor Float T.F32 (T.R2 Pts Feat), T.Tensor Int T.I64 (T.R1 Pts) ) -> T.Tensor Float T.F32 T.R0
mlpLoss p ( x, y ) =
    x |> Linear.apply p.l1 |> T.tanh |> Linear.apply p.l2 |> Nn.crossEntropyIndices y


{-| The MLP's training graph, built by `Train.step`: one step of SGD at rate 0.5 on `mlpLoss`. Its
fed output `loss` is the loss on the parameters the run was given.
-}
mlpStep : Result (List String) Graph
mlpStep =
    Train.step mlpParams (Optim.sgd 0.5) mlpBatch mlpLoss


{-| The graph `measure`, built by `Train.measure`, that computes `mlpLoss` from the MLP's parameter
buffers and a batch, without training. Its one output, fed, is `result`.
-}
mlpMeasure : Result (List String) Graph
mlpMeasure =
    Train.measure mlpParams mlpBatch mlpLoss


{-| The 12 training points, as their 48 features in row-major order and their 12 labels. Point `i`
is in class `i` modulo 3; its feature at the index of its class is 1 + s and its other features are
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


{-| `points` as the fed inputs of `mlpStep` and `mlpMeasure`: the features as floats under
`batch0`, and the labels as ints under `batch1`.
-}
batchInputs : List ( String, Session.Input )
batchInputs =
    [ ( "batch0", Session.fromFloats (Tuple.first points) ), ( "batch1", Session.fromInts (Tuple.second points) ) ]


{-| `points` as values for `Tensor.Eval.run`, under the fed inputs' names: `batch0` of `f32` and
shape `[12, 4]`, and `batch1` of `si64` and shape `[12]`.
-}
batchValues : Dict String Value
batchValues =
    Dict.fromList
        [ ( "batch0", { dtype = "f32", shape = [ 12, 4 ], data = Floats (Tuple.first points) } )
        , ( "batch1", { dtype = "si64", shape = [ 12 ], data = Ints (Tuple.second points) } )
        ]


{-| The first contents of `mlpStep`'s resident buffers, from `Train.initial` with seed 1, as pairs
of a buffer's name and its bytes.
-}
initial : List ( String, Bytes )
initial =
    Train.initial mlpParams (Optim.sgd 0.5) 1


{-| Returns the resident inputs of `g`, each decoded by its spec from the buffer of its name in
`buffers`, keyed by resident name. An input whose buffer is missing or cannot be decoded is left
out.
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


{-| Returns `body`'s expectation for the built graph, or, when the graph could not be built, a
failure listing the build's errors.
-}
withGraph : Result (List String) Graph -> (Graph -> Expectation) -> Expectation
withGraph r body =
    case r of
        Ok g ->
            body g

        Err e ->
            Expect.fail (String.join "; " e)


{-| A host session whose ports send and receive nothing, and whose messages are its `Message`s
unchanged.
-}
hostSession : Session.Session Session.Message
hostSession =
    Session.host { send = \_ -> Cmd.none, receive = \_ -> Sub.none } identity


{-| Hands the session one `Next` message through `update` for each reply in its queue, and returns
the session, with its queue empty, and the events in the order the replies were queued.
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


{-| Sends `commands`, then drains the session as `drain` does, and returns the session and the
events. The `Cmd` that `send` returns is dropped, so from a host session only the replies the
session queued itself are seen.
-}
sendAll : List Session.Command -> Session.Session msg -> ( Session.Session msg, List Event )
sendAll commands s =
    drain (Tuple.first (Session.send commands s))


{-| Compiles `g`, then drains the session as `drain` does, and returns the session, the graph's
handle and the events. The `Cmd` that `compile` returns is dropped.
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


{-| Returns the requests a host session would send for `commands`, or the message with which it
refuses them.
-}
requestsFor : List Session.Command -> Session.Session msg -> Result String (List Request)
requestsFor commands s =
    S.hostRequests commands s |> Result.map Tuple.second


{-| Returns a short description of an event, for comparing lists of them: the constructor's name,
then the message it carries, or its name or path and the number of its bytes, or its exit code.
Handles, outputs and the contents of bytes are left out.
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


{-| The tests of the bytes `Max.Internal.Protocol` writes for each request.
-}
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


{-| The tests of the requests a host session builds from commands, and of the runs it refuses
before anything is sent.
-}
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


{-| The tests of how a host session reads reply bytes, written by the tests, into events.
-}
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


{-| The tests of `Max.Internal.Elements`: the exact bytes `encode` writes for five of the dtypes,
round trips through `encode` and `decode`, decoding, and `check`.
-}
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


{-| An in-Elm session whose messages are its `Message`s unchanged.
-}
elmSession : Session.Session Session.Message
elmSession =
    Session.inElm identity


{-| Returns the float elements of the output `name` of every `Ran` in `events`, joined in order.
A `Ran` with no such output, and every other event, adds nothing.
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


{-| Returns the elements of a value whose data are `Floats`, or an empty list for any other data.
-}
floatsOf : Value -> List Float
floatsOf v =
    case v.data of
        Floats l ->
            l

        _ ->
            []


{-| Runs `n` steps of the training graph `step` with `Tensor.Eval.run` on `batchValues`, starting
from the buffers of `initial`, and returns the loss of each step with the resident values after the
last, or the errors of the first step that fails. After each step every output but `loss` replaces
the resident value of its name.

With `rounded`, each new resident value is first encoded in its dtype and decoded again, which
rounds `f32` values to `f32` as an in-Elm session's buffers do; a value whose encoding or decoding
fails is kept as it is.

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


{-| The tests of sessions on the in-Elm backend. The last also checks a compile refusal on a host
session.
-}
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


{-| The tests of `Max.Safetensors`: reading a checkpoint's header length and entries, and the
commands that read and load a checkpoint.
-}
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
