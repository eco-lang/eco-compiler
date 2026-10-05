module LssInstanceTagCollisionTest exposing (main)

{-| NESTED LOCAL-MULTI INSTANCE TAGS — runtime guard for the (fixed)
instance-tag collision in `Compiler.MonoSolver.Engine.localInstanceTagFor`.

`outer` and `inner` are both LET-bound functions used at two lambda sets, so
local-multi gives each two instances. When ordinal 0 kept the enclosing tag
even under a tagged instance (`localInstanceTagFor`, fixed 2026-10-05), the
tag of `inner$1` inside `outer` (outer 0, inner 1: `mixTag 0 1`) EQUALLED the
tag of `inner` inside `outer$1` (outer 1, inner 0: the enclosing `mixTag 0 1`).
The lambda `\t -> g (hashOf t)` was then minted under the same key in both, so
two behaviourally different closures (one captures `g` only, the other
`hashOf` and `g`) shared one member id: a singleton `LSet [m]` indexing two
bodies, the shape `LssInstanceQualTest` guards against. Ordinal 0 is now
composed under a tagged instance, so the ids differ.

The answers were right even with the collision (AbiCloning's fingerprint fence
declined the shared singleton); this test turns a regression of either the tag
scheme or the fence into a wrong ANSWER. The Mono-level guard is
`TestLogic.Monomorphize.LssInstanceQualTest` ("8. nested instances ...").

`List.map` over `inputs` keeps the inliner from folding the question away.

-}

import Html exposing (text)


-- CHECK: results: [[12, 7, 8, 5], [20, 11, 12, 7], [32, 17, 18, 10]]


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
