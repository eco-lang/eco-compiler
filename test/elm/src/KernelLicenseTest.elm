module KernelLicenseTest exposing (main)

{-| LSS_022 — the kernel parametricity license
(`plans/kernel-parametricity-license.md` §5, E2E fixture).

Under a `TypeFaithful` row the monomorphizer stops poisoning a kernel's arrow
positions and lets ordinary unification transport lambda sets straight
through the kernel. That is a precision win, and the precise failure it risks
is a FALSE SINGLETON: if a licensed position ended up carrying a narrower set
than the runtime values actually inhabiting it, a downstream consumer would
stamp a direct call to the wrong closure and one lambda's code would run in
another's place.

Every CHECK below is chosen so that a false singleton produces a DIFFERENT
number, not a crash — the `b: 11` discipline of `LssSigFlowTest.elm`:

  - `a`/`b` — the same licensed kernel (`List.map2`) reached with two distinct
    callbacks. Collapsing them swaps `+` for `*`.
  - `c` — a `List (Int -> Int)` argument. This is the position the license
    newly opens: the v1 positional row poisoned `List a`, so its element arrow
    read ⊤; licensed, it carries the caller's two lambdas. Collapsing the two
    yields `[11, 13]` or `[3, 30]` instead of `[11, 30]`.
  - `d` — `List.sortBy` PERMUTING a list of functions. The permutation is the
    license's B1(b) "move along a shared type variable" case, and the sort key
    is deliberately the inverse of the source order, so any mix-up between the
    two closures shows up as `[6, 15]`.
  - `e`/`f` — `String.map` with two distinct callbacks, and `String.foldr`,
    whose accumulator `b` is the only type variable in the whole String
    surface.

-}

import Char
import Html exposing (text)


{-| Two distinct closures with clearly different behaviour, held in a list so
they cross the kernel boundary as ELEMENTS (the `List a` position) rather than
as the callback.
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



-- CHECK: a: [11, 22]
-- CHECK: b: [10, 40]
-- CHECK: c: [11, 30]
-- CHECK: d: [15, 6]
-- CHECK: e: "ABC"
-- CHECK: f: "zzz"
-- CHECK: g: "cba"
