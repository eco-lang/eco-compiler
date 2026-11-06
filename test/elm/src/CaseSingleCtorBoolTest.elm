module CaseSingleCtorBoolTest exposing (main)

{-| A case expression matches `True` and `False` literal patterns inside a
single-constructor custom type wrapping a `Bool`.

`nestedMatch` wraps a `Bool` in `ForceMultiline` and matches it against
`ForceMultiline True` and `ForceMultiline False`, and `extractBool` unwraps the
`Bool` with a variable pattern. The test prints each branch's result and each
unwrapped value.

-}

-- CHECK: nested_true: "split"
-- CHECK: nested_false: "join"
-- CHECK: extract_true: True
-- CHECK: extract_false: False

import Html exposing (text)


type ForceMultiline
    = ForceMultiline Bool


nestedMatch : Bool -> String
nestedMatch b =
    let
        fm =
            ForceMultiline b
    in
    case fm of
        ForceMultiline True ->
            "split"

        ForceMultiline False ->
            "join"


extractBool : ForceMultiline -> Bool
extractBool fm =
    case fm of
        ForceMultiline b ->
            b


main =
    let
        _ = Debug.log "nested_true" (nestedMatch True)
        _ = Debug.log "nested_false" (nestedMatch False)
        _ = Debug.log "extract_true" (extractBool (ForceMultiline True))
        _ = Debug.log "extract_false" (extractBool (ForceMultiline False))
    in
    text "done"
