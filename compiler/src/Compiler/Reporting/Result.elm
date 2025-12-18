module Compiler.Reporting.Result exposing
    ( RResult(..), RStep(..), Step(..)
    , ok, throw, warn, run
    , map, apply, andThen
    , traverse, traverseDict, indexedTraverse, mapTraverseWithKey
    , loop
    )

{-| A specialized Result type for compiler operations with warnings and state.

This module provides a Result monad that threads through compiler info and
warnings while accumulating errors. It enables compositional error handling
throughout the compilation pipeline.


# Types

@docs RResult, RStep, Step


# Basics

@docs ok, throw, warn, run


# Combinators

@docs map, apply, andThen


# Traversals

@docs traverse, traverseDict, indexedTraverse, mapTraverseWithKey


# Loops

@docs loop

-}

import Compiler.Data.Index as Index
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Reporting.Warning as Warning
import Data.Map as Dict exposing (Dict)



-- RESULT


{-| A Result monad that threads compiler info and warnings through computations.

Wraps a function that takes current info and warnings state, and produces a step
result that may succeed with a value or fail with one or more errors.

-}
type RResult info warnings error a
    = RResult (info -> warnings -> RStep info warnings error a)


{-| Represents the result of a single step in an RResult computation.

Either succeeds with updated info, warnings, and a value, or fails with
accumulated errors.

-}
type RStep info warnings error a
    = ROk info warnings a
    | RErr info warnings (OneOrMore.OneOrMore error)


{-| Execute an RResult computation with empty initial state.

Returns accumulated warnings and either a successful value or non-empty list of errors.
Warnings are returned in the order they were added.

-}
run : RResult () (List w) e a -> ( List w, Result (OneOrMore.OneOrMore e) a )
run (RResult k) =
    case k () [] of
        ROk () w a ->
            ( List.reverse w, Ok a )

        RErr () w e ->
            ( List.reverse w, Err e )



-- LOOP


{-| Represents a step in a loop computation.

Loop continues with new state, Done completes with final value.

-}
type Step state a
    = Loop state
    | Done a


{-| Repeatedly apply a function to a state until it returns Done.

Allows implementing tail-recursive loops within the RResult monad while
threading info and warnings through each iteration.

-}
loop : (state -> RResult i w e (Step state a)) -> state -> RResult i w e a
loop callback state =
    RResult <|
        \i w ->
            loopHelp callback i w state


loopHelp : (state -> RResult i w e (Step state a)) -> i -> w -> state -> RStep i w e a
loopHelp callback i w state =
    case callback state of
        RResult k ->
            case k i w of
                RErr i1 w1 e ->
                    RErr i1 w1 e

                ROk i1 w1 (Loop newState) ->
                    loopHelp callback i1 w1 newState

                ROk i1 w1 (Done a) ->
                    ROk i1 w1 a



-- HELPERS


{-| Create a successful RResult with a value.

Does not modify info or warnings state.

-}
ok : a -> RResult i w e a
ok a =
    RResult <|
        \i w ->
            ROk i w a


{-| Add a warning to the current computation without failing.

Warnings accumulate in the order they are added.

-}
warn : Warning.Warning -> RResult i (List Warning.Warning) e ()
warn warning =
    RResult <|
        \i warnings ->
            ROk i (warning :: warnings) ()


{-| Create a failed RResult with a single error.

Terminates the computation with the given error.

-}
throw : e -> RResult i w e a
throw e =
    RResult <|
        \i w ->
            RErr i w (OneOrMore.one e)



-- FANCY INSTANCE STUFF


{-| Transform the value inside a successful RResult.

If the computation failed, the error is preserved unchanged.

-}
map : (a -> b) -> RResult i w e a -> RResult i w e b
map func (RResult k) =
    RResult <|
        \i w ->
            case k i w of
                ROk i1 w1 value ->
                    ROk i1 w1 (func value)

                RErr i1 w1 e ->
                    RErr i1 w1 e


{-| Apply a function wrapped in an RResult to a value wrapped in an RResult.

Runs both computations in sequence, threading info and warnings through both.
If both fail, errors are accumulated using OneOrMore.more.

-}
apply : RResult i w x a -> RResult i w x (a -> b) -> RResult i w x b
apply (RResult kv) (RResult kf) =
    RResult <|
        \i w ->
            case kf i w of
                ROk i1 w1 func ->
                    case kv i1 w1 of
                        ROk i2 w2 value ->
                            ROk i2 w2 (func value)

                        RErr i2 w2 e2 ->
                            RErr i2 w2 e2

                RErr i1 w1 e1 ->
                    case kv i1 w1 of
                        ROk i2 w2 _ ->
                            RErr i2 w2 e1

                        RErr i2 w2 e2 ->
                            RErr i2 w2 (OneOrMore.more e1 e2)


{-| Chain RResult computations sequentially.

If the first computation succeeds, its value is passed to the callback to
produce the next computation. Info and warnings thread through both steps.

-}
andThen : (a -> RResult i w x b) -> RResult i w x a -> RResult i w x b
andThen callback (RResult ka) =
    RResult <|
        \i w ->
            case ka i w of
                ROk i1 w1 a ->
                    case callback a of
                        RResult kb ->
                            kb i1 w1

                RErr i1 w1 e ->
                    RErr i1 w1 e


{-| Apply a function to each element of a list, accumulating results.

Threads info and warnings through each element in sequence. If any application
fails, errors are accumulated. Returns the list of results in original order.

-}
traverse : (a -> RResult i w x b) -> List a -> RResult i w x (List b)
traverse func =
    List.foldl
        (\a (RResult acc) ->
            RResult <|
                \i w ->
                    let
                        (RResult kv) =
                            func a
                    in
                    case acc i w of
                        ROk i1 w1 accList ->
                            case kv i1 w1 of
                                ROk i2 w2 value ->
                                    ROk i2 w2 (value :: accList)

                                RErr i2 w2 e2 ->
                                    RErr i2 w2 e2

                        RErr i1 w1 e1 ->
                            case kv i1 w1 of
                                ROk i2 w2 _ ->
                                    RErr i2 w2 e1

                                RErr i2 w2 e2 ->
                                    RErr i2 w2 (OneOrMore.more e1 e2)
        )
        (ok [])
        >> map List.reverse


{-| Traverse a dictionary with a key-aware function, building a new dictionary.

Applies the function to each key-value pair in the dictionary, threading RResult
state through each application. Uses loop for tail-recursive efficiency.

-}
mapTraverseWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> RResult i w x b) -> Dict comparable k a -> RResult i w x (Dict comparable k b)
mapTraverseWithKey toComparable keyComparison f dict =
    loop (mapTraverseWithKeyHelp toComparable f) ( Dict.toList keyComparison dict, Dict.empty )


mapTraverseWithKeyHelp :
    (k -> comparable)
    -> (k -> a -> RResult i w x b)
    -> ( List ( k, a ), Dict comparable k b )
    -> RResult i w x (Step ( List ( k, a ), Dict comparable k b ) (Dict comparable k b))
mapTraverseWithKeyHelp toComparable f ( pairs, result ) =
    case pairs of
        [] ->
            ok (Done result)

        ( k, a ) :: rest ->
            map (\b -> Loop ( rest, Dict.insert toComparable k b result )) (f k a)


{-| Traverse a dictionary with a function that only depends on values.

Similar to mapTraverseWithKey but the function doesn't receive the key.
Builds a new dictionary with transformed values while threading RResult state.

-}
traverseDict : (k -> comparable) -> (k -> k -> Order) -> (a -> RResult i w x b) -> Dict comparable k a -> RResult i w x (Dict comparable k b)
traverseDict toComparable keyComparison func =
    Dict.foldr keyComparison (\k a -> andThen (\acc -> map (\b -> Dict.insert toComparable k b acc) (func a))) (ok Dict.empty)


{-| Traverse a list with an index-aware function.

Applies the function to each element along with its zero-based index,
accumulating results while threading RResult state through the computation.

-}
indexedTraverse : (Index.ZeroBased -> a -> RResult i w error b) -> List a -> RResult i w error (List b)
indexedTraverse func xs =
    List.foldr (\a -> andThen (\acc -> map (\b -> b :: acc) a)) (ok []) (Index.indexedMap func xs)
