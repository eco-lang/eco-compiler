module LetBasicTest exposing (main)

{-| Test basic let expressions.
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
