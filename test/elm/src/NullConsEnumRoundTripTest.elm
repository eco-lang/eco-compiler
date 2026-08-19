module NullConsEnumRoundTripTest exposing (main)

{-| Null-cons embedding (HEAP_044): a 4-ctor enum value returned from a
function round-trips through case dispatch and equality. Every ctor is an
embedded null-cons constant carrying its declaration index.
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

        -- Kernel equality on two independently produced ctors: word equality.
        _ =
            Debug.log "eqSame" (pick 2 == East)

        _ =
            Debug.log "eqDiff" (pick 0 == West)

        -- Embedded ctors as ordinary heap-slot values (list members).
        _ =
            Debug.log "listAll" (List.length [ North, South, East, West ])

        -- The typed debug printer must name the ctor from the embedded
        -- DECLARATION INDEX, not fall back to "the type's first nullary
        -- ctor" (which would print North for all four).
        _ =
            Debug.log "printFirst" North

        _ =
            Debug.log "printLast" West

        _ =
            Debug.log "printViaFn" (pick 2)
    in
    text "done"
