module ParserAdvancedDeadEndTest exposing (main)

{-| `Parser.Advanced.run` reports a failed `token` with the custom problem value given in its `Token`.

The parser expects the token `"hello"` and is run on `"world"`. The test
checks that the run fails and that the first dead end's `problem` is
`Expected "hello"`, the value supplied with the token.

Among what is not tested: the dead end's row, column and context stack, and
any dead ends after the first.
-}

-- CHECK: custom_problem: True

import Html exposing (text)
import Parser.Advanced as PA


type MyProblem
    = Expected String


p : PA.Parser c MyProblem ()
p =
    PA.token (PA.Token "hello" (Expected "hello"))


main =
    let
        result = PA.run p "world"
        hasExpected =
            case result of
                Err (de :: _) ->
                    case de.problem of
                        Expected s ->
                            s == "hello"

                _ ->
                    False
        _ = Debug.log "custom_problem" hasExpected
    in
    text "done"
