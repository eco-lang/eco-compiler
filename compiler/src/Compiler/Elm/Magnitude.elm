module Compiler.Elm.Magnitude exposing
    ( Magnitude(..)
    , compare, toChars
    )

{-| Semantic versioning magnitude types.

Represents the three levels of version changes in semantic versioning:
PATCH for bug fixes, MINOR for backward-compatible additions, and MAJOR
for breaking changes.


# Types

@docs Magnitude


# Operations

@docs compare, toChars

-}

-- MAGNITUDE


type Magnitude
    = PATCH
    | MINOR
    | MAJOR


toChars : Magnitude -> String
toChars magnitude =
    case magnitude of
        PATCH ->
            "PATCH"

        MINOR ->
            "MINOR"

        MAJOR ->
            "MAJOR"


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
