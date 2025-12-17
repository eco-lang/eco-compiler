module Common.Format.RWS exposing
    ( RWS
    , andThen
    , error
    , evalRWS
    , get
    , mapM_
    , modify
    , put
    , replicateM
    , return
    , runRWS
    , tell
    )

{-| Reader-Writer-State monad for document parsing.
Combines read-only environment (r), write-only log (Dict), and mutable state (s).

@docs RWS, andThen, error, evalRWS, get, mapM_, modify, put, replicateM, return, runRWS, tell

-}

import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)


{-| Reader-Writer-State monad computation.
Takes an environment (r) and state (s), returns a result (a), updated state, and log.
-}
type alias RWS r s a =
    -- type alias RWS r w s a =
    -- r: (), w: ReferenceMap, s: ContainerStack, a: Container
    r -> s -> ( a, s, Dict String String ( String, String ) )


{-| Evaluate the RWS computation, returning the result and accumulated log.
Discards the final state.
-}
evalRWS : RWS r s a -> r -> s -> ( a, Dict String String ( String, String ) )
evalRWS rws r s =
    let
        ( a, _, w ) =
            runRWS rws r s
    in
    ( a, w )


{-| Run the RWS computation, returning the result, final state, and accumulated log.
-}
runRWS : RWS r s a -> r -> s -> ( a, s, Dict String String ( String, String ) )
runRWS rws r s =
    rws r s


{-| Map a monadic action over a list and discard the results.
Useful for performing side effects on each element.
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


{-| Monadic bind for RWS computations.
Sequences two computations, passing the result of the first to a function producing the second.
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


{-| Get the current state.
-}
get : RWS r s s
get =
    \_ s -> ( s, s, Dict.empty )


{-| Replace the state with a new value.
-}
put : s -> RWS r s ()
put newState =
    \_ _ -> ( (), newState, Dict.empty )


{-| Modify the state using a transformation function.
-}
modify : (s -> s) -> RWS r s ()
modify f =
    \_ s -> ( (), f s, Dict.empty )


{-| Lift a pure value into the RWS context.
-}
return : a -> RWS r s a
return a =
    \_ s -> ( a, s, Dict.empty )


{-| Append to the log (writer component).
-}
tell : Dict String String ( String, String ) -> RWS r s ()
tell log =
    \_ s -> ( (), s, log )


{-| Repeat a computation n times and collect the results.
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


{-| Raise an error with the given message.
Crashes the computation.
-}
error : String -> RWS r s a
error =
    crash
