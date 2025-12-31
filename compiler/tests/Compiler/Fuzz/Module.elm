module Compiler.Fuzz.Module exposing
    ( complexExprFuzzer
    , mixedContainerFuzzer
    , -- Module fuzzers
      multiDefModuleFuzzer
    )

{-| Module-level fuzzers.

These fuzzers generate complete modules with multiple definitions,
and complex mixed expressions.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.Data.Name exposing (Name)
import Compiler.Fuzz.Structure
    exposing
        ( BinopCategory(..)
        , arityFuzzer
        , binopChainFuzzer
        , multiBindingLetFuzzer
        , multiBranchCaseFuzzer
        , nestedLetFuzzer
        )
import Compiler.Fuzz.TypedExpr as TE
    exposing
        ( Scope
        , SimpleType(..)
        , addVar
        , decrementDepth
        , emptyScope
        , exprFuzzerForType
        , reserveName
        , simpleTypeFuzzer
        , uniqueNameFuzzer
        )
import Fuzz exposing (Fuzzer)



-- =============================================================================
-- DEFINITION COUNT FUZZER
-- =============================================================================


{-| Fuzzer for number of top-level definitions (1-5, biased toward fewer).
-}
defCountFuzzer : Fuzzer Int
defCountFuzzer =
    Fuzz.frequency
        [ ( 2, Fuzz.constant 1 )
        , ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.intRange 4 5 )
        ]



-- =============================================================================
-- MULTI-DEFINITION MODULE FUZZER
-- =============================================================================


{-| Generate a module with multiple top-level definitions.

In Elm, all top-level definitions are mutually recursive, so we need to:

1.  First generate all the top-level names
2.  Reserve all names in scope before generating any bodies
3.  Then generate the body for each definition

This prevents let bindings in bodies from shadowing other top-level names.

-}
multiDefModuleFuzzer : Int -> Fuzzer Src.Module
multiDefModuleFuzzer maxDepth =
    defCountFuzzer
        |> Fuzz.andThen
            (\count ->
                -- First, generate all the top-level names
                generateDefNames (emptyScope maxDepth) count
                    |> Fuzz.andThen
                        (\names ->
                            -- Reserve all names in scope before generating bodies
                            let
                                scopeWithAllNames =
                                    List.foldl reserveName (emptyScope maxDepth) names
                            in
                            -- Generate the body for each definition
                            generateDefsForNames scopeWithAllNames names []
                        )
            )


{-| Generate a list of unique top-level definition names.
-}
generateDefNames : Scope -> Int -> Fuzzer (List Name)
generateDefNames scope count =
    if count <= 0 then
        Fuzz.constant []

    else
        uniqueNameFuzzer scope
            |> Fuzz.andThen
                (\name ->
                    generateDefNames (reserveName name scope) (count - 1)
                        |> Fuzz.map (\rest -> name :: rest)
                )


{-| Generate definitions for a list of pre-determined names.
-}
generateDefsForNames : Scope -> List Name -> List ( Name, List Src.Pattern, Src.Expr ) -> Fuzzer Src.Module
generateDefsForNames scope names accDefs =
    case names of
        [] ->
            Fuzz.constant (B.makeModuleWithDefs "Test" (List.reverse accDefs))

        name :: restNames ->
            topLevelDefBodyFuzzer scope name
                |> Fuzz.andThen
                    (\( args, body ) ->
                        generateDefsForNames scope restNames (( name, args, body ) :: accDefs)
                    )


{-| Generate just the body (and optionally args) for a pre-determined name.
-}
topLevelDefBodyFuzzer : Scope -> Name -> Fuzzer ( List Src.Pattern, Src.Expr )
topLevelDefBodyFuzzer scope name =
    Fuzz.oneOf
        [ -- Simple value definition
          simpleTypeFuzzer
            |> Fuzz.andThen
                (\defType ->
                    exprFuzzerForType (decrementDepth scope) defType
                        |> Fuzz.map (\body -> ( [], body ))
                )
        , -- Function definition
          Fuzz.map2 Tuple.pair simpleTypeFuzzer arityFuzzer
            |> Fuzz.andThen
                (\( returnType, arity ) ->
                    -- Generate params sequentially to ensure unique names
                    generateFunctionParams scope arity
                        |> Fuzz.andThen
                            (\( patterns, bindings ) ->
                                let
                                    bodyScope =
                                        List.foldl (\( n, t ) s -> addVar n t s) (decrementDepth scope) bindings
                                in
                                exprFuzzerForType bodyScope returnType
                                    |> Fuzz.map (\body -> ( patterns, body ))
                            )
                )
        ]


{-| Generate function parameters sequentially to ensure unique names.
-}
generateFunctionParams : Scope -> Int -> Fuzzer ( List Src.Pattern, List ( Name, SimpleType ) )
generateFunctionParams scope arity =
    generateFunctionParamsHelper scope arity [] []


generateFunctionParamsHelper : Scope -> Int -> List Src.Pattern -> List ( Name, SimpleType ) -> Fuzzer ( List Src.Pattern, List ( Name, SimpleType ) )
generateFunctionParamsHelper scope remaining accPatterns accBindings =
    if remaining <= 0 then
        Fuzz.constant ( List.reverse accPatterns, List.reverse accBindings )

    else
        functionParamFuzzer scope
            |> Fuzz.andThen
                (\( pattern, bindings ) ->
                    let
                        -- Reserve all names from this parameter for subsequent parameters
                        newScope =
                            List.foldl (\( n, _ ) s -> reserveName n s) scope bindings
                    in
                    generateFunctionParamsHelper newScope (remaining - 1) (pattern :: accPatterns) (bindings ++ accBindings)
                )


functionParamFuzzer : Scope -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
functionParamFuzzer scope =
    simpleTypeFuzzer
        |> Fuzz.andThen
            (\paramType ->
                uniqueNameFuzzer scope
                    |> Fuzz.map (\name -> ( B.pVar name, [ ( name, paramType ) ] ))
            )



-- =============================================================================
-- MIXED CONTAINER FUZZER
-- =============================================================================


{-| Generate expressions with mixed container types.
-}
mixedContainerFuzzer : Scope -> Fuzzer Src.Expr
mixedContainerFuzzer scope =
    Fuzz.oneOf
        [ -- List of tuples
          TE.listExprFuzzer scope (TTuple TInt TString)
        , -- Tuple of lists
          TE.tupleExprFuzzer scope (TList TInt) (TList TString)
        , -- Record with list field
          TE.recordExprFuzzer scope
            [ ( "items", TList TInt )
            , ( "count", TInt )
            ]
        , -- List of records
          TE.listExprFuzzer scope
            (TRecord [ ( "x", TInt ), ( "y", TInt ) ])
        , -- Nested tuples
          TE.tupleExprFuzzer scope
            (TTuple TInt TInt)
            (TTuple TString TBool)
        , -- 3-tuple with mixed types
          TE.tuple3ExprFuzzer scope TInt TString TBool
        ]



-- =============================================================================
-- COMPLEX EXPRESSION FUZZER
-- =============================================================================


{-| Generate complex expressions combining multiple structural elements.
-}
complexExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
complexExprFuzzer scope resultType =
    if scope.depth <= 0 then
        exprFuzzerForType scope resultType

    else
        Fuzz.frequency
            [ ( 3, Fuzz.constant () |> Fuzz.andThen (\_ -> exprFuzzerForType scope resultType) )
            , ( 2, Fuzz.constant () |> Fuzz.andThen (\_ -> multiBindingLetFuzzer scope resultType) )
            , ( 2, Fuzz.constant () |> Fuzz.andThen (\_ -> multiBranchCaseFuzzer scope TInt resultType) )
            , ( 1, Fuzz.constant () |> Fuzz.andThen (\_ -> nestedLetFuzzer scope resultType 2) )
            , ( 1, Fuzz.constant () |> Fuzz.andThen (\_ -> binopExprForType scope resultType) )
            ]


binopExprForType : Scope -> SimpleType -> Fuzzer Src.Expr
binopExprForType scope resultType =
    case resultType of
        TInt ->
            binopChainFuzzer scope Arithmetic

        TBool ->
            binopChainFuzzer scope Boolean

        TString ->
            binopChainFuzzer scope Append

        _ ->
            exprFuzzerForType scope resultType
