module EtaExpandStateTest exposing (main)

{-| Pre-mono η-expansion, runtime differential
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` §5).

This is the `SeqM` probe VERBATIM — the chain written at ALIAS arity, which is
how all 169 callers of `System.TypeCheck.IO.andThen` are written. The compiler
must produce `SeqEta`'s result from it: `sequence` gains its state parameter,
every `andThen` reaches three arguments, and both continuations gain one of
their own.

The numbers are the guard. η-expansion moves the evaluation of everything left
of the new binders from once to once per call, and it reassociates nothing —
so if the state threading, the branch pushing (`pure [] s0` in the `[]` arm) or
the merge into the under-applied call were wrong in ANY way, these columns
print different numbers rather than running slower. `sequence` is a `Cycle`
member with a `case`, so the R8 hazard (a `jumps` entry left holding the
un-applied PAP while its siblings are saturated) is live in this fixture.

`List.map run [ 1, 2, 3 ]` is load-bearing: a single monomorphic use lets the
inliner fold the whole question away before any of this is reached.

The pin must print the same numbers in every flag arm — with `etaExpand` on and
off, and in both inliner positions.

-}

import Html exposing (text)



-- CHECK: r: [30, 42, 54]


type alias St a =
    Int -> ( Int, a )


andThen : (a -> St b) -> St a -> St b
andThen f ma s0 =
    let
        ( s1, a ) =
            ma s0
    in
    f a s1


pure : a -> St a
pure x s =
    ( s, x )


tick : St Int
tick s =
    ( s + 1, s )


tick2 : St Int
tick2 s =
    ( s + 2, s * 10 )


sequence : List (St a) -> St (List a)
sequence actions =
    case actions of
        [] ->
            pure []

        m :: rest ->
            m |> andThen (\x -> sequence rest |> andThen (\xs -> pure (x :: xs)))


run : Int -> Int
run n =
    List.sum (Tuple.second (sequence [ tick, tick2, pure 5, tick ] n))


main =
    let
        _ =
            Debug.log "r" (List.map run [ 1, 2, 3 ])
    in
    text "done"
