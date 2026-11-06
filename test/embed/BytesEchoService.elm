port module BytesEchoService exposing (main)

{-| The program `embed_host.js` drives in its `bytes` and `unit-flags` scenarios, built both for the
JS backend and as a Node addon (run-node-addon-tests.sh), so that the two can be compared: a bytes
port service (PORT_008). It is a fixture, not an E2E test: it never ends on its own.

At start it sends on `bytesOut` the Bytes forms the native runtime keeps, in order: the empty Bytes
(an embedded constant), one byte (a nursery object), 100,000 bytes (over the 8 KiB large-object
threshold, so a pinned body) and a 50,000-byte slice of those (`Decode.bytes` at offset 10). After
that it sends every Bytes value that arrives on `bytesIn` straight back out on `bytesOut`.

-}

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Platform


port bytesOut : Bytes -> Cmd msg


port bytesIn : (Bytes -> msg) -> Sub msg


type Msg
    = Got Bytes


{-| Byte `i` is `i` mod 251.
-}
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


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , Cmd.batch
        (List.map bytesOut
            [ Encode.encode (Encode.sequence [])
            , Encode.encode (Encode.unsignedInt8 7)
            , large
            , slice
            ]
        )
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got bytes ->
            ( model, bytesOut bytes )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> bytesIn Got
        }
