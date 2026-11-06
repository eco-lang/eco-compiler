module LssMixedSigHonestyTest exposing (main)

{-| A function that returns either its function argument or a fixed top-level function returns the argument when told to.

`pickG c f` returns `f` when `c` is `True` and `incr` otherwise, and `d f = pickG True f` always
returns `f`. Applied to 41:

  - `d ident` gives 41, `d incr` gives 42, and `d double` gives 82.
  - `shared` makes the same three calls through one lambda mapped over the list
    `[ ident, incr, double ]`, giving `[41,42,82]`.

A program that wrongly called `incr` in place of the argument would print 42 for `viaIdent`.

## eco

Runtime guard for honest empty-as-source (LSS_026 in design_docs/invariants.csv; the call
argument transport work, plans/lss-gap2-callarg-transport.md). `pickG`'s signature fact is mixed:
the member `incr` plus a source for its own `f` parameter. Inside `d`, the argument `f` is not
connected to that parameter's instantiation slot, so the slot is an unconstrained variable. Read
as an empty contribution, `d`'s fact would claim `incr` is the only function `d` can return.

A lambda set is a completeness claim. A consumer that trusts a singleton, such as the
post-settle devirtualization (LSS_025 in design_docs/invariants.csv,
plans/lss-post-settle-fn-global-devirt.md), would then call `incr` directly and `viaIdent` would
print 42. The CHECK lines must hold with every flag setting. The list form sends the three
functions through one shared call site so the inliner cannot fold the question away.

-}

import Html exposing (text)

-- CHECK: viaIdent: 41
-- CHECK: viaIncr: 42
-- CHECK: viaDouble: 82
-- CHECK: shared: [41,42,82]


ident : Int -> Int
ident x =
    x


incr : Int -> Int
incr x =
    x + 1


double : Int -> Int
double x =
    x * 2


{-| Returns `f` when `c` is `True`, and `incr` otherwise.
-}
pickG : Bool -> (Int -> Int) -> (Int -> Int)
pickG c f =
    if c then
        f

    else
        incr


{-| Returns `f`, by way of `pickG True`.
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
