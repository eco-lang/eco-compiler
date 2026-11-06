module LssGapCtorRebuild exposing (main)

{-| Function values stored in custom type constructors survive being rebuilt,
wrapped by a polymorphic function, or passed through an identity function.

`PS x` has a constructor `Cerr2 Int (Int -> x)` carrying a function. The four
values summed in `main` are:

  - `rebuilt`: `mapPS` matches `Cerr2 r t` and returns `Cerr2 r t` unchanged,
    so `runPS` gives 10 + (1 + 2) = 13
  - `direct`: `runPS` applied to a `Cerr2` built in place, 4 + 1 * 2 = 6
  - `wrapped`: the polymorphic `wrapAny` puts the function `bump` in a `Box`,
    and `unBox` applies it to 5, giving 6
  - `viaId`: a `Cerr2` passed through the polymorphic `idf`, 3 + (1 + 4) = 8

The total printed is 33.

## eco

A lambda-set specialization (LSS) probe for where LTop is manufactured
(plans/lss-ctor-arrow-identity.md). In the self-compile the largest LTop class
came from the storeless classification path, and most of its constructor share
belonged to `Cerr` / `Eerr` of compiler/src/Compiler/Lexer/Primitives.elm, whose
payload is a deferred error builder; some construction sites took the
store-aware path and others did not. Each value in `main` is one candidate
shape: `rebuilt` is the destructure-and-rebuild of the parser's `map`, where the
payload is a pattern-bound local whose use-site type may be a variable rather
than an arrow; `wrapped` passes the function through a bare type variable;
`direct` is the control and should be covered; `viaId` crosses an item boundary
through a polymorphic identity.

Read with `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`; the
decisive rows are `Cerr2|/r/a0` and `Box|/a0`.

-}

-- CHECK: ctorRebuild: 33

import Html exposing (text)


type PS x
    = Ok2 Int
    | Cerr2 Int (Int -> x)


type Box a
    = Box a


{-| Applies `f` to an `Ok2` payload and rebuilds a `Cerr2` from its own
pattern variables.
-}
mapPS : (Int -> Int) -> PS x -> PS x
mapPS f ps =
    case ps of
        Ok2 n ->
            Ok2 (f n)

        Cerr2 r t ->
            Cerr2 r t


runPS : PS Int -> Int
runPS ps =
    case ps of
        Ok2 n ->
            n

        Cerr2 r t ->
            r + t 1


{-| Wraps a value of any type in a `Box`.
-}
wrapAny : a -> Box a
wrapAny v =
    Box v


unBox : Box (Int -> Int) -> Int
unBox (Box g) =
    g 5


idf : a -> a
idf v =
    v


bump : Int -> Int
bump n =
    n + 1


main =
    let
        rebuilt =
            runPS (mapPS bump (Cerr2 10 (\i -> i + 2)))

        direct =
            runPS (Cerr2 4 (\i -> i * 2))

        wrapped =
            unBox (wrapAny bump)

        viaId =
            runPS (idf (Cerr2 3 (\i -> i + 4)))

        _ =
            Debug.log "ctorRebuild" (rebuilt + direct + wrapped + viaId)
    in
    text "h"
