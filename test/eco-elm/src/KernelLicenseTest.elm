module KernelLicenseTest exposing (main)

{-| Checks `List.map2`, `List.sortBy`, `String.map` and `String.foldr` with several different callbacks, including lists of functions.

Each line is chosen so that running the wrong callback prints a different value
rather than failing:

  - `a` and `b` call `List.map2` with addition and with multiplication.
  - `c` zips the list of functions `fns` with `[10, 10]` and applies each,
    giving `[11,30]`; swapping the two functions would give `[30,11]`.
  - `d` sorts `fns` by each function's value at 0, which reverses their order,
    then applies each to 5, giving `[15,6]`.
  - `e` and `f` call `String.map` with two different character functions.
  - `g` uses `String.foldr` with a `String` accumulator to reverse `"abc"`.

## eco

Exercises the LSS_022 kernel parametricity license (design_docs/invariants.csv;
plans/kernel-parametricity-license.md). Under a type-faithful row the
monomorphizer stops poisoning a kernel's arrow positions and lets unification
carry lambda sets through the kernel. The failure this risks is a false
singleton, where a call is stamped as a direct call to the wrong closure, so
every CHECK is chosen to print a different value rather than crash (the same
approach as test/eco-elm/src/LssSigFlowTest.elm).

`c` is the position the license newly opens: `fns` crosses the kernel boundary
as `List a` elements, which the older positional row poisoned. `d` is
`List.sortBy` permuting functions, a move along a shared type variable, with
the sort key the inverse of the source order. `g`'s accumulator is the only
type variable in the String kernel surface.

-}

import Char
import Html exposing (text)


{-| Two functions with different results, `+ 1` and `* 3`, held as list
elements rather than passed as a callback.
-}
fns : List (Int -> Int)
fns =
    [ \x -> x + 1
    , \x -> x * 3
    ]


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" (List.map2 (\x y -> x + y) [ 1, 2 ] [ 10, 20 ])

        _ =
            Debug.log "b" (List.map2 (\x y -> x * y) [ 1, 2 ] [ 10, 20 ])

        _ =
            Debug.log "c" (List.map2 (\f n -> f n) fns [ 10, 10 ])

        _ =
            Debug.log "d" (List.map (\f -> f 5) (List.sortBy (\f -> f 0) fns))

        _ =
            Debug.log "e" (String.map (\ch -> Char.toUpper ch) "abc")

        _ =
            Debug.log "f" (String.map (\_ -> 'z') "abc")

        _ =
            Debug.log "g" (String.foldr (\ch acc -> acc ++ String.fromChar ch) "" "abc")
    in
    text "done"



-- CHECK: a: [11,22]
-- CHECK: b: [10,40]
-- CHECK: c: [11,30]
-- CHECK: d: [15,6]
-- CHECK: e: "ABC"
-- CHECK: f: "zzz"
-- CHECK: g: "cba"
