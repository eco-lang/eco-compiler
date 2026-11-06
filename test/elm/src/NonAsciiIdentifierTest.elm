module NonAsciiIdentifierTest exposing (main)

{-| A top-level value whose name contains a non-ASCII letter, `café`, is
read as one identifier and can be referenced; the program logs its value, 7.
-}

-- CHECK: NonAsciiIdentifierTest: 7

import Html exposing (text)


café : Int
café =
    7


main =
    let
        _ =
            Debug.log "NonAsciiIdentifierTest" café
    in
    text "done"
