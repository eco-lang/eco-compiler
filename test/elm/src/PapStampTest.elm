module PapStampTest exposing (main)

{-| Regression shape for the LSS `p|` fast-stamp unsoundness found on 2026-09-11.

A state-monad `Step` whose `succeed` is written at full arity (a 2-ary global,
so `succeed x` is a PAP of a global — the shape η-expansion produces), and a
consumer `andThen k step` whose `step` is EITHER that PAP or a closure returned
by another `andThen` call, chosen by a runtime condition. The `Just` branch
must run its state effect.

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
        -- Just branch: loadType bumps counter 3 -> 4 and bindDemand logs one entry: 4*10 + 1 = 41
        -- Nothing branch: nothing happens: 3*10 + 0 = 30 ; sum = 71 ... report Just-branch + 1 so a skipped
        -- effect (30 + 1 = 31) is distinguishable from the correct 42.
        result =
            run (Just 5) + 1

        _ =
            Debug.log "PapStampTest" result
    in
    text "ok"
