module LssGapAliasCombinator exposing (main)

{-| Combinators over a function-typed type alias work when the callback passed
to `andThenP` returns its function in three different ways.

`P a` is an alias for `Int -> ( a, Int )`, so a callback of type `a -> P b`
returns a function. The three definitions summed in `main` differ only in how
that function is produced:

  - `viaCall`: the callback calls another combinator, `\x -> pureP (x + 1)`,
    giving 1 + 1 = 2
  - `viaLambda`: the callback returns a lambda literal, `\x -> \i -> ( x + 2, i )`,
    giving 2 + 2 = 4
  - `viaLocal`: the callback is a let-bound function returning a let-bound
    `P` value, giving 3 + 3 = 6

The total printed is 12.

## eco

A lambda-set specialization (LSS) coverage probe for the constructor-arrow
identity work (plans/lss-ctor-arrow-identity.md), written after
test/eco-elm/src/LssGapDecoderChain.elm came back fully covered. The bulk of
unresolved positions in the self-compile is the callback result spine (rows such
as `andThen|/a0/r`), which exists only when the callback's own result is an
arrow, as happens when a combinator is typed over a function-typed alias like
`P a`, transparent in MonoType. The three definitions produce that returned
function as a call result, a lambda literal and a let-bound local (the
`enrichFromEnv` path).

Read the analysis with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1` and
grep `^pos|`; the decisive rows are `andThenP|/a0/r` and `runP|/a0`.

-}

-- CHECK: aliasCombinator: 12

import Html exposing (text)


type alias P a =
    Int -> ( a, Int )


pureP : a -> P a
pureP a =
    \i -> ( a, i )


andThenP : (a -> P b) -> P a -> P b
andThenP f p =
    \i ->
        let
            ( a, i2 ) =
                p i
        in
        f a i2


runP : P a -> a
runP p =
    Tuple.first (p 0)


viaCall : Int
viaCall =
    runP (andThenP (\x -> pureP (x + 1)) (pureP 1))


viaLambda : Int
viaLambda =
    runP (andThenP (\x -> \i -> ( x + 2, i )) (pureP 2))


viaLocal : Int
viaLocal =
    let
        mk x =
            let
                inner =
                    pureP (x + 3)
            in
            inner
    in
    runP (andThenP mk (pureP 3))


main =
    let
        _ =
            Debug.log "aliasCombinator" (viaCall + viaLambda + viaLocal)
    in
    text "h"
