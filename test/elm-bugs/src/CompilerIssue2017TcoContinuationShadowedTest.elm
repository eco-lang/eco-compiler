module CompilerIssue2017TcoContinuationShadowedTest exposing (main)

{-| A continuation passed through a tail call captures the reassigned argument and calls itself.

<https://github.com/elm/compiler/issues/2017>

In Elm 0.19.1 the TCO loop reassigns `continuation`, so the closure
`\newValue -> continuation newValue` ends up calling itself: the program overflows the stack.
It should call the original continuation and return 1.

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
