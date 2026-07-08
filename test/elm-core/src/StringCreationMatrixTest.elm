module StringCreationMatrixTest exposing (main)

{-| The same logical ASCII string built via several creation paths (literal,
String.fromInt, slice, reverse, ++) must be mutually equal, hash-equal as Dict
keys, and match the same string `case` pattern — regardless of the underlying
representation (interned UTF-8 leaf / view / UTF-16). Value-blind by design.
-}

-- CHECK: Creation.eq: True
-- CHECK: Creation.dict: True
-- CHECK: Creation.case: True

import Dict
import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "abc123" ->
            "matched"

        _ ->
            "no"


main : Html.Html msg
main =
    let
        viaLiteral =
            "abc123"

        viaConcat =
            "abc" ++ String.fromInt 123

        viaSlice =
            String.slice 2 8 "XYabc123ZW"

        viaReverse =
            String.reverse "321cba"

        eq =
            (viaLiteral == viaConcat)
                && (viaConcat == viaSlice)
                && (viaSlice == viaReverse)
                && (String.length viaConcat == 6)

        d =
            Dict.fromList [ ( viaConcat, 1 ), ( "other", 2 ) ]

        dictOk =
            (Dict.get "abc123" d == Just 1)
                && (Dict.get viaSlice d == Just 1)
                && (Dict.get viaReverse d == Just 1)

        caseOk =
            (classify viaConcat == "matched")
                && (classify viaSlice == "matched")
                && (classify viaReverse == "matched")

        _ =
            Debug.log "Creation.eq" eq

        _ =
            Debug.log "Creation.dict" dictOk

        _ =
            Debug.log "Creation.case" caseOk
    in
    text ""
