module EmbeddedEmptyStringCaptureTest exposing (main)

{-| A local function that refers to an empty string defined in the enclosing
`let` sees it as empty, with length 0.
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
