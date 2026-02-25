module SourceIR.Fuzz.TypedExpr exposing
    ( Scope
      -- Scope operations
    , -- Types
      SimpleType(..)
    , decrementDepth
      -- Expression fuzzers
    , emptyScope
    , exprFuzzerForType
    , intExprFuzzer
    )

{-| Type-indexed expression and pattern fuzzers.

These fuzzers generate syntactically valid, type-correct Elm expressions
and patterns. Each fuzzer is parameterized by the type it produces.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.Data.Name exposing (Name)
import Fuzz exposing (Fuzzer)



-- =============================================================================
-- TYPES
-- =============================================================================


{-| Simple type representation for tracking types during generation.
-}
type SimpleType
    = TInt
    | TFloat
    | TString
    | TBool
    | TList SimpleType
    | TTuple SimpleType SimpleType
    | TRecord (List ( Name, SimpleType ))


{-| Scope tracks variables in scope and remaining depth budget.

  - `vars`: Variables available for reference
  - `usedNames`: Names that are taken (for shadowing prevention) but not yet available
  - `depth`: Remaining recursion depth budget

-}
type alias Scope =
    { vars : List ( Name, SimpleType )
    , usedNames : List Name
    , depth : Int
    }



-- =============================================================================
-- SCOPE OPERATIONS
-- =============================================================================


{-| Create an empty scope with a given depth budget.
-}
emptyScope : Int -> Scope
emptyScope maxDepth =
    { vars = [], usedNames = [], depth = maxDepth }


{-| Add a variable to scope (both available for reference and reserved).
-}
addVar : Name -> SimpleType -> Scope -> Scope
addVar name tipe scope =
    { scope
        | vars = ( name, tipe ) :: scope.vars
        , usedNames = name :: scope.usedNames
    }


{-| Reserve a name (prevents shadowing) without making it available for reference.
Use this when generating a binding value before the binding is complete.
-}
reserveName : Name -> Scope -> Scope
reserveName name scope =
    { scope | usedNames = name :: scope.usedNames }


{-| Decrement the depth budget.
-}
decrementDepth : Scope -> Scope
decrementDepth scope =
    { scope | depth = scope.depth - 1 }


{-| Get all variable names of a given type.
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


{-| Fuzzer for valid Elm identifiers.
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


{-| Generate a name not already in scope or reserved.
-}
uniqueNameFuzzer : Scope -> Fuzzer Name
uniqueNameFuzzer scope =
    let
        -- Check both vars and usedNames to prevent shadowing
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
            -- Fallback with suffix
            genNotTaken ()

        avail ->
            Fuzz.oneOfValues avail



-- =============================================================================
-- INT EXPRESSION FUZZER
-- =============================================================================


{-| Generate an expression of type Int.
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
                    -- Reserve name for binding value to prevent shadowing
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


intNegateFuzzer : Scope -> Fuzzer Src.Expr
intNegateFuzzer scope =
    Fuzz.map B.negateExpr (intExprFuzzer (decrementDepth scope))


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


{-| Generate an expression of type Float.
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


floatNegateFuzzer : Scope -> Fuzzer Src.Expr
floatNegateFuzzer scope =
    Fuzz.map B.negateExpr (floatExprFuzzer (decrementDepth scope))



-- =============================================================================
-- STRING EXPRESSION FUZZER
-- =============================================================================


{-| Generate an expression of type String.
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


{-| Generate an expression of type Bool.
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
-- UNIT EXPRESSION FUZZER
-- =============================================================================
-- =============================================================================
-- LIST EXPRESSION FUZZER
-- =============================================================================


{-| Generate an expression of type List a.
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


listLeafFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listLeafFuzzer scope elemType =
    Fuzz.intRange 0 4
        |> Fuzz.andThen
            (\len ->
                Fuzz.listOfLength len (exprFuzzerForType (decrementDepth scope) elemType)
                    |> Fuzz.map B.listExpr
            )


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


{-| Generate an expression of type (a, b).
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


tupleLeafFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleLeafFuzzer scope typeA typeB =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map2 B.tupleExpr
        (exprFuzzerForType innerScope typeA)
        (exprFuzzerForType innerScope typeB)


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


{-| Generate an expression of type { field1 : a, field2 : b, ... }.
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


{-| Generate an expression of the given type.
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


{-| Generate an Int pattern with bindings.
-}
intPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
intPatternFuzzer =
    Fuzz.oneOf
        [ Fuzz.map (\n -> ( B.pInt n, [] )) Fuzz.int
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TInt ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Generate a String pattern with bindings.
-}
stringPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
stringPatternFuzzer =
    Fuzz.oneOf
        [ Fuzz.map (\s -> ( B.pStr s, [] )) (Fuzz.oneOfValues [ "", "a", "hello", "test" ])
        , Fuzz.map (\name -> ( B.pVar name, [ ( name, TString ) ] )) nameFuzzer
        , Fuzz.constant ( B.pAnything, [] )
        ]


{-| Generate a tuple pattern with bindings.
-}
tuplePatternFuzzer : SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
tuplePatternFuzzer typeA typeB =
    Fuzz.oneOf
        [ -- Full destructure
          Fuzz.map2
            (\( patA, bindingsA ) ( patB, bindingsB ) ->
                ( B.pTuple patA patB, bindingsA ++ bindingsB )
            )
            (patternFuzzerForType typeA)
            (patternFuzzerForType typeB)
        , -- Variable binding
          Fuzz.map (\name -> ( B.pVar name, [ ( name, TTuple typeA typeB ) ] )) nameFuzzer
        , -- Wildcard
          Fuzz.constant ( B.pAnything, [] )
        ]


{-| Generate a list pattern with bindings.
-}
listPatternFuzzer : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
listPatternFuzzer elemType =
    Fuzz.oneOf
        [ -- Empty list
          Fuzz.constant ( B.pList [], [] )
        , -- Cons pattern
          Fuzz.map2
            (\( headPat, headBindings ) tailName ->
                ( B.pCons headPat (B.pVar tailName)
                , headBindings ++ [ ( tailName, TList elemType ) ]
                )
            )
            (patternFuzzerForType elemType)
            nameFuzzer
        , -- Variable
          Fuzz.map (\name -> ( B.pVar name, [ ( name, TList elemType ) ] )) nameFuzzer
        , -- Wildcard
          Fuzz.constant ( B.pAnything, [] )
        ]


{-| Generate a record pattern with bindings.
-}
recordPatternFuzzer : List ( Name, SimpleType ) -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
recordPatternFuzzer fields =
    let
        fieldNames =
            List.map Tuple.first fields
    in
    Fuzz.oneOf
        [ -- Record pattern with all fields
          Fuzz.constant ( B.pRecord fieldNames, fields )
        , -- Variable
          Fuzz.map (\name -> ( B.pVar name, [ ( name, TRecord fields ) ] )) nameFuzzer
        , -- Wildcard
          Fuzz.constant ( B.pAnything, [] )
        ]


{-| Generate a pattern for any type.
-}
patternFuzzerForType : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
patternFuzzerForType tipe =
    case tipe of
        TInt ->
            intPatternFuzzer

        TString ->
            stringPatternFuzzer

        TBool ->
            -- Bool patterns: just use variable or wildcard
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
            -- Fallback
            Fuzz.oneOf
                [ Fuzz.map (\name -> ( B.pVar name, [ ( name, tipe ) ] )) nameFuzzer
                , Fuzz.constant ( B.pAnything, [] )
                ]



-- =============================================================================
-- HELPERS
-- =============================================================================


{-| Sequence a list of fuzzers into a fuzzer of lists.
-}
fuzzSequence : List (Fuzzer a) -> Fuzzer (List a)
fuzzSequence fuzzers =
    case fuzzers of
        [] ->
            Fuzz.constant []

        first :: rest ->
            Fuzz.map2 (::) first (fuzzSequence rest)
