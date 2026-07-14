module RaiseProbe exposing (main)

{-| H6.2 U2b probe: a state-function monad in miniature (the
System.TypeCheck.IO shape — `Step a = St -> (St, a)` type alias,
`andThen` returning a lambda, combinators partially applied). Under
`ECO_ARITY_RAISE=1` the staged specs (`andThen`, `pure`, `bump` via the
closure-literal arm; `chain` via the cost-bounded call arm) are raised to
flat arity, the driver's application then merges/inlines through the
whole chain, and the bind closures vanish. Flag-off this compiles and
runs identically with closures — this test pins BEHAVIOR for both modes
(the corpus runs flag-off; the flag-on run is exercised by the H6.2
gates).
-}

import Html exposing (text)

-- CHECK: result: (24, 18)


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
    in
    text "done"
