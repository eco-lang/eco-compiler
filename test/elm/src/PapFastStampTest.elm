module PapFastStampTest exposing (main)

{-| LSS\_040 — `p|` PAP-of-global FAST stamp, runtime differential
(`plans/lss-pap-fast-stamp.md` §5).

A partial application of a global (`add 5`, `add3 4 5`, `tag "abc"`) flows
into a higher-order helper whose call site then carries a singleton
`{p|<global>|<k>}` annotation. Under `lss.stamp.papFast` that site is
FAST-stamped: the emission loads the `k` bound arguments back out of the PAP
object and calls the global's spec with the full row. If the stamp ever
loaded the wrong slots, the wrong kinds, or called the wrong spec, these
columns print different numbers — a wrong ANSWER, not a slow one, and one a
unit test cannot see.

The pin must print the same numbers in every flag arm: it is a guard.

Coverage, deliberately: k = 1 and k = 2; an Int return, a BOXED (String)
return and a TUPLE return — R4 in the plan's review named return-ABI parity
for spec targets as the one thing it could not settle by reading. Results are
reduced to Ints before logging so the CHECK lines do not depend on
`Debug.log`'s rendering of strings and tuples.

`List.map run inputs` is load-bearing: a single monomorphic use lets the
inliner fold the whole question away before any lambda set is consulted.

-}

import Html exposing (text)



-- CHECK: k1: [9, 10, 11]
-- CHECK: k2: [13, 14, 15]
-- CHECK: boxed: [7, 8, 9]
-- CHECK: tuple: [9, 11, 13]


add : Int -> Int -> Int
add a b =
    a + b


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


tag : String -> Int -> String
tag prefix n =
    prefix ++ String.repeat n "x"


pair : Int -> Int -> ( Int, Int )
pair a b =
    ( a, b * 2 )


applyI : (Int -> Int) -> Int -> Int
applyI f n =
    f n


applyS : (Int -> String) -> Int -> String
applyS f n =
    f n


applyT : (Int -> ( Int, Int )) -> Int -> ( Int, Int )
applyT f n =
    f n


run : Int -> { k1 : Int, k2 : Int, boxed : Int, tuple : Int }
run n =
    let
        ( x, y ) =
            applyT (pair 1) n
    in
    { k1 = applyI (add 5) n
    , k2 = applyI (add3 4 5) n
    , boxed = String.length (applyS (tag "abc") n)
    , tuple = x + y
    }


inputs : List Int
inputs =
    [ 4, 5, 6 ]


main =
    let
        results =
            List.map run inputs

        _ =
            Debug.log "k1" (List.map .k1 results)

        _ =
            Debug.log "k2" (List.map .k2 results)

        _ =
            Debug.log "boxed" (List.map .boxed results)

        _ =
            Debug.log "tuple" (List.map .tuple results)
    in
    text "done"
