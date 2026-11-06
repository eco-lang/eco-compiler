module CompilerIssue1947MultilineStringInLetBinopTest exposing (..)

{-| A multi-line string whose closing quotes are left of the `let` body cannot be followed by an operator.

<https://github.com/elm/compiler/issues/1947>

The closing `"""` of a multi-line string in a let binding sits in column 1, and Elm 0.19.1
rejects the `++` that follows it with a parse error. The program is valid; it should compile and
log the string, a newline followed by `!`.

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
