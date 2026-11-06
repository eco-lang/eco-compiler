module NullConsEnumRoundTripTest exposing (main)

{-| Values of a four-constructor enumeration, `Compass`, returned from a
function, are matched by `case`, compared with `==`, placed in a list and
printed by `Debug.log` with their own constructor names.

`pick` maps 0, 1 and 2 to `North`, `South` and `East`, and any other number to
`West`. The last three lines check that `Debug.log` prints `North`, `West`
and `East` for those constructors, whether written directly or returned by
`pick`.

## eco

Exercises null-constructor embedding (HEAP_044 in design_docs/invariants.csv;
plans/null-cons-hpointer-embedding.md). Every `Compass` constructor is an embedded constant word
carrying its declaration index, so a value returned from a function must round-trip through case
dispatch, kernel equality (word equality) and `Debug.log`, which recovers the constructor name
from the index.

-}

-- CHECK: viaFn1: "north"
-- CHECK: viaFn2: "south"
-- CHECK: viaFn3: "east"
-- CHECK: viaFn4: "west"
-- CHECK: eqSame: True
-- CHECK: eqDiff: False
-- CHECK: listAll: 4
-- CHECK: printFirst: North
-- CHECK: printLast: West
-- CHECK: printViaFn: East

import Html exposing (text)


type Compass
    = North
    | South
    | East
    | West


pick : Int -> Compass
pick n =
    case n of
        0 ->
            North

        1 ->
            South

        2 ->
            East

        _ ->
            West


show : Compass -> String
show c =
    case c of
        North ->
            "north"

        South ->
            "south"

        East ->
            "east"

        West ->
            "west"


main =
    let
        _ =
            Debug.log "viaFn1" (show (pick 0))

        _ =
            Debug.log "viaFn2" (show (pick 1))

        _ =
            Debug.log "viaFn3" (show (pick 2))

        _ =
            Debug.log "viaFn4" (show (pick 3))

        _ =
            Debug.log "eqSame" (pick 2 == East)

        _ =
            Debug.log "eqDiff" (pick 0 == West)

        _ =
            Debug.log "listAll" (List.length [ North, South, East, West ])

        _ =
            Debug.log "printFirst" North

        _ =
            Debug.log "printLast" West

        _ =
            Debug.log "printViaFn" (pick 2)
    in
    text "done"
