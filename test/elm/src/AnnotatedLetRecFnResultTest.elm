module AnnotatedLetRecFnResultTest exposing (main)

{-| A recursive let-bound function whose type annotation has a function as its result works.

`go : Int -> (a -> a) -> (a -> a)` composes `f` with itself on each of `n`
steps, doubling the number of applications each time, so `twice 4` applies
`\x -> x + 1` sixteen (2 to the power 4) times to 0.

-}

-- CHECK: AnnotatedLetRecFnResultTest: 16

import Html exposing (text)


twice : Int -> Int
twice m =
    let
        go : Int -> (a -> a) -> (a -> a)
        go n f =
            if n <= 0 then
                f

            else
                go (n - 1) (f >> f)
    in
    go m (\x -> x + 1) 0


main =
    let
        _ =
            Debug.log "AnnotatedLetRecFnResultTest" (twice 4)
    in
    text "done"
