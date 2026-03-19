module TailRecClosureAccTest exposing (main)

{-| Test tail-recursive accumulator closure in a let binding.
-}

-- CHECK: result: 15

import Html exposing (text)


recursiveLet : Int -> Int
recursiveLet n =
    let
        go acc m =
            if m <= 0 then acc else go (acc + m) (m - 1)
    in
    go 0 n


main =
    let
        result = recursiveLet 5
        _ = Debug.log "result" result
    in
    text "done"
