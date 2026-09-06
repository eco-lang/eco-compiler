module LssInstanceQualTest exposing (main)

{-| INSTANCE-QUALIFIED LAMBDA MEMBERS — runtime differential
(`plans/lss-instance-qualified-members.md` §5).

`fold` is a LET-bound function applied at two types that differ only in the
lambda set of `hashOf`, so local-multi mints `fold` and `fold$1` and
re-translates its RHS twice. The lambda `\t -> hashOf t + 1` is ONE source
lambda, so before instance qualification both re-translations minted the SAME
member id: a singleton `LSet [m]` indexing two behaviourally different bodies.

That is the E11 representative-hijack shape. If any consumer ever stamps one
instance over the other, BOTH columns print the `triple` answer (or both the
`double` one) and the totals collapse — a wrong ANSWER, not a slow one. A unit
test cannot see that; only a lowered, executed binary can.

The pin must print the same numbers in every flag arm — it is a guard, not a
bug demo. Nothing at HEAD is expected to take the false stamp (AbiCloning's
LSS_024 fingerprint fence declines it), and nothing flag-on should either
(the ids are distinct, so each member has exactly one instance).

`List.map` over `inputs` is load-bearing: a single monomorphic use lets the
inliner fold the whole question away before any lambda set is consulted.

-}

import Html exposing (text)


-- CHECK: tripled: [13, 16, 19]
-- CHECK: doubled: [9, 11, 13]
-- CHECK: totals: [22, 27, 32]


triple : Int -> Int
triple x =
    x * 3


double : Int -> Int
double x =
    x * 2


apply1 : (Int -> Int) -> Int -> Int
apply1 f n =
    f n


{-| The mRecord shape: one source lambda, one let-bound helper parameterised by
a function, two applications with different functions.
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
