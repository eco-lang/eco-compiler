module Utils.Task.Extra exposing
    ( run, throw
    , io, mio, eio
    , apply, mapM
    )

{-| Tasks come in two kinds that do not combine directly, and this module
supplies the few combinators for moving between them and for chaining them.

An _infallible_ task has the type `Task Never a`. No value of type `Never`
exists, so such a task cannot fail, and anything that goes wrong can only be
reported in its result, for instance as a `Maybe` or a `Result`. A _fallible_
task has the type `Task x a` for an error type `x` other than `Never`, and
fails with a value of that type.

`run` turns a fallible task into an infallible one whose result is a `Result`.
`io`, `mio` and `eio` go the other way: `io` gives an infallible task any error
type, and `mio` and `eio` also turn a `Nothing` or an `Err` in its result into a
failure. `throw` makes a task that fails straight away.

`apply` and `mapM` combine several tasks into one. Both perform their tasks one
after another, and both stop at the first failure.


# Task Execution

@docs run, throw


# IO Task Conversions

@docs io, mio, eio


# Task Combinators

@docs apply, mapM

-}

import Task exposing (Task)



-- ====== TASKS ======


{-| Returns a task that performs `task` and never fails: it succeeds with `Ok`
and the value when `task` succeeds, and with `Err` and the error when `task`
fails.
-}
run : Task x a -> Task Never (Result x a)
run task =
    task
        |> Task.map Ok
        |> Task.onError (Err >> Task.succeed)


{-| Returns a task that fails with the given error without doing anything else.
It is `Task.fail` under another name.
-}
throw : x -> Task x a
throw =
    Task.fail



-- ====== IO ======


{-| Returns `work` with its error type changed to whatever the caller needs.
The result still never fails.
-}
io : Task Never a -> Task x a
io work =
    Task.mapError never work


{-| Returns a task that performs `work` and succeeds with the value inside its
`Just`, or fails with `x` when `work` produces `Nothing`.
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


{-| Returns a task that performs `work` and succeeds with the value inside its
`Ok`, or fails with `func` applied to the error when `work` produces `Err`.
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



-- ====== COMBINATORS ======


{-| Returns a task that performs `mf`, then `ma`, and succeeds with the
function from `mf` applied to the value from `ma`.

The value task comes first in the argument list so that a pipeline reads in
order: `Task.succeed f |> apply a |> apply b` performs `a`, then `b`, and
succeeds with `f` applied to both results. The function task is performed
first, so if it fails, `ma` is never performed.

-}
apply : Task x a -> Task x (a -> b) -> Task x b
apply ma mf =
    Task.andThen (\f -> Task.map f ma) mf


{-| Returns a task that performs the task `f` gives for each element of the
list, first to last, and succeeds with the list of their results in the same
order.

It stops at the first task that fails and fails with its error, so the tasks
for later elements are never performed. An empty list gives a task that
succeeds with an empty list.

-}
mapM : (a -> Task x b) -> List a -> Task x (List b)
mapM f =
    List.map f >> Task.sequence
