module StringCreationMatrixTest exposing (main)

{-| The same string produced in different ways is `==`, finds the same `Dict`
entry, and matches the same string pattern in a `case`.

The string `"abc123"` is produced four ways: as a literal, as `"abc" ++
String.fromInt 123`, with `String.slice`, and with `String.reverse`. The test
logs three results:

  - `eq`: all four are equal and the concatenated one has length 6;
  - `dict`: a `Dict` keyed by the concatenated one returns its value for the
    literal, sliced and reversed ones;
  - `case`: the concatenated, sliced and reversed ones each match the
    `"abc123"` pattern.

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
