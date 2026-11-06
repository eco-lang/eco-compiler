port module PortBytesEchoTest exposing (main)

{-| `Bytes` out and in over ports, an Eco extension (stock Elm rejects a `Bytes`
port payload). On the JS backend the outgoing port encodes its payload with
`_Json_encodeBytes` and the incoming one decodes with `_Json_decodeBytes`
(`Compiler.LocalOpt.Erased.Port`). Natively both are bytes ports (PORT_008):
no JSON codec, and the host gets and gives raw bytes.

The harness echo (test/ElmE2ETestBase.hpp `installPortEchoBounce` under the JIT,
test/aot_port_host.cpp under AOT) feeds every `echoOut` payload back into `echoIn`,
so the program gets back the bytes it sent and logs them.

Reported bug (2026-11-05, fixed 2026-11-06 by plans/native-bytes-ports.md): a
native build of a program with a `Bytes` port failed to link with
`undefined symbol: Elm_Kernel_Json_encodeBytes`, which no native kernel defined.

-}

-- CHECK: PortBytesEchoTest sent: 4
-- CHECK: PortBytesEchoTest got: [1,2,254,255]

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Platform


port echoOut : Bytes -> Cmd msg


port echoIn : (Bytes -> msg) -> Sub msg


type Msg
    = Got Bytes


type alias Model =
    { received : Bool }


payload : Bytes
payload =
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 [ 1, 2, 254, 255 ]))


{-| The bytes as a list of unsigned 8-bit values.
-}
toList : Bytes -> Maybe (List Int)
toList bytes =
    let
        step ( n, acc ) =
            if n <= 0 then
                Decode.succeed (Decode.Done (List.reverse acc))

            else
                Decode.map (\b -> Decode.Loop ( n - 1, b :: acc )) Decode.unsignedInt8
    in
    Decode.decode (Decode.loop ( Bytes.width bytes, [] ) step) bytes


init : () -> ( Model, Cmd Msg )
init _ =
    let
        _ =
            Debug.log "PortBytesEchoTest sent" (Bytes.width payload)
    in
    ( { received = False }, echoOut payload )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got bytes ->
            let
                _ =
                    Debug.log "PortBytesEchoTest got" (Maybe.withDefault [] (toList bytes))
            in
            ( { model | received = True }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.received then
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
