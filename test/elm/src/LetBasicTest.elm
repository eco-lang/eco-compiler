module LetBasicTest exposing (main)

{-| Two groups of `let` bindings, where later bindings use earlier ones: `x + y` on two
Int literals gives 5, and `"hello" ++ " " ++ "world"` gives `"hello world"`.
-}

-- CHECK: result1: 5
-- CHECK: result2: "hello world"

import Html exposing (text)


main =
    let
        x = 2
        y = 3
        result1 = x + y

        greeting = "hello"
        name = "world"
        result2 = greeting ++ " " ++ name

        _ = Debug.log "result1" result1
        _ = Debug.log "result2" result2
    in
    text "done"
