module ErrorMessagesIssue322LetRecursiveRecordLambdaTest exposing (main)

{-| A `let`-bound record whose field is a lambda that refers back to the record (through
another lambda) is rejected as an infinite loop, although the same definitions at top level
compile and run.

<https://github.com/elm/error-message-catalog/issues/322>

Elm 0.19.1 reports BAD RECURSION ("The `func` value is defined directly in terms of itself")
for the `let` version. The recursion goes through a lambda, so it is well founded: the program
should compile and print 120.

-}

-- CHECK: factorial 5: 120

import Html exposing (text)


factorial : Int -> Int
factorial num =
    let
        eval f x =
            f () x

        func =
            { f =
                \n ->
                    if n == 0 then
                        1

                    else
                        n * eval (\_ -> func.f) (n - 1)
            }
    in
    func.f num


main =
    let
        _ =
            Debug.log "factorial 5" (factorial 5)
    in
    text "done"
