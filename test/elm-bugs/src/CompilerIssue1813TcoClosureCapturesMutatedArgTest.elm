module CompilerIssue1813TcoClosureCapturesMutatedArgTest exposing (main)

{-| A lambda created in a self tail call keeps the argument value of its own call.

<https://github.com/elm/compiler/issues/1813>

Elm 0.19.1 compiles the tail call into a `while` loop that reassigns `n`, and the closures
`\() -> n` all capture that one variable, so they all return 0. Each closure should return
the `n` of its own call: `[1,2,3]`.

-}

-- CHECK: results: [1,2,3]

import Html exposing (text)


loop : Int -> List (() -> Int) -> List (() -> Int)
loop n list =
    if n <= 0 then
        list

    else
        loop (n - 1) ((\() -> n) :: list)


main =
    let
        _ =
            Debug.log "results" (List.map (\f -> f ()) (loop 3 []))
    in
    text "done"
