port module PortBytesEchoSizesTest exposing (main)

{-| `Bytes` of every form the native runtime keeps them in, out and back in over
a bytes port (PORT_008): the empty Bytes (an embedded constant), a small buffer
(a nursery object), a 100,000-byte buffer (over the 8 KiB large-object threshold,
so a pinned body), and a 50,000-byte slice of that one (`Decode.bytes`, a slice
object over the same body).

The harness echo sends each payload back; the program sends the next once the
previous one is back, and logs each one's width and the sum of its bytes.

-}

-- CHECK: PortBytesEchoSizesTest got: (0,0)
-- CHECK: PortBytesEchoSizesTest got: (1,7)
-- CHECK: PortBytesEchoSizesTest got: (100000,12492401)
-- CHECK: PortBytesEchoSizesTest got: (50000,6245410)
-- CHECK: PortBytesEchoSizesTest done: 4

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Platform


port echoOut : Bytes -> Cmd msg


port echoIn : (Bytes -> msg) -> Sub msg


type Msg
    = Got Bytes


type alias Model =
    { pending : List Bytes
    , received : Int
    }


large : Bytes
large =
    Encode.encode (Encode.sequence (List.map (\i -> Encode.unsignedInt8 (modBy 251 i)) (List.range 0 99999)))


{-| Bytes 10 to 50,009 of `large`, read with `Decode.bytes`.
-}
slice : Bytes
slice =
    let
        decoder =
            Decode.bytes 10 |> Decode.andThen (\_ -> Decode.bytes 50000)
    in
    Maybe.withDefault (Encode.encode (Encode.sequence [])) (Decode.decode decoder large)


payloads : List Bytes
payloads =
    [ Encode.encode (Encode.sequence [])
    , Encode.encode (Encode.unsignedInt8 7)
    , large
    , slice
    ]


{-| The sum of the bytes as unsigned 8-bit values.
-}
sum : Bytes -> Int
sum bytes =
    let
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Decode.Done acc)

            else
                Decode.map (\b -> Decode.Loop ( n - 1, acc + b )) Decode.unsignedInt8
    in
    Maybe.withDefault -1 (Decode.decode (Decode.loop ( Bytes.width bytes, 0 ) step) bytes)


sendNext : Model -> ( Model, Cmd Msg )
sendNext model =
    case model.pending of
        next :: rest ->
            ( { model | pending = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortBytesEchoSizesTest done" model.received
            in
            ( model, Cmd.none )


init : () -> ( Model, Cmd Msg )
init _ =
    sendNext { pending = payloads, received = 0 }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got bytes ->
            let
                _ =
                    Debug.log "PortBytesEchoSizesTest got" ( Bytes.width bytes, sum bytes )
            in
            sendNext { model | received = model.received + 1 }


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.received >= List.length payloads then
        Sub.none

    else
        echoIn Got


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
