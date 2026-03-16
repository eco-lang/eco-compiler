module CaseSingleCtorBoolMultiTypeTest exposing (main)

{-| Test case expression on a single-constructor custom type wrapping Bool
when another single-constructor type wrapping Int exists in scope.

Reproduces a codegen bug where findSingleCtorUnboxedField searches all
single-constructor types and may find a type wrapping Int (unboxed) instead
of the actual ForceMultiline type wrapping Bool (boxed). This causes
eco.project.custom to emit i64 for a Bool field, but the subsequent
eco.case with case_kind="bool" expects i1.
-}

-- CHECK: nested_true: "split"
-- CHECK: nested_false: "join"
-- CHECK: extract_true: True
-- CHECK: extract_false: False
-- CHECK: wrap_int: 42

import Html exposing (text)


type ForceMultiline
    = ForceMultiline Bool


type Wrapper
    = Wrapper Int


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


useWrapper : Wrapper -> Int
useWrapper w =
    case w of
        Wrapper n ->
            n


main =
    let
        _ = Debug.log "nested_true" (nestedMatch True)
        _ = Debug.log "nested_false" (nestedMatch False)
        _ = Debug.log "extract_true" (extractBool (ForceMultiline True))
        _ = Debug.log "extract_false" (extractBool (ForceMultiline False))
        _ = Debug.log "wrap_int" (useWrapper (Wrapper 42))
    in
    text "done"
