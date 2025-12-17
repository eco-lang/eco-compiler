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


{-| Represents the severity level of a version change in semantic versioning.
-}
type Magnitude
    = PATCH
    | MINOR
    | MAJOR


{-| Converts a magnitude value to its string representation (e.g., PATCH -> "PATCH").
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


{-| Compares two magnitude values, ordering them from least severe (PATCH) to most severe (MAJOR).
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
