module PapFastStampTest exposing (main)

{-| Tests partial applications of top-level functions and of a constructor,
passed to higher-order helpers that supply the remaining arguments.

`run n` builds a record of these cases applied to `n`:

  - `k1`: `add 5` with one argument bound.
  - `k2`: `add3 4 5` with two arguments bound.
  - `boxed`: `tag "abc"`, returning a `String`, logged as its length.
  - `tuple`: `pair 1`, returning a tuple, logged as the sum of its parts.
  - `ctor1` and `ctor2`: the constructor `Rect` with one and two of its three
    fields bound, logged through `measure`.

`run` is mapped over the inputs `[ 4, 5, 6 ]`, and each field is logged as a
list of three `Int`s.

## eco

Runtime differential for the LSS `p|` PAP-of-global fast stamp
(plans/lss-pap-fast-stamp.md). Each partial application of a global flows into
a higher-order helper whose call site carries a singleton `{p|<global>|<k>}`
lambda-set annotation; with the fast stamp on, that site loads the `k` bound
arguments back out of the PAP object and calls the global's specialization
directly. A wrong slot, slot kind or target shows up as wrong numbers, which a
unit test cannot see; the output must be the same with the stamp on or off.

Coverage is k = 1 and k = 2, with an `Int`, a boxed `String` and a tuple
return, to check return-ABI parity for specialization targets. `Rect` covers
constructor PAPs; its fields mix an unboxed `Int`, a `Bool` (always
`!eco.value` in a heap field) and a boxed list. Results are reduced to `Int`s so
the CHECK lines do not depend on `Debug.log` rendering. `List.map run inputs`
is load-bearing: a single monomorphic use lets the inliner fold the question
away before any lambda set is consulted.

-}

import Html exposing (text)



-- CHECK: k1: [9,10,11]
-- CHECK: k2: [13,14,15]
-- CHECK: boxed: [7,8,9]
-- CHECK: tuple: [9,11,13]
-- CHECK: ctor1: [11,12,15]
-- CHECK: ctor2: [7,8,9]


{-| A shape whose `Rect` constructor has fields of three different types, an
`Int`, a `Bool` and a `List Int`, so that each partially applied `Rect` in
the test must keep its bound fields in the right places for `measure` to
return the expected number.
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
