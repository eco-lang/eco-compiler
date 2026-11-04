module HashNegativeSeedTest exposing (main)

{-| HASH-01 (plans/kernel-lib-bug-fixes.md): `Eco.Hash.stringWithSeed` with a
    negative seed. The narrow hash is documented to be in `[0, 2^26)` for
    every seed, the seed reduced with `modBy 2^26` as the pure twin
    (compiler/src-xhr/Eco/Hash.elm) does. The native kernel (K/Hash.cpp) and
    the JS twin (Eco/Kernel/Hash.js) reduce the seed with C++ `%` / JS `%`,
    which keeps its sign, so a negative seed gave a negative hash (fixed:
    both now reduce the seed as `modBy` does).

    Expected values: the `modBy` formula, checked against the pure twin
    compiled with stock Elm 0.19.1. Before the fix the native build printed
    -1000000, -32999896, -15254639, -60029390 and `inRange: False`. The seed 23 row is
    a control that is right today.
-}

-- CHECK: negEmpty: 66108864
-- CHECK: negA: 34108968
-- CHECK: negAb: 51854225
-- CHECK: negHello: 7079474
-- CHECK: inRange: True
-- CHECK: pos: 943378

import Eco.Hash
import Platform


{-| Returns `b`; its first argument only orders the `Debug.log` lines, since Elm
    reorders independent `let` bindings.
-}
after : a -> b -> b
after _ b =
    b


report : () -> ()
report _ =
    let
        negEmpty =
            Debug.log "negEmpty" (Eco.Hash.stringWithSeed (-1000000) "")

        negA =
            after negEmpty (Debug.log "negA" (Eco.Hash.stringWithSeed (-1000000) "a"))

        negAb =
            after negA (Debug.log "negAb" (Eco.Hash.stringWithSeed (-1000000) "ab"))

        negHello =
            after negAb (Debug.log "negHello" (Eco.Hash.stringWithSeed (-5) "hello"))

        -- Fresh calls, not the `Debug.log` results above: an Int that came back from
        -- `Debug.log` compares wrongly with `<` inside a `List.all` lambda (a separate
        -- codegen bug, see DebugLogIntCompareTest in test/elm).
        inRange =
            after negHello
                (Debug.log "inRange"
                    (List.all (\h -> h >= 0 && h < 67108864)
                        [ Eco.Hash.stringWithSeed (-1000000) ""
                        , Eco.Hash.stringWithSeed (-1000000) "a"
                        , Eco.Hash.stringWithSeed (-1000000) "ab"
                        , Eco.Hash.stringWithSeed (-5) "hello"
                        ]
                    )
                )
    in
    after inRange (always () (Debug.log "pos" (Eco.Hash.stringWithSeed 23 "abc")))


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
