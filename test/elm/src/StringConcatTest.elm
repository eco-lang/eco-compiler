module StringConcatTest exposing (main)

{-| Test string concatenation.
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
