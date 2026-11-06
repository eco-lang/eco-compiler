module AccessorFunctionFieldInListTest exposing (main)

{-| Record accessors for function-typed fields can be used as list elements.

`.op` and `.op2` read fields of type `Int -> Int`. They are placed in a list of
type `List (Ops -> Int -> Int)`, and each is applied to one record and then to
10, giving `10 + 1` and `10 * 2`.

-}

-- CHECK: results: [11,20]

import Html exposing (text)


type alias Ops =
    { op : Int -> Int, op2 : Int -> Int }


main =
    let
        ops : Ops
        ops =
            { op = \n -> n + 1, op2 = \n -> n * 2 }

        getters : List (Ops -> Int -> Int)
        getters =
            [ .op, .op2 ]

        _ =
            Debug.log "results" (List.map (\g -> g ops 10) getters)
    in
    text "done"
