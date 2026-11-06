module AddTest exposing (main)

{-| `Debug.log` prints an `Int` bound in a `let`.

Despite the module's name, the program does no addition: it logs the literal
42.

-}

-- CHECK: AddTest: 42

import Html exposing (text)


main =
    let
        result =
            42

        _ =
            Debug.log "AddTest" result
    in
    text "hello"
