module EqualityMultiTypePapTest exposing (main)

{-| Test that (==) used as a function value across multiple types
(Int, String, Char) in the same module does not cause kernel
signature mismatch. All must use AllBoxed ABI.
-}

-- CHECK: intFiltered: [3, 3]
-- CHECK: strFiltered: ["b", "b"]
-- CHECK: classify: "matched foo"

import Html exposing (text)


classify : String -> String
classify s =
    case s of
        "foo" ->
            "matched foo"

        _ ->
            "other"


main =
    let
        eqInt = (==)
        eqStr = (==)
        intFiltered = List.filter (eqInt 3) [1, 2, 3, 4, 3]
        strFiltered = List.filter (eqStr "b") ["a", "b", "c", "b"]
        _ = Debug.log "intFiltered" intFiltered
        _ = Debug.log "strFiltered" strFiltered
        _ = Debug.log "classify" (classify "foo")
    in
    text "done"
