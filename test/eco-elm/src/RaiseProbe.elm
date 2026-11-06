module RaiseProbe exposing (main)

{-| A miniature state monad built from a function type alias computes the expected results.

`Step a` is an alias for `St -> ( St, a )`. `pure` and `bump` return lambdas, `andThen`
returns a lambda that threads the state, and `chain` and `tupleish` combine them with
nested `andThen` calls.

  - `result`: `chain 5` from `n = 1` bumps by 5 (giving 6), then by 6 \* 2 (giving 18), and
    returns 6 + 18, so it logs `(24,18)`.
  - `probe2`: `tupleish 5` from `n = 0` reads the counter twice (1, then 2) and returns
    5 \* 100 + 1 \* 10 + 2 = 512.

## eco

Probe for arity raising (`ECO_ARITY_RAISE`, read in
compiler/src/Builder/Eco/Config.elm). The shape is that of the type checker's
`System.TypeCheck.IO` monad. With the flag on, `andThen`, `pure` and `bump`
(closure-literal bodies) and `chain` (a cheap call) are raised to flat arity
and the bind closures inline away; with it off the program runs with closures.
The test pins the behavior in both modes; the corpus runs with the flag off.

-}

import Html exposing (text)

-- CHECK: result: (24,18)
-- CHECK: probe2: 512


type alias St =
    { n : Int, hist : List Int }


type alias Step a =
    St -> ( St, a )


pure : a -> Step a
pure x =
    \s -> ( s, x )


andThen : (a -> Step b) -> Step a -> Step b
andThen f ma =
    \s0 ->
        let
            ( s1, a ) =
                ma s0
        in
        f a s1


bump : Int -> Step Int
bump k =
    \s -> ( { s | n = s.n + k }, s.n + k )


chain : Int -> Step Int
chain k =
    andThen (\a -> andThen (\b -> pure (a + b)) (bump (a * 2))) (bump k)


run : Step a -> St -> ( St, a )
run m s =
    m s


main =
    let
        ( s1, v ) =
            run (chain 5) { n = 1, hist = [] }

        _ =
            Debug.log "result" ( v, s1.n )

        _ =
            Debug.log "probe2" probe2
    in
    text "done"


mkVar : Step Int
mkVar s =
    ( { s | n = s.n + 1 }, s.n + 1 )


tupleish : Int -> Step Int
tupleish a =
    andThen (\v1 -> andThen (\v2 -> pure (a * 100 + v1 * 10 + v2)) mkVar) mkVar


probe2 : Int
probe2 =
    let
        ( _, v ) =
            run (tupleish 5) { n = 0, hist = [] }
    in
    v
