module Utils.Task.Extra exposing
    ( apply
    , eio
    , io
    , mapM
    , mio
    , run
    , throw
    , void
    )

{-| Additional utilities for working with Elm tasks, providing common patterns for error handling
and task composition.

# Task Execution

@docs run, throw

# IO Task Conversions

@docs io, mio, eio

# Task Combinators

@docs void, apply, mapM

-}

import Task exposing (Task)



-- TASKS


{-| Converts a fallible task into an infallible task that returns a Result.
Captures both success and failure cases as Result values.
-}
run : Task x a -> Task Never (Result x a)
run task =
    task
        |> Task.map Ok
        |> Task.onError (Err >> Task.succeed)


{-| Creates a task that immediately fails with the given error value.
Alias for Task.fail that provides clearer intent for exception-like error handling.
-}
throw : x -> Task x a
throw =
    Task.fail



-- IO


{-| Converts an infallible task to a task with any error type.
Useful when an infallible IO operation needs to be used in a context expecting a fallible task.
-}
io : Task Never a -> Task x a
io work =
    Task.mapError never work


{-| Converts an infallible task returning Maybe into a fallible task.
If the task produces Nothing, fails with the provided error value.
-}
mio : x -> Task Never (Maybe a) -> Task x a
mio x work =
    work
        |> Task.mapError never
        |> Task.andThen
            (\m ->
                case m of
                    Just a ->
                        Task.succeed a

                    Nothing ->
                        Task.fail x
            )


{-| Converts an infallible task returning Result into a fallible task.
Maps the error value using the provided function before failing the task.
-}
eio : (x -> y) -> Task Never (Result x a) -> Task y a
eio func work =
    work
        |> Task.mapError never
        |> Task.andThen
            (\m ->
                case m of
                    Ok a ->
                        Task.succeed a

                    Err err ->
                        func err |> Task.fail
            )



-- INSTANCES


{-| Discards the result of a task, replacing it with unit.
Useful when you need to execute a task for its side effects but don't care about its return value.
-}
void : Task x a -> Task x ()
void =
    Task.map (always ())


{-| Applies a task containing a function to a task containing a value.
This is the applicative apply operation for tasks, enabling applicative-style composition.
-}
apply : Task x a -> Task x (a -> b) -> Task x b
apply ma mf =
    Task.andThen (\f -> Task.map f ma) mf


{-| Maps a task-returning function over a list and sequences the results.
Executes each task in sequence and collects the results into a list.
-}
mapM : (a -> Task x b) -> List a -> Task x (List b)
mapM f =
    List.map f >> Task.sequence
