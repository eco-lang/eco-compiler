module Compiler.Elm.Magnitude exposing
    ( Magnitude(..)
    , compare, toChars
    )

{-| A package's version number tells its users how much its API has changed,
and this module names those amounts.

Semantic versioning writes a version as `MAJOR.MINOR.PATCH` and raises one of
the three parts at each release, according to how much the API changed. A
_magnitude_ is the part to be raised. Which change to an API earns which
magnitude is decided in `Builder.Deps.Diff`, not here.

Magnitudes are ordered by size, by `compare`, so that the largest of several
can be taken.


# Types

@docs Magnitude


# Operations

@docs compare, toChars

-}

-- ====== MAGNITUDE ======


{-| The size of a change to a package's API, named after the part of the
version number it requires to be raised.

`PATCH` leaves the API as it was, `MINOR` only adds to it, and `MAJOR` changes
or removes something in it.

A custom type is not `comparable` in Elm, so the order of these, from `PATCH`
up to `MAJOR`, is given by `compare`.

-}
type Magnitude
    = PATCH
    | MINOR
    | MAJOR


{-| Returns the name of `magnitude` in capitals, spelled as its constructor
is: `"PATCH"`, `"MINOR"` or `"MAJOR"`.
-}
toChars : Magnitude -> String
toChars magnitude =
    case magnitude of
        PATCH ->
            "PATCH"

        MINOR ->
            "MINOR"

        MAJOR ->
            "MAJOR"


{-| Returns how `m1` compares with `m2` in size, where `PATCH` is the
smallest and `MAJOR` the largest. It stands in for `Basics.compare`, which a
custom type cannot be given to.
-}
compare : Magnitude -> Magnitude -> Order
compare m1 m2 =
    let
        toInt : Magnitude -> number
        toInt m =
            case m of
                PATCH ->
                    0

                MINOR ->
                    1

                MAJOR ->
                    2
    in
    Basics.compare (toInt m1) (toInt m2)
