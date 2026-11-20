module NullableChainClosureTest exposing (main)

{-| A `case` on a pair of `Maybe { n : Int }`s, whose fallback branch holds a
closure, under `NullableMaybe` (plans/constructor-representation-levels.md N1).
The pass splits the pair's chain of two `Just` tests into nested one-test
chains, each with the fallback; the fallback's closure is moved into a shared
jump so that its lambda is not duplicated (MONO_019). Every combination of the
pair is printed.

-}

-- CHECK: jj: 3
-- CHECK: jn: 10
-- CHECK: nj: 10
-- CHECK: nn: 10

import Html exposing (text)


pairOr : ( Maybe { n : Int }, Maybe { n : Int } ) -> Int
pairOr p =
    case p of
        ( Just a, Just b ) ->
            a.n + b.n

        _ ->
            List.foldl (\x acc -> x + acc) 0 [ 1, 2, 3, 4 ]


main =
    let
        r n =
            Just { n = n }

        _ =
            Debug.log "jj" (pairOr ( r 1, r 2 ))

        _ =
            Debug.log "jn" (pairOr ( r 1, Nothing ))

        _ =
            Debug.log "nj" (pairOr ( Nothing, r 2 ))

        _ =
            Debug.log "nn" (pairOr ( Nothing, Nothing ))
    in
    text "done"
