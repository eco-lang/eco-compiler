module BytesHostEndiannessTest exposing (main)

{-| `Bytes.getHostEndianness` is a `Task` that succeeds with an `Endianness`, `LE` on a
little-endian machine.

The program performs the task once at start-up and logs the result as `"LE"` or `"BE"`. The
expected output is `"LE"`, so the test assumes a little-endian host; on a big-endian machine it
would fail although `BE` is the correct answer there.
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
