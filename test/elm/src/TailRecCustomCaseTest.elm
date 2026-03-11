module TailRecCustomCaseTest exposing (main)

{-| Test tail-recursive function with case on custom type and
pattern destructuring, ensuring TailRec handles FanOut correctly.
-}

-- CHECK: total: 10

import Html exposing (text)


type MyList a
    = Nil
    | Cons a (MyList a)


sumMyList : Int -> MyList Int -> Int
sumMyList acc list =
    case list of
        Nil ->
            acc

        Cons x rest ->
            sumMyList (acc + x) rest


main =
    let
        myList = Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))
        _ = Debug.log "total" (sumMyList 0 myList)
    in
    text "done"
