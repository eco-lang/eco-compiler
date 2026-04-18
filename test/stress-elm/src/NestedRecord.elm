module NestedRecord exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


type alias Inner =
    { x : Int
    , y : Int
    }


type alias Outer =
    { label : Int
    , inner : Inner
    }


buildRecords : Int -> List Outer -> List Outer
buildRecords i acc =
    if i <= 0 then
        acc
    else
        buildRecords (i - 1) ({ label = i, inner = { x = i, y = -i } } :: acc)


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


negateInner : Outer -> Outer
negateInner r =
    { r | inner = { x = -r.inner.x, y = -r.inner.y } }


main =
    let
        original =
            buildRecords m []

        transformed =
            applyNTimes n (List.map negateInner) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
