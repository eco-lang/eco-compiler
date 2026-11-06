module LetSeparatedStagingTest exposing (main)

{-| A function defined with fewer parameters than its annotated type returns, from
different `case` branches, lambdas that take the remaining arguments in
different groupings.

`caseFunc : Int -> Int -> Int -> Int -> Int` takes `n` and `k`; for `n = 0` it
returns `\a -> let y = a + k in \z -> y + z`, otherwise `\a z -> a + z`. `main`
logs `caseFunc 0 10 5 3`, which is 18. The file has no CHECK line, so its output
is not compared.

-}

import Html exposing (text)

caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc n k =
    case n of
        0 -> \a -> let y = a + k in \z -> y + z
        _ -> \a z -> a + z

main =
    let
        _ = Debug.log "result" (caseFunc 0 10 5 3)
    in
    text "done"
