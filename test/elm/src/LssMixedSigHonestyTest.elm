module LssMixedSigHonestyTest exposing (main)

{-| LSS_026(a) runtime honesty pin
(`plans/lss-gap2-callarg-transport.md` §0.5, Phase 1).

`d f = pickG True f` returns the CALLER's function at runtime. `pickG`'s
signature fact is honestly mixed — members `{g|incr}` plus a promoted source
for its own `f` param — but inside `d` the argument `f` never connects to
that param's instantiation slot (the A.1 arg-position leak), so the slot
dangles as an unconstrained FlexVar. Read as an ∅ contribution, `d`'s
internalized fact would claim `{g|incr}` is the COMPLETE inhabitant set of
`d`'s result.

It is not, and `Mono.LSet` is a completeness claim: a downstream consumer
that trusts a `{g|X}` SINGLETON — LSS_025's post-settle devirt is exactly
such a consumer, and a standalone-global member GROUNDS at the consuming
zonk (LSS_019) so it reaches that consumer in devirt-ready form — may
rewrite these dispatches into direct calls to `incr`. Then `viaIdent` prints
42 instead of 41: the representative-hijack miscompile class, observable in
program OUTPUT.

The pin runs in BOTH flag arms and must print the same numbers in each. It
is a guard, not a bug demo — nothing at HEAD is expected to take the false
stamp today (the guards decline for other reasons); its job is to fail loudly
if some future consumer starts trusting the set that §0.5 shows can be
false.

The list form exists so the three inhabitants reach `d` through one shared
call site: a single monomorphic use would let the inliner fold the whole
question away before any set is consulted.

-}

import Html exposing (text)

-- CHECK: viaIdent: 41
-- CHECK: viaIncr: 42
-- CHECK: viaDouble: 82
-- CHECK: shared: [41, 42, 82]


ident : Int -> Int
ident x =
    x


incr : Int -> Int
incr x =
    x + 1


double : Int -> Int
double x =
    x * 2


{-| One honest branch (the param) and one standalone-global branch — the
result fact carries members AND a source.
-}
pickG : Bool -> (Int -> Int) -> (Int -> Int)
pickG c f =
    if c then
        f

    else
        incr


{-| The wrapper whose signature internalizes `pickG`'s fact over a dangling
inflow.
-}
d : (Int -> Int) -> (Int -> Int)
d f =
    pickG True f


apply1 : (Int -> Int) -> Int -> Int
apply1 f n =
    f n


main =
    let
        _ =
            Debug.log "viaIdent" (d ident 41)

        _ =
            Debug.log "viaIncr" (d incr 41)

        _ =
            Debug.log "viaDouble" (d double 41)

        _ =
            Debug.log "shared" (List.map (\f -> apply1 (d f) 41) [ ident, incr, double ])
    in
    text "done"
