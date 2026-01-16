module Mrec exposing (main)

import Html exposing (text)

isEvenOddExample : Int -> ( Bool, Bool )
isEvenOddExample n =
    let
        isEven : Int -> Bool
        isEven m =
            if m == 0 then
                True
            else
                isOdd (m - 1)

        isOdd : Int -> Bool
        isOdd m =
            if m == 0 then
                False
            else
                isEven (m - 1)
    in
    ( isEven n, isOdd n )

main = isEvenOddExample |> Debug.toString |> text