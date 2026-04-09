module EmbeddedEmptyStringCaptureTest exposing (main)

{-| Test empty string captured by a closure and used in operations.
-}

-- CHECK: isEmpty: True
-- CHECK: len: 0

import Html exposing (text)


main =
    let
        s =
            ""

        f () =
            ( String.isEmpty s, String.length s )

        ( isEmpty, len ) =
            f ()

        _ = Debug.log "isEmpty" isEmpty
        _ = Debug.log "len" len
    in
    text "done"
