module EqualityIntPapWithStringChainTest exposing (main)

{-| Test that using (==) as a function value on Int coexists with
string pattern matching in a case expression. Both paths register
Elm_Kernel_Utils_equal - the PAP path must use AllBoxed ABI.
Exercises CGEN_038 and KERN_006.
-}

-- CHECK: filtered: [5, 5]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        "bar" ->
            "matched bar"

        _ ->
            "other"


main =
    let
        eq = (==)
        filtered = List.filter (eq 5) [1, 2, 5, 3, 5]
        _ = Debug.log "filtered" filtered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
