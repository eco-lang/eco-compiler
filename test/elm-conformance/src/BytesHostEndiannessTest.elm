module BytesHostEndiannessTest exposing (main)

{-| `Bytes.getHostEndianness`, recorded from Elm on node (run-js-e2e.js --record) on a
little-endian host. eco's kernel took no arguments and returned the raw word 0 or 1, neither a
Task nor an `Endianness`, although elm/bytes calls it as
`Elm.Kernel.Bytes.getHostEndianness LE BE` (plans/kg-reported-bugs.md step 1, kernel audit).

-}

-- CHECK: host endianness: "LE"

import Bytes exposing (Endianness(..))
import Task


type Msg
    = Got Endianness


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform Got Bytes.getHostEndianness )
        , update =
            \(Got e) model ->
                let
                    _ =
                        Debug.log "host endianness"
                            (case e of
                                LE ->
                                    "LE"

                                BE ->
                                    "BE"
                            )
                in
                ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
