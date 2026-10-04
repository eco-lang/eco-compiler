module Common.Format.RWS exposing (RWS, andThen, error, evalRWS, get, mapM_, modify, put, replicateM, return, tell)

{-| Lets a computation made of many steps pass a state from each step to the
next, and gather a dictionary of entries as it goes, without every step taking
and returning both by hand.

An `RWS r s a` is a reader-writer-state computation. Given an environment of
type `r` and a state of type `s`, it produces a result of type `a`, a new state,
and a log. The environment, the reader part, is handed unchanged to every step;
no function here reads it, so it is only carried along. The state is what each
step receives from the step before, and `put` and `modify` replace it. The log,
the writer part, is not a type parameter: it is fixed to a
`Dict String ( String, String )`, and a step adds entries to it with `tell`.

Steps are chained with `andThen`, which merges the logs of the two steps. When
both have an entry for the same key, the entry of the step that ran first is
kept.

`mapM_` does not visit a list in order. It runs its action on the last element
first and passes the state from the end of the list towards the start.

@docs RWS, andThen, error, evalRWS, get, mapM_, modify, put, replicateM, return, tell

-}

import Dict exposing (Dict)
import Utils.Crash exposing (crash)


{-| A computation that, given an environment and a state, returns its result,
the new state, and the log entries it produced.

This is a name for a function type, not a new type, so any function of this
shape is accepted where an `RWS` is expected.

-}
type alias RWS r s a =
    r -> s -> ( a, s, Dict String ( String, String ) )


{-| Runs `rws` with environment `r` and initial state `s`, and returns its
result and its log, dropping the final state.
-}
evalRWS : RWS r s a -> r -> s -> ( a, Dict String ( String, String ) )
evalRWS rws r s =
    let
        ( a, _, w ) =
            runRWS rws r s
    in
    ( a, w )


{-| Runs `rws` with environment `r` and initial state `s`, and returns its
result, its final state and its log.
-}
runRWS : RWS r s a -> r -> s -> ( a, s, Dict String ( String, String ) )
runRWS rws r s =
    rws r s


{-| Builds a computation that runs `f` on each element of `xs`, discarding the
results and keeping the final state and the merged log.

The elements are visited from last to first. `f` runs on the last element
against the starting state, and each earlier element sees the state the one
after it left. When two steps log the same key, the entry of the step that ran
first, which is the one for the later element, is kept. An empty list leaves
the state unchanged and logs nothing.

-}
mapM_ : (a -> RWS r s b) -> List a -> RWS r s ()
mapM_ f xs =
    \r s0 ->
        List.foldr
            (\x ( _, s, w ) ->
                let
                    ( _, newS, newW ) =
                        f x r s
                in
                ( (), newS, Dict.union w newW )
            )
            ( (), s0, Dict.empty )
            xs


{-| Builds a computation that runs `rwsa`, passes its result to `f`, and runs
the computation `f` returns on the state `rwsa` left. The two logs are merged,
and where both have an entry for the same key, the one from `rwsa` is kept.
-}
andThen : (a -> RWS r s b) -> RWS r s a -> RWS r s b
andThen f rwsa =
    \r s0 ->
        let
            ( a, s1, w1 ) =
                rwsa r s0

            ( b, s2, w2 ) =
                f a r s1
        in
        ( b, s2, Dict.union w1 w2 )


{-| A computation whose result is the current state, which it leaves
unchanged.
-}
get : RWS r s s
get =
    \_ s -> ( s, s, Dict.empty )


{-| Builds a computation that replaces the state with `newState`.
-}
put : s -> RWS r s ()
put newState =
    \_ _ -> ( (), newState, Dict.empty )


{-| Builds a computation that replaces the state with the result of applying
`f` to it.
-}
modify : (s -> s) -> RWS r s ()
modify f =
    \_ s -> ( (), f s, Dict.empty )


{-| Builds a computation whose result is `a`, leaving the state unchanged and
logging nothing.
-}
return : a -> RWS r s a
return a =
    \_ s -> ( a, s, Dict.empty )


{-| Builds a computation that logs the entries of `log` and leaves the state
unchanged. Earlier entries are not overwritten: `andThen` keeps an earlier
step's entry over a later one with the same key.
-}
tell : Dict String ( String, String ) -> RWS r s ()
tell log =
    \_ s -> ( (), s, log )


{-| Builds a computation that runs `rws` `n` times in sequence, each run seeing
the state the one before it left, and returns the results in the order they
were produced. For an `n` of zero or less it runs nothing and returns an empty
list.
-}
replicateM : Int -> RWS r s a -> RWS r s (List a)
replicateM n rws =
    if n <= 0 then
        return []

    else
        rws
            |> andThen
                (\a ->
                    replicateM (n - 1) rws
                        |> andThen (\list -> return (a :: list))
                )


{-| Aborts the program with the given message, through `Utils.Crash.crash`.

The abort happens as soon as `error` is applied to its message, not when the
computation it stands for is run.

-}
error : String -> RWS r s a
error =
    crash
