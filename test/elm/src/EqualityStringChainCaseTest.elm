module EqualityStringChainCaseTest exposing (main)

{-| A `case` on a `( String, Bool )` tuple with string-literal patterns selects the right branch, and direct `==` on strings gives the right answer, in the same module.

`classify` matches `( "foo", True )` and `( "bar", False )`, and falls through to `"other"` for `( "baz", True )`. `"hello" == "hello"` is `True` and `"hello" == "world"` is `False`.
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
