module TailLoopMutualRecMutualRecursionInsideATailLoopTest exposing (..)

{-| Mutual recursion inside a tail loop.

From `SourceIR.TailLoopMutualRecCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
