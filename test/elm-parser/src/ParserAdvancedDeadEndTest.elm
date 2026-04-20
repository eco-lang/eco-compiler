module ParserAdvancedDeadEndTest exposing (main)

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
