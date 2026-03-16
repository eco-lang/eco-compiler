module CaseSingleCtorBoolTest exposing (main)

{-| Test case expression on a single-constructor custom type wrapping Bool.

Reproduces a codegen bug where eco.project.custom emits i64 (tag type) for a
Bool field inside a single-constructor wrapper, but the subsequent eco.case
with case_kind="bool" expects i1.
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
