module LssLayoutQualMemberTest exposing (main)

{-| A function that builds a state-passing computation from its function argument works with two different arguments.

`Step a` is a function from an `Int` state to a new state and a value. `andThenS` sequences two
steps, `getS` returns the state as the value, and `mid f` sequences `getS` with a lambda that
captures `f` and returns `f (v + 1)`. `runS` runs a step and keeps the value, so
`runS (mid f) s` is `f (s + 1)`:

  - `a`: `(\x -> x + 5)` with state 5 gives 11.
  - `b`: `(\x -> x * 3)` with state 6 gives 21.

## eco

Reproducer for layout-qualified members (plans/lss-layout-qualified-members.md). The two
callers split `mid` into two specializations with the same layout that differ only in the lambda
set on `f`'s arrow. Each specialization's callback lambda flows into one shared `andThenS`-shaped
function, a miniature of the `andThen` chains in the compiler's own type checker.

With layout-qualified members both `mid` specializations mint the callback under one member id, so
the shared callback slot is a singleton again and AbiCloning
(compiler/src/Compiler/MonoOpt/AbiCloning.elm) consults it. Its fingerprint fence must decline
here, because the two clones capture different `f`s, keeping generic dispatch and these outputs.

-}

-- CHECK: a: 11
-- CHECK: b: 21

import Html exposing (text)


type alias Step a =
    Int -> ( Int, a )


andThenS : (a -> Step b) -> Step a -> Step b
andThenS f ma =
    \s0 ->
        let
            ( s1, a ) =
                ma s0
        in
        f a s1


getS : Step Int
getS s =
    ( s, s )


mid : (Int -> Int) -> Step Int
mid f =
    andThenS (\v -> \s -> ( s, f (v + 1) )) getS


runS : Step a -> Int -> a
runS ma s =
    Tuple.second (ma s)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" (runS (mid (\x -> x + 5)) 5)

        _ =
            Debug.log "b" (runS (mid (\x -> x * 3)) 6)
    in
    text "done"
