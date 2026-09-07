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
-- CHECK: ctor1: [11, 12, 15]
-- CHECK: ctor2: [7, 8, 9]


{-| §11.1: constructors are partially applied too, and a constructor spec is a
real function of its fields. `Rect 2` (k = 1) and `Rect 2 True` (k = 2) flow
into helpers whose call sites carry `{p|Rect|1}` / `{p|Rect|2}`. The fields
mix an unboxed Int, a Bool (always `!eco.value` in a heap field) and a boxed
list, so a wrong slot kind or a wrong field ABI shows up as a wrong number.
-}
type Shape
    = Rect Int Bool (List Int)
    | Circle Int


measure : Shape -> Int
measure s =
    case s of
        Rect w flag xs ->
            w
                + List.sum xs
                + (if flag then
                    1

                   else
                    0
                  )

        Circle r ->
            r


applyR1 : (Bool -> List Int -> Shape) -> Int -> Shape
applyR1 f n =
    f (modBy 2 n == 0) [ n, n ]


applyR2 : (List Int -> Shape) -> Int -> Shape
applyR2 f n =
    f [ n ]


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


run : Int -> { k1 : Int, k2 : Int, boxed : Int, tuple : Int, ctor1 : Int, ctor2 : Int }
run n =
    let
        ( x, y ) =
            applyT (pair 1) n
    in
    { k1 = applyI (add 5) n
    , k2 = applyI (add3 4 5) n
    , boxed = String.length (applyS (tag "abc") n)
    , tuple = x + y
    , ctor1 = measure (applyR1 (Rect 2) n)
    , ctor2 = measure (applyR2 (Rect 2 True) n)
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

        _ =
            Debug.log "ctor1" (List.map .ctor1 results)

        _ =
            Debug.log "ctor2" (List.map .ctor2 results)
    in
    text "done"
