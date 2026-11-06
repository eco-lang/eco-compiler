module PapStampTest exposing (main)

{-| Tests a state-passing `andThen` whose step argument is chosen at run time
between a partially applied `succeed` and a function returned by another
`andThen`, and checks that the chosen step's effects on the state happen.

`Step a` is a function from a state record to `Result String ( a, S )`.
`succeed` is defined with two parameters although its result type is a
function, so `succeed ()` is a partial application. `translateLet` passes
either `succeed ()` or `andThen (\annVar -> bindDemand annVar instType)
(loadType defType)` to an outer `andThen`, depending on its `Maybe Int`
argument. The test runs only the `Just` case.

## eco

Regression shape for an unsoundness in the LSS `p|` fast stamp
(plans/lss-pap-fast-stamp.md), found 2026-09-11. `succeed` written at full
arity makes `succeed ()` a PAP of a global, the shape eta-expansion produces.
The consumer's step is either that PAP or a closure returned by `andThen`,
chosen at run time, so the call site's lambda set is not a singleton and must
not be fast-stamped as one. A wrong stamp skips the `Just` branch's state
effect, which prints 31 instead of 42.

-}

-- CHECK: PapStampTest: 42

import Html exposing (text)


type alias S =
    { counter : Int, log : List Int }


type alias Step a =
    S -> Result String ( a, S )


succeed : a -> Step a
succeed a s =
    Ok ( a, s )


andThen : (a -> Step b) -> Step a -> Step b
andThen f step =
    \s ->
        case step s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                f a s1


loadType : Int -> Step Int
loadType n =
    \s -> Ok ( n + s.counter, { s | counter = s.counter + 1 } )


bindDemand : Int -> Int -> Step ()
bindDemand annVar inst =
    \s -> Ok ( (), { s | log = annVar + inst :: s.log } )


translateLet : Maybe Int -> Int -> Step Int
translateLet singleInstance defType =
    andThen
        (\_ -> \s -> Ok ( s.counter * 10 + List.length s.log, s ))
        (case singleInstance of
            Just instType ->
                andThen (\annVar -> bindDemand annVar instType) (loadType defType)

            Nothing ->
                succeed ()
        )


run : Maybe Int -> Int
run mb =
    case translateLet mb 7 { counter = 3, log = [] } of
        Ok ( v, _ ) ->
            v

        Err _ ->
            -1


main =
    let
        -- In the Just branch loadType raises counter from 3 to 4 and bindDemand
        -- adds one log entry, so the final step returns 4 * 10 + 1 = 41, and
        -- 41 + 1 = 42. If both effects were skipped the result would be
        -- 3 * 10 + 0 + 1 = 31.
        result =
            run (Just 5) + 1

        _ =
            Debug.log "PapStampTest" result
    in
    text "ok"
