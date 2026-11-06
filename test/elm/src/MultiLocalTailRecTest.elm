module MultiLocalTailRecTest exposing (main)

{-| Two independent self-recursive functions defined in the same `let` block, each calling itself in tail position, both run correctly.

`countDown 5` recurses down to `0` and returns `0`; `sumUp 5 0` accumulates
`5 + 4 + 3 + 2 + 1` into `15`. The logged sum is `15`.
-}

-- CHECK: result: 15

import Html exposing (text)


main =
    let
        countDown i =
            if i <= 0 then
                0

            else
                countDown (i - 1)

        sumUp i acc =
            if i <= 0 then
                acc

            else
                sumUp (i - 1) (acc + i)

        _ =
            Debug.log "result" (countDown 5 + sumUp 5 0)
    in
    text "done"
