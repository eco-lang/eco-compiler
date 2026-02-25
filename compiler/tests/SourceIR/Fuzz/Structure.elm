module SourceIR.Fuzz.Structure exposing
    ( BinopCategory(..)
    , arityFuzzer
    , binopChainFuzzer
      -- Structural expression fuzzers
    , lambdaExprFuzzer
      -- Binop fuzzers
    , multiBindingLetFuzzer
    , multiBranchCaseFuzzer
    , nestedLetFuzzer
    )

{-| Structural complexity fuzzers.

These fuzzers vary the shape of constructs: number of bindings,
number of branches, nesting depth, etc.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.Data.Name exposing (Name)
import Fuzz exposing (Fuzzer)
import SourceIR.Fuzz.TypedExpr
    exposing
        ( Scope
        , SimpleType(..)
        , addVar
        , decrementDepth
        , exprFuzzerForType
        , nameFuzzer
        , patternFuzzerForType
        , reserveName
        , simpleTypeFuzzer
        , uniqueNameFuzzer
        )



-- =============================================================================
-- COUNT FUZZERS
-- =============================================================================


{-| Fuzzer for number of bindings in a let (1-5, biased toward fewer).
-}
bindingCountFuzzer : Fuzzer Int
bindingCountFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.constant 1 )
        , ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.intRange 4 5 )
        ]


{-| Fuzzer for number of branches in a case (2-4, biased toward fewer).
-}
branchCountFuzzer : Fuzzer Int
branchCountFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.constant 2 )
        , ( 3, Fuzz.constant 3 )
        , ( 2, Fuzz.constant 4 )
        ]


{-| Fuzzer for function arity (1-4, biased toward fewer).
-}
arityFuzzer : Fuzzer Int
arityFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.constant 1 )
        , ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.constant 4 )
        ]


{-| Fuzzer for binop chain length (1-3).
-}
chainLengthFuzzer : Fuzzer Int
chainLengthFuzzer =
    Fuzz.frequency
        [ ( 3, Fuzz.constant 1 )
        , ( 2, Fuzz.constant 2 )
        , ( 1, Fuzz.intRange 3 5 )
        ]



-- =============================================================================
-- MULTI-BINDING LET FUZZER
-- =============================================================================


{-| Generate a let expression with multiple bindings.

In Elm, let bindings are mutually recursive, so we need to:

1.  First generate all the binding names and types
2.  Reserve all names in scope before generating any values
3.  Then generate the value for each binding

-}
multiBindingLetFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
multiBindingLetFuzzer scope resultType =
    bindingCountFuzzer
        |> Fuzz.andThen
            (\count ->
                -- First, generate all binding names and types
                generateBindingNamesAndTypes scope count
                    |> Fuzz.andThen
                        (\bindings ->
                            -- Reserve all names in scope before generating values
                            let
                                scopeWithAllNames =
                                    List.foldl (\( name, _ ) s -> reserveName name s) scope bindings

                                innerScope =
                                    decrementDepth scopeWithAllNames

                                -- Also add all bindings to scope for body (where they're available)
                                bodyScope =
                                    List.foldl (\( name, t ) s -> addVar name t s) scope bindings
                            in
                            -- Generate the value for each binding
                            generateBindingValues innerScope bindings []
                                |> Fuzz.andThen
                                    (\defs ->
                                        exprFuzzerForType bodyScope resultType
                                            |> Fuzz.map (\body -> B.letExpr defs body)
                                    )
                        )
            )


{-| Generate a list of unique binding names and their types.
-}
generateBindingNamesAndTypes : Scope -> Int -> Fuzzer (List ( Name, SimpleType ))
generateBindingNamesAndTypes scope count =
    if count <= 0 then
        Fuzz.constant []

    else
        Fuzz.map2 Tuple.pair (uniqueNameFuzzer scope) simpleTypeFuzzer
            |> Fuzz.andThen
                (\( name, bindingType ) ->
                    generateBindingNamesAndTypes (reserveName name scope) (count - 1)
                        |> Fuzz.map (\rest -> ( name, bindingType ) :: rest)
                )


{-| Generate values for a list of pre-determined binding names and types.
-}
generateBindingValues : Scope -> List ( Name, SimpleType ) -> List Src.Def -> Fuzzer (List Src.Def)
generateBindingValues scope bindings accDefs =
    case bindings of
        [] ->
            Fuzz.constant (List.reverse accDefs)

        ( name, bindingType ) :: restBindings ->
            exprFuzzerForType scope bindingType
                |> Fuzz.andThen
                    (\value ->
                        let
                            def =
                                B.define name [] value
                        in
                        generateBindingValues scope restBindings (def :: accDefs)
                    )



-- =============================================================================
-- MULTI-BRANCH CASE FUZZER
-- =============================================================================


{-| Generate a case expression with multiple branches.
-}
multiBranchCaseFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
multiBranchCaseFuzzer scope subjectType resultType =
    let
        innerScope =
            decrementDepth scope
    in
    Fuzz.map2
        (\subject branches ->
            B.caseExpr subject branches
        )
        (exprFuzzerForType innerScope subjectType)
        (caseBranchesFuzzer innerScope subjectType resultType)


caseBranchesFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer (List ( Src.Pattern, Src.Expr ))
caseBranchesFuzzer scope subjectType resultType =
    branchCountFuzzer
        |> Fuzz.andThen
            (\count ->
                -- Generate count-1 specific patterns, then a catch-all
                let
                    specificCount =
                        max 0 (count - 1)
                in
                Fuzz.map2
                    (\specifics catchAll ->
                        specifics ++ [ catchAll ]
                    )
                    (Fuzz.listOfLength specificCount (specificBranchFuzzer scope subjectType resultType))
                    (catchAllBranchFuzzer scope subjectType resultType)
            )


specificBranchFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, Src.Expr )
specificBranchFuzzer scope subjectType resultType =
    patternFuzzerForType subjectType
        |> Fuzz.andThen
            (\( pattern, bindings ) ->
                let
                    branchScope =
                        List.foldl (\( n, t ) s -> addVar n t s) scope bindings
                in
                exprFuzzerForType (decrementDepth branchScope) resultType
                    |> Fuzz.map (\body -> ( pattern, body ))
            )


catchAllBranchFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, Src.Expr )
catchAllBranchFuzzer scope subjectType resultType =
    Fuzz.oneOf
        [ -- Wildcard
          exprFuzzerForType (decrementDepth scope) resultType
            |> Fuzz.map (\body -> ( B.pAnything, body ))
        , -- Variable binding
          nameFuzzer
            |> Fuzz.andThen
                (\name ->
                    exprFuzzerForType (decrementDepth (addVar name subjectType scope)) resultType
                        |> Fuzz.map (\body -> ( B.pVar name, body ))
                )
        ]



-- =============================================================================
-- NESTED LET FUZZER
-- =============================================================================


{-| Generate nested let expressions.
-}
nestedLetFuzzer : Scope -> SimpleType -> Int -> Fuzzer Src.Expr
nestedLetFuzzer scope resultType nestingLevels =
    if nestingLevels <= 0 then
        exprFuzzerForType scope resultType

    else
        uniqueNameFuzzer scope
            |> Fuzz.andThen
                (\name ->
                    let
                        -- Reserve the name BEFORE generating binding value to prevent shadowing
                        -- in any nested let expressions within the binding value
                        scopeWithReservedName =
                            reserveName name (decrementDepth scope)

                        -- Add the name to scope for the body (where it's available for reference)
                        scopeWithName =
                            addVar name resultType (decrementDepth scope)
                    in
                    Fuzz.map2
                        (\bindingValue innerExpr ->
                            B.letExpr
                                [ B.define name [] bindingValue ]
                                innerExpr
                        )
                        (exprFuzzerForType scopeWithReservedName resultType)
                        (nestedLetFuzzer scopeWithName resultType (nestingLevels - 1))
                )



-- =============================================================================
-- LAMBDA EXPRESSION FUZZER
-- =============================================================================


{-| Generate a lambda expression with multiple parameters.
-}
lambdaExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
lambdaExprFuzzer scope resultType =
    arityFuzzer
        |> Fuzz.andThen
            (\arity ->
                lambdaWithArityFuzzer scope resultType arity
            )


lambdaWithArityFuzzer : Scope -> SimpleType -> Int -> Fuzzer Src.Expr
lambdaWithArityFuzzer scope resultType arity =
    -- Generate params sequentially to ensure unique names
    generateLambdaParams scope arity
        |> Fuzz.andThen
            (\( patterns, bindings ) ->
                let
                    bodyScope =
                        List.foldl (\( n, t ) s -> addVar n t s) (decrementDepth scope) bindings
                in
                exprFuzzerForType bodyScope resultType
                    |> Fuzz.map (\body -> B.lambdaExpr patterns body)
            )


{-| Generate lambda parameters sequentially to ensure unique names.
-}
generateLambdaParams : Scope -> Int -> Fuzzer ( List Src.Pattern, List ( Name, SimpleType ) )
generateLambdaParams scope arity =
    generateLambdaParamsHelper scope arity [] []


generateLambdaParamsHelper : Scope -> Int -> List Src.Pattern -> List ( Name, SimpleType ) -> Fuzzer ( List Src.Pattern, List ( Name, SimpleType ) )
generateLambdaParamsHelper scope remaining accPatterns accBindings =
    if remaining <= 0 then
        Fuzz.constant ( List.reverse accPatterns, List.reverse accBindings )

    else
        paramFuzzer scope
            |> Fuzz.andThen
                (\( pattern, bindings ) ->
                    let
                        -- Reserve all names from this parameter for subsequent parameters
                        newScope =
                            List.foldl (\( n, _ ) s -> reserveName n s) scope bindings
                    in
                    generateLambdaParamsHelper newScope (remaining - 1) (pattern :: accPatterns) (bindings ++ accBindings)
                )


paramFuzzer : Scope -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
paramFuzzer scope =
    simpleTypeFuzzer
        |> Fuzz.andThen
            (\paramType ->
                Fuzz.oneOf
                    [ uniqueNameFuzzer scope
                        |> Fuzz.map (\name -> ( B.pVar name, [ ( name, paramType ) ] ))
                    , Fuzz.constant ( B.pAnything, [] )
                    ]
            )



-- =============================================================================
-- BINOP CHAIN FUZZER
-- =============================================================================


{-| Categories of binary operators.
-}
type BinopCategory
    = Arithmetic
    | Boolean
    | Append


{-| Generate a chain of binary operators.
-}
binopChainFuzzer : Scope -> BinopCategory -> Fuzzer Src.Expr
binopChainFuzzer scope category =
    let
        -- Comparison and Equality operators are non-associative in Elm.
        -- Chaining them (e.g., `a < b < c`) is a compile error.
        -- Boolean and Append are limited to length 1 to avoid deep nesting
        -- that causes stack overflow in the type checker.
        -- Arithmetic can be chained normally.
        lengthFuzzer =
            case category of
                Boolean ->
                    Fuzz.constant 2

                Append ->
                    Fuzz.constant 2

                Arithmetic ->
                    chainLengthFuzzer
    in
    lengthFuzzer
        |> Fuzz.andThen
            (\length ->
                binopChainFuzzerN scope category length
            )


binopChainFuzzerN : Scope -> BinopCategory -> Int -> Fuzzer Src.Expr
binopChainFuzzerN scope category length =
    let
        ( operandType, operators ) =
            categoryInfo category

        innerScope =
            decrementDepth scope
    in
    Fuzz.map2
        (\ops final ->
            B.binopsExpr ops final
        )
        (Fuzz.listOfLength length
            (Fuzz.map2 Tuple.pair
                (exprFuzzerForType innerScope operandType)
                (Fuzz.oneOfValues operators)
            )
        )
        (exprFuzzerForType innerScope operandType)


categoryInfo : BinopCategory -> ( SimpleType, List String )
categoryInfo category =
    case category of
        Arithmetic ->
            ( TInt, [ "+", "-", "*" ] )

        Boolean ->
            ( TBool, [ "&&", "||" ] )

        Append ->
            ( TString, [ "++" ] )
