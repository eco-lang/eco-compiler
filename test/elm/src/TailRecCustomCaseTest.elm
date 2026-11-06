module TailRecCustomCaseTest exposing (main)

{-| A self tail-recursive function that matches on a user-defined list type and
destructures its `Cons` constructor gives the right result: summing
`Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))` is 10.
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
