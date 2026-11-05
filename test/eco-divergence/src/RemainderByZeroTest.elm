module RemainderByZeroTest exposing (main)

{-| `remainderBy 0`, inline and through a function value. eco's integer division is total
(CGEN_084, decision D1 of plans/kernel-lib-bug-fixes.md): `remainderBy 0 x` is 0, as `modBy 0 x`
and `x // 0` are. In Elm `remainderBy` is JavaScript's `a % b`, so `remainderBy 0 x` is NaN held
in an Int. `modBy 0` is covered by ModByZeroKernelPathTest. The operands come from `List.length`
so that no compiler can fold them.

The CHECK lines are eco's output; the `-- ELM:` lines are what Elm 0.19.1 prints on node.

-}

-- DIVERGENCE: eco's remainderBy 0 x is 0 (CGEN_084); in Elm it is NaN held in an Int
-- CHECK: inline: 0
-- CHECK: negative: 0
-- CHECK: map: [0,0]
-- CHECK: value: 0
-- CHECK: plusOne: 1
-- ELM: inline: NaN
-- ELM: negative: NaN
-- ELM: map: [NaN,NaN]
-- ELM: value: NaN
-- ELM: plusOne: NaN

import Html exposing (text)


applyTo : (Int -> Int -> Int) -> Int -> Int -> Int
applyTo f a b =
    f a b


main =
    let
        zero =
            List.length []

        _ =
            Debug.log "inline" (remainderBy zero 7)

        _ =
            Debug.log "negative" (remainderBy zero -7)

        _ =
            Debug.log "map" (List.map (remainderBy zero) [ 5, -3 ])

        _ =
            Debug.log "value" (applyTo remainderBy zero 7)

        _ =
            Debug.log "plusOne" (remainderBy zero 7 + 1)
    in
    text "done"
