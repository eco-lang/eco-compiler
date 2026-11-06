module CaseSingleCtorBoolMultiTypeTest exposing (main)

{-| A case expression matches `True` and `False` literal patterns inside a
single-constructor custom type wrapping a `Bool`, while another
single-constructor type, wrapping an `Int`, is defined in the same module.

`nestedMatch` wraps a `Bool` in `ForceMultiline` and matches it against
`ForceMultiline True` and `ForceMultiline False`. `extractBool` unwraps the
`Bool` with a variable pattern, and `useWrapper` unwraps the `Int` from
`Wrapper 42`. The test prints each branch's result and each unwrapped value.

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
