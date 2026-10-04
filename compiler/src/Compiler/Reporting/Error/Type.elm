module Compiler.Reporting.Error.Type exposing
    ( Error(..)
    , Expected(..), Context(..), SubContext(..), Category(..), MaybeName(..)
    , PExpected(..), PContext(..), PCategory(..)
    , typeReplace, ptypeReplace
    , toReport
    , errorEncoder, errorDecoder
    )

{-| When a type check fails, the type checker records an `Error`, and this
module is both the vocabulary of those errors and the code that turns one into
the message a user reads.

Every check compares two types. The _actual_ type is the one an expression or
pattern turned out to have, and the _expected_ type is the one its
surroundings require. Two types that cannot be made equal make a poor message
on their own: the user also needs to know why that type was expected, and what
kind of thing produced the other one. So the constraint generator records,
where it can, why a type was expected and what kind of thing produced the
actual type.

An _expectation_ (`Expected` for expressions, `PExpected` for patterns) is an
expected type together with where it came from: nowhere in particular, a
surrounding construct described by a _context_ (`Context`, `PContext`), or a
type annotation (`FromAnnotation`). A _category_ (`Category`, `PCategory`)
says what kind of expression or pattern has the actual type, such as a list
literal, an `if`, or the result of a call.

`Expected` and `PExpected` are parameterised by the type they carry. During
constraint generation that is the solver's type; when a check fails,
`Compiler.Type.Solve` swaps in the printable `Compiler.Type.Error.Type` with
`typeReplace` or `ptypeReplace` and builds the `Error`. Every type inside an
`Error` is therefore a `Compiler.Type.Error.Type`.

Most of the file is `toReport` and its helpers, which choose for each error a
title, the source snippet and the part of it to highlight, the wording, and
hints. The arithmetic, boolean, comparison, equality, append, cons and pipe
operators have their own explanations. The two types are printed and
compared by `Compiler.Type.Error.toComparison`, and the first of the problems
it detects becomes a hint; the rest are not shown. Positions such as a list
entry, a branch or an argument are zero-based `Index.ZeroBased` values, printed
as ordinals such as `1st`.

`errorEncoder` and `errorDecoder` give an `Error` a binary form.


# Errors

@docs Error


# Expression Type Errors

@docs Expected, Context, SubContext, Category, MaybeName


# Pattern Type Errors

@docs PExpected, PContext, PCategory


# Type Manipulation

@docs typeReplace, ptypeReplace


# Reporting

@docs toReport


# Serialization

@docs errorEncoder, errorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Reporting.Report as Report
import Compiler.Reporting.Suggest as Suggest
import Compiler.Type.Error as T
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== ERRORS ======


{-| A failed type check, holding what is needed to explain it.

`BadExpr` is an expression whose actual type, the `T.Type`, does not fit its
expectation. The region is the expression's own, and the category says what
kind of expression it is.

`BadPattern` is the same for a pattern.

`InfiniteType` is a variable whose type would have to contain itself. It
carries the variable's name and its type as far as it can be printed, with
`∞` where it repeats. The name can be an argument or a pattern variable, not
only a definition's.

-}
type Error
    = BadExpr A.Region Category T.Type (Expected T.Type)
    | BadPattern A.Region PCategory T.Type (PExpected T.Type)
    | InfiniteType A.Region Name T.Type



-- ====== EXPRESSION EXPECTATIONS ======


{-| An expected type for an expression, together with where the expectation
came from.

`NoExpectation` has no particular source.

`FromContext` comes from a surrounding construct. Its region is that
construct's, such as the whole call or the whole operator application, and
it is the region a report shows.

`FromAnnotation` comes from the type annotation of the named definition. The
`Int` is the number of arguments the definition takes, which no report uses.
The `SubContext` says which part of the definition must match, and the
expected type is the part of the annotation left after one arrow per argument.

-}
type Expected tipe
    = NoExpectation tipe
    | FromContext A.Region Context tipe
    | FromAnnotation Name Int SubContext tipe


{-| The construct that made an expression's type expected, with what is needed
to word a report about it. Every `Index.ZeroBased` here is a zero-based
position.

`ListEntry` is an element of a list literal, expected to match the elements
before it. `Negate` is the operand of a unary minus, expected to be a number.

`OpLeft` and `OpRight` are the left and right operands of the named binary
operator.

`IfCondition` is the condition of an `if`, expected to be a `Bool`. `IfBranch`
and `CaseBranch` are branches expected to match the branches before them.

`CallArity` is the function in a call, carrying the number of arguments it was
given; it fails when the function's type does not take that many. `CallArg` is
one argument of a call.

`RecordAccess` is the record in a field access. It carries the record
expression's region, a name for the record where one can be given, the field
name's region and the field name.

`RecordUpdateKeys` is the record in a record update, carrying the fields the
update sets. `RecordUpdateValue` is the new value of the named field.

`Destructure` is the value of a definition whose left side is a pattern.

-}
type Context
    = ListEntry Index.ZeroBased
    | Negate
    | OpLeft Name
    | OpRight Name
    | IfCondition
    | IfBranch Index.ZeroBased
    | CaseBranch Index.ZeroBased
    | CallArity MaybeName Int
    | CallArg MaybeName Index.ZeroBased
    | RecordAccess A.Region (Maybe Name) A.Region Name
    | RecordUpdateKeys (Dict Name Can.FieldUpdate)
    | RecordUpdateValue Name
    | Destructure


{-| The part of an annotated definition that is expected to match the type
the annotation gives it.

`TypedIfBranch` and `TypedCaseBranch` are one branch, by zero-based position,
of an `if` or `case` that the definition's body results in, possibly through
`let` bodies or other branches. `TypedBody` is the body as
a whole.

-}
type SubContext
    = TypedIfBranch Index.ZeroBased
    | TypedCaseBranch Index.ZeroBased
    | TypedBody


{-| The name of the thing being called, if it has one, and what kind of thing
it is. A report uses it to name what was called, such as "the `f` function" or
"the (+) operator"; with `NoName` it falls back to a generic phrase.
-}
type MaybeName
    = FuncName Name
    | CtorName Name
    | OpName Name
    | NoName


{-| The kind of expression that has the actual type, which decides how a report
introduces that type, as in "This `if` expression produces:" or "It is a list
of type:".

`Number` is an integer literal or a negation, whose type may be any number;
`Float` is a float literal. `CallResult` is the result of a call, naming what
was called. `Accessor` is a field access function such as `.name`, and `Access`
the value of a field access such as `r.name`. `Local` is a variable defined in
this module, local or top-level, annotated or not; `Foreign` is a name that
carries its own type, such as an imported value, a constructor or an operator.
`Effects` is used when checking an effect manager, which only core libraries
define.

-}
type Category
    = List
    | Number
    | Float
    | String
    | Char
    | If
    | Case
    | CallResult MaybeName
    | Lambda
    | Accessor Name
    | Access Name
    | Record
    | Tuple
    | Unit
    | Shader
    | Effects
    | Local Name
    | Foreign Name



-- ====== PATTERN EXPECTATIONS ======


{-| An expected type for a pattern, together with where the expectation came
from.

`PNoExpectation` has no particular source. `PFromContext` comes from the
construct the pattern is in, whose region is the one a report shows.

-}
type PExpected tipe
    = PNoExpectation tipe
    | PFromContext A.Region PContext tipe


{-| The construct that made a pattern's type expected. Every `Index.ZeroBased`
here is a zero-based position.

`PTypedArg` is an argument pattern of the named annotated definition.
`PCaseMatch` is a `case` branch's pattern, expected to match the value being
examined, or the earlier patterns after the first. `PCtorArg` is an argument
pattern of the named constructor. `PListEntry` is an entry of a list pattern.
`PTail` is the pattern after `::`.

-}
type PContext
    = PTypedArg Name Index.ZeroBased
    | PCaseMatch Index.ZeroBased
    | PCtorArg Name Index.ZeroBased
    | PListEntry Index.ZeroBased
    | PTail


{-| The kind of pattern that has the actual type, which decides how a report
introduces that type. `PCtor` names the constructor.
-}
type PCategory
    = PRecord
    | PUnit
    | PTuple
    | PList
    | PCtor Name
    | PInt
    | PStr
    | PChr
    | PBool



-- ====== HELPERS ======


{-| Returns `expectation` with its type replaced by `tipe`, keeping where the
expectation came from.
-}
typeReplace : Expected a -> b -> Expected b
typeReplace expectation tipe =
    case expectation of
        NoExpectation _ ->
            NoExpectation tipe

        FromContext region context _ ->
            FromContext region context tipe

        FromAnnotation name arity context _ ->
            FromAnnotation name arity context tipe


{-| Returns `expectation` with its type replaced by `tipe`, keeping where the
expectation came from.
-}
ptypeReplace : PExpected a -> b -> PExpected b
ptypeReplace expectation tipe =
    case expectation of
        PNoExpectation _ ->
            PNoExpectation tipe

        PFromContext region context _ ->
            PFromContext region context tipe



-- ====== TO REPORT ======


{-| Builds the report for a type error, showing the code it concerns in
`source`, with type names written as `localizer` says.

An `InfiniteType` is titled INFINITE TYPE, a failed `CallArity` check TOO
MANY ARGS, and every other error TYPE MISMATCH. A mismatch report explains
the context the expected type came from and usually shows the two types with
their differences highlighted, with a hint for the first problem
`Compiler.Type.Error.toComparison` detects. The report's suggestion list is
always empty.

-}
toReport : Code.Source -> L.Localizer -> Error -> Report.Report
toReport source localizer err =
    case err of
        BadExpr region category actualType expected ->
            toExprReport source localizer region category actualType expected

        BadPattern region category tipe expected ->
            toPatternReport source localizer region category tipe expected

        InfiniteType region name overallType ->
            toInfiniteReport source localizer region name overallType



-- ====== TO PATTERN REPORT ======


{-| Builds the TYPE MISMATCH report for a pattern at `patternRegion` whose
type `tipe` does not fit `expected`.
-}
toPatternReport : Code.Source -> L.Localizer -> A.Region -> PCategory -> T.Type -> PExpected T.Type -> Report.Report
toPatternReport source localizer patternRegion category tipe expected =
    Report.report "TYPE MISMATCH" patternRegion [] <|
        case expected of
            PNoExpectation expectedType ->
                Code.toSnippet source patternRegion Nothing <|
                    ( D.fromChars "This pattern is being used in an unexpected way:"
                    , patternTypeComparison localizer
                        tipe
                        expectedType
                        (addPatternCategory "It is" category)
                        "But it needs to match:"
                        []
                    )

            PFromContext region context expectedType ->
                Code.toSnippet source region (Just patternRegion) <|
                    case context of
                        PTypedArg name index ->
                            ( D.reflow <|
                                "The "
                                    ++ D.ordinal index
                                    ++ " argument to `"
                                    ++ name
                                    ++ "` is weird."
                            , patternTypeComparison localizer
                                tipe
                                expectedType
                                (addPatternCategory "The argument is a pattern that matches" category)
                                ("But the type annotation on `"
                                    ++ name
                                    ++ "` says the "
                                    ++ D.ordinal index
                                    ++ " argument should be:"
                                )
                                []
                            )

                        PCaseMatch index ->
                            if index == Index.first then
                                ( "The 1st pattern in this `case` causing a mismatch:" |> D.reflow
                                , patternTypeComparison localizer
                                    tipe
                                    expectedType
                                    (addPatternCategory "The first pattern is trying to match" category)
                                    "But the expression between `case` and `of` is:"
                                    [ "These can never match! Is the pattern the problem? Or is it the expression?" |> D.reflow
                                    ]
                                )

                            else
                                ( D.reflow <|
                                    "The "
                                        ++ D.ordinal index
                                        ++ " pattern in this `case` does not match the previous ones."
                                , patternTypeComparison localizer
                                    tipe
                                    expectedType
                                    (addPatternCategory ("The " ++ D.ordinal index ++ " pattern is trying to match") category)
                                    "But all the previous patterns match:"
                                    [ D.link "Note"
                                        "A `case` expression can only handle one type of value, so you may want to use"
                                        "custom-types"
                                        "to handle “mixing” types."
                                    ]
                                )

                        PCtorArg name index ->
                            ( D.reflow <|
                                "The "
                                    ++ D.ordinal index
                                    ++ " argument to `"
                                    ++ name
                                    ++ "` is weird."
                            , patternTypeComparison localizer
                                tipe
                                expectedType
                                (addPatternCategory "It is trying to match" category)
                                ("But `"
                                    ++ name
                                    ++ "` needs its "
                                    ++ D.ordinal index
                                    ++ " argument to be:"
                                )
                                []
                            )

                        PListEntry index ->
                            ( D.reflow <|
                                "The "
                                    ++ D.ordinal index
                                    ++ " pattern in this list does not match all the previous ones:"
                            , patternTypeComparison localizer
                                tipe
                                expectedType
                                (addPatternCategory ("The " ++ D.ordinal index ++ " pattern is trying to match") category)
                                "But all the previous patterns in the list are:"
                                [ D.link "Hint"
                                    "Everything in a list must be the same type of value. This way, we never run into unexpected values partway through a List.map, List.foldl, etc. Read"
                                    "custom-types"
                                    "to learn how to “mix” types."
                                ]
                            )

                        PTail ->
                            ( "The pattern after (::) is causing issues." |> D.reflow
                            , patternTypeComparison localizer
                                tipe
                                expectedType
                                (addPatternCategory "The pattern after (::) is trying to match" category)
                                "But it needs to match lists like this:"
                                []
                            )



-- ====== PATTERN HELPERS ======


{-| Builds the body of a pattern mismatch: the line `iAmSeeing` over the actual
type, the line `insteadOf` over the expected type, then the hint for the first
detected problem, then `contextHints`.
-}
patternTypeComparison : L.Localizer -> T.Type -> T.Type -> String -> String -> List D.Doc -> D.Doc
patternTypeComparison localizer actual expected iAmSeeing insteadOf contextHints =
    let
        ( actualDoc, expectedDoc, problems ) =
            T.toComparison localizer actual expected
    in
    D.stack <|
        [ D.reflow iAmSeeing
        , D.indent 4 actualDoc
        , D.reflow insteadOf
        , D.indent 4 expectedDoc
        ]
            ++ problemsToHint problems
            ++ contextHints


{-| Returns `iAmTryingToMatch` completed with a phrase for the kind of pattern,
such as " lists of type:".
-}
addPatternCategory : String -> PCategory -> String
addPatternCategory iAmTryingToMatch category =
    iAmTryingToMatch
        ++ (case category of
                PRecord ->
                    " record values of type:"

                PUnit ->
                    " unit values:"

                PTuple ->
                    " tuples of type:"

                PList ->
                    " lists of type:"

                PCtor name ->
                    " `" ++ name ++ "` values of type:"

                PInt ->
                    " integers:"

                PStr ->
                    " strings:"

                PChr ->
                    " characters:"

                PBool ->
                    " booleans:"
           )



-- ====== EXPR HELPERS ======


{-| Builds the body of an expression mismatch: the line `iAmSeeing` over the
actual type, the line `insteadOf` over the expected type, then `contextHints`,
then the hint for the first detected problem. This is the reverse of the hint
order in `patternTypeComparison`.
-}
typeComparison : L.Localizer -> T.Type -> T.Type -> String -> String -> List D.Doc -> D.Doc
typeComparison localizer actual expected iAmSeeing insteadOf contextHints =
    let
        ( actualDoc, expectedDoc, problems ) =
            T.toComparison localizer actual expected
    in
    D.stack <|
        [ D.reflow iAmSeeing
        , D.indent 4 actualDoc
        , D.reflow insteadOf
        , D.indent 4 expectedDoc
        ]
            ++ contextHints
            ++ problemsToHint problems


{-| Builds a mismatch body that prints only the actual type: `iAmSeeing` over
it, then `furtherDetails`, then the hint for the first problem detected
against `expected`.
-}
loneType : L.Localizer -> T.Type -> T.Type -> D.Doc -> List D.Doc -> D.Doc
loneType localizer actual expected iAmSeeing furtherDetails =
    let
        ( actualDoc, _, problems ) =
            T.toComparison localizer actual expected
    in
    D.stack <|
        [ iAmSeeing
        , D.indent 4 actualDoc
        ]
            ++ furtherDetails
            ++ problemsToHint problems


{-| Returns the line that introduces an expression's actual type. For a
variable, a field access, a field access function, an `if`, a `case` or a call
of a named function or constructor, the line describes that and `thisIs` is
ignored; otherwise `thisIs` is completed with a phrase such as " a list of
type:".
-}
addCategory : String -> Category -> String
addCategory thisIs category =
    case category of
        Local name ->
            "This `" ++ name ++ "` value is a:"

        Foreign name ->
            "This `" ++ name ++ "` value is a:"

        Access field ->
            "The value at ." ++ field ++ " is a:"

        Accessor field ->
            "This ." ++ field ++ " field access function has type:"

        If ->
            "This `if` expression produces:"

        Case ->
            "This `case` expression produces:"

        List ->
            thisIs ++ " a list of type:"

        Number ->
            thisIs ++ " a number of type:"

        Float ->
            thisIs ++ " a float of type:"

        String ->
            thisIs ++ " a string of type:"

        Char ->
            thisIs ++ " a character of type:"

        Lambda ->
            thisIs ++ " an anonymous function of type:"

        Record ->
            thisIs ++ " a record of type:"

        Tuple ->
            thisIs ++ " a tuple of type:"

        Unit ->
            thisIs ++ " a unit value:"

        Shader ->
            thisIs ++ " a GLSL shader of type:"

        Effects ->
            thisIs ++ " a thing for CORE LIBRARIES ONLY."

        CallResult maybeName ->
            case maybeName of
                NoName ->
                    thisIs ++ ":"

                FuncName name ->
                    "This `" ++ name ++ "` call produces:"

                CtorName name ->
                    "This `" ++ name ++ "` call produces:"

                OpName _ ->
                    thisIs ++ ":"


{-| Returns the hint for the first of `problems`, or none for an empty list.
The other problems are ignored.
-}
problemsToHint : List T.Problem -> List D.Doc
problemsToHint problems =
    case problems of
        [] ->
            []

        problem :: _ ->
            problemToHint problem


{-| Returns the hint paragraphs for one detected problem, which may be none.

A problem about a type variable gives no hint when the other type is an
unconstrained flexible variable, an infinite type or an earlier error.

-}
problemToHint : T.Problem -> List D.Doc
problemToHint problem =
    case problem of
        T.IntFloat ->
            [ D.fancyLink "Note"
                [ D.fromChars "Read" ]
                "implicit-casts"
                [ D.fromChars "to"
                , D.fromChars "learn"
                , D.fromChars "why"
                , D.fromChars "Elm"
                , D.fromChars "does"
                , D.fromChars "not"
                , D.fromChars "implicitly"
                , D.fromChars "convert"
                , D.fromChars "Ints"
                , D.fromChars "to"
                , D.fromChars "Floats."
                , D.fromChars "Use"
                , D.green (D.fromChars "toFloat")
                , D.fromChars "and"
                , D.green (D.fromChars "round")
                , D.fromChars "to"
                , D.fromChars "do"
                , D.fromChars "explicit"
                , D.fromChars "conversions."
                ]
            ]

        T.StringFromInt ->
            [ D.toFancyHint
                [ D.fromChars "Want"
                , D.fromChars "to"
                , D.fromChars "convert"
                , D.fromChars "an"
                , D.fromChars "Int"
                , D.fromChars "into"
                , D.fromChars "a"
                , D.fromChars "String?"
                , D.fromChars "Use"
                , D.fromChars "the"
                , D.green (D.fromChars "String.fromInt")
                , D.fromChars "function!"
                ]
            ]

        T.StringFromFloat ->
            [ D.toFancyHint
                [ D.fromChars "Want"
                , D.fromChars "to"
                , D.fromChars "convert"
                , D.fromChars "a"
                , D.fromChars "Float"
                , D.fromChars "into"
                , D.fromChars "a"
                , D.fromChars "String?"
                , D.fromChars "Use"
                , D.fromChars "the"
                , D.green (D.fromChars "String.fromFloat")
                , D.fromChars "function!"
                ]
            ]

        T.StringToInt ->
            [ D.toFancyHint
                [ D.fromChars "Want"
                , D.fromChars "to"
                , D.fromChars "convert"
                , D.fromChars "a"
                , D.fromChars "String"
                , D.fromChars "into"
                , D.fromChars "an"
                , D.fromChars "Int?"
                , D.fromChars "Use"
                , D.fromChars "the"
                , D.green (D.fromChars "String.toInt")
                , D.fromChars "function!"
                ]
            ]

        T.StringToFloat ->
            [ D.toFancyHint
                [ D.fromChars "Want"
                , D.fromChars "to"
                , D.fromChars "convert"
                , D.fromChars "a"
                , D.fromChars "String"
                , D.fromChars "into"
                , D.fromChars "a"
                , D.fromChars "Float?"
                , D.fromChars "Use"
                , D.fromChars "the"
                , D.green (D.fromChars "String.toFloat")
                , D.fromChars "function!"
                ]
            ]

        T.AnythingToBool ->
            [ "Elm does not have “truthiness” such that ints and strings and lists are automatically converted to booleans. Do that conversion explicitly!" |> D.toSimpleHint
            ]

        T.AnythingFromMaybe ->
            [ D.toFancyHint
                [ D.fromChars "Use"
                , D.green (D.fromChars "Maybe.withDefault")
                , D.fromChars "to"
                , D.fromChars "handle"
                , D.fromChars "possible"
                , D.fromChars "errors."
                , D.fromChars "Longer"
                , D.fromChars "term,"
                , D.fromChars "it"
                , D.fromChars "is"
                , D.fromChars "usually"
                , D.fromChars "better"
                , D.fromChars "to"
                , D.fromChars "write"
                , D.fromChars "out"
                , D.fromChars "the"
                , D.fromChars "full"
                , D.fromChars "`case`"
                , D.fromChars "though!"
                ]
            ]

        T.ArityMismatch x y ->
            [ D.toSimpleHint <|
                if x < y then
                    "It looks like it takes too few arguments. I was expecting " ++ String.fromInt (y - x) ++ " more."

                else
                    "It looks like it takes too many arguments. I see " ++ String.fromInt (x - y) ++ " extra."
            ]

        T.BadFlexSuper direction super tipe ->
            case tipe of
                T.Lambda _ _ _ ->
                    badFlexSuper direction super tipe

                T.Infinite ->
                    []

                T.Error ->
                    []

                T.FlexVar _ ->
                    []

                T.FlexSuper s _ ->
                    badFlexFlexSuper super s

                T.RigidVar y ->
                    badRigidVar y (toASuperThing super)

                T.RigidSuper s _ ->
                    badRigidSuper s (toASuperThing super)

                T.Type _ _ _ ->
                    badFlexSuper direction super tipe

                T.Record _ _ ->
                    badFlexSuper direction super tipe

                T.Unit ->
                    badFlexSuper direction super tipe

                T.Tuple _ _ _ ->
                    badFlexSuper direction super tipe

                T.Alias _ _ _ _ ->
                    badFlexSuper direction super tipe

        T.BadRigidVar x tipe ->
            case tipe of
                T.Lambda _ _ _ ->
                    badRigidVar x "a function"

                T.Infinite ->
                    []

                T.Error ->
                    []

                T.FlexVar _ ->
                    []

                T.FlexSuper s _ ->
                    badRigidVar x (toASuperThing s)

                T.RigidVar y ->
                    badDoubleRigid x y

                T.RigidSuper _ y ->
                    badDoubleRigid x y

                T.Type _ n _ ->
                    badRigidVar x ("a `" ++ n ++ "` value")

                T.Record _ _ ->
                    badRigidVar x "a record"

                T.Unit ->
                    badRigidVar x "a unit value"

                T.Tuple _ _ _ ->
                    badRigidVar x "a tuple"

                T.Alias _ n _ _ ->
                    badRigidVar x ("a `" ++ n ++ "` value")

        T.BadRigidSuper super x tipe ->
            case tipe of
                T.Lambda _ _ _ ->
                    badRigidSuper super "a function"

                T.Infinite ->
                    []

                T.Error ->
                    []

                T.FlexVar _ ->
                    []

                T.FlexSuper s _ ->
                    badRigidSuper super (toASuperThing s)

                T.RigidVar y ->
                    badDoubleRigid x y

                T.RigidSuper _ y ->
                    badDoubleRigid x y

                T.Type _ n _ ->
                    badRigidSuper super ("a `" ++ n ++ "` value")

                T.Record _ _ ->
                    badRigidSuper super "a record"

                T.Unit ->
                    badRigidSuper super "a unit value"

                T.Tuple _ _ _ ->
                    badRigidSuper super "a tuple"

                T.Alias _ n _ _ ->
                    badRigidSuper super ("a `" ++ n ++ "` value")

        T.FieldsMissing fields ->
            case List.map (D.fromName >> D.green) fields of
                [] ->
                    []

                [ f1 ] ->
                    [ D.toFancyHint
                        [ D.fromChars "Looks"
                        , D.fromChars "like"
                        , D.fromChars "the"
                        , f1
                        , D.fromChars "field"
                        , D.fromChars "is"
                        , D.fromChars "missing."
                        ]
                    ]

                fieldDocs ->
                    [ D.toFancyHint <|
                        [ D.fromChars "Looks"
                        , D.fromChars "like"
                        , D.fromChars "fields"
                        ]
                            ++ D.commaSep (D.fromChars "and") identity fieldDocs
                            ++ [ D.fromChars "are", D.fromChars "missing." ]
                    ]

        T.FieldTypo typo possibilities ->
            case Suggest.sort typo identity possibilities of
                [] ->
                    []

                nearest :: _ ->
                    [ D.toFancyHint <|
                        [ D.fromChars "Seems"
                        , D.fromChars "like"
                        , D.fromChars "a"
                        , D.fromChars "record"
                        , D.fromChars "field"
                        , D.fromChars "typo."
                        , D.fromChars "Maybe"
                        , D.dullyellow (D.fromName typo)
                        , D.fromChars "should"
                        , D.fromChars "be"
                        , D.green (D.fromName nearest) |> D.a (D.fromChars "?")
                        ]
                    , D.toSimpleHint
                        "Can more type annotations be added? Type annotations always help me give more specific messages, and I think they could help a lot in this case!"
                    ]



-- ====== BAD RIGID HINTS ======


{-| Returns the hint for a type variable `name` from an annotation that the code
uses as `aThing`, a phrase such as "a record".
-}
badRigidVar : Name -> String -> List D.Doc
badRigidVar name aThing =
    [ D.toSimpleHint <|
        "Your type annotation uses type variable `"
            ++ name
            ++ "` which means ANY type of value can flow through, but your code is saying it specifically wants "
            ++ aThing
            ++ ". Maybe change your type annotation to be more specific? Maybe change the code to be more general?"
    , D.reflowLink "Read" "type-annotations" "for more advice!"
    ]


{-| Returns the hint for two type variables from an annotation that the code
uses as one.
-}
badDoubleRigid : Name -> Name -> List D.Doc
badDoubleRigid x y =
    [ D.toSimpleHint <|
        "Your type annotation uses `"
            ++ x
            ++ "` and `"
            ++ y
            ++ "` as separate type variables. Your code seems to be saying they are the same though. Maybe they should be the same in your type annotation? Maybe your code uses them in a weird way?"
    , D.reflowLink "Read" "type-annotations" "for more advice!"
    ]


{-| Returns a phrase for a value of a constrained type, such as "a `number`
value".
-}
toASuperThing : T.Super -> String
toASuperThing super =
    case super of
        T.Number ->
            "a `number` value"

        T.Comparable ->
            "a `comparable` value"

        T.CompAppend ->
            "a `compappend` value"

        T.Appendable ->
            "an `appendable` value"



-- ====== BAD SUPER HINTS ======


{-| Returns the hint for a constrained type variable the solver was free to bind
that meets `tipe`, which does not satisfy the constraint.

For `number` met by `String`, `direction` decides the advice: `Have`, where
the number is the actual type, suggests `String.fromInt`, and `Need` suggests
`String.toInt`.

-}
badFlexSuper : T.Direction -> T.Super -> T.Type -> List D.Doc
badFlexSuper direction super tipe =
    case super of
        T.Comparable ->
            case tipe of
                T.Record _ _ ->
                    [ D.link "Hint"
                        "I do not know how to compare records. I can only compare ints, floats, chars, strings, lists of comparable values, and tuples of comparable values. Check out"
                        "comparing-records"
                        "for ideas on how to proceed."
                    ]

                T.Type _ name _ ->
                    [ D.toSimpleHint <|
                        "I do not know how to compare `"
                            ++ name
                            ++ "` values. I can only compare ints, floats, chars, strings, lists of comparable values, and tuples of comparable values."
                    , D.reflowLink
                        "Check out"
                        "comparing-custom-types"
                        "for ideas on how to proceed."
                    ]

                _ ->
                    [ "I only know how to compare ints, floats, chars, strings, lists of comparable values, and tuples of comparable values." |> D.toSimpleHint
                    ]

        T.Appendable ->
            [ D.toSimpleHint "I only know how to append strings and lists."
            ]

        T.CompAppend ->
            [ D.toSimpleHint "Only strings and lists are both comparable and appendable."
            ]

        T.Number ->
            case tipe of
                T.Type home name _ ->
                    if T.isString home name then
                        case direction of
                            T.Have ->
                                [ D.toFancyHint
                                    [ D.fromChars "Try"
                                    , D.fromChars "using"
                                    , D.green (D.fromChars "String.fromInt")
                                    , D.fromChars "to"
                                    , D.fromChars "convert"
                                    , D.fromChars "it"
                                    , D.fromChars "to"
                                    , D.fromChars "a"
                                    , D.fromChars "string?"
                                    ]
                                ]

                            T.Need ->
                                [ D.toFancyHint
                                    [ D.fromChars "Try"
                                    , D.fromChars "using"
                                    , D.green (D.fromChars "String.toInt")
                                    , D.fromChars "to"
                                    , D.fromChars "convert"
                                    , D.fromChars "it"
                                    , D.fromChars "to"
                                    , D.fromChars "an"
                                    , D.fromChars "integer?"
                                    ]
                                ]

                    else
                        badFlexSuperNumber

                _ ->
                    badFlexSuperNumber


{-| The hint that only `Int` and `Float` values are numbers.
-}
badFlexSuperNumber : List D.Doc
badFlexSuperNumber =
    [ D.toFancyHint
        [ D.fromChars "Only"
        , D.green (D.fromChars "Int")
        , D.fromChars "and"
        , D.green (D.fromChars "Float")
        , D.fromChars "values"
        , D.fromChars "work"
        , D.fromChars "as"
        , D.fromChars "numbers."
        ]
    ]


{-| Returns the hint for a constrained type variable from an annotation that the
code uses as `aThing`, a phrase such as "a record".
-}
badRigidSuper : T.Super -> String -> List D.Doc
badRigidSuper super aThing =
    let
        ( superType, manyThings ) =
            case super of
                T.Number ->
                    ( "number", "ints AND floats" )

                T.Comparable ->
                    ( "comparable", "ints, floats, chars, strings, lists, and tuples" )

                T.Appendable ->
                    ( "appendable", "strings AND lists" )

                T.CompAppend ->
                    ( "compappend", "strings AND lists" )
    in
    [ D.toSimpleHint <|
        "The `"
            ++ superType
            ++ "` in your type annotation is saying that "
            ++ manyThings
            ++ " can flow through, but your code is saying it specifically wants "
            ++ aThing
            ++ ". Maybe change your type annotation to be more specific? Maybe change the code to be more general?"
    , D.reflowLink "Read" "type-annotations" "for more advice!"
    ]


{-| Returns the hint that no value satisfies both constraints.
-}
badFlexFlexSuper : T.Super -> T.Super -> List D.Doc
badFlexFlexSuper s1 s2 =
    let
        likeThis : T.Super -> String
        likeThis super =
            case super of
                T.Number ->
                    "a number"

                T.Comparable ->
                    "comparable"

                T.CompAppend ->
                    "a compappend"

                T.Appendable ->
                    "appendable"
    in
    [ D.toSimpleHint <|
        "There are no values in Elm that are both "
            ++ likeThis s1
            ++ " and "
            ++ likeThis s2
            ++ "."
    ]



-- ====== TO EXPR REPORT ======


{-| Builds the report for an expression at `exprRegion` whose type `tipe` does
not fit `expected`.

Without a context, the snippet is the expression itself. With one, the snippet
is the region the context carries. Inside it the expression is usually
highlighted; a record access or update highlights the field or record
concerned, and a destructuring definition, two operands that disagree, or a
record update with no missing field highlight the whole region. The report's
own region is always `exprRegion`.

For a function given too many arguments, the message says how many it takes,
counting the arguments in the function's type, or says it is not a function
when that type is not a function type at its top level.

-}
toExprReport : Code.Source -> L.Localizer -> A.Region -> Category -> T.Type -> Expected T.Type -> Report.Report
toExprReport source localizer exprRegion category tipe expected =
    case expected of
        NoExpectation expectedType ->
            Report.report "TYPE MISMATCH" exprRegion [] <|
                Code.toSnippet source
                    exprRegion
                    Nothing
                    ( D.fromChars "This expression is being used in an unexpected way:"
                    , typeComparison localizer
                        tipe
                        expectedType
                        (addCategory "It is" category)
                        "But you are trying to use it as:"
                        []
                    )

        FromAnnotation name _ subContext expectedType ->
            let
                thing : String
                thing =
                    case subContext of
                        TypedIfBranch index ->
                            D.ordinal index ++ " branch of this `if` expression:"

                        TypedCaseBranch index ->
                            D.ordinal index ++ " branch of this `case` expression:"

                        TypedBody ->
                            "body of the `" ++ name ++ "` definition:"

                itIs : String
                itIs =
                    case subContext of
                        TypedIfBranch index ->
                            "The " ++ D.ordinal index ++ " branch is"

                        TypedCaseBranch index ->
                            "The " ++ D.ordinal index ++ " branch is"

                        TypedBody ->
                            "The body is"
            in
            ( D.reflow ("Something is off with the " ++ thing)
            , typeComparison localizer
                tipe
                expectedType
                (addCategory itIs category)
                ("But the type annotation on `" ++ name ++ "` says it should be:")
                []
            )
                |> Code.toSnippet source exprRegion Nothing
                |> Report.report "TYPE MISMATCH" exprRegion []

        FromContext region context expectedType ->
            let
                mismatch : ( ( Maybe A.Region, String ), ( String, String, List D.Doc ) ) -> Report.Report
                mismatch ( ( maybeHighlight, problem ), ( thisIs, insteadOf, furtherDetails ) ) =
                    Report.report "TYPE MISMATCH" exprRegion [] <|
                        Code.toSnippet source
                            region
                            maybeHighlight
                            ( D.reflow problem
                            , typeComparison localizer tipe expectedType (addCategory thisIs category) insteadOf furtherDetails
                            )

                badType : ( ( Maybe A.Region, String ), ( String, List D.Doc ) ) -> Report.Report
                badType ( ( maybeHighlight, problem ), ( thisIs, furtherDetails ) ) =
                    Report.report "TYPE MISMATCH" exprRegion [] <|
                        Code.toSnippet source
                            region
                            maybeHighlight
                            ( D.reflow problem
                            , loneType localizer tipe expectedType (D.reflow (addCategory thisIs category)) furtherDetails
                            )

                custom : Maybe A.Region -> ( D.Doc, D.Doc ) -> Report.Report
                custom maybeHighlight docPair =
                    Code.toSnippet source region maybeHighlight docPair |> Report.report "TYPE MISMATCH" exprRegion []
            in
            case context of
                ListEntry index ->
                    let
                        ith : String
                        ith =
                            D.ordinal index
                    in
                    mismatch
                        ( ( Just exprRegion
                          , "The " ++ ith ++ " element of this list does not match all the previous elements:"
                          )
                        , ( "The " ++ ith ++ " element is"
                          , "But all the previous elements in the list are:"
                          , [ D.link "Hint"
                                "Everything in a list must be the same type of value. This way, we never run into unexpected values partway through a List.map, List.foldl, etc. Read"
                                "custom-types"
                                "to learn how to “mix” types."
                            ]
                          )
                        )

                Negate ->
                    badType
                        ( ( Just exprRegion
                          , "I do not know how to negate this type of value:"
                          )
                        , ( "It is"
                          , [ D.fillSep
                                [ D.fromChars "But"
                                , D.fromChars "I"
                                , D.fromChars "only"
                                , D.fromChars "now"
                                , D.fromChars "how"
                                , D.fromChars "to"
                                , D.fromChars "negate"
                                , D.dullyellow (D.fromChars "Int")
                                , D.fromChars "and"
                                , D.dullyellow (D.fromChars "Float")
                                , D.fromChars "values."
                                ]
                            ]
                          )
                        )

                OpLeft op ->
                    opLeftToDocs localizer category op tipe expectedType |> custom (Just exprRegion)

                OpRight op ->
                    case opRightToDocs localizer category op tipe expectedType of
                        EmphBoth details ->
                            custom Nothing details

                        EmphRight details ->
                            custom (Just exprRegion) details

                IfCondition ->
                    badType
                        ( ( Just exprRegion
                          , "This `if` condition does not evaluate to a boolean value, True or False."
                          )
                        , ( "It is"
                          , [ D.fillSep
                                [ D.fromChars "But"
                                , D.fromChars "I"
                                , D.fromChars "need"
                                , D.fromChars "this"
                                , D.fromChars "`if`"
                                , D.fromChars "condition"
                                , D.fromChars "to"
                                , D.fromChars "be"
                                , D.fromChars "a"
                                , D.dullyellow (D.fromChars "Bool")
                                , D.fromChars "value."
                                ]
                            ]
                          )
                        )

                IfBranch index ->
                    let
                        ith : String
                        ith =
                            D.ordinal index
                    in
                    mismatch
                        ( ( Just exprRegion
                          , "The " ++ ith ++ " branch of this `if` does not match all the previous branches:"
                          )
                        , ( "The " ++ ith ++ " branch is"
                          , "But all the previous branches result in:"
                          , [ D.link "Hint"
                                "All branches in an `if` must produce the same type of values. This way, no matter which branch we take, the result is always a consistent shape. Read"
                                "custom-types"
                                "to learn how to “mix” types."
                            ]
                          )
                        )

                CaseBranch index ->
                    let
                        ith : String
                        ith =
                            D.ordinal index
                    in
                    mismatch
                        ( ( Just exprRegion
                          , "The " ++ ith ++ " branch of this `case` does not match all the previous branches:"
                          )
                        , ( "The " ++ ith ++ " branch is"
                          , "But all the previous branches result in:"
                          , [ D.link "Hint"
                                "All branches in a `case` must produce the same type of values. This way, no matter which branch we take, the result is always a consistent shape. Read"
                                "custom-types"
                                "to learn how to “mix” types."
                            ]
                          )
                        )

                CallArity maybeFuncName numGivenArgs ->
                    (case countArgs tipe of
                        0 ->
                            let
                                thisValue : String
                                thisValue =
                                    case maybeFuncName of
                                        NoName ->
                                            "This value"

                                        FuncName name ->
                                            "The `" ++ name ++ "` value"

                                        CtorName name ->
                                            "The `" ++ name ++ "` value"

                                        OpName op ->
                                            "The (" ++ op ++ ") operator"
                            in
                            ( (thisValue ++ " is not a function, but it was given " ++ D.args numGivenArgs ++ ".") |> D.reflow
                            , "Are there any missing commas? Or missing parentheses?" |> D.reflow
                            )

                        n ->
                            let
                                thisFunction : String
                                thisFunction =
                                    case maybeFuncName of
                                        NoName ->
                                            "This function"

                                        FuncName name ->
                                            "The `" ++ name ++ "` function"

                                        CtorName name ->
                                            "The `" ++ name ++ "` constructor"

                                        OpName op ->
                                            "The (" ++ op ++ ") operator"
                            in
                            ( (thisFunction ++ " expects " ++ D.args n ++ ", but it got " ++ String.fromInt numGivenArgs ++ " instead.") |> D.reflow
                            , "Are there any missing commas? Or missing parentheses?" |> D.reflow
                            )
                    )
                        |> Code.toSnippet source region (Just exprRegion)
                        |> Report.report "TOO MANY ARGS" exprRegion []

                CallArg maybeFuncName index ->
                    let
                        ith : String
                        ith =
                            D.ordinal index

                        thisFunction : String
                        thisFunction =
                            case maybeFuncName of
                                NoName ->
                                    "this function"

                                FuncName name ->
                                    "`" ++ name ++ "`"

                                CtorName name ->
                                    "`" ++ name ++ "`"

                                OpName op ->
                                    "(" ++ op ++ ")"
                    in
                    mismatch
                        ( ( Just exprRegion
                          , "The " ++ ith ++ " argument to " ++ thisFunction ++ " is not what I expect:"
                          )
                        , ( "This argument is"
                          , "But " ++ thisFunction ++ " needs the " ++ ith ++ " argument to be:"
                          , if Index.toHuman index == 1 then
                                []

                            else
                                [ D.toSimpleHint <|
                                    "I always figure out the argument types from left to right. If an argument is acceptable, "
                                        ++ "I assume it is \"correct\" and move on. So the problem may actually be in one of the previous arguments!"
                                ]
                          )
                        )

                RecordAccess recordRegion maybeName fieldRegion field ->
                    case T.iteratedDealias tipe of
                        T.Record fields ext ->
                            custom (Just fieldRegion)
                                ( D.reflow <|
                                    "This "
                                        ++ Maybe.withDefault "" (Maybe.map (\n -> "`" ++ n ++ "`") maybeName)
                                        ++ " record does not have a `"
                                        ++ field
                                        ++ "` field:"
                                , case Suggest.sort field Tuple.first (Dict.toList fields) of
                                    [] ->
                                        D.reflow "In fact, it is a record with NO fields!"

                                    f :: fs ->
                                        D.stack
                                            [ D.reflow <|
                                                "This is usually a typo. Here are the "
                                                    ++ Maybe.withDefault "" (Maybe.map (\n -> "`" ++ n ++ "`") maybeName)
                                                    ++ " fields that are most similar:"
                                            , toNearbyRecord localizer f fs ext
                                            , D.fillSep
                                                [ D.fromChars "So"
                                                , D.fromChars "maybe"
                                                , D.dullyellow (D.fromName field)
                                                , D.fromChars "should"
                                                , D.fromChars "be"
                                                , D.green (D.fromName (Tuple.first f))
                                                    |> D.a (D.fromChars "?")
                                                ]
                                            ]
                                )

                        _ ->
                            badType
                                ( ( Just recordRegion
                                  , "This is not a record, so it has no fields to access!"
                                  )
                                , ( "It is"
                                  , [ D.fillSep
                                        [ D.fromChars "But"
                                        , D.fromChars "I"
                                        , D.fromChars "need"
                                        , D.fromChars "a"
                                        , D.fromChars "record"
                                        , D.fromChars "with"
                                        , D.fromChars "a"
                                        , D.dullyellow (D.fromName field)
                                        , D.fromChars "field!"
                                        ]
                                    ]
                                  )
                                )

                RecordUpdateKeys expectedFields ->
                    case T.iteratedDealias tipe of
                        T.Record actualFields ext ->
                            case Dict.diff expectedFields actualFields |> Dict.toList |> List.sortBy Tuple.first of
                                [] ->
                                    mismatch
                                        ( ( Nothing
                                          , "Something is off with this record update:"
                                          )
                                        , ( "The record is"
                                          , "But this update needs it to be compatable with:"
                                          , [ D.reflow <|
                                                "Do you mind creating an <http://sscce.org/> that produces this error message and sharing it at "
                                                    ++ "<https://github.com/elm/error-message-catalog/issues> so we can try to give better advice here?"
                                            ]
                                          )
                                        )

                                ( field, Can.FieldUpdate fieldRegion _ ) :: _ ->
                                    let
                                        fStr : String
                                        fStr =
                                            "`" ++ field ++ "`"
                                    in
                                    custom (Just fieldRegion)
                                        ( D.reflow <|
                                            "The record does not have a "
                                                ++ fStr
                                                ++ " field:"
                                        , case Suggest.sort field Tuple.first (Dict.toList actualFields) of
                                            [] ->
                                                "In fact, it is a record with NO fields!" |> D.reflow

                                            f :: fs ->
                                                D.stack
                                                    [ "This is usually a typo. Here are the record fields that are most similar:" |> D.reflow
                                                    , toNearbyRecord localizer f fs ext
                                                    , D.fillSep
                                                        [ D.fromChars "So"
                                                        , D.fromChars "maybe"
                                                        , D.dullyellow (D.fromName field)
                                                        , D.fromChars "should"
                                                        , D.fromChars "be"
                                                        , D.green (D.fromName (Tuple.first f))
                                                            |> D.a (D.fromChars "?")
                                                        ]
                                                    ]
                                        )

                        _ ->
                            badType
                                ( ( Just exprRegion
                                  , "This is not a record, so it has no fields to update!"
                                  )
                                , ( "It is"
                                  , [ "But I need a record!" |> D.reflow
                                    ]
                                  )
                                )

                RecordUpdateValue field ->
                    mismatch
                        ( ( Just exprRegion
                          , "I cannot update the `" ++ field ++ "` field like this:"
                          )
                        , ( "You are trying to update `" ++ field ++ "` to be"
                          , "But it should be:"
                          , [ D.toSimpleNote
                                "The record update syntax does not allow you to change the type of fields. You can achieve that with record constructors or the record literal syntax."
                            ]
                          )
                        )

                Destructure ->
                    mismatch
                        ( ( Nothing
                          , "This definition is causing issues:"
                          )
                        , ( "You are defining"
                          , "But then trying to destructure it as:"
                          , []
                          )
                        )



-- ====== HELPERS ======


{-| Returns the number of arguments of a function type, or 0 for any type that
is not a function type at its top level, including an alias of one.
-}
countArgs : T.Type -> Int
countArgs tipe =
    case tipe of
        T.Lambda _ _ stuff ->
            1 + List.length stuff

        _ ->
            0



-- ====== FIELD NAME HELPERS ======


{-| Builds an indented record type showing `f`, the field closest to a
misspelt name, and the fields `fs` after it in order of closeness. Up to three
of `fs` are shown; with more, the record is shown as an excerpt and without
its extension variable.
-}
toNearbyRecord : L.Localizer -> ( Name, T.Type ) -> List ( Name, T.Type ) -> T.Extension -> D.Doc
toNearbyRecord localizer f fs ext =
    D.indent 4 <|
        if List.length fs <= 3 then
            RT.vrecord (List.map (fieldToDocs localizer) (f :: fs)) (extToDoc ext)

        else
            RT.vrecordSnippet (fieldToDocs localizer f) (List.map (fieldToDocs localizer) (List.take 3 fs))


{-| Returns a field's name and printed type.
-}
fieldToDocs : L.Localizer -> ( Name, T.Type ) -> ( D.Doc, D.Doc )
fieldToDocs localizer ( name, tipe ) =
    ( D.fromName name
    , T.toDoc localizer RT.None tipe
    )


{-| Returns the name of the variable that extends a record, or `Nothing` for a
closed record.
-}
extToDoc : T.Extension -> Maybe D.Doc
extToDoc ext =
    case ext of
        T.Closed ->
            Nothing

        T.FlexOpen x ->
            Just (D.fromName x)

        T.RigidOpen x ->
            Just (D.fromName x)



-- ====== OP LEFT ======


{-| Builds the message and body for a left operand of `op` whose type `tipe`
does not fit `expected`.

Arithmetic, division, boolean, comparison, `++` and `<|` operators have their
own explanations; `+` also recognises a `String` or a `List` operand, and `*`
a `List`. Any other operator gets a plain comparison of the two types.

-}
opLeftToDocs : L.Localizer -> Category -> Name -> T.Type -> T.Type -> ( D.Doc, D.Doc )
opLeftToDocs localizer category op tipe expected =
    case op of
        "+" ->
            if isString tipe then
                badStringAdd

            else if isList tipe then
                badListAdd localizer category "left" tipe expected

            else
                badMath localizer category "Addition" "left" "+" tipe expected []

        "*" ->
            if isList tipe then
                badListMul localizer category "left" tipe expected

            else
                badMath localizer category "Multiplication" "left" "*" tipe expected []

        "-" ->
            badMath localizer category "Subtraction" "left" "-" tipe expected []

        "^" ->
            badMath localizer category "Exponentiation" "left" "^" tipe expected []

        "/" ->
            badFDiv localizer (D.fromChars "left") tipe expected

        "//" ->
            badIDiv localizer (D.fromChars "left") tipe expected

        "&&" ->
            badBool localizer (D.fromChars "&&") (D.fromChars "left") tipe expected

        "||" ->
            badBool localizer (D.fromChars "||") (D.fromChars "left") tipe expected

        "<" ->
            badCompLeft localizer category "<" "left" tipe expected

        ">" ->
            badCompLeft localizer category ">" "left" tipe expected

        "<=" ->
            badCompLeft localizer category "<=" "left" tipe expected

        ">=" ->
            badCompLeft localizer category ">=" "left" tipe expected

        "++" ->
            badAppendLeft localizer category tipe expected

        "<|" ->
            ( D.fromChars "The left side of (<|) needs to be a function so I can pipe arguments to it!"
            , loneType localizer
                tipe
                expected
                (D.reflow (addCategory "I am seeing" category))
                [ D.reflow "This needs to be some kind of function though!" ]
            )

        _ ->
            ( D.reflow ("The left argument of (" ++ op ++ ") is causing problems:")
            , typeComparison localizer
                tipe
                expected
                (addCategory "The left argument is" category)
                ("But (" ++ op ++ ") needs the left argument to be:")
                []
            )



-- ====== OP RIGHT ======


{-| The message and body for a right operand, with which part of the code the
report highlights.

`EmphBoth` marks the whole operator application rather than one operand,
because the two operands disagree and either may be wrong. `EmphRight`
highlights the right operand.

-}
type RightDocs
    = EmphBoth ( D.Doc, D.Doc )
    | EmphRight ( D.Doc, D.Doc )


{-| Builds the message and body for a right operand of `op` whose type `tipe`
does not fit `expected`.

For `+`, `*`, `-` and `^`, an `Int` where a `Float` is expected, or the
reverse, gets advice on converting. Comparison and equality treat a mismatch as
one between the two sides; so does `::` when both sides are lists, and `++`
except for a number appended to a `String` or a `List`. For `|>` the right
side's first parameter type is compared with the type of the value being
piped. Any operator without its own explanation gets `badOpRightFallback`.

-}
opRightToDocs : L.Localizer -> Category -> Name -> T.Type -> T.Type -> RightDocs
opRightToDocs localizer category op tipe expected =
    case op of
        "+" ->
            if isFloat expected && isInt tipe then
                badCast op FloatInt

            else if isInt expected && isFloat tipe then
                badCast op IntFloat

            else if isString tipe then
                EmphRight badStringAdd

            else if isList tipe then
                EmphRight (badListAdd localizer category "right" tipe expected)

            else
                EmphRight (badMath localizer category "Addition" "right" "+" tipe expected [])

        "*" ->
            if isFloat expected && isInt tipe then
                badCast op FloatInt

            else if isInt expected && isFloat tipe then
                badCast op IntFloat

            else if isList tipe then
                EmphRight (badListMul localizer category "right" tipe expected)

            else
                EmphRight (badMath localizer category "Multiplication" "right" "*" tipe expected [])

        "-" ->
            if isFloat expected && isInt tipe then
                badCast op FloatInt

            else if isInt expected && isFloat tipe then
                badCast op IntFloat

            else
                EmphRight (badMath localizer category "Subtraction" "right" "-" tipe expected [])

        "^" ->
            if isFloat expected && isInt tipe then
                badCast op FloatInt

            else if isInt expected && isFloat tipe then
                badCast op IntFloat

            else
                EmphRight (badMath localizer category "Exponentiation" "right" "^" tipe expected [])

        "/" ->
            EmphRight (badFDiv localizer (D.fromChars "right") tipe expected)

        "//" ->
            EmphRight (badIDiv localizer (D.fromChars "right") tipe expected)

        "&&" ->
            EmphRight (badBool localizer (D.fromChars "&&") (D.fromChars "right") tipe expected)

        "||" ->
            EmphRight (badBool localizer (D.fromChars "||") (D.fromChars "right") tipe expected)

        "<" ->
            badCompRight localizer "<" tipe expected

        ">" ->
            badCompRight localizer ">" tipe expected

        "<=" ->
            badCompRight localizer "<=" tipe expected

        ">=" ->
            badCompRight localizer ">=" tipe expected

        "==" ->
            badEquality localizer "==" tipe expected

        "/=" ->
            badEquality localizer "/=" tipe expected

        "::" ->
            badConsRight localizer category tipe expected

        "++" ->
            badAppendRight localizer category tipe expected

        "<|" ->
            EmphRight
                ( D.reflow "I cannot send this through the (<|) pipe:"
                , typeComparison localizer
                    tipe
                    expected
                    "The argument is:"
                    "But (<|) is piping it to a function that expects:"
                    []
                )

        "|>" ->
            case ( tipe, expected ) of
                ( T.Lambda expectedArgType _ _, T.Lambda argType _ _ ) ->
                    EmphRight
                        ( D.reflow "This function cannot handle the argument sent through the (|>) pipe:"
                        , typeComparison localizer
                            argType
                            expectedArgType
                            "The argument is:"
                            "But (|>) is piping it to a function that expects:"
                            []
                        )

                _ ->
                    EmphRight
                        ( D.reflow "The right side of (|>) needs to be a function so I can pipe arguments to it!"
                        , loneType localizer
                            tipe
                            expected
                            (D.reflow (addCategory "But instead of a function, I am seeing" category))
                            []
                        )

        _ ->
            badOpRightFallback localizer category op tipe expected


{-| Builds a plain comparison for a right operand of `op`, with a hint that the
left side was checked first and so the problem may lie in how the two sides
interact.
-}
badOpRightFallback : L.Localizer -> Category -> Name -> T.Type -> T.Type -> RightDocs
badOpRightFallback localizer category op tipe expected =
    EmphRight
        ( D.reflow ("The right argument of (" ++ op ++ ") is causing problems.")
        , typeComparison localizer
            tipe
            expected
            (addCategory "The right argument is" category)
            ("But (" ++ op ++ ") needs the right argument to be:")
            [ D.toSimpleHint <|
                "With operators like ("
                    ++ op
                    ++ ") I always check the left side first. If it seems fine, I assume it is correct and check the right side. So the problem may be in how the left and right arguments interact!"
            ]
        )


{-| Returns whether `tipe` is written as `Int`. An alias of `Int` is not.
-}
isInt : T.Type -> Bool
isInt tipe =
    case tipe of
        T.Type home name [] ->
            T.isInt home name

        _ ->
            False


{-| Returns whether `tipe` is written as `Float`. An alias of `Float` is not.
-}
isFloat : T.Type -> Bool
isFloat tipe =
    case tipe of
        T.Type home name [] ->
            T.isFloat home name

        _ ->
            False


{-| Returns whether `tipe` is written as `String`. An alias of `String` is not.
-}
isString : T.Type -> Bool
isString tipe =
    case tipe of
        T.Type home name [] ->
            T.isString home name

        _ ->
            False


{-| Returns whether `tipe` is written as a `List` of something. An alias of a
list is not.
-}
isList : T.Type -> Bool
isList tipe =
    case tipe of
        T.Type home name [ _ ] ->
            T.isList home name

        _ ->
            False



-- ====== BAD CONS ======


{-| Builds the explanation for a right operand of `::` whose type `tipe` does
not fit `expected`.

When both are lists, the element types are compared, the left operand being
the expected element and the list's elements the actual one, with a hint about
`++` when the elements are themselves lists. A right side that is not a list
gets an explanation that `::` needs one.

-}
badConsRight : L.Localizer -> Category -> T.Type -> T.Type -> RightDocs
badConsRight localizer category tipe expected =
    case tipe of
        T.Type home1 name1 [ actualElement ] ->
            if T.isList home1 name1 then
                case expected of
                    T.Type home2 name2 [ expectedElement ] ->
                        if T.isList home2 name2 then
                            EmphBoth
                                ( D.reflow "I am having trouble with this (::) operator:"
                                , typeComparison localizer
                                    expectedElement
                                    actualElement
                                    "The left side of (::) is:"
                                    "But you are trying to put that into a list filled with:"
                                    (case expectedElement of
                                        T.Type home name [ _ ] ->
                                            if T.isList home name then
                                                [ D.toSimpleHint
                                                    "Are you trying to append two lists? The (++) operator appends lists, whereas the (::) operator is only for adding ONE element to a list."
                                                ]

                                            else
                                                [ D.reflow
                                                    "Lists need ALL elements to be the same type though."
                                                ]

                                        _ ->
                                            [ D.reflow
                                                "Lists need ALL elements to be the same type though."
                                            ]
                                    )
                                )

                        else
                            badOpRightFallback localizer category "::" tipe expected

                    _ ->
                        badOpRightFallback localizer category "::" tipe expected

            else
                EmphRight
                    ( D.reflow "The (::) operator can only add elements onto lists."
                    , loneType localizer
                        tipe
                        expected
                        (D.reflow (addCategory "The right side is" category))
                        [ D.fillSep
                            [ D.fromChars "But"
                            , D.fromChars "(::)"
                            , D.fromChars "needs"
                            , D.fromChars "a"
                            , D.dullyellow (D.fromChars "List")
                            , D.fromChars "on"
                            , D.fromChars "the"
                            , D.fromChars "right."
                            ]
                        ]
                    )

        _ ->
            EmphRight
                ( D.reflow "The (::) operator can only add elements onto lists."
                , loneType localizer
                    tipe
                    expected
                    (D.reflow (addCategory "The right side is" category))
                    [ D.fillSep
                        [ D.fromChars "But"
                        , D.fromChars "(::)"
                        , D.fromChars "needs"
                        , D.fromChars "a"
                        , D.dullyellow (D.fromChars "List")
                        , D.fromChars "on"
                        , D.fromChars "the"
                        , D.fromChars "right."
                        ]
                    ]
                )



-- ====== BAD APPEND ======


{-| What a type is as far as `++` is concerned. `ANumber` carries the number
type's name and the function that turns it into a string.
-}
type AppendType
    = ANumber D.Doc D.Doc
    | AString
    | AList
    | AOther


{-| Returns what `tipe` is as far as `++` is concerned, looking only at its top
level. A `number` variable is a number that `String.fromInt` converts.
-}
toAppendType : T.Type -> AppendType
toAppendType tipe =
    case tipe of
        T.Type home name _ ->
            if T.isInt home name then
                ANumber (D.fromChars "Int") (D.fromChars "String.fromInt")

            else if T.isFloat home name then
                ANumber (D.fromChars "Float") (D.fromChars "String.fromFloat")

            else if T.isString home name then
                AString

            else if T.isList home name then
                AList

            else
                AOther

        T.FlexSuper T.Number _ ->
            ANumber (D.fromChars "number") (D.fromChars "String.fromInt")

        _ ->
            AOther


{-| Builds the explanation for a left operand of `++` whose type `tipe`
cannot be appended, with advice on converting it to a string when it is a
number.
-}
badAppendLeft : L.Localizer -> Category -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badAppendLeft localizer category tipe expected =
    case toAppendType tipe of
        ANumber thing stringFromThing ->
            ( D.fillSep
                [ D.fromChars "The"
                , D.fromChars "(++)"
                , D.fromChars "operator"
                , D.fromChars "can"
                , D.fromChars "append"
                , D.fromChars "List"
                , D.fromChars "and"
                , D.fromChars "String"
                , D.fromChars "values,"
                , D.fromChars "but"
                , D.fromChars "not"
                , D.dullyellow thing
                , D.fromChars "values"
                , D.fromChars "like"
                , D.fromChars "this:"
                ]
            , D.fillSep
                [ D.fromChars "Try"
                , D.fromChars "using"
                , D.green stringFromThing
                , D.fromChars "to"
                , D.fromChars "turn"
                , D.fromChars "it"
                , D.fromChars "into"
                , D.fromChars "a"
                , D.fromChars "string?"
                , D.fromChars "Or"
                , D.fromChars "put"
                , D.fromChars "it"
                , D.fromChars "in"
                , D.fromChars "[]"
                , D.fromChars "to"
                , D.fromChars "make"
                , D.fromChars "it"
                , D.fromChars "a"
                , D.fromChars "list?"
                , D.fromChars "Or"
                , D.fromChars "switch"
                , D.fromChars "to"
                , D.fromChars "the"
                , D.fromChars "(::)"
                , D.fromChars "operator?"
                ]
            )

        _ ->
            ( D.reflow "The (++) operator cannot append this type of value:"
            , loneType localizer
                tipe
                expected
                (D.reflow (addCategory "I am seeing" category))
                [ D.fillSep
                    [ D.fromChars "But"
                    , D.fromChars "the"
                    , D.fromChars "(++)"
                    , D.fromChars "operator"
                    , D.fromChars "is"
                    , D.fromChars "only"
                    , D.fromChars "for"
                    , D.fromChars "appending"
                    , D.dullyellow (D.fromChars "List")
                    , D.fromChars "and"
                    , D.dullyellow (D.fromChars "String")
                    , D.fromChars "values."
                    , D.fromChars "Maybe"
                    , D.fromChars "put"
                    , D.fromChars "this"
                    , D.fromChars "value"
                    , D.fromChars "in"
                    , D.fromChars "[]"
                    , D.fromChars "to"
                    , D.fromChars "make"
                    , D.fromChars "it"
                    , D.fromChars "a"
                    , D.fromChars "list?"
                    ]
                ]
            )


{-| Builds the explanation for a right operand of `++` whose type `tipe` does
not fit `expected`, which the report presents as the left operand's type.

A number appended to a `String` or a `List`, and a `String` and a `List`
appended together, get specific advice; any other pair gets a comparison of
the left side's type against the right's.

-}
badAppendRight : L.Localizer -> Category -> T.Type -> T.Type -> RightDocs
badAppendRight localizer category tipe expected =
    case ( toAppendType expected, toAppendType tipe ) of
        ( AString, ANumber thing stringFromThing ) ->
            EmphRight
                ( D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "thought"
                    , D.fromChars "I"
                    , D.fromChars "was"
                    , D.fromChars "appending"
                    , D.dullyellow (D.fromChars "String")
                    , D.fromChars "values"
                    , D.fromChars "here,"
                    , D.fromChars "not"
                    , D.dullyellow thing
                    , D.fromChars "values"
                    , D.fromChars "like"
                    , D.fromChars "this:"
                    ]
                , D.fillSep
                    [ D.fromChars "Try"
                    , D.fromChars "using"
                    , D.green stringFromThing
                    , D.fromChars "to"
                    , D.fromChars "turn"
                    , D.fromChars "it"
                    , D.fromChars "into"
                    , D.fromChars "a"
                    , D.fromChars "string?"
                    ]
                )

        ( AList, ANumber thing _ ) ->
            EmphRight
                ( D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "thought"
                    , D.fromChars "I"
                    , D.fromChars "was"
                    , D.fromChars "appending"
                    , D.dullyellow (D.fromChars "List")
                    , D.fromChars "values"
                    , D.fromChars "here,"
                    , D.fromChars "not"
                    , D.dullyellow thing
                    , D.fromChars "values"
                    , D.fromChars "like"
                    , D.fromChars "this:"
                    ]
                , D.reflow "Try putting it in [] to make it a list?"
                )

        ( AString, AList ) ->
            EmphBoth
                ( D.reflow "The (++) operator needs the same type of value on both sides:"
                , D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "see"
                    , D.fromChars "a"
                    , D.dullyellow (D.fromChars "String")
                    , D.fromChars "on"
                    , D.fromChars "the"
                    , D.fromChars "left"
                    , D.fromChars "and"
                    , D.fromChars "a"
                    , D.dullyellow (D.fromChars "List")
                    , D.fromChars "on"
                    , D.fromChars "the"
                    , D.fromChars "right."
                    , D.fromChars "Which"
                    , D.fromChars "should"
                    , D.fromChars "it"
                    , D.fromChars "be?"
                    , D.fromChars "Does"
                    , D.fromChars "the"
                    , D.fromChars "string"
                    , D.fromChars "need"
                    , D.fromChars "[]"
                    , D.fromChars "around"
                    , D.fromChars "it"
                    , D.fromChars "to"
                    , D.fromChars "become"
                    , D.fromChars "a"
                    , D.fromChars "list?"
                    ]
                )

        ( AList, AString ) ->
            EmphBoth
                ( D.reflow "The (++) operator needs the same type of value on both sides:"
                , D.fillSep
                    [ D.fromChars "I"
                    , D.fromChars "see"
                    , D.fromChars "a"
                    , D.dullyellow (D.fromChars "List")
                    , D.fromChars "on"
                    , D.fromChars "the"
                    , D.fromChars "left"
                    , D.fromChars "and"
                    , D.fromChars "a"
                    , D.dullyellow (D.fromChars "String")
                    , D.fromChars "on"
                    , D.fromChars "the"
                    , D.fromChars "right."
                    , D.fromChars "Which"
                    , D.fromChars "should"
                    , D.fromChars "it"
                    , D.fromChars "be?"
                    , D.fromChars "Does"
                    , D.fromChars "the"
                    , D.fromChars "string"
                    , D.fromChars "need"
                    , D.fromChars "[]"
                    , D.fromChars "around"
                    , D.fromChars "it"
                    , D.fromChars "to"
                    , D.fromChars "become"
                    , D.fromChars "a"
                    , D.fromChars "list?"
                    ]
                )

        _ ->
            EmphBoth
                ( D.reflow "The (++) operator cannot append these two values:"
                , typeComparison localizer
                    expected
                    tipe
                    "I already figured out that the left side of (++) is:"
                    (addCategory "But this clashes with the right side, which is" category)
                    []
                )



-- ====== BAD MATH ======


{-| The two number types met by an arithmetic operator, left then right:
`FloatInt` is a `Float` on the left and an `Int` on the right.
-}
type ThisThenThat
    = FloatInt
    | IntFloat


{-| Builds the explanation for an arithmetic operator `op` with an `Int` on one
side and a `Float` on the other, advising `toFloat` or `round`.
-}
badCast : Name -> ThisThenThat -> RightDocs
badCast op thisThenThat =
    EmphBoth
        ( D.reflow <|
            "I need both sides of ("
                ++ op
                ++ ") to be the exact same type. Both Int or both Float."
        , let
            anInt : List D.Doc
            anInt =
                [ D.fromChars "an", D.dullyellow (D.fromChars "Int") ]

            aFloat : List D.Doc
            aFloat =
                [ D.fromChars "a", D.dullyellow (D.fromChars "Float") ]

            toFloat : D.Doc
            toFloat =
                D.green (D.fromChars "toFloat")

            round : D.Doc
            round =
                D.green (D.fromChars "round")
          in
          case thisThenThat of
            FloatInt ->
                badCastHelp aFloat anInt round toFloat

            IntFloat ->
                badCastHelp anInt aFloat toFloat round
        )


{-| Builds the body of `badCast`: which types are on the left and the right,
which conversion to use on each side, and a link about implicit casts.

Despite their names, `anInt` and `aFloat` are the left and the right type, and
`toFloat` and `round` the conversions for the left and the right.

-}
badCastHelp : List D.Doc -> List D.Doc -> D.Doc -> D.Doc -> D.Doc
badCastHelp anInt aFloat toFloat round =
    D.stack
        [ D.fillSep <|
            [ D.fromChars "But"
            , D.fromChars "I"
            , D.fromChars "see"
            ]
                ++ anInt
                ++ [ D.fromChars "on"
                   , D.fromChars "the"
                   , D.fromChars "left"
                   , D.fromChars "and"
                   ]
                ++ aFloat
                ++ [ D.fromChars "on"
                   , D.fromChars "the"
                   , D.fromChars "right."
                   ]
        , D.fillSep
            [ D.fromChars "Use"
            , toFloat
            , D.fromChars "on"
            , D.fromChars "the"
            , D.fromChars "left"
            , D.fromChars "(or"
            , round
            , D.fromChars "on"
            , D.fromChars "the"
            , D.fromChars "right)"
            , D.fromChars "to"
            , D.fromChars "make"
            , D.fromChars "both"
            , D.fromChars "sides"
            , D.fromChars "match!"
            ]
        , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
        ]


{-| The message and body for a `String` operand of `+`, advising `++`.
-}
badStringAdd : ( D.Doc, D.Doc )
badStringAdd =
    ( D.fillSep
        [ D.fromChars "I"
        , D.fromChars "cannot"
        , D.fromChars "do"
        , D.fromChars "addition"
        , D.fromChars "with"
        , D.dullyellow (D.fromChars "String")
        , D.fromChars "values"
        , D.fromChars "like"
        , D.fromChars "this"
        , D.fromChars "one:"
        ]
    , D.stack
        [ D.fillSep
            [ D.fromChars "The"
            , D.fromChars "(+)"
            , D.fromChars "operator"
            , D.fromChars "only"
            , D.fromChars "works"
            , D.fromChars "with"
            , D.dullyellow (D.fromChars "Int")
            , D.fromChars "and"
            , D.dullyellow (D.fromChars "Float")
            , D.fromChars "values."
            ]
        , D.toFancyHint
            [ D.fromChars "Switch"
            , D.fromChars "to"
            , D.fromChars "the"
            , D.green (D.fromChars "(++)")
            , D.fromChars "operator"
            , D.fromChars "to"
            , D.fromChars "append"
            , D.fromChars "strings!"
            ]
        ]
    )


{-| Builds the explanation for a list operand of `+`, advising `++`.
`direction` is "left" or "right".
-}
badListAdd : L.Localizer -> Category -> String -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badListAdd localizer category direction tipe expected =
    ( D.fromChars "I cannot do addition with lists:"
    , loneType localizer
        tipe
        expected
        (D.reflow (addCategory ("The " ++ direction ++ " side of (+) is") category))
        [ D.fillSep
            [ D.fromChars "But"
            , D.fromChars "(+)"
            , D.fromChars "only"
            , D.fromChars "works"
            , D.fromChars "with"
            , D.dullyellow (D.fromChars "Int")
            , D.fromChars "and"
            , D.dullyellow (D.fromChars "Float")
            , D.fromChars "values."
            ]
        , D.toFancyHint
            [ D.fromChars "Switch"
            , D.fromChars "to"
            , D.fromChars "the"
            , D.green (D.fromChars "(++)")
            , D.fromChars "operator"
            , D.fromChars "to"
            , D.fromChars "append"
            , D.fromChars "lists!"
            ]
        ]
    )


{-| Builds the explanation for a list operand of `*`, suggesting `List.repeat`.
`direction` is "left" or "right".
-}
badListMul : L.Localizer -> Category -> String -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badListMul localizer category direction tipe expected =
    badMath localizer category "Multiplication" direction "*" tipe expected <|
        [ D.toFancyHint
            [ D.fromChars "Maybe"
            , D.fromChars "you"
            , D.fromChars "want"
            , D.green (D.fromChars "List.repeat")
            , D.fromChars "to"
            , D.fromChars "build"
            , D.fromChars "a"
            , D.fromChars "list"
            , D.fromChars "of"
            , D.fromChars "repeated"
            , D.fromChars "values?"
            ]
        ]


{-| Builds the explanation for an operand of the arithmetic operator `op` that
is not a number. `operation` names the operation, as in "Addition", and
`direction` is "left" or "right"; `otherHints` follow the explanation.
-}
badMath : L.Localizer -> Category -> String -> String -> String -> T.Type -> T.Type -> List D.Doc -> ( D.Doc, D.Doc )
badMath localizer category operation direction op tipe expected otherHints =
    ( D.reflow <|
        operation
            ++ " does not work with this value:"
    , loneType localizer
        tipe
        expected
        (D.reflow (addCategory ("The " ++ direction ++ " side of (" ++ op ++ ") is") category))
        (D.fillSep
            [ D.fromChars "But"
            , D.fromChars ("(" ++ op ++ ")")
            , D.fromChars "only"
            , D.fromChars "works"
            , D.fromChars "with"
            , D.dullyellow (D.fromChars "Int")
            , D.fromChars "and"
            , D.dullyellow (D.fromChars "Float")
            , D.fromChars "values."
            ]
            :: otherHints
        )
    )


{-| Builds the explanation for an operand of `/` that is not a `Float`. An
`Int` operand gets advice on `toFloat` and `//`.
-}
badFDiv : L.Localizer -> D.Doc -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badFDiv localizer direction tipe expected =
    ( D.reflow "The (/) operator is specifically for floating-point division:"
    , if isInt tipe then
        D.stack
            [ D.fillSep
                [ D.fromChars "The"
                , direction
                , D.fromChars "side"
                , D.fromChars "of"
                , D.fromChars "(/)"
                , D.fromChars "must"
                , D.fromChars "be"
                , D.fromChars "a"
                , D.dullyellow (D.fromChars "Float") |> D.a (D.fromChars ",")
                , D.fromChars "but"
                , D.fromChars "I"
                , D.fromChars "am"
                , D.fromChars "seeing"
                , D.fromChars "an"
                , D.dullyellow (D.fromChars "Int") |> D.a (D.fromChars ".")
                , D.fromChars "I"
                , D.fromChars "recommend:"
                ]
            , D.vcat
                [ D.green (D.fromChars "toFloat")
                    |> D.a (D.fromChars " for explicit conversions     ")
                    |> D.a (D.black (D.fromChars "(toFloat 5 / 2) == 2.5"))
                , D.green (D.fromChars "(//)   ")
                    |> D.a (D.fromChars " for integer division         ")
                    |> D.a (D.black (D.fromChars "(5 // 2)        == 2"))
                ]
            , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
            ]

      else
        loneType localizer
            tipe
            expected
            (D.fillSep
                [ D.fromChars "The"
                , direction
                , D.fromChars "side"
                , D.fromChars "of"
                , D.fromChars "(/)"
                , D.fromChars "must"
                , D.fromChars "be"
                , D.fromChars "a"
                , D.dullyellow (D.fromChars "Float") |> D.a (D.fromChars ",")
                , D.fromChars "but"
                , D.fromChars "instead"
                , D.fromChars "I"
                , D.fromChars "am"
                , D.fromChars "seeing:"
                ]
            )
            []
    )


{-| Builds the explanation for an operand of `//` that is not an `Int`. A
`Float` operand gets a list of rounding functions.
-}
badIDiv : L.Localizer -> D.Doc -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badIDiv localizer direction tipe expected =
    ( D.reflow "The (//) operator is specifically for integer division:"
    , if isFloat tipe then
        D.stack
            [ D.fillSep
                [ D.fromChars "The"
                , direction
                , D.fromChars "side"
                , D.fromChars "of"
                , D.fromChars "(//)"
                , D.fromChars "must"
                , D.fromChars "be"
                , D.fromChars "an"
                , D.dullyellow (D.fromChars "Int") |> D.a (D.fromChars ",")
                , D.fromChars "but"
                , D.fromChars "I"
                , D.fromChars "am"
                , D.fromChars "seeing"
                , D.fromChars "a"
                , D.dullyellow (D.fromChars "Float") |> D.a (D.fromChars ".")
                , D.fromChars "I"
                , D.fromChars "recommend"
                , D.fromChars "doing"
                , D.fromChars "the"
                , D.fromChars "conversion"
                , D.fromChars "explicitly"
                , D.fromChars "with"
                , D.fromChars "one"
                , D.fromChars "of"
                , D.fromChars "these"
                , D.fromChars "functions:"
                ]
            , D.vcat
                [ D.green (D.fromChars "round") |> D.a (D.fromChars " 3.5     == 4")
                , D.green (D.fromChars "floor") |> D.a (D.fromChars " 3.5     == 3")
                , D.green (D.fromChars "ceiling") |> D.a (D.fromChars " 3.5   == 4")
                , D.green (D.fromChars "truncate") |> D.a (D.fromChars " 3.5  == 3")
                ]
            , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
            ]

      else
        loneType localizer
            tipe
            expected
            (D.fillSep
                [ D.fromChars "The"
                , direction
                , D.fromChars "side"
                , D.fromChars "of"
                , D.fromChars "(//)"
                , D.fromChars "must"
                , D.fromChars "be"
                , D.fromChars "an"
                , D.dullyellow (D.fromChars "Int") |> D.a (D.fromChars ",")
                , D.fromChars "but"
                , D.fromChars "instead"
                , D.fromChars "I"
                , D.fromChars "am"
                , D.fromChars "seeing:"
                ]
            )
            []
    )



-- ====== BAD BOOLS ======


{-| Builds the explanation for an operand of `&&` or `||` that is not a `Bool`.
-}
badBool : L.Localizer -> D.Doc -> D.Doc -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badBool localizer op direction tipe expected =
    ( D.reflow "I am struggling with this boolean operation:"
    , loneType localizer
        tipe
        expected
        (D.fillSep
            [ D.fromChars "Both"
            , D.fromChars "sides"
            , D.fromChars "of"
            , D.fromChars "(" |> D.a op |> D.a (D.fromChars ")")
            , D.fromChars "must"
            , D.fromChars "be"
            , D.dullyellow (D.fromChars "Bool")
            , D.fromChars "values,"
            , D.fromChars "but"
            , D.fromChars "the"
            , direction
            , D.fromChars "side"
            , D.fromChars "is:"
            ]
        )
        []
    )



-- ====== BAD COMPARISON ======


{-| Builds the explanation for a left operand of a comparison operator that
cannot be compared.
-}
badCompLeft : L.Localizer -> Category -> String -> String -> T.Type -> T.Type -> ( D.Doc, D.Doc )
badCompLeft localizer category op direction tipe expected =
    ( D.reflow "I cannot do a comparison with this value:"
    , loneType localizer
        tipe
        expected
        (D.reflow (addCategory ("The " ++ direction ++ " side of (" ++ op ++ ") is") category))
        [ D.fillSep
            [ D.fromChars "But"
            , D.fromChars ("(" ++ op ++ ")")
            , D.fromChars "only"
            , D.fromChars "works"
            , D.fromChars "on"
            , D.dullyellow (D.fromChars "Int") |> D.a (D.fromChars ",")
            , D.dullyellow (D.fromChars "Float") |> D.a (D.fromChars ",")
            , D.dullyellow (D.fromChars "Char") |> D.a (D.fromChars ",")
            , D.fromChars "and"
            , D.dullyellow (D.fromChars "String")
            , D.fromChars "values."
            , D.fromChars "It"
            , D.fromChars "can"
            , D.fromChars "work"
            , D.fromChars "on"
            , D.fromChars "lists"
            , D.fromChars "and"
            , D.fromChars "tuples"
            , D.fromChars "of"
            , D.fromChars "comparable"
            , D.fromChars "values"
            , D.fromChars "as"
            , D.fromChars "well,"
            , D.fromChars "but"
            , D.fromChars "it"
            , D.fromChars "is"
            , D.fromChars "usually"
            , D.fromChars "better"
            , D.fromChars "to"
            , D.fromChars "find"
            , D.fromChars "a"
            , D.fromChars "different"
            , D.fromChars "path."
            ]
        ]
    )


{-| Builds the explanation for a comparison whose right operand has a different
type from the left, presenting `expected` as the left operand's type.
-}
badCompRight : L.Localizer -> String -> T.Type -> T.Type -> RightDocs
badCompRight localizer op tipe expected =
    EmphBoth
        ( ("I need both sides of (" ++ op ++ ") to be the same type:") |> D.reflow
        , typeComparison localizer
            expected
            tipe
            ("The left side of (" ++ op ++ ") is:")
            "But the right side is:"
            [ ("I cannot compare different types though! Which side of (" ++ op ++ ") is the problem?") |> D.reflow
            ]
        )



-- ====== BAD EQUALITY ======


{-| Builds the explanation for `==` or `/=` whose right operand has a different
type from the left, presenting `expected` as the left operand's type. When
either side is a `Float`, it adds a note that float equality is unreliable
instead of the usual remark.
-}
badEquality : L.Localizer -> String -> T.Type -> T.Type -> RightDocs
badEquality localizer op tipe expected =
    EmphBoth
        ( ("I need both sides of (" ++ op ++ ") to be the same type:") |> D.reflow
        , typeComparison localizer
            expected
            tipe
            ("The left side of (" ++ op ++ ") is:")
            "But the right side is:"
            [ if isFloat tipe || isFloat expected then
                "Equality on floats is not 100% reliable due to the design of IEEE 754. I recommend a check like (abs (x - y) < 0.0001) instead." |> D.toSimpleNote

              else
                D.reflow "Different types can never be equal though! Which side is messed up?"
            ]
        )



-- ====== INFINITE TYPES ======


{-| Builds the INFINITE TYPE report for the variable `name`, whose type
`overallType` contains itself.
-}
toInfiniteReport : Code.Source -> L.Localizer -> A.Region -> Name -> T.Type -> Report.Report
toInfiniteReport source localizer region name overallType =
    ( ("I am inferring a weird self-referential type for " ++ name ++ ":") |> D.reflow
    , D.stack
        [ "Here is my best effort at writing down the type. You will see ∞ for parts of the type that repeat something already printed out infinitely." |> D.reflow
        , D.indent 4 (D.dullyellow (T.toDoc localizer RT.None overallType))
        , D.reflowLink
            "Staring at this type is usually not so helpful, so I recommend reading the hints at"
            "infinite-type"
            "to get unstuck!"
        ]
    )
        |> Code.toSnippet source region Nothing
        |> Report.report "INFINITE TYPE" region []



-- ====== ENCODERS and DECODERS ======


{-| Encodes a type error in the form `errorDecoder` reads.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder error =
    case error of
        BadExpr region category actualType expected ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , categoryEncoder category
                , T.typeEncoder actualType
                , expectedEncoder T.typeEncoder expected
                ]

        BadPattern region category tipe expected ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , pCategoryEncoder category
                , T.typeEncoder tipe
                , pExpectedEncoder T.typeEncoder expected
                ]

        InfiniteType region name overallType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string name
                , T.typeEncoder overallType
                ]


{-| A decoder for a type error written by `errorEncoder`.

Not every error survives the round trip. A `RecordUpdateKeys` context holds
the update's field values as expressions, and they are encoded with
`Compiler.AST.Canonical.fieldUpdateEncoder`, which cannot be read back when a
value contains a record literal or a record update.

-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 BadExpr
                            A.regionDecoder
                            categoryDecoder
                            T.typeDecoder
                            (expectedDecoder T.typeDecoder)

                    1 ->
                        Bytes.Decode.map4 BadPattern
                            A.regionDecoder
                            pCategoryDecoder
                            T.typeDecoder
                            (pExpectedDecoder T.typeDecoder)

                    2 ->
                        Bytes.Decode.map3 InfiniteType
                            A.regionDecoder
                            BD.string
                            T.typeDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `Category` as a tag byte followed by its payload.
-}
categoryEncoder : Category -> Bytes.Encode.Encoder
categoryEncoder category =
    case category of
        List ->
            Bytes.Encode.unsignedInt8 0

        Number ->
            Bytes.Encode.unsignedInt8 1

        Float ->
            Bytes.Encode.unsignedInt8 2

        String ->
            Bytes.Encode.unsignedInt8 3

        Char ->
            Bytes.Encode.unsignedInt8 4

        If ->
            Bytes.Encode.unsignedInt8 5

        Case ->
            Bytes.Encode.unsignedInt8 6

        CallResult maybeName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , maybeNameEncoder maybeName
                ]

        Lambda ->
            Bytes.Encode.unsignedInt8 8

        Accessor field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.string field
                ]

        Access field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.string field
                ]

        Record ->
            Bytes.Encode.unsignedInt8 11

        Tuple ->
            Bytes.Encode.unsignedInt8 12

        Unit ->
            Bytes.Encode.unsignedInt8 13

        Shader ->
            Bytes.Encode.unsignedInt8 14

        Effects ->
            Bytes.Encode.unsignedInt8 15

        Local name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , BE.string name
                ]

        Foreign name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , BE.string name
                ]


{-| A decoder for a `Category` written by `categoryEncoder`.
-}
categoryDecoder : Bytes.Decode.Decoder Category
categoryDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed List

                    1 ->
                        Bytes.Decode.succeed Number

                    2 ->
                        Bytes.Decode.succeed Float

                    3 ->
                        Bytes.Decode.succeed String

                    4 ->
                        Bytes.Decode.succeed Char

                    5 ->
                        Bytes.Decode.succeed If

                    6 ->
                        Bytes.Decode.succeed Case

                    7 ->
                        Bytes.Decode.map CallResult maybeNameDecoder

                    8 ->
                        Bytes.Decode.succeed Lambda

                    9 ->
                        Bytes.Decode.map Accessor BD.string

                    10 ->
                        Bytes.Decode.map Access BD.string

                    11 ->
                        Bytes.Decode.succeed Record

                    12 ->
                        Bytes.Decode.succeed Tuple

                    13 ->
                        Bytes.Decode.succeed Unit

                    14 ->
                        Bytes.Decode.succeed Shader

                    15 ->
                        Bytes.Decode.succeed Effects

                    16 ->
                        Bytes.Decode.map Local BD.string

                    17 ->
                        Bytes.Decode.map Foreign BD.string

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes an expectation, writing its type with `encoder`.
-}
expectedEncoder : (a -> Bytes.Encode.Encoder) -> Expected a -> Bytes.Encode.Encoder
expectedEncoder encoder expected =
    case expected of
        NoExpectation expectedType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder expectedType
                ]

        FromContext region context expectedType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , contextEncoder context
                , encoder expectedType
                ]

        FromAnnotation name arity subContext expectedType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string name
                , BE.int arity
                , subContextEncoder subContext
                , encoder expectedType
                ]


{-| Produces a decoder for an expectation written by `expectedEncoder`, reading
its type with `decoder`.
-}
expectedDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (Expected a)
expectedDecoder decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map NoExpectation
                            decoder

                    1 ->
                        Bytes.Decode.map3 FromContext
                            A.regionDecoder
                            contextDecoder
                            decoder

                    2 ->
                        Bytes.Decode.map4 FromAnnotation
                            BD.string
                            BD.int
                            subContextDecoder
                            decoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `Context` as a tag byte followed by its payload.
-}
contextEncoder : Context -> Bytes.Encode.Encoder
contextEncoder context =
    case context of
        ListEntry index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                ]

        Negate ->
            Bytes.Encode.unsignedInt8 1

        OpLeft op ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string op
                ]

        OpRight op ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string op
                ]

        IfCondition ->
            Bytes.Encode.unsignedInt8 4

        IfBranch index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , Index.zeroBasedEncoder index
                ]

        CaseBranch index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , Index.zeroBasedEncoder index
                ]

        CallArity maybeFuncName numGivenArgs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , maybeNameEncoder maybeFuncName
                , BE.int numGivenArgs
                ]

        CallArg maybeFuncName index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , maybeNameEncoder maybeFuncName
                , Index.zeroBasedEncoder index
                ]

        RecordAccess recordRegion maybeName fieldRegion field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , A.regionEncoder recordRegion
                , BE.maybe BE.string maybeName
                , A.regionEncoder fieldRegion
                , BE.string field
                ]

        RecordUpdateKeys expectedFields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.stdDict BE.string Can.fieldUpdateEncoder expectedFields
                ]

        RecordUpdateValue field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.string field
                ]

        Destructure ->
            Bytes.Encode.unsignedInt8 12


{-| A decoder for a `Context` written by `contextEncoder`.
-}
contextDecoder : Bytes.Decode.Decoder Context
contextDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map ListEntry Index.zeroBasedDecoder

                    1 ->
                        Bytes.Decode.succeed Negate

                    2 ->
                        Bytes.Decode.map OpLeft BD.string

                    3 ->
                        Bytes.Decode.map OpRight BD.string

                    4 ->
                        Bytes.Decode.succeed IfCondition

                    5 ->
                        Bytes.Decode.map IfBranch Index.zeroBasedDecoder

                    6 ->
                        Bytes.Decode.map CaseBranch Index.zeroBasedDecoder

                    7 ->
                        Bytes.Decode.map2 CallArity
                            maybeNameDecoder
                            BD.int

                    8 ->
                        Bytes.Decode.map2 CallArg
                            maybeNameDecoder
                            Index.zeroBasedDecoder

                    9 ->
                        Bytes.Decode.map4 RecordAccess
                            A.regionDecoder
                            (BD.maybe BD.string)
                            A.regionDecoder
                            BD.string

                    10 ->
                        Bytes.Decode.map RecordUpdateKeys
                            (BD.stdDict BD.string Can.fieldUpdateDecoder)

                    11 ->
                        Bytes.Decode.map RecordUpdateValue BD.string

                    12 ->
                        Bytes.Decode.succeed Destructure

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `SubContext` as a tag byte followed by its payload.
-}
subContextEncoder : SubContext -> Bytes.Encode.Encoder
subContextEncoder subContext =
    case subContext of
        TypedIfBranch index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                ]

        TypedCaseBranch index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Index.zeroBasedEncoder index
                ]

        TypedBody ->
            Bytes.Encode.unsignedInt8 2


{-| A decoder for a `SubContext` written by `subContextEncoder`.
-}
subContextDecoder : Bytes.Decode.Decoder SubContext
subContextDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map TypedIfBranch Index.zeroBasedDecoder

                    1 ->
                        Bytes.Decode.map TypedCaseBranch Index.zeroBasedDecoder

                    2 ->
                        Bytes.Decode.succeed TypedBody

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `PCategory` as a tag byte followed by its payload.
-}
pCategoryEncoder : PCategory -> Bytes.Encode.Encoder
pCategoryEncoder pCategory =
    case pCategory of
        PRecord ->
            Bytes.Encode.unsignedInt8 0

        PUnit ->
            Bytes.Encode.unsignedInt8 1

        PTuple ->
            Bytes.Encode.unsignedInt8 2

        PList ->
            Bytes.Encode.unsignedInt8 3

        PCtor name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string name
                ]

        PInt ->
            Bytes.Encode.unsignedInt8 5

        PStr ->
            Bytes.Encode.unsignedInt8 6

        PChr ->
            Bytes.Encode.unsignedInt8 7

        PBool ->
            Bytes.Encode.unsignedInt8 8


{-| A decoder for a `PCategory` written by `pCategoryEncoder`.
-}
pCategoryDecoder : Bytes.Decode.Decoder PCategory
pCategoryDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed PRecord

                    1 ->
                        Bytes.Decode.succeed PUnit

                    2 ->
                        Bytes.Decode.succeed PTuple

                    3 ->
                        Bytes.Decode.succeed PList

                    4 ->
                        Bytes.Decode.map PCtor BD.string

                    5 ->
                        Bytes.Decode.succeed PInt

                    6 ->
                        Bytes.Decode.succeed PStr

                    7 ->
                        Bytes.Decode.succeed PChr

                    8 ->
                        Bytes.Decode.succeed PBool

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a pattern expectation, writing its type with `encoder`.
-}
pExpectedEncoder : (a -> Bytes.Encode.Encoder) -> PExpected a -> Bytes.Encode.Encoder
pExpectedEncoder encoder pExpected =
    case pExpected of
        PNoExpectation expectedType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , encoder expectedType
                ]

        PFromContext region context expectedType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , pContextEncoder context
                , encoder expectedType
                ]


{-| Produces a decoder for a pattern expectation written by `pExpectedEncoder`,
reading its type with `decoder`.
-}
pExpectedDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (PExpected a)
pExpectedDecoder decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map PNoExpectation decoder

                    1 ->
                        Bytes.Decode.map3 PFromContext
                            A.regionDecoder
                            pContextDecoder
                            decoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `MaybeName` as a tag byte followed by its name, if any.
-}
maybeNameEncoder : MaybeName -> Bytes.Encode.Encoder
maybeNameEncoder maybeName =
    case maybeName of
        FuncName name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                ]

        CtorName name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        OpName op ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string op
                ]

        NoName ->
            Bytes.Encode.unsignedInt8 3


{-| A decoder for a `MaybeName` written by `maybeNameEncoder`.
-}
maybeNameDecoder : Bytes.Decode.Decoder MaybeName
maybeNameDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map FuncName BD.string

                    1 ->
                        Bytes.Decode.map CtorName BD.string

                    2 ->
                        Bytes.Decode.map OpName BD.string

                    3 ->
                        Bytes.Decode.succeed NoName

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `PContext` as a tag byte followed by its payload.
-}
pContextEncoder : PContext -> Bytes.Encode.Encoder
pContextEncoder pContext =
    case pContext of
        PTypedArg name index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                , Index.zeroBasedEncoder index
                ]

        PCaseMatch index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Index.zeroBasedEncoder index
                ]

        PCtorArg name index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string name
                , Index.zeroBasedEncoder index
                ]

        PListEntry index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , Index.zeroBasedEncoder index
                ]

        PTail ->
            Bytes.Encode.unsignedInt8 4


{-| A decoder for a `PContext` written by `pContextEncoder`.
-}
pContextDecoder : Bytes.Decode.Decoder PContext
pContextDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 PTypedArg
                            BD.string
                            Index.zeroBasedDecoder

                    1 ->
                        Bytes.Decode.map PCaseMatch Index.zeroBasedDecoder

                    2 ->
                        Bytes.Decode.map2 PCtorArg
                            BD.string
                            Index.zeroBasedDecoder

                    3 ->
                        Bytes.Decode.map PListEntry Index.zeroBasedDecoder

                    4 ->
                        Bytes.Decode.succeed PTail

                    _ ->
                        Bytes.Decode.fail
            )
