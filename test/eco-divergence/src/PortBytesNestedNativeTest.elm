port module PortBytesNestedNativeTest exposing (main)

{-| PORT ERROR (native only): `Bytes` inside another port payload type.

A native port carries JSON text, except a bytes port, whose whole payload is
`Bytes` and which carries raw bytes (PORT_008, plans/native-bytes-ports.md). JSON
text cannot carry `Bytes`, so a native build rejects a `Bytes` anywhere else in
a payload; the JS backend accepts it. This limit goes when a general binary port
interface for native code replaces the interim bytes ports.

-}

-- DIVERGENCE: eco's native target rejects Bytes nested in a port payload; eco's JS target accepts it, and Elm 0.19.1 rejects any Bytes port
-- COMPILE-ERROR: PORT ERROR, Bytes inside a List port payload
-- CHECK: -- PORT ERROR -
-- CHECK: The `chunksOut` port carries `Bytes` inside another type

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Platform


port chunksOut : List Bytes -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), chunksOut [ Encode.encode (Encode.unsignedInt8 1) ] )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
