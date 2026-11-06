module ListCursorEscapeTest exposing (main)

{-| Self-recursive drop-while functions return the remaining suffix of a list,
whether they stop at its first element, in the middle, or run off the end.

`skipBelow`, `skipBelowF` and `skipUntil` drop leading elements of an Int, Float
or String list while a condition holds and return the rest. Most input lists are
built with `List.map` over `List.range`. The cases cover a stop in the middle
(`midChunk`), at the first element (`atStart`), past the end (`toEnd`), an empty
input, a literal list (`cells`), a suffix that is itself walked again
(`rewalk`), a 50000-element list (`long`, `longLen`), and 300 rounds over fresh
2000-element lists whose suffix heads and lengths are summed (`churn`).
`lastEven` keeps a suffix in an accumulator argument instead of returning it
directly.

## eco

Exercises the escape-slot form of the list-cursor rewrite in
runtime/src/codegen/Passes/EcoListCursor.cpp. Each drop-while loop returns the
rest of the list it walks, so the rewritten loop carries a (node, idx) cursor
and calls `eco_list_pos_view` once after the loop. `List.map` builds the inputs
as chunked spines, so a loop can stop mid-chunk (idx > 0), at the start of a
node (idx 0), or at the end of the list. `rewalk` walks a view made at a loop
exit with a cursor again, and `churn` builds fresh spines every round so minor
collections run between and around the exits' views.

-}

-- CHECK: midChunk: [6,7,8,9,10]
-- CHECK: atStart: [1,2,3,4,5,6,7,8,9,10]
-- CHECK: toEnd: []
-- CHECK: empty: []
-- CHECK: cells: [4,5]
-- CHECK: rewalk: [9,10]
-- CHECK: rewalkSum: 19
-- CHECK: floats: [3.5,4.5]
-- CHECK: strings: ["d","e"]
-- CHECK: lastEven: [10]
-- CHECK: long: 49001
-- CHECK: longLen: 1000
-- CHECK: churn: (225750,374550)

import Html exposing (text)


skipBelow : Int -> List Int -> List Int
skipBelow limit xs =
    case xs of
        x :: rest ->
            if x < limit then
                skipBelow limit rest

            else
                xs

        [] ->
            []


skipBelowF : Float -> List Float -> List Float
skipBelowF limit xs =
    case xs of
        x :: rest ->
            if x < limit then
                skipBelowF limit rest

            else
                xs

        [] ->
            []


skipUntil : String -> List String -> List String
skipUntil s xs =
    case xs of
        x :: rest ->
            if x /= s then
                skipUntil s rest

            else
                xs

        [] ->
            []


{-| Returns the suffix starting at the last even element, or `acc` if there is
none; the current candidate suffix is carried in the accumulator argument.
-}
lastEvenSuffix : List Int -> List Int -> List Int
lastEvenSuffix acc xs =
    case xs of
        x :: rest ->
            if modBy 2 x == 0 then
                lastEvenSuffix xs rest

            else
                lastEvenSuffix acc rest

        [] ->
            acc


chunked : Int -> List Int
chunked n =
    List.map (\x -> x + 0) (List.range 1 n)


main =
    let
        ten =
            chunked 10

        rest =
            skipBelow 9 (skipBelow 6 ten)

        long =
            skipBelow 49001 (chunked 50000)

        _ =
            Debug.log "midChunk" (skipBelow 6 ten)

        _ =
            Debug.log "atStart" (skipBelow 0 ten)

        _ =
            Debug.log "toEnd" (skipBelow 100 ten)

        _ =
            Debug.log "empty" (skipBelow 3 [])

        _ =
            Debug.log "cells" (skipBelow 4 [ 1, 2, 3, 4, 5 ])

        _ =
            Debug.log "rewalk" rest

        _ =
            Debug.log "rewalkSum" (List.sum rest)

        _ =
            Debug.log "floats" (skipBelowF 3 (List.map (\x -> toFloat x + 0.5) (List.range 0 4)))

        _ =
            Debug.log "strings" (skipUntil "d" (List.map identity [ "a", "b", "c", "d", "e" ]))

        _ =
            Debug.log "lastEven" (lastEvenSuffix [] (chunked 10))

        _ =
            Debug.log "long" (Maybe.withDefault 0 (List.head long))

        _ =
            Debug.log "longLen" (List.length long)

        -- Each round drops the elements below 5 * i from a fresh `chunked 2000`.
        churn =
            List.foldl
                (\i ( h, l ) ->
                    let
                        r =
                            skipBelow (i * 5) (chunked 2000)
                    in
                    ( h + Maybe.withDefault 0 (List.head r), l + List.length r )
                )
                ( 0, 0 )
                (List.range 1 300)

        _ =
            Debug.log "churn" churn
    in
    text "ok"
