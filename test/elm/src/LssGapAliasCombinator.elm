module LssGapAliasCombinator exposing (main)

{-| P0.b probe v2 for plans/lss-ctor-arrow-identity.md §8.2 — rewritten from
the census after v1 (`LssGapDecoderChain`) came back 100 % covered.

The corpus mass is NOT the applicative-over-a-custom-type shape; it is the
CALLBACK RESULT SPINE: `andThen|/a0/r` (475 var), `map3|/a0/r/r` (197),
`foldl|/a0/r` (162), `map|/a0/r` (110). A row at `/a0/r` exists only when the
callback's own RESULT is an arrow — which happens when the combinator's type
is written over a FUNCTION-TYPED TYPE ALIAS (`type alias P a = Int -> (a,
Int)`), transparent in MonoType. The value at that position is whatever the
callback body evaluates to: here a CALL to another combinator (a returned
closure), which is exactly the class no syntactic arg-injection can name.

Three rungs, each a different way to produce the returned function:

  - `viaCall`   — callback body is a CALL returning an alias-function
                  (`\x -> pureP (x + 1)`); the value is a returned closure.
  - `viaLambda` — callback body is a LITERAL (`\x -> \i -> ( x, i )`); the
                  inner literal is syntactically present.
  - `viaLocal`  — callback body is a LET-BOUND local holding an
                  alias-function; the enrichFromEnv path.

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`;
the decisive rows are `andThenP|/a0/r` and `runP|/a0`.

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
