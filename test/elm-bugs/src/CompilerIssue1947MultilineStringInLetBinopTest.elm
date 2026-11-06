module CompilerIssue1947MultilineStringInLetBinopTest exposing (..)

{-| A multi-line string whose closing quotes are left of the `let` body cannot be followed by an operator.

<https://github.com/elm/compiler/issues/1947>

The closing `"""` of a multi-line string ends up in column 1, and Elm 0.19.1 then rejects the
`++` after it with a parse error, as if the string's contents set the indentation. The program is
valid and should compile.

-}

-- CHECK: someString: "\n!"

import Html exposing (text)


main =
    let
        someString =
            """
""" ++ "!"

        _ =
            Debug.log "someString" someString
    in
    text "done"
