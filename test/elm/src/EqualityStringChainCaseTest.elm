module EqualityStringChainCaseTest exposing (main)

{-| Test that string equality in chain patterns (tuple case) coexists with
direct string equality calls.

When a string pattern appears in a tuple case like (String, Bool), the
decision tree may produce a Chain node with IsStr test, which calls
Utils_equal with I1 return. Direct (==) on strings calls Utils_equal
with eco.value return. Both must use the same kernel signature.
-}

-- CHECK: case1: "matched foo+True"
-- CHECK: case2: "matched bar+False"
-- CHECK: case3: "other"
-- CHECK: eq1: True
-- CHECK: eq2: False

import Html exposing (text)


classify : String -> Bool -> String
classify s b =
    case ( s, b ) of
        ( "foo", True ) -> "matched foo+True"
        ( "bar", False ) -> "matched bar+False"
        _ -> "other"


main =
    let
        _ = Debug.log "case1" (classify "foo" True)
        _ = Debug.log "case2" (classify "bar" False)
        _ = Debug.log "case3" (classify "baz" True)
        _ = Debug.log "eq1" ("hello" == "hello")
        _ = Debug.log "eq2" ("hello" == "world")
    in
    text "done"
