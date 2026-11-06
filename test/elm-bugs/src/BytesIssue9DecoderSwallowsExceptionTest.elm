module BytesIssue9DecoderSwallowsExceptionTest exposing (main)

{-| `Bytes.Decode.decode` turns any exception thrown inside a decoder into `Nothing`.

<https://github.com/elm/bytes/issues/9>

The decoder's `try`/`catch` is meant for reads past the end of the bytes, but in Elm 0.19.1
(elm/bytes 1.0.8) it also catches a crash in user code (a `Debug.todo`, or a stack overflow) in a
`map`, and `decode` returns `Nothing` as if the bytes were malformed. The crash must propagate.

-}

-- EXIT: 1
-- CHECK: boom
-- CHECK-NOT: decoded: Nothing

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode (E.unsignedInt8 1)

        _ =
            Debug.log "decoded" (D.decode (D.map (\_ -> Debug.todo "boom") D.unsignedInt8) bytes |> Maybe.map (\() -> ()))
    in
    text "done"
