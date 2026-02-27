module Control.Monad.State.Strict exposing
    ( StateT(..)
    , evalStateT
    , liftIO
    , put
    )

{-| A strict state transformer monad for threading state through IO computations.

This module provides a state monad transformer that wraps IO tasks, allowing you to
maintain and update state across asynchronous operations. The state is evaluated
strictly, ensuring predictable evaluation order.


# State Transformer Type

@docs StateT


# Running Computations

@docs evalStateT


# Lifting

@docs liftIO


# State Operations

@docs put

-}

import Eco.Runtime
import Json.Encode as Encode
import System.IO as IO
import Task exposing (Task)


{-| newtype StateT s m a

A state transformer monad parameterized by:

s - The state.
m - The inner monad. (== IO)

The return function leaves the state unchanged, while >>= uses the final state of the first computation as the initial state of the second.

Ref.: <https://hackage.haskell.org/package/transformers-0.6.1.2/docs/Control-Monad-Trans-State-Lazy.html#t:StateT>

-}
type StateT s a
    = StateT (s -> Task Never ( a, s ))


{-| Evaluates a state transformer computation with an initial state, returning only the result and discarding the final state.
-}
evalStateT : StateT s a -> s -> Task Never a
evalStateT (StateT f) =
    f >> Task.map Tuple.first


{-| Lifts a Task computation into the StateT monad transformer, leaving the state unchanged.
-}
liftIO : Task Never a -> StateT s a
liftIO io =
    StateT (\s -> Task.map (\a -> ( a, s )) io)


{-| Stores the given REPL state to the underlying storage.
-}
put : IO.ReplState -> Task Never ()
put (IO.ReplState imports types decls) =
    Eco.Runtime.saveState
        (Encode.object
            [ ( "imports", Encode.dict identity Encode.string imports )
            , ( "types", Encode.dict identity Encode.string types )
            , ( "decls", Encode.dict identity Encode.string decls )
            ]
        )
