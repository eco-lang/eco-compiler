module StringConcatTest exposing (main)

{-| `++` and `String.append` join strings.

`"Hello" ++ "World"`, a three-part `"Hello" ++ " " ++ "World"`, and
`String.append "foo" "bar"` are each logged.
-}

-- CHECK: concat1: "HelloWorld"
-- CHECK: concat2: "Hello World"
-- CHECK: append: "foobar"

import Html exposing (text)


main =
    let
        _ = Debug.log "concat1" ("Hello" ++ "World")
        _ = Debug.log "concat2" ("Hello" ++ " " ++ "World")
        _ = Debug.log "append" (String.append "foo" "bar")
    in
    text "done"
