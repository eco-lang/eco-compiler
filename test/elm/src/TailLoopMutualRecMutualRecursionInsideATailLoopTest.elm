module TailLoopMutualRecMutualRecursionInsideATailLoopTest exposing (..)

{-| A self tail-recursive function whose loop body defines a pair of mutually recursive
local functions, and calls one of them to compute the next accumulator, gives the right
result.

`loop n acc` counts down from `n`, and on each step defines `isEven` and `isOdd` in a
`let`, each calling the other on `k - 1`. It adds one to the accumulator when `isEven n`
holds, so `loop 4 0` counts the even numbers 4 and 2 and returns 2.

-}

-- CHECK: testValue: 2

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


testValue : Int
testValue =
    loop 4 0


loop : Int -> Int -> Int
loop n acc =
    if n <= 0 then
        acc

    else
        let
            isEven k =
                if k == 0 then
                    True

                else
                    isOdd (k - 1)

            isOdd k =
                if k == 0 then
                    False

                else
                    isEven (k - 1)
        in
        loop (n - 1)
            (if isEven n then
                acc + 1

             else
                acc
            )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
