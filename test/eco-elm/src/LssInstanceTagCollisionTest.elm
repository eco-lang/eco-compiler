module LssInstanceTagCollisionTest exposing (main)

{-| Nested let-bound helpers, each applied to two different functions, keep four distinct closures apart.

In `run`, `outer hashOf` defines `inner g`, which applies `\t -> g (hashOf t)` to `n`. `outer` is
called with `hashA` (doubling) and `hashB` (adding one), and inside each, `inner` is called with
`hashA` and `hashB`, so each element of a result row is `g (hashOf n)` for one of the four
combinations, in the order (A,A), (A,B), (B,A), (B,B). For `n` = 3 that row is `[12,7,8,5]`; the
program logs the rows for 3, 5 and 8.

`LssInstanceQualTest` covers the single-level version of this shape.

## eco

Runtime guard for the instance-tag scheme of `localInstanceTagFor`
(compiler/src/Compiler/Monomorphize/Solver/Engine.elm). `outer` and `inner` are both let-bound and
each get two local-multi instances. When ordinal 0 kept the enclosing tag (fixed 2026-10-05), the
tag of the second `inner` inside the first `outer` equalled the tag of the first `inner` inside the
second `outer`, so the lambda `\t -> g (hashOf t)` got one member id for two different closures.
Ordinal 0 is now composed under a tagged instance.

The answers were right even with the collision, because AbiCloning's fingerprint fence
(compiler/src/Compiler/MonoOpt/AbiCloning.elm) declined the shared singleton; this test makes a
regression of either the tag scheme or the fence a wrong answer. The single-level guard is
test/eco-elm/src/LssInstanceQualTest.elm, and the monomorphizer-level one is case 8 of
compiler/tests/Compiler/Monomorphize/Solver/LssInstanceQualTest.elm. `List.map` over `inputs`
keeps the inliner from folding the calls away.

-}

import Html exposing (text)


-- CHECK: results: [[12,7,8,5],[20,11,12,7],[32,17,18,10]]


hashA : Int -> Int
hashA x =
    x + x


hashB : Int -> Int
hashB x =
    x + 1


apply1 : (Int -> Int) -> Int -> Int
apply1 f n =
    f n


run : Int -> List Int
run n =
    let
        outer hashOf =
            let
                inner g =
                    apply1 (\t -> g (hashOf t)) n
            in
            [ inner hashA, inner hashB ]
    in
    outer hashA ++ outer hashB


inputs : List Int
inputs =
    [ 3, 5, 8 ]


main =
    let
        _ =
            Debug.log "results" (List.map run inputs)
    in
    text "done"
