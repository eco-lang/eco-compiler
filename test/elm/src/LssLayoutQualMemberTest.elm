module LssLayoutQualMemberTest exposing (main)

{-| LSS_024 reproducer (plans/lss-layout-qualified-members.md §5.4): a
two-caller family forcing an annotation-only same-layout key split of `mid`
({mA} vs {mB} on `f`'s arrow) whose per-spec callback lambdas feed ONE
shared `andThenS`-shaped HOF — the miniature of the sigFlow
`variableToCanType` → `System.TypeCheck.IO.andThen` de-stamp (Phase 0
census: specs 16373/16375 reading same-raw sibling 2-sets).

Under `lss.layoutQualMembers` both `mid` specs mint their callback under ONE
layout-qualified member id, the shared HOF's callback slot re-becomes a
singleton, and AbiCloning consults it — where the fingerprint fence must
DECLINE this particular family (the clones capture different `f`s: an
E11-divergent pair), keeping generic dispatch and these exact outputs. The
stamped-vs-de-stamped 3-way pin (flag-off / sigFlow-on unfixed /
sigFlow-on fixed) is a census assertion made in the plan's Phase 2/3 runs;
THIS fixture pins end-to-end value correctness under every flag combination.

-}

-- CHECK: a: 11
-- CHECK: b: 21

import Html exposing (text)


type alias Step a =
    Int -> ( Int, a )


andThenS : (a -> Step b) -> Step a -> Step b
andThenS f ma =
    \s0 ->
        let
            ( s1, a ) =
                ma s0
        in
        f a s1


getS : Step Int
getS s =
    ( s, s )


mid : (Int -> Int) -> Step Int
mid f =
    andThenS (\v -> \s -> ( s, f (v + 1) )) getS


runS : Step a -> Int -> a
runS ma s =
    Tuple.second (ma s)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" (runS (mid (\x -> x + 5)) 5)

        _ =
            Debug.log "b" (runS (mid (\x -> x * 3)) 6)
    in
    text "done"
