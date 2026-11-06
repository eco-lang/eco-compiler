module RecursiveTopLevelLambdaTest exposing (..)

{-| A top-level value defined as a lambda that refers to itself can be called recursively.

`count` is defined as `\n -> ...` rather than with a parameter, and calls
`count (n + 1)` until `n > 3`, so `count 0` gives 4.
-}

-- CHECK: testValue: 4

import Basics exposing (..)
import Char exposing (Char)
import Html exposing (text)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple


testValue =
    count 0


count =
    \n ->
        if n > 3 then
            n

        else
            count (n + 1)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
