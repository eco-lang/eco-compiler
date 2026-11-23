module FoldPureAccumulatorTest exposing (main)

{-| A left fold over a state monad, starting from `pure ()`, runs every step
in order.

`imapM_ action xs` folds the indexed list with `List.foldl`, chaining each
`action i x` after the accumulator with `andThen` and discarding its result
with `map`; the first accumulator is `pure ()`. `count` adds `i` and the
string's length to `n`, so `[ "a", "bb", "ccc" ]` gives 0+1 + 1+2 + 2+3 = 9;
`record` conses `String.fromInt i ++ x` onto `log`, so `[ "x", "y" ]` gives
`[ "1y", "0x" ]`.

## eco

Guards a lambda-set completeness bug in the solver monomorphizer
(compiler/tests/Compiler/Monomorphize/Solver/LambdaArgOrderTest.elm,
plans/lss-capture-qualified-members.md §9.2). The step lambda is `List.foldl`'s first
argument and `pure ()` its second; when the lambda was translated first, the
accumulator's lambda set lacked `pure ()`'s member, `andThen`'s call `ma s`
was stamped as a direct call to the step lambda, and the first iteration ran
that code on `pure ()`'s closure, which crashed natively. Lambda literals are
now translated after the call's other arguments.

-}

-- CHECK: state: (9,["1y","0x"])

import Html exposing (text)


type alias State =
    { n : Int, log : List String }


type alias IO a =
    State -> ( State, a )


pure : a -> IO a
pure a =
    \s -> ( s, a )


andThen : (a -> IO b) -> IO a -> IO b
andThen f ma =
    \s ->
        let
            ( s1, a ) =
                ma s
        in
        f a s1


map : (a -> b) -> IO a -> IO b
map f ma =
    \s ->
        let
            ( s1, a ) =
                ma s
        in
        ( s1, f a )


imapM_ : (Int -> String -> IO b) -> List String -> IO ()
imapM_ action xs =
    List.foldl
        (\( i, x ) ioAcc ->
            ioAcc
                |> andThen (\_ -> action i x)
                |> map (\_ -> ())
        )
        (pure ())
        (List.indexedMap Tuple.pair xs)


count : Int -> String -> IO Int
count i x =
    \s -> ( { s | n = s.n + i + String.length x }, i )


record : Int -> String -> IO ()
record i x =
    \s -> ( { s | log = (String.fromInt i ++ x) :: s.log }, () )


main =
    let
        ( s1, _ ) =
            imapM_ count [ "a", "bb", "ccc" ] { n = 0, log = [] }

        ( s2, _ ) =
            imapM_ record [ "x", "y" ] s1

        _ =
            Debug.log "state" ( s2.n, s2.log )
    in
    text "done"
