module LssInstanceQualTest exposing (main)

{-| A let-bound helper that takes a function and wraps it in one lambda gives each application its own behaviour.

In `run`, `fold hashOf` applies `\t -> hashOf t + 1` to `n`, and is used twice, with `triple`
and with `double`. Over the inputs 4, 5 and 6:

  - `tripled` logs `3n + 1`: `[13,16,19]`.
  - `doubled` logs `2n + 1`: `[9,11,13]`.
  - `totals` logs their sums: `[22,27,32]`.

If both uses ran the same lambda body, the two columns would be equal.

## eco

Runtime guard for instance-qualified lambda members (the instance qualification work,
plans/lss-instance-qualified-members.md). `fold` is a let-bound function used at two types that
differ only in the lambda set of `hashOf`, so the monomorphizer's local-multi path makes two
instances and translates the body twice. Before instance qualification both translations gave
the single source lambda the same member id: a singleton set indexing two different bodies.

If a consumer ever devirtualized one instance over the other, both columns would print the same
answers: a wrong result, which only an executed binary shows. AbiCloning's fingerprint fence
(compiler/src/Compiler/MonoOpt/AbiCloning.elm) declines that stamp, and with distinct ids each
member has one instance. `List.map` over `inputs` keeps the inliner from folding the calls away
before any lambda set is consulted. The monomorphizer-level test is
compiler/tests/Compiler/Monomorphize/Solver/LssInstanceQualTest.elm.

-}

import Html exposing (text)


-- CHECK: tripled: [13,16,19]
-- CHECK: doubled: [9,11,13]
-- CHECK: totals: [22,27,32]


triple : Int -> Int
triple x =
    x * 3


double : Int -> Int
double x =
    x * 2


apply1 : (Int -> Int) -> Int -> Int
apply1 f n =
    f n


{-| Returns `( triple n + 1, double n + 1 )`, each computed through the lambda that the local `fold` builds.
-}
run : Int -> ( Int, Int )
run n =
    let
        fold hashOf =
            apply1 (\t -> hashOf t + 1) n
    in
    ( fold triple, fold double )


inputs : List Int
inputs =
    [ 4, 5, 6 ]


main =
    let
        results =
            List.map run inputs

        _ =
            Debug.log "tripled" (List.map Tuple.first results)

        _ =
            Debug.log "doubled" (List.map Tuple.second results)

        _ =
            Debug.log "totals" (List.map (\( a, b ) -> a + b) results)
    in
    text "done"
