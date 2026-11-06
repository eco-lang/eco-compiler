module SolverLayoutStepMonadTest exposing (main)

{-| A state monad built from a generic `andThen` and lambda continuations carries an `Int` result and a state record through each step.

A step is a function from `State` to `( State, a )`. `pure_ x` returns `x` and
leaves the state alone, and `andThen k f` runs `f` and hands its result and new
state to `k`. `prog` starts with `pure_ 7`, then adds 7 to `count` and returns
8, then returns `8 * 3`. Run from `count = 0`, it gives 24 and a count of 7,
printed as `v * 1000 + count`, which is 24007.

## eco

A solver layout probe (compiler/src/Compiler/Monomorphize/Solver/Translate.elm)
for the state-monad shape of the compiler's own IO alias. The `( State, a )`
tuples cross combinator and lambda boundaries, each a seam between id domains.
The element is an unboxable `Int` throughout, so a stale or disconnected view in
any spec would turn a raw `i64` slot into a boxed read.

-}

-- CHECK: SolverLayoutStepMonad: 24007

import Html exposing (text)


type alias State =
    { count : Int }


andThen : (a -> State -> ( State, b )) -> (State -> ( State, a )) -> State -> ( State, b )
andThen k f s =
    let
        ( s1, x ) =
            f s
    in
    k x s1


pure_ : a -> State -> ( State, a )
pure_ x s =
    ( s, x )


prog : State -> ( State, Int )
prog =
    pure_ 7
        |> andThen (\i -> \s -> ( { count = s.count + i }, i + 1 ))
        |> andThen (\j -> pure_ (j * 3))


main =
    let
        ( finalState, v ) =
            prog { count = 0 }

        _ =
            Debug.log "SolverLayoutStepMonad" (v * 1000 + finalState.count)
    in
    text "done"
