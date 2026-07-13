module SolverLayoutStepMonadTest exposing (main)

{-| Solver layout probe: a State-threading monad (the IO-alias shape)
driven through generic `andThen` combinators with lambda continuations.
The `( state, a )` tuples cross combinator/lambda boundaries — each an
id-domain seam. The element is Int (unboxable) end to end; a stale or
disconnected view in any spec turns a raw i64 slot into a boxed read.
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
