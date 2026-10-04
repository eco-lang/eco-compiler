module SourceIR.Fuzz.TypedExpr exposing
    ( Scope
    , SimpleType(..)
    , decrementDepth
    , emptyScope
    , exprFuzzerForType
    , intExprFuzzer
    )

{-| Fuzz tests that build programs as Source AST values need random expressions
that are well typed. This module generates an expression of a requested type
that uses each variable only where a value of that variable's type is
expected, so the expression is well typed wherever the variables its `Scope`
lists are bound at the types the `Scope` gives them.

A `SimpleType` names the type wanted. A `Scope` lists the variables an
expression may refer to, the names it must not bind again (Elm rejects a local
binding that shadows a name already in scope), and the depth budget.

The depth budget bounds nesting. Given a budget of 0 or less, each expression
fuzzer produces only a leaf. Above that it picks, with equal chance, a leaf or
one of the compound forms its type allows, and generates that form's parts with
the budget one less:

  - `Int`: `let`, `if`, negation, and a `case` with a single branch that binds
    the subject to a fresh name.
  - `Float`: `let`, `if` and negation.
  - `String`, `Bool`, lists, pairs and records: `let` and `if`.

A leaf of type `Int`, `Float`, `String` or `Bool` is a literal or, with equal
chance when the scope has one, a variable of that type. A leaf of a list, pair
or record type is a literal whose elements are generated with the budget one
less: a list of 0 to 4 elements, a pair, or a record with exactly the requested
fields. Such a leaf is never itself a variable, so a `let` of a list, pair or
record binds a name that nothing uses. Every `let` and `case` binder is a name
the scope does not hold, and every `if` condition is a generated `Bool`
expression.

Each choice among a type's forms is wrapped in `Fuzz.andThen`, so only the
fuzzer of the form chosen is built, not the fuzzers of every form down to the
end of the budget.

The expressions are built with `Compiler.AST.SourceBuilder`, and some are
shapes the parser never produces: an `Int` literal can be negative, a negation
can wrap a `let`, `if`, `case` or another negation, a `Float` literal can be
infinite or NaN (`Fuzz.float` produces both), and a `String` literal holds the
text `Fuzz.string` gave without escaping, so it can contain a raw `"`, `\` or
newline. `Bool` literals are the qualified constructors `Basics.True` and
`Basics.False`.

The module also holds fuzzers for a pattern of each type, paired with the names
and types the pattern binds. They are not exposed and nothing outside them calls
them. A record pattern binds the record's field names; every other variable in
a pattern is named from a fixed list, with no check against the scope or the
pattern's other variables, so one pattern can bind a name twice.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.Data.Name exposing (Name)
import Fuzz exposing (Fuzzer)



-- =============================================================================
-- TYPES
-- =============================================================================


{-| A type this module can generate an expression of.

`TList` is a list of its element type. `TTuple` is a pair; no larger tuple can
be asked for. `TRecord` is a closed record with the given fields, which a
record literal writes in the order listed.

There is no `Char`, unit, function or custom type.

-}
type SimpleType
    = TInt
    | TFloat
    | TString
    | TBool
    | TList SimpleType
    | TTuple SimpleType SimpleType
    | TRecord (List ( Name, SimpleType ))


{-| The context an expression is generated in: the variables it may refer
to, the names it must not bind, and how much nesting it may still use.

`vars` are the variables an expression may refer to, each with its type.
`usedNames` are names a new binding must not take. `addVar` puts a variable in
both lists, while a name whose definition is still being generated is in
`usedNames` alone. A fresh name is checked against both lists, so a `Scope`
built by hand need not repeat its `vars` in `usedNames`. A name in scope that
neither list holds is not avoided.

`depth` is the depth budget. Each compound form, and each list, pair or record
literal, generates its parts with one less, and at 0 or less only leaves are
generated. Nothing stops it going negative.

-}
type alias Scope =
    { vars : List ( Name, SimpleType )
    , usedNames : List Name
    , depth : Int
    }



-- =============================================================================
-- SCOPE OPERATIONS
-- =============================================================================


{-| Creates a scope with no variables and no reserved names, with a depth
budget of `maxDepth`.
-}
emptyScope : Int -> Scope
emptyScope maxDepth =
    { vars = [], usedNames = [], depth = maxDepth }


{-| Returns `scope` with `name` added as a variable of type `tipe`, which an
expression may refer to and no later binding may take.
-}
addVar : Name -> SimpleType -> Scope -> Scope
addVar name tipe scope =
    { scope
        | vars = ( name, tipe ) :: scope.vars
        , usedNames = name :: scope.usedNames
    }


{-| Returns `scope` with `name` barred from new bindings but not available to
refer to. A `let` generates its definition's value in such a scope, so the value
cannot bind the name being defined.
-}
reserveName : Name -> Scope -> Scope
reserveName name scope =
    { scope | usedNames = name :: scope.usedNames }


{-| Returns `scope` with its depth budget one less.
-}
decrementDepth : Scope -> Scope
decrementDepth scope =
    { scope | depth = scope.depth - 1 }


{-| Returns the names of the variables in `scope` whose type is `tipe`, in
the order of `scope.vars`.
-}
varsOfType : SimpleType -> Scope -> List Name
varsOfType tipe scope =
    List.filterMap
        (\( name, t ) ->
            if t == tipe then
                Just name

            else
                Nothing
        )
        scope.vars



-- =============================================================================
-- UTILITY FUZZERS
-- =============================================================================


{-| A fuzzer for one of fourteen fixed lower-case names, with no check against
any scope. Only the pattern fuzzers use it.
-}
nameFuzzer : Fuzzer Name
nameFuzzer =
    Fuzz.oneOfValues
        [ "x"
        , "y"
        , "z"
        , "a"
        , "b"
        , "c"
        , "n"
        , "m"
        , "foo"
        , "bar"
        , "baz"
        , "val"
        , "tmp"
        , "res"
        ]


{-| Produces a fuzzer for a name that `scope` neither lists as a variable nor
reserves. It is a single lower-case letter, chosen with equal chance from those
still free, or, once all 26 are taken, `var` followed by a number from 1 to
1000, drawn again until the result is free.
-}
uniqueNameFuzzer : Scope -> Fuzzer Name
uniqueNameFuzzer scope =
    let
        -- vars is read too, because a Scope built by hand may not repeat them.
        takenNames =
            scope.usedNames ++ List.map Tuple.first scope.vars

        allNames =
            [ "a"
            , "b"
            , "c"
            , "d"
            , "e"
            , "f"
            , "g"
            , "h"
            , "i"
            , "j"
            , "k"
            , "l"
            , "m"
            , "n"
            , "o"
            , "p"
            , "q"
            , "r"
            , "s"
            , "t"
            , "u"
            , "v"
            , "w"
            , "x"
            , "y"
            , "z"
            ]

        available q =
            List.filter (\n -> not (List.member n takenNames)) q

        genNotTaken () =
            Fuzz.intRange 1 1000
                |> Fuzz.andThen
                    (\i ->
                        case available [ "var" ++ String.fromInt i ] of
                            [] ->
                                genNotTaken ()

                            v :: _ ->
                                Fuzz.constant v
                    )
    in
    case available allNames of
        [] ->
            genNotTaken ()

        avail ->
            Fuzz.oneOfValues avail



-- =============================================================================
-- INT EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `Int` whose free variables are
variables of `scope`, each used at its own type, and which binds no name `scope`
holds.

With a depth budget of 0 or less it is a leaf: any `Int` literal, negative ones
included, or an `Int` variable of `scope`. Above that it is, with equal chance,
a leaf, a `let`, an `if`, a negation, or a `case` whose single branch binds the
subject to a fresh name, with the parts generated at the budget one less.

-}
intExprFuzzer : Scope -> Fuzzer Src.Expr
intExprFuzzer scope =
    if scope.depth <= 0 then
        intLeafFuzzer scope

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> intLeafFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> intLetFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> intIfFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> intNegateFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> intCaseFuzzer scope)
            ]


{-| Produces a fuzzer for an `Int` literal or, with equal chance when `scope`
has one, an `Int` variable of `scope`.
-}
intLeafFuzzer : Scope -> Fuzzer Src.Expr
intLeafFuzzer scope =
    let
        availableVars =
            varsOfType TInt scope
    in
    case availableVars of
        [] ->
            Fuzz.map B.intExpr Fuzz.int

        _ ->
            Fuzz.oneOf
                [ Fuzz.map B.intExpr Fuzz.int
                , Fuzz.oneOfValues availableVars |> Fuzz.map B.varExpr
                ]


{-| Produces a fuzzer for `let name = value in body`, where `name` is one
`scope` does not hold and `value` and `body` are `Int` expressions one level
lower; `name` is an `Int` variable in `body` only.
-}
intLetFuzzer : Scope -> Fuzzer Src.Expr
intLetFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (intExprFuzzer reservedScope)
                    (intExprFuzzer (addVar bindingName TInt innerScope))
            )


{-| Produces a fuzzer for an `if` whose condition is a `Bool` expression and
whose branches are `Int` expressions, all one level lower and generated
independently.
-}
intIfFuzzer : Scope -> Fuzzer Src.Expr
intIfFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (intExprFuzzer innerScope)
        (intExprFuzzer innerScope)


{-| Produces a fuzzer for the negation of an `Int` expression one level lower.
-}
intNegateFuzzer : Scope -> Fuzzer Src.Expr
intNegateFuzzer scope =
    Fuzz.map B.negateExpr (intExprFuzzer (decrementDepth scope))


{-| Produces a fuzzer for `case subject of name -> body`, where `name` is one
`scope` does not hold and `subject` and `body` are `Int` expressions one level
lower; `name` is an `Int` variable in `body` only. The one branch matches every
value.
-}
intCaseFuzzer : Scope -> Fuzzer Src.Expr
intCaseFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\patternName ->
                Fuzz.map2
                    (\subject bodyExpr ->
                        B.caseExpr subject
                            [ ( B.pVar patternName, bodyExpr )
                            ]
                    )
                    (intExprFuzzer innerScope)
                    (intExprFuzzer (addVar patternName TInt innerScope))
            )



-- =============================================================================
-- FLOAT EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `Float`, chosen as
`intExprFuzzer` chooses but with no `case`.
-}
floatExprFuzzer : Scope -> Fuzzer Src.Expr
floatExprFuzzer scope =
    if scope.depth <= 0 then
        floatLeafFuzzer scope

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> floatLeafFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> floatLetFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> floatIfFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> floatNegateFuzzer scope)
            ]


{-| Produces a fuzzer for a `Float` literal from `Fuzz.float`, which includes
infinities and NaN, or, with equal chance when `scope` has one, a `Float`
variable of `scope`.
-}
floatLeafFuzzer : Scope -> Fuzzer Src.Expr
floatLeafFuzzer scope =
    let
        availableVars =
            varsOfType TFloat scope
    in
    case availableVars of
        [] ->
            Fuzz.map B.floatExpr Fuzz.float

        _ ->
            Fuzz.oneOf
                [ Fuzz.map B.floatExpr Fuzz.float
                , Fuzz.oneOfValues availableVars |> Fuzz.map B.varExpr
                ]


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for `Float`.
-}
floatLetFuzzer : Scope -> Fuzzer Src.Expr
floatLetFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (floatExprFuzzer reservedScope)
                    (floatExprFuzzer (addVar bindingName TFloat innerScope))
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with `Float`
branches.
-}
floatIfFuzzer : Scope -> Fuzzer Src.Expr
floatIfFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (floatExprFuzzer innerScope)
        (floatExprFuzzer innerScope)


{-| Produces a fuzzer for the negation of a `Float` expression one level lower.
-}
floatNegateFuzzer : Scope -> Fuzzer Src.Expr
floatNegateFuzzer scope =
    Fuzz.map B.negateExpr (floatExprFuzzer (decrementDepth scope))



-- =============================================================================
-- STRING EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `String`: a leaf, a `let` or
an `if`, chosen as `intExprFuzzer` chooses.
-}
stringExprFuzzer : Scope -> Fuzzer Src.Expr
stringExprFuzzer scope =
    if scope.depth <= 0 then
        stringLeafFuzzer scope

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> stringLeafFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> stringLetFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> stringIfFuzzer scope)
            ]


{-| Produces a fuzzer for a `String` literal holding `Fuzz.string`'s text
unescaped or, with equal chance when `scope` has one, a `String` variable of
`scope`.
-}
stringLeafFuzzer : Scope -> Fuzzer Src.Expr
stringLeafFuzzer scope =
    let
        availableVars =
            varsOfType TString scope
    in
    case availableVars of
        [] ->
            Fuzz.map B.strExpr Fuzz.string

        _ ->
            Fuzz.oneOf
                [ Fuzz.map B.strExpr Fuzz.string
                , Fuzz.oneOfValues availableVars |> Fuzz.map B.varExpr
                ]


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for `String`.
-}
stringLetFuzzer : Scope -> Fuzzer Src.Expr
stringLetFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (stringExprFuzzer reservedScope)
                    (stringExprFuzzer (addVar bindingName TString innerScope))
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with `String`
branches.
-}
stringIfFuzzer : Scope -> Fuzzer Src.Expr
stringIfFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (stringExprFuzzer innerScope)
        (stringExprFuzzer innerScope)



-- =============================================================================
-- BOOL EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `Bool`: a leaf, a `let` or an
`if`, chosen as `intExprFuzzer` chooses.
-}
boolExprFuzzer : Scope -> Fuzzer Src.Expr
boolExprFuzzer scope =
    if scope.depth <= 0 then
        boolLeafFuzzer scope

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> boolLeafFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> boolLetFuzzer scope)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> boolIfFuzzer scope)
            ]


{-| Produces a fuzzer for `Basics.True` or `Basics.False` or, with equal chance
when `scope` has one, a `Bool` variable of `scope`.
-}
boolLeafFuzzer : Scope -> Fuzzer Src.Expr
boolLeafFuzzer scope =
    let
        availableVars =
            varsOfType TBool scope
    in
    case availableVars of
        [] ->
            Fuzz.map B.boolExpr Fuzz.bool

        _ ->
            Fuzz.oneOf
                [ Fuzz.map B.boolExpr Fuzz.bool
                , Fuzz.oneOfValues availableVars |> Fuzz.map B.varExpr
                ]


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for `Bool`.
-}
boolLetFuzzer : Scope -> Fuzzer Src.Expr
boolLetFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (boolExprFuzzer reservedScope)
                    (boolExprFuzzer (addVar bindingName TBool innerScope))
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with `Bool`
branches.
-}
boolIfFuzzer : Scope -> Fuzzer Src.Expr
boolIfFuzzer scope =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (boolExprFuzzer innerScope)
        (boolExprFuzzer innerScope)



-- =============================================================================
-- LIST EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `List` of `elemType`: a leaf,
a `let` or an `if`, chosen as `intExprFuzzer` chooses.
-}
listExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listExprFuzzer scope elemType =
    if scope.depth <= 0 then
        listLeafFuzzer scope elemType

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> listLeafFuzzer scope elemType)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> listLetFuzzer scope elemType)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> listIfFuzzer scope elemType)
            ]


{-| Produces a fuzzer for a list literal of 0 to 4 elements, each an expression
of type `elemType` one level lower. It never refers to a list variable.
-}
listLeafFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listLeafFuzzer scope elemType =
    Fuzz.intRange 0 4
        |> Fuzz.andThen
            (\len ->
                Fuzz.listOfLength len (exprFuzzerForType (decrementDepth scope) elemType)
                    |> Fuzz.map B.listExpr
            )


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for a list of
`elemType`. The list variable it binds is never referred to, because no list
leaf is a variable.
-}
listLetFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listLetFuzzer scope elemType =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (listExprFuzzer reservedScope elemType)
                    (listExprFuzzer (addVar bindingName (TList elemType) innerScope) elemType)
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with branches that are
lists of `elemType`.
-}
listIfFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listIfFuzzer scope elemType =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (listExprFuzzer innerScope elemType)
        (listExprFuzzer innerScope elemType)



-- =============================================================================
-- TUPLE EXPRESSION FUZZERS
-- =============================================================================


{-| Produces a fuzzer for an expression of type `( typeA, typeB )`: a leaf, a
`let` or an `if`, chosen as `intExprFuzzer` chooses.
-}
tupleExprFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleExprFuzzer scope typeA typeB =
    if scope.depth <= 0 then
        tupleLeafFuzzer scope typeA typeB

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> tupleLeafFuzzer scope typeA typeB)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> tupleLetFuzzer scope typeA typeB)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> tupleIfFuzzer scope typeA typeB)
            ]


{-| Produces a fuzzer for a pair literal whose elements are expressions of type
`typeA` and `typeB`, one level lower. It never refers to a pair variable.
-}
tupleLeafFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleLeafFuzzer scope typeA typeB =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map2 B.tupleExpr
        (exprFuzzerForType innerScope typeA)
        (exprFuzzerForType innerScope typeB)


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for a pair of
`typeA` and `typeB`. The pair variable it binds is never referred to, because
no pair leaf is a variable.
-}
tupleLetFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleLetFuzzer scope typeA typeB =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (tupleExprFuzzer reservedScope typeA typeB)
                    (tupleExprFuzzer (addVar bindingName (TTuple typeA typeB) innerScope) typeA typeB)
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with branches that are
pairs of `typeA` and `typeB`.
-}
tupleIfFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleIfFuzzer scope typeA typeB =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (tupleExprFuzzer innerScope typeA typeB)
        (tupleExprFuzzer innerScope typeA typeB)



-- =============================================================================
-- RECORD EXPRESSION FUZZER
-- =============================================================================


{-| Produces a fuzzer for an expression of the closed record type with
`fields`: a leaf, a `let` or an `if`, chosen as `intExprFuzzer` chooses.
-}
recordExprFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordExprFuzzer scope fields =
    if scope.depth <= 0 then
        recordLeafFuzzer scope fields

    else
        Fuzz.oneOf
            [ Fuzz.constant () |> Fuzz.andThen (\_ -> recordLeafFuzzer scope fields)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> recordLetFuzzer scope fields)
            , Fuzz.constant () |> Fuzz.andThen (\_ -> recordIfFuzzer scope fields)
            ]


{-| Produces a fuzzer for a record literal with exactly `fields`, in the order
given, each value an expression of the field's type one level lower. It never
refers to a record variable.
-}
recordLeafFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordLeafFuzzer scope fields =
    let
        innerScope =
            decrementDepth scope
    in
    fields
        |> List.map
            (\( name, tipe ) ->
                exprFuzzerForType innerScope tipe
                    |> Fuzz.map (\expr -> ( name, expr ))
            )
        |> fuzzSequence
        |> Fuzz.map B.recordExpr


{-| Produces a fuzzer for a `let` as `intLetFuzzer` does, for the record type
with `fields`. The record variable it binds is never referred to, because no
record leaf is a variable.
-}
recordLetFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordLetFuzzer scope fields =
    let
        innerScope =
            decrementDepth scope
    in
    uniqueNameFuzzer scope
        |> Fuzz.andThen
            (\bindingName ->
                let
                    reservedScope =
                        reserveName bindingName innerScope
                in
                Fuzz.map2
                    (\bindingValue body ->
                        B.letExpr
                            [ B.define bindingName [] bindingValue ]
                            body
                    )
                    (recordExprFuzzer reservedScope fields)
                    (recordExprFuzzer (addVar bindingName (TRecord fields) innerScope) fields)
            )


{-| Produces a fuzzer for an `if` as `intIfFuzzer` does, with branches of the
record type with `fields`.
-}
recordIfFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordIfFuzzer scope fields =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map3 B.ifExpr
        (boolExprFuzzer innerScope)
        (recordExprFuzzer innerScope fields)
        (recordExprFuzzer innerScope fields)



-- =============================================================================
-- UNIFIED TYPE DISPATCHER
-- =============================================================================


{-| Produces a fuzzer for an expression of type `tipe` in `scope`, by the rules
the module documentation sets out for that type.
-}
exprFuzzerForType : Scope -> SimpleType -> Fuzzer Src.Expr
exprFuzzerForType scope tipe =
    case tipe of
        TInt ->
            intExprFuzzer scope

        TFloat ->
            floatExprFuzzer scope

        TString ->
            stringExprFuzzer scope

        TBool ->
            boolExprFuzzer scope

        TList elemType ->
            listExprFuzzer scope elemType

        TTuple a b ->
            tupleExprFuzzer scope a b

        TRecord fields ->
            recordExprFuzzer scope fields



-- =============================================================================
-- PATTERN FUZZERS
-- =============================================================================


{-| A fuzzer for an `Int` pattern, paired with what it binds: an integer
literal, which binds nothing and can be negative, a variable from `nameFuzzer`,
or `_`.
-}
intPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
intPatternFuzzer =
    Fuzz.oneOf
        [ Fuzz.map (\n -> ( B.pInt n, [] )) Fuzz.int
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TInt ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| A fuzzer for a `String` pattern, paired with what it binds: one of four
fixed string literals, a variable from `nameFuzzer`, or `_`.
-}
stringPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
stringPatternFuzzer =
    Fuzz.oneOf
        [ Fuzz.map (\s -> ( B.pStr s, [] )) (Fuzz.oneOfValues [ "", "a", "hello", "test" ])
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TString ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Produces a fuzzer for a pattern of the pair type of `typeA` and `typeB`,
paired with what it binds: a pair of patterns for the two element types, a
variable, or `_`. The bindings of a pair pattern are the first element's then
the second's, and nothing stops the two binding the same name.
-}
tuplePatternFuzzer : SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
tuplePatternFuzzer typeA typeB =
    Fuzz.oneOf
        [ Fuzz.map2
            (\( patA, bindingsA ) ( patB, bindingsB ) ->
                ( B.pTuple patA patB, bindingsA ++ bindingsB )
            )
            (patternFuzzerForType typeA)
            (patternFuzzerForType typeB)
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TTuple typeA typeB ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Produces a fuzzer for a pattern of a list of `elemType`, paired with what
it binds: `[]`, `head :: tail` with a pattern of `elemType` for the head and a
variable for the tail, a variable, or `_`. Nothing stops the head and the tail
binding the same name.
-}
listPatternFuzzer : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
listPatternFuzzer elemType =
    Fuzz.oneOf
        [ Fuzz.constant ( B.pList [], [] )
        , Fuzz.map2
            (\( headPat, headBindings ) tailName ->
                ( B.pCons headPat (B.pVar tailName)
                , headBindings ++ [ ( tailName, TList elemType ) ]
                )
            )
            (patternFuzzerForType elemType)
            nameFuzzer
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TList elemType ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Produces a fuzzer for a pattern of the record type with `fields`, paired
with what it binds: a record pattern binding every field under its own name, a
variable, or `_`.
-}
recordPatternFuzzer : List ( Name, SimpleType ) -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
recordPatternFuzzer fields =
    let
        fieldNames =
            List.map Tuple.first fields
    in
    Fuzz.oneOf
        [ Fuzz.constant ( B.pRecord fieldNames, fields )
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TRecord fields ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Produces a fuzzer for a pattern of type `tipe`, paired with the names and
types it binds. A `Bool` or `Float` pattern is only a variable or `_`. Variable
names other than a record pattern's field names come from `nameFuzzer`, with no
check against any scope.
-}
patternFuzzerForType : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
patternFuzzerForType tipe =
    case tipe of
        TInt ->
            intPatternFuzzer

        TString ->
            stringPatternFuzzer

        TBool ->
            Fuzz.oneOf
                [ Fuzz.map (\name -> ( B.pVar name, [ ( name, TBool ) ] )) nameFuzzer
                , Fuzz.constant ( B.pAnything, [] )
                ]

        TList elemType ->
            listPatternFuzzer elemType

        TTuple a b ->
            tuplePatternFuzzer a b

        TRecord fields ->
            recordPatternFuzzer fields

        _ ->
            -- Only TFloat reaches here.
            Fuzz.oneOf
                [ Fuzz.map (\name -> ( B.pVar name, [ ( name, tipe ) ] )) nameFuzzer
                , Fuzz.constant ( B.pAnything, [] )
                ]



-- =============================================================================
-- HELPERS
-- =============================================================================


{-| Produces a fuzzer for a list holding one value from each of `fuzzers`, in
the same order.
-}
fuzzSequence : List (Fuzzer a) -> Fuzzer (List a)
fuzzSequence fuzzers =
    case fuzzers of
        [] ->
            Fuzz.constant []

        first :: rest ->
            Fuzz.map2 (::) first (fuzzSequence rest)
