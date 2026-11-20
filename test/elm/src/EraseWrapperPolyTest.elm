module EraseWrapperPolyTest exposing (main)

{-| A polymorphic wrapper `type Box a = Box a` used at several types, including
inside a polymorphic helper whose type variable stays open (an empty list
argument), and a phantom-typed wrapper `type Quantity number units = Quantity
number` at `Float` and `Int` with two unit types.

-}

-- CHECK: ints: [1,2]
-- CHECK: strs: ["a"]
-- CHECK: recs: [3]
-- CHECK: empty: 0
-- CHECK: dist: 3.5
-- CHECK: count: 7
-- CHECK: q: Quantity 1.5
-- CHECK: unboxList: [Quantity 1.5,Quantity 2]

import Html exposing (text)


type Box a
    = Box a


unbox : Box a -> a
unbox (Box a) =
    a


countBoxes : List (Box a) -> Int
countBoxes boxes =
    List.length boxes


type Quantity number units
    = Quantity number


type Meters
    = Meters


type Items
    = Items


add : Quantity number units -> Quantity number units -> Quantity number units
add (Quantity a) (Quantity b) =
    Quantity (a + b)


meters : Float -> Quantity Float Meters
meters =
    Quantity


items : Int -> Quantity Int Items
items =
    Quantity


main =
    let
        _ =
            Debug.log "ints" (List.map unbox [ Box 1, Box 2 ])

        _ =
            Debug.log "strs" (List.map unbox [ Box "a" ])

        _ =
            Debug.log "recs" (List.map (unbox >> .n) [ Box { n = 3 } ])

        _ =
            Debug.log "empty" (countBoxes [])

        (Quantity d) =
            add (meters 1.5) (meters 2)

        _ =
            Debug.log "dist" d

        (Quantity c) =
            add (items 3) (items 4)

        _ =
            Debug.log "count" c

        _ =
            Debug.log "q" (meters 1.5)

        _ =
            Debug.log "unboxList" [ meters 1.5, meters 2 ]
    in
    text "done"
