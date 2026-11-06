port module PortBytesEmitTest exposing (main)

{-| Bytes emitted into an incoming port by a host (PORT_010,
plans/native-bytes-ports-2.md). Each `emitOut` payload is `[op] ++ body`; the
harness (test/ElmE2ETestBase.hpp under the JIT, test/aot_port_host.cpp under
AOT) answers each one with a result on `emitIn` and a verdict on
`emitVerdict`:

  - op 0: `reverse body`, emitted with capacity = its length;
  - op 1: the same with capacity len + len/2 + 1, a short fill kept in place
    when the value is large;
  - op 2: the same with capacity 4 len + 64, a short fill copied;
  - op 3: `[rc]` of an emit whose fill cancels (2);
  - op 4: `[rc]` of an emit made inside a fill (4);
  - op 5: `reverse body` emitted from another thread;
  - op 6: `reverse body` emitted from another thread, from a retained copy,
    after the callback has returned;
  - op 7: op 0 with the heap path made to fail, so the emit falls back;
  - op 8: op 0, with a collection forced before the queued value is
    delivered, which aborts unless the value moved.

The verdict is 1 when the emit took the path the op expects (direct in the
heap, off the heap, or the fallback); the JIT harness checks that from the
runtime's emit counters, and the AOT host, which cannot see them, always
says 1. The program logs `[op, width, sum, first byte, verdict]` once it has
both. While requests are outstanding it also keeps a timer running, whose hold
keeps the event loop up while op 6's thread has yet to emit: nothing else holds
it between that callback's return and the thread's emit.

-}

-- CHECK: PortBytesEmitTest got: [0,0,0,-1,1]
-- CHECK: PortBytesEmitTest got: [0,1,3,3,1]
-- CHECK: PortBytesEmitTest got: [0,31,3348,213,1]
-- CHECK: PortBytesEmitTest got: [0,32,3568,220,1]
-- CHECK: PortBytesEmitTest got: [0,4000,498888,135,1]
-- CHECK: PortBytesEmitTest got: [0,6000,749004,79,1]
-- CHECK: PortBytesEmitTest got: [0,20000,2499308,189,1]
-- CHECK: PortBytesEmitTest got: [1,0,0,-1,1]
-- CHECK: PortBytesEmitTest got: [1,1,3,3,1]
-- CHECK: PortBytesEmitTest got: [1,4000,498888,135,1]
-- CHECK: PortBytesEmitTest got: [1,6000,749004,79,1]
-- CHECK: PortBytesEmitTest got: [1,20000,2499308,189,1]
-- CHECK: PortBytesEmitTest got: [2,0,0,-1,1]
-- CHECK: PortBytesEmitTest got: [2,31,3348,213,1]
-- CHECK: PortBytesEmitTest got: [2,6000,749004,79,1]
-- CHECK: PortBytesEmitTest got: [2,20000,2499308,189,1]
-- CHECK: PortBytesEmitTest got: [3,1,2,2,1]
-- CHECK: PortBytesEmitTest got: [4,1,4,4,1]
-- CHECK: PortBytesEmitTest got: [5,100,11858,194,1]
-- CHECK: PortBytesEmitTest got: [5,20000,2499308,189,1]
-- CHECK: PortBytesEmitTest got: [6,100,11858,194,1]
-- CHECK: PortBytesEmitTest got: [6,20000,2499308,189,1]
-- CHECK: PortBytesEmitTest got: [7,100,11858,194,1]
-- CHECK: PortBytesEmitTest got: [8,100,11858,194,1]
-- CHECK: PortBytesEmitTest done: 24
-- CHECK-NOT: ,0]

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Platform
import Time


port emitOut : Bytes -> Cmd msg


port emitIn : (Bytes -> msg) -> Sub msg


port emitVerdict : (Bytes -> msg) -> Sub msg


type Msg
    = Got Bytes
    | Verdict Bytes
    | Tick


type alias Model =
    { pending : List ( Int, Int )
    , current : Int
    , result : Maybe Bytes
    , verdict : Maybe Int
    , received : Int
    }


{-| The (op, body length) of each request, in order. Op 6 is not last, so that
the harness's thread for it is joined by the request after it.
-}
requests : List ( Int, Int )
requests =
    List.map (Tuple.pair 0) [ 0, 1, 31, 32, 4000, 6000, 20000 ]
        ++ List.map (Tuple.pair 1) [ 0, 1, 4000, 6000, 20000 ]
        ++ List.map (Tuple.pair 2) [ 0, 31, 6000, 20000 ]
        ++ [ ( 3, 5 ), ( 4, 5 ), ( 5, 100 ), ( 5, 20000 ), ( 6, 100 ), ( 6, 20000 ), ( 7, 100 ), ( 8, 100 ) ]


body : Int -> List Encode.Encoder
body n =
    List.map (\i -> Encode.unsignedInt8 (modBy 251 (i * 7 + 3))) (List.range 0 (n - 1))


request : ( Int, Int ) -> Bytes
request ( op, n ) =
    Encode.encode (Encode.sequence (Encode.unsignedInt8 op :: body n))


{-| The bytes as unsigned 8-bit values.
-}
toList : Bytes -> List Int
toList bytes =
    let
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.map (\b -> Decode.Loop ( n - 1, b :: acc )) Decode.unsignedInt8
    in
    Maybe.withDefault [] (Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes)


sendNext : Model -> ( Model, Cmd Msg )
sendNext model =
    case model.pending of
        next :: rest ->
            ( { model | pending = rest, current = Tuple.first next, result = Nothing, verdict = Nothing }
            , emitOut (request next)
            )

        [] ->
            let
                _ =
                    Debug.log "PortBytesEmitTest done" model.received
            in
            ( model, Cmd.none )


{-| Logs and moves on once both the result and the verdict are in.
-}
settle : Model -> ( Model, Cmd Msg )
settle model =
    case ( model.result, model.verdict ) of
        ( Just bytes, Just verdict ) ->
            let
                values =
                    toList bytes

                _ =
                    Debug.log "PortBytesEmitTest got"
                        [ model.current
                        , Bytes.width bytes
                        , List.sum values
                        , Maybe.withDefault -1 (List.head values)
                        , verdict
                        ]
            in
            sendNext { model | received = model.received + 1 }

        _ ->
            ( model, Cmd.none )


init : () -> ( Model, Cmd Msg )
init _ =
    sendNext { pending = requests, current = -1, result = Nothing, verdict = Nothing, received = 0 }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got bytes ->
            settle { model | result = Just bytes }

        Verdict bytes ->
            settle { model | verdict = Just (Maybe.withDefault 0 (List.head (toList bytes))) }

        Tick ->
            ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.received >= List.length requests then
        Sub.none

    else
        Sub.batch [ emitIn Got, emitVerdict Verdict, Time.every 20 (\_ -> Tick) ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
