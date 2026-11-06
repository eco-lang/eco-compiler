module TailRecCaseDestructTest exposing (main)

{-| Self tail-recursive functions whose tail calls sit in a `case` branch that
destructures a list with `x :: xs` give the right results.

  - `myFoldl (+) 0 [1, 2, 3, 4, 5]`, a hand-written left fold, is 15.
  - `mySum [1, 2, 3, 4]`, which calls `myFoldl` with `(+)`, is 10.
  - `myCountHelper 0 [10, 20, 30]`, which ignores each element with `_ :: rest`, counts 3.
-}

-- CHECK: foldl: 15
-- CHECK: sum: 10
-- CHECK: count: 3

import Html exposing (text)


myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl func acc list =
    case list of
        [] ->
            acc

        x :: xs ->
            myFoldl func (func x acc) xs


mySum : List Int -> Int
mySum list =
    myFoldl (+) 0 list


myCountHelper : Int -> List a -> Int
myCountHelper acc list =
    case list of
        [] ->
            acc

        _ :: rest ->
            myCountHelper (acc + 1) rest


main =
    let
        _ = Debug.log "foldl" (myFoldl (+) 0 [1, 2, 3, 4, 5])
        _ = Debug.log "sum" (mySum [1, 2, 3, 4])
        _ = Debug.log "count" (myCountHelper 0 [10, 20, 30])
    in
    text "done"
