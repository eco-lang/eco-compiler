module Compiler.Elm.Constraint exposing
    ( Constraint, Error(..)
    , anything, exactly, untilNextMajor, untilNextMinor, defaultElm
    , satisfies, goodElm, intersect
    , toChars, lowerBound
    , encode, decoder
    )

{-| Version constraint types and operations.

Represents version ranges using upper and lower bounds with inclusive/exclusive
operators. Supports constraint intersection, satisfaction checking, and
validation against the current Elm compiler version.


# Types

@docs Constraint, Error


# Constructors

@docs anything, exactly, untilNextMajor, untilNextMinor, defaultElm


# Validation

@docs satisfies, goodElm, intersect


# Conversion

@docs toChars, lowerBound


# Encoding and Decoding

@docs encode, decoder

-}

import Compiler.Elm.Version as V
import Compiler.Json.Decode as D exposing (Decoder)
import Compiler.Json.Encode as E exposing (Value)
import Compiler.Parse.Primitives as P exposing (Col, Row)



-- CONSTRAINTS


{-| Represents a version constraint as a range with lower and upper bounds.
Each bound can be inclusive (<=) or exclusive (<).
-}
type Constraint
    = Range RangeProps


type alias RangeProps =
    { lower : V.Version
    , lowerOp : Op
    , upperOp : Op
    , upper : V.Version
    }


type Op
    = Less
    | LessOrEqual


{-| Helper to construct Range with positional args
-}
range : V.Version -> Op -> Op -> V.Version -> Constraint
range lower lowerOp upperOp upper =
    Range { lower = lower, lowerOp = lowerOp, upperOp = upperOp, upper = upper }



-- COMMON CONSTRAINTS


{-| Creates a constraint that matches exactly one specific version.
-}
exactly : V.Version -> Constraint
exactly version =
    range version LessOrEqual LessOrEqual version


{-| Creates a constraint that accepts any valid version (1.0.0 through max version).
-}
anything : Constraint
anything =
    range V.one LessOrEqual LessOrEqual V.maxVersion



-- EXTRACT VERSION


{-| Extracts the lower bound version from a constraint.
-}
lowerBound : Constraint -> V.Version
lowerBound (Range props) =
    props.lower



-- TO CHARS


{-| Converts a constraint to its string representation.
Format: "lower <= v < upper" or similar based on operators.
-}
toChars : Constraint -> String
toChars constraint =
    case constraint of
        Range { lower, lowerOp, upperOp, upper } ->
            V.toChars lower ++ opToChars lowerOp ++ "v" ++ opToChars upperOp ++ V.toChars upper


opToChars : Op -> String
opToChars op =
    case op of
        Less ->
            " < "

        LessOrEqual ->
            " <= "



-- IS SATISFIED


{-| Checks whether a given version satisfies the constraint.
Returns True if the version falls within the constraint's range.
-}
satisfies : Constraint -> V.Version -> Bool
satisfies constraint version =
    case constraint of
        Range { lower, lowerOp, upperOp, upper } ->
            isLess lowerOp lower version
                && isLess upperOp version upper


isLess : Op -> (V.Version -> V.Version -> Bool)
isLess op =
    case op of
        Less ->
            \lower upper ->
                V.compare lower upper == LT

        LessOrEqual ->
            \lower upper ->
                V.compare lower upper /= GT



-- INTERSECT


{-| Computes the intersection of two constraints.
Returns Nothing if the constraints do not overlap, otherwise returns
a new constraint representing the overlapping range.
-}
intersect : Constraint -> Constraint -> Maybe Constraint
intersect (Range r1) (Range r2) =
    let
        ( newLo, newLop ) =
            case V.compare r1.lower r2.lower of
                LT ->
                    ( r2.lower, r2.lowerOp )

                EQ ->
                    ( r1.lower
                    , if List.member Less [ r1.lowerOp, r2.lowerOp ] then
                        Less

                      else
                        LessOrEqual
                    )

                GT ->
                    ( r1.lower, r1.lowerOp )

        ( newHi, newHop ) =
            case V.compare r1.upper r2.upper of
                LT ->
                    ( r1.upper, r1.upperOp )

                EQ ->
                    ( r1.upper
                    , if List.member Less [ r1.upperOp, r2.upperOp ] then
                        Less

                      else
                        LessOrEqual
                    )

                GT ->
                    ( r2.upper, r2.upperOp )
    in
    if V.compare newLo newHi /= GT then
        Just (range newLo newLop newHop newHi)

    else
        Nothing



-- ELM CONSTRAINT


{-| Checks whether the current Elm compiler version satisfies the constraint.
-}
goodElm : Constraint -> Bool
goodElm constraint =
    satisfies constraint V.elmCompiler


{-| Returns the default Elm version constraint.
For major version 1+, constrains until the next major version.
For major version 0, constrains until the next minor version.
-}
defaultElm : Constraint
defaultElm =
    let
        (V.Version major _ _) =
            V.elmCompiler
    in
    if major > 0 then
        untilNextMajor V.elmCompiler

    else
        untilNextMinor V.elmCompiler



-- CREATE CONSTRAINTS


{-| Creates a constraint from the given version up to (but not including) the next major version.
Example: untilNextMajor 1.2.3 creates constraint "1.2.3 <= v < 2.0.0"
-}
untilNextMajor : V.Version -> Constraint
untilNextMajor version =
    range version LessOrEqual Less (V.bumpMajor version)


{-| Creates a constraint from the given version up to (but not including) the next minor version.
Example: untilNextMinor 1.2.3 creates constraint "1.2.3 <= v < 1.3.0"
-}
untilNextMinor : V.Version -> Constraint
untilNextMinor version =
    range version LessOrEqual Less (V.bumpMinor version)



-- JSON


{-| Encodes a constraint as a JSON string value.
-}
encode : Constraint -> Value
encode constraint =
    E.string (toChars constraint)


{-| Decodes a constraint from a JSON string.
Returns an Error if the format is invalid or the range is malformed.
-}
decoder : Decoder Error Constraint
decoder =
    D.customString parser BadFormat



-- PARSER


{-| Represents errors that can occur when parsing constraint strings.
BadFormat indicates a syntax error at the given row and column.
InvalidRange indicates the lower bound is not less than the upper bound.
-}
type Error
    = BadFormat Row Col
    | InvalidRange V.Version V.Version


parser : P.Parser Error Constraint
parser =
    parseVersion
        |> P.andThen
            (\lower ->
                P.word1 ' ' BadFormat
                    |> P.andThen
                        (\_ ->
                            parseOp
                                |> P.andThen
                                    (\loOp ->
                                        P.word1 ' ' BadFormat
                                            |> P.andThen
                                                (\_ ->
                                                    P.word1 'v' BadFormat
                                                        |> P.andThen
                                                            (\_ ->
                                                                P.word1 ' ' BadFormat
                                                                    |> P.andThen
                                                                        (\_ ->
                                                                            parseOp
                                                                                |> P.andThen
                                                                                    (\hiOp ->
                                                                                        P.word1 ' ' BadFormat
                                                                                            |> P.andThen
                                                                                                (\_ ->
                                                                                                    parseVersion
                                                                                                        |> P.andThen
                                                                                                            (\higher ->
                                                                                                                P.Parser <|
                                                                                                                    \((P.State st) as state) ->
                                                                                                                        if V.compare lower higher == LT then
                                                                                                                            P.Eok (range lower loOp hiOp higher) state

                                                                                                                        else
                                                                                                                            P.Eerr st.row st.col (\_ _ -> InvalidRange lower higher)
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


parseVersion : P.Parser Error V.Version
parseVersion =
    P.specialize (\( r, c ) _ _ -> BadFormat r c) V.parser


parseOp : P.Parser Error Op
parseOp =
    P.word1 '<' BadFormat
        |> P.andThen
            (\_ ->
                P.oneOfWithFallback
                    [ P.word1 '=' BadFormat
                        |> P.map (\_ -> LessOrEqual)
                    ]
                    Less
            )
