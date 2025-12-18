module Control.Monad.State.TypeCheck.Strict exposing
    ( StateT(..)
    , runStateT, evalStateT
    , pure, map, apply, andThen
    , liftIO, gets, modify
    , traverseList, traverseTuple, traverseMap
    )

{-| A strict state transformer monad for type checking operations.

This module provides a state monad transformer specialized for use during type checking,
wrapping the type checker's IO monad. It allows threading type checking state through
computations while maintaining strict evaluation semantics.


# State Transformer Type

@docs StateT


# Running Computations

@docs runStateT, evalStateT


# Core Operations

@docs pure, map, apply, andThen


# Lifting and State Access

@docs liftIO, gets, modify


# Traversals

@docs traverseList, traverseTuple, traverseMap

-}

import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)


{-| newtype StateT s m a

A state transformer monad parameterized by:

s - The state.
m - The inner monad. (== IO)

The return function leaves the state unchanged, while >>= uses the final state of the first computation as the initial state of the second.

Ref.: <https://hackage.haskell.org/package/transformers-0.6.1.2/docs/Control-Monad-Trans-State-Lazy.html#t:StateT>

-}
type StateT s a
    = StateT (s -> IO ( a, s ))


{-| Runs a state transformer computation with an initial state, returning both the result and final state.
-}
runStateT : StateT s a -> s -> IO ( a, s )
runStateT (StateT f) =
    f


{-| Evaluates a state transformer computation with an initial state, returning only the result and discarding the final state.
-}
evalStateT : StateT s a -> s -> IO a
evalStateT (StateT f) =
    f >> IO.map Tuple.first


{-| Lifts an IO computation into the StateT monad transformer, leaving the state unchanged.
-}
liftIO : IO a -> StateT s a
liftIO io =
    StateT (\s -> IO.map (\a -> ( a, s )) io)


{-| Applies a function wrapped in StateT to a value wrapped in StateT, threading state through both computations.
-}
apply : StateT s a -> StateT s (a -> b) -> StateT s b
apply (StateT arg) (StateT func) =
    StateT
        (\s ->
            arg s
                |> IO.andThen
                    (\( a, sa ) ->
                        func sa
                            |> IO.map (\( fb, sb ) -> ( fb a, sb ))
                    )
        )


{-| Maps a function over the result value of a StateT computation, leaving the state unchanged.
-}
map : (a -> b) -> StateT s a -> StateT s b
map func argStateT =
    apply argStateT (pure func)


{-| Chains StateT computations, passing the result of the first computation to a function that produces the second computation.
-}
andThen : (a -> StateT s b) -> StateT s a -> StateT s b
andThen func (StateT arg) =
    StateT
        (\s ->
            arg s
                |> IO.andThen
                    (\( a, sa ) ->
                        case func a of
                            StateT fb ->
                                fb sa
                    )
        )


{-| Wraps a pure value in a StateT computation, leaving the state unchanged.
-}
pure : a -> StateT s a
pure value =
    StateT (\s -> IO.pure ( value, s ))


{-| Retrieves a projection of the current state by applying a function to it.
-}
gets : (s -> a) -> StateT s a
gets f =
    StateT (\s -> IO.pure ( f s, s ))


{-| Modifies the current state by applying a transformation function to it.
-}
modify : (s -> s) -> StateT s ()
modify f =
    StateT (\s -> IO.pure ( (), f s ))


{-| Applies a stateful computation to each element of a list, threading state through all computations and collecting results.
-}
traverseList : (a -> StateT s b) -> List a -> StateT s (List b)
traverseList f =
    List.foldr (\a -> andThen (\c -> map (\va -> va :: c) (f a)))
        (pure [])


{-| Applies a stateful computation to the second element of a tuple, leaving the first element unchanged.
-}
traverseTuple : (b -> StateT s c) -> ( a, b ) -> StateT s ( a, c )
traverseTuple f ( a, b ) =
    map (Tuple.pair a) (f b)


{-| Applies a stateful computation to each value in a dictionary, threading state through all computations and collecting results.
-}
traverseMap : (k -> k -> Order) -> (k -> comparable) -> (a -> StateT s b) -> Dict comparable k a -> StateT s (Dict comparable k b)
traverseMap keyComparison toComparable f =
    traverseMapWithKey keyComparison toComparable (\_ -> f)


traverseMapWithKey : (k -> k -> Order) -> (k -> comparable) -> (k -> a -> StateT s b) -> Dict comparable k a -> StateT s (Dict comparable k b)
traverseMapWithKey keyComparison toComparable f =
    Dict.foldl keyComparison
        (\k a -> andThen (\c -> map (\va -> Dict.insert toComparable k va c) (f k a)))
        (pure Dict.empty)
