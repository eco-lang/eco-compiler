module Compiler.Elm.Constraint exposing
    ( Constraint, Error(..)
    , anything, exactly, untilNextMajor, untilNextMinor, defaultElm
    , satisfies, goodElm, intersect
    , toChars, lowerBound
    , encode, decoder
    )

{-| A package, or the Elm language itself, can be acceptable at more than
one version, and a constraint is how such a range of versions is stated. This
module is that range: how one is made, written and read back, tested against a
version, and combined with another.

A constraint has a lower and an upper version, and each bound is either
inclusive or exclusive. Its written form is, for example, `1.0.0 <= v < 2.0.0`:
the lower version, `<` or `<=`, the letter `v` standing for the version being
tested, `<` or `<=` again, and the upper version, with one space between each.
A version _satisfies_ a constraint when it lies within that range. Versions and
their order are as `Compiler.Elm.Version` describes.

Nothing requires a constraint to be satisfied by any version. `intersect` can
return one such as `2.0.0 <= v < 2.0.0`, which no version satisfies. In the
other direction, `decoder` refuses any written constraint whose lower version
is not strictly before its upper version, so the written form of an `exactly`
constraint does not decode.


# Types

@docs Constraint, Error


# Constructors

@docs anything, exactly, untilNextMajor, untilNextMinor, defaultElm


# Testing and Combining

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



-- ====== CONSTRAINTS ======


{-| A range of versions, bounded below and above, with each bound either
inclusive or exclusive.

A value is made by one of the constructors below, by `intersect` or by
`decoder`. None of these checks that any version satisfies the result.
`decoder` requires the lower version to be strictly before the upper one, but
even that does not ensure it: no version satisfies `1.0.0 < v < 1.0.1`.

-}
type Constraint
    = Range RangeProps


{-| The four parts of a constraint, in the order they are written: the lower
version, the operator between it and the tested version, the operator between
the tested version and the upper version, and the upper version.
-}
type alias RangeProps =
    { lower : V.Version
    , lowerOp : Op
    , upperOp : Op
    , upper : V.Version
    }


{-| The comparison a bound makes with the tested version, read left to right
as the constraint is written.

`Less` makes the bound exclusive, written `<`, and `LessOrEqual` makes it
inclusive, written `<=`.

-}
type Op
    = Less
    | LessOrEqual


{-| Builds a constraint from its four parts, given in the order they are
written.
-}
range : V.Version -> Op -> Op -> V.Version -> Constraint
range lower lowerOp upperOp upper =
    Range { lower = lower, lowerOp = lowerOp, upperOp = upperOp, upper = upper }



-- ====== COMMON CONSTRAINTS ======


{-| Returns the constraint that `version` satisfies and no other version does,
written `version <= v <= version`.
-}
exactly : V.Version -> Constraint
exactly version =
    range version LessOrEqual LessOrEqual version


{-| The constraint satisfied by every version from `Compiler.Elm.Version.one`
(1.0.0) up to and including `Compiler.Elm.Version.maxVersion`.

Versions before 1.0.0 do not satisfy it, and nor do the versions later than
`maxVersion` that its docstring describes.

-}
anything : Constraint
anything =
    range V.one LessOrEqual LessOrEqual V.maxVersion



-- ====== EXTRACT VERSION ======


{-| Returns the constraint's lower version, whether or not that version
satisfies it: when the lower bound is exclusive, it does not.
-}
lowerBound : Constraint -> V.Version
lowerBound (Range props) =
    props.lower



-- ====== TO CHARS ======


{-| Returns the written form of a constraint, such as `1.0.0 <= v < 2.0.0`.
-}
toChars : Constraint -> String
toChars constraint =
    case constraint of
        Range { lower, lowerOp, upperOp, upper } ->
            V.toChars lower ++ opToChars lowerOp ++ "v" ++ opToChars upperOp ++ V.toChars upper


{-| Returns the written form of an operator with a space on either side.
-}
opToChars : Op -> String
opToChars op =
    case op of
        Less ->
            " < "

        LessOrEqual ->
            " <= "



-- ====== IS SATISFIED ======


{-| Returns whether `version` satisfies the constraint: it is after the lower
version, or equal to it when that bound is inclusive, and before the upper
version, or equal to it when that bound is inclusive.
-}
satisfies : Constraint -> V.Version -> Bool
satisfies constraint version =
    case constraint of
        Range { lower, lowerOp, upperOp, upper } ->
            isLess lowerOp lower version
                && isLess upperOp version upper


{-| Returns the test that `op` makes between the version on its left and the
version on its right: strictly before for `Less`, before or equal for
`LessOrEqual`.
-}
isLess : Op -> (V.Version -> V.Version -> Bool)
isLess op =
    case op of
        Less ->
            \lower upper ->
                V.compare lower upper == LT

        LessOrEqual ->
            \lower upper ->
                V.compare lower upper /= GT



-- ====== INTERSECT ======


{-| Returns the constraint whose bounds are the tighter of the two constraints'
bounds, or `Nothing` when its lower version would be after its upper version.

The lower bound is the later of the two lower versions, and the upper bound the
earlier of the two upper versions. Where both constraints name the same version
for a bound, the bound is exclusive if either of theirs is.

Only the versions are compared to decide on `Nothing`. When the two versions
are equal and either bound is exclusive, the result is `Just` a constraint that
no version satisfies: intersecting `1.0.0 <= v < 2.0.0` with
`2.0.0 <= v < 3.0.0` gives `2.0.0 <= v < 2.0.0`.

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



-- ====== ELM CONSTRAINT ======


{-| Returns whether `Compiler.Elm.Version.elmCompiler`, the version of Elm this
compiler implements, satisfies the constraint.
-}
goodElm : Constraint -> Bool
goodElm constraint =
    satisfies constraint V.elmCompiler


{-| The constraint on the Elm version that starts at, and includes,
`Compiler.Elm.Version.elmCompiler`, the version this compiler implements, and
runs up to, but not including, the next major version when its major number is
above 0, or the next minor version when it is 0.
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



-- ====== CREATE CONSTRAINTS ======


{-| Returns the constraint from `version`, inclusive, up to the next major
version, exclusive, so `1.2.3` gives `1.2.3 <= v < 2.0.0`.
-}
untilNextMajor : V.Version -> Constraint
untilNextMajor version =
    range version LessOrEqual Less (V.bumpMajor version)


{-| Returns the constraint from `version`, inclusive, up to the next minor
version, exclusive, so `1.2.3` gives `1.2.3 <= v < 1.3.0`.
-}
untilNextMinor : V.Version -> Constraint
untilNextMinor version =
    range version LessOrEqual Less (V.bumpMinor version)



-- ====== JSON ======


{-| Returns the constraint as a JSON string holding its written form.

Not every result decodes again with `decoder`: the form of a constraint whose
lower version is not strictly before its upper version, such as one made by
`exactly`, is refused with `InvalidRange`.

-}
encode : Constraint -> Value
encode constraint =
    E.string (toChars constraint)


{-| A decoder for a constraint held in a JSON string in its written form.

The whole string must be one constraint, with exactly one space between its
parts; either operator may be `<` or `<=`. Once both versions have been read, a
lower version that is not strictly before the upper one fails with
`InvalidRange`, whatever the operators and whether or not text follows. Any
other string that does not have this form fails with `BadFormat`. The string is
read as `Compiler.Json.Decode.customString` describes.

-}
decoder : Decoder Error Constraint
decoder =
    D.customString parser BadFormat



-- ====== PARSER ======


{-| Why a string could not be read as a constraint.

`BadFormat` means the string does not have the written form of a constraint.
It carries the row and column at which reading failed, or at which reading
stopped when text is left over after an upper version that is later than the
lower one.

`InvalidRange` means the string read correctly up to the end of the upper
version, but the lower version, the first it carries, is not strictly before
the upper version, the second. It is reported whether or not text follows.

-}
type Error
    = BadFormat Row Col
    | InvalidRange V.Version V.Version


{-| A parser for the written form of a constraint.

It fails with `BadFormat` at the position where the form is broken, and, once
both versions have been read, with `InvalidRange` unless the lower version is
strictly before the upper one. It does not require the input to end after the
upper version.

-}
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


{-| A parser for one version, read by `Compiler.Elm.Version.parser`, whose
failure becomes `BadFormat` at the row and column that parser failed at.
-}
parseVersion : P.Parser Error V.Version
parseVersion =
    P.specialize (\( r, c ) _ _ -> BadFormat r c) V.parser


{-| A parser for an operator: `<=` gives `LessOrEqual`, and `<` not followed
by `=` gives `Less`. Anything that does not start with `<` fails with
`BadFormat`.
-}
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
