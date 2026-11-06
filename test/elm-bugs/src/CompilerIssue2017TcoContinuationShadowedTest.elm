module CompilerIssue2017TcoContinuationShadowedTest exposing (main)

{-| A lambda passed in a self tail call must call the original continuation, not itself.

<https://github.com/elm/compiler/issues/2017>

Elm 0.19.1 compiles the tail call to a loop that reassigns `continuation`, so the lambda
`\newValue -> continuation (newValue + 1)` ends up calling itself and the program overflows the
stack. `windDown 1 identity` should call `identity 1` and return 1.

-}

-- CHECK: windDown: 1

import Html exposing (text)


windDown : Int -> (Int -> Int) -> Int
windDown value continuation =
    if value > 0 then
        windDown (value - 1) (\newValue -> continuation (newValue + 1))

    else
        continuation 0


main =
    let
        _ =
            Debug.log "windDown" (windDown 1 identity)
    in
    text "done"
