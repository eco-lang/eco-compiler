module Common.Format.RWS exposing (RWS, andThen, evalRWS, get, mapM_, modify, put, replicateM, return)

{-| Lets a computation made of many steps pass a state from each step to the
next, without every step taking and returning it by hand.

An `RWS r s a` is a reader-state computation. Given an environment of type `r`
and a state of type `s`, it produces a result of type `a` and a new state. The
environment, the reader part, is handed unchanged to every step; no function
here reads it, so it is only carried along. The state is what each step
receives from the step before, and `put` and `modify` replace it.

`mapM_` does not visit a list in order. It runs its action on the last element
first and passes the state from the end of the list towards the start.

@docs RWS, andThen, evalRWS, get, mapM_, modify, put, replicateM, return

-}


{-| A computation that, given an environment and a state, returns its result
and the new state.

This is a name for a function type, not a new type, so any function of this
shape is accepted where an `RWS` is expected.

-}
type alias RWS r s a =
    r -> s -> ( a, s )


{-| Runs `rws` with environment `r` and initial state `s`, and returns its
result, dropping the final state.
-}
evalRWS : RWS r s a -> r -> s -> a
evalRWS rws r s =
    Tuple.first (rws r s)


{-| Builds a computation that runs `f` on each element of `xs`, discarding the
results and keeping the final state.

The elements are visited from last to first. `f` runs on the last element
against the starting state, and each earlier element sees the state the one
after it left. An empty list leaves the state unchanged.

-}
mapM_ : (a -> RWS r s b) -> List a -> RWS r s ()
mapM_ f xs =
    \r s0 ->
        List.foldr
            (\x ( _, s ) ->
                ( (), Tuple.second (f x r s) )
            )
            ( (), s0 )
            xs


{-| Builds a computation that runs `rwsa`, passes its result to `f`, and runs
the computation `f` returns on the state `rwsa` left.
-}
andThen : (a -> RWS r s b) -> RWS r s a -> RWS r s b
andThen f rwsa =
    \r s0 ->
        let
            ( a, s1 ) =
                rwsa r s0
        in
        f a r s1


{-| A computation whose result is the current state, which it leaves
unchanged.
-}
get : RWS r s s
get =
    \_ s -> ( s, s )


{-| Builds a computation that replaces the state with `newState`.
-}
put : s -> RWS r s ()
put newState =
    \_ _ -> ( (), newState )


{-| Builds a computation that replaces the state with the result of applying
`f` to it.
-}
modify : (s -> s) -> RWS r s ()
modify f =
    \_ s -> ( (), f s )


{-| Builds a computation whose result is `a`, leaving the state unchanged.
-}
return : a -> RWS r s a
return a =
    \_ s -> ( a, s )


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
