module Compiler.Elm.Constraint exposing
    ( Constraint
    , Error(..)
    , anything
    , decoder
    , defaultElm
    , encode
    , exactly
    , goodElm
    , intersect
    , lowerBound
    , satisfies
    , toChars
    , untilNextMajor
    , untilNextMinor
    )

import Compiler.Elm.Version as V
import Compiler.Json.Decode as D exposing (Decoder)
import Compiler.Json.Encode as E exposing (Value)
import Compiler.Parse.Primitives as P exposing (Col, Row)



-- CONSTRAINTS


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


exactly : V.Version -> Constraint
exactly version =
    range version LessOrEqual LessOrEqual version


anything : Constraint
anything =
    range V.one LessOrEqual LessOrEqual V.maxVersion



-- EXTRACT VERSION


lowerBound : Constraint -> V.Version
lowerBound (Range props) =
    props.lower



-- TO CHARS


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


goodElm : Constraint -> Bool
goodElm constraint =
    satisfies constraint V.elmCompiler


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


untilNextMajor : V.Version -> Constraint
untilNextMajor version =
    range version LessOrEqual Less (V.bumpMajor version)


untilNextMinor : V.Version -> Constraint
untilNextMinor version =
    range version LessOrEqual Less (V.bumpMinor version)



-- JSON


encode : Constraint -> Value
encode constraint =
    E.string (toChars constraint)


decoder : Decoder Error Constraint
decoder =
    D.customString parser BadFormat



-- PARSER


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
