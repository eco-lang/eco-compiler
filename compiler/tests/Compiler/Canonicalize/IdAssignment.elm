module Compiler.Canonicalize.IdAssignment exposing
    ( expectUniqueIds
    , expectUniqueIdsCanonical
    )

{-| Shared test infrastructure for canonicalization ID testing.

This module provides test verification functions that check canonicalization
ID uniqueness.

For Source AST builders, use Compiler.AST.SourceBuilder.
For Canonical AST builders, use Compiler.AST.CanonicalBuilder.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Data.Map as Dict exposing (Dict)
import Expect
import Set



-- ============================================================================
-- TEST INFRASTRUCTURE
-- ============================================================================


{-| Main test expectation: canonicalize the module and verify all IDs are unique.

This function:

1.  Runs the canonicalizer on the source module
2.  Collects all expression IDs and pattern IDs from the result
3.  Verifies that all IDs are positive
4.  Verifies that all expression IDs are unique
5.  Verifies that all pattern IDs are unique
6.  Verifies that expression and pattern IDs are disjoint

-}
expectUniqueIds : Src.Module -> Expect.Expectation
expectUniqueIds modul =
    let
        result =
            Canonicalize.canonicalize ("eco", "example") Basic.testIfaces modul
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                errorCount =
                    List.length errorList

                firstError =
                    List.head errorList
                        |> Maybe.map errorToString
                        |> Maybe.withDefault "unknown"
            in
            Expect.fail
                ("Canonicalization failed with "
                    ++ String.fromInt errorCount
                    ++ " error(s): "
                    ++ firstError
                )

        ( _, Ok canModule ) ->
            let
                -- Collect IDs as lists to detect duplicates
                ( exprIdsList, patternIdsList ) =
                    collectModuleIdsAsList canModule

                allIdsList =
                    exprIdsList ++ patternIdsList

                -- Find duplicates in expression IDs
                exprDuplicates =
                    findDuplicates exprIdsList

                -- Find duplicates in pattern IDs
                patternDuplicates =
                    findDuplicates patternIdsList

                -- Find overlap between expression and pattern IDs
                exprIdsSet =
                    Set.fromList exprIdsList

                patternIdsSet =
                    Set.fromList patternIdsList

                overlap =
                    Set.toList (Set.intersect exprIdsSet patternIdsSet)

                -- Find negative IDs
                negativeIds =
                    List.filter (\id -> id < 0) allIdsList
            in
            if not (List.isEmpty negativeIds) then
                Expect.fail
                    ("Found negative IDs: "
                        ++ String.join ", " (List.map String.fromInt negativeIds)
                    )

            else if not (List.isEmpty exprDuplicates) then
                Expect.fail
                    ("Duplicate expression IDs found: "
                        ++ String.join ", " (List.map String.fromInt exprDuplicates)
                    )

            else if not (List.isEmpty patternDuplicates) then
                Expect.fail
                    ("Duplicate pattern IDs found: "
                        ++ String.join ", " (List.map String.fromInt patternDuplicates)
                    )

            else if not (List.isEmpty overlap) then
                Expect.fail
                    ("Expression and pattern IDs overlap: "
                        ++ String.join ", " (List.map String.fromInt overlap)
                    )

            else
                Expect.pass


{-| Find duplicate values in a list. Returns the values that appear more than once.
-}
findDuplicates : List Int -> List Int
findDuplicates ids =
    let
        countOccurrences =
            List.foldl
                (\id acc ->
                    Dict.update identity
                        id
                        (\maybeCount ->
                            case maybeCount of
                                Nothing ->
                                    Just 1

                                Just n ->
                                    Just (n + 1)
                        )
                        acc
                )
                Dict.empty

        counts =
            countOccurrences ids
    in
    Dict.foldl compare
        (\id count acc ->
            if count > 1 then
                id :: acc

            else
                acc
        )
        []
        counts


{-| Convert a canonicalization error to a string for debugging.
-}
errorToString : CanError.Error -> String
errorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundBinop _ name _ ->
            "NotFoundBinop: " ++ name

        CanError.RecursiveLet (A.At _ name) _ ->
            "RecursiveLet: " ++ name

        CanError.NotFoundType _ maybeModule name _ ->
            "NotFoundType: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundVariant _ maybeModule name _ ->
            "NotFoundVariant: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        _ ->
            "Other error"


{-| Collect all expression and pattern IDs from a canonical module as lists.
This preserves duplicates so we can detect and report them.
-}
collectModuleIdsAsList : Can.Module -> ( List Int, List Int )
collectModuleIdsAsList (Can.Module { decls }) =
    collectDeclsIdsAsList decls


{-| Collect IDs from declarations as lists.
-}
collectDeclsIdsAsList : Can.Decls -> ( List Int, List Int )
collectDeclsIdsAsList decls =
    case decls of
        Can.Declare def rest ->
            let
                ( exprIds, patternIds ) =
                    collectDefIdsAsList def

                ( restExprIds, restPatternIds ) =
                    collectDeclsIdsAsList rest
            in
            ( exprIds ++ restExprIds, patternIds ++ restPatternIds )

        Can.DeclareRec def defs rest ->
            let
                ( defExprIds, defPatternIds ) =
                    collectDefIdsAsList def

                defsIds =
                    List.foldl
                        (\d ( eAcc, pAcc ) ->
                            let
                                ( e, p ) =
                                    collectDefIdsAsList d
                            in
                            ( e ++ eAcc, p ++ pAcc )
                        )
                        ( defExprIds, defPatternIds )
                        defs

                ( restExprIds, restPatternIds ) =
                    collectDeclsIdsAsList rest
            in
            ( Tuple.first defsIds ++ restExprIds
            , Tuple.second defsIds ++ restPatternIds
            )

        Can.SaveTheEnvironment ->
            ( [], [] )


{-| Collect IDs from a definition as lists.
-}
collectDefIdsAsList : Can.Def -> ( List Int, List Int )
collectDefIdsAsList def =
    case def of
        Can.Def _ patterns expr ->
            let
                patternIds =
                    List.concatMap collectPatternIdsAsList patterns
            in
            ( collectExprIdsAsList expr, patternIds )

        Can.TypedDef _ _ patternsWithTypes expr _ ->
            let
                patternIds =
                    List.concatMap (\( p, _ ) -> collectPatternIdsAsList p) patternsWithTypes
            in
            ( collectExprIdsAsList expr, patternIds )


{-| Collect all expression IDs from an expression as a list (recursively).
-}
collectExprIdsAsList : Can.Expr -> List Int
collectExprIdsAsList (A.At _ { id, node }) =
    id :: collectExprNodeIdsAsList node


{-| Collect expression IDs from an expression node as a list.
-}
collectExprNodeIdsAsList : Can.Expr_ -> List Int
collectExprNodeIdsAsList node =
    case node of
        Can.VarLocal _ ->
            []

        Can.VarTopLevel _ _ ->
            []

        Can.VarKernel _ _ ->
            []

        Can.VarForeign _ _ _ ->
            []

        Can.VarCtor _ _ _ _ _ ->
            []

        Can.VarDebug _ _ _ ->
            []

        Can.VarOperator _ _ _ _ ->
            []

        Can.Chr _ ->
            []

        Can.Str _ ->
            []

        Can.Int _ ->
            []

        Can.Float _ ->
            []

        Can.List exprs ->
            List.concatMap collectExprIdsAsList exprs

        Can.Negate expr ->
            collectExprIdsAsList expr

        Can.Binop _ _ _ _ left right ->
            collectExprIdsAsList left ++ collectExprIdsAsList right

        Can.Lambda _ body ->
            collectExprIdsAsList body

        Can.Call func args ->
            collectExprIdsAsList func ++ List.concatMap collectExprIdsAsList args

        Can.If branches final ->
            List.concatMap
                (\( cond, then_ ) ->
                    collectExprIdsAsList cond ++ collectExprIdsAsList then_
                )
                branches
                ++ collectExprIdsAsList final

        Can.Let def body ->
            Tuple.first (collectDefIdsAsList def) ++ collectExprIdsAsList body

        Can.LetRec defs body ->
            List.concatMap (\d -> Tuple.first (collectDefIdsAsList d)) defs
                ++ collectExprIdsAsList body

        Can.LetDestruct _ expr body ->
            collectExprIdsAsList expr ++ collectExprIdsAsList body

        Can.Case subject branches ->
            collectExprIdsAsList subject
                ++ List.concatMap
                    (\(Can.CaseBranch _ branchBody) ->
                        collectExprIdsAsList branchBody
                    )
                    branches

        Can.Accessor _ ->
            []

        Can.Access record _ ->
            collectExprIdsAsList record

        Can.Update record fields ->
            collectExprIdsAsList record
                ++ Dict.foldl A.compareLocated
                    (\_ (Can.FieldUpdate _ expr) acc -> collectExprIdsAsList expr ++ acc)
                    []
                    fields

        Can.Record fields ->
            Dict.foldl A.compareLocated (\_ expr acc -> collectExprIdsAsList expr ++ acc) [] fields

        Can.Unit ->
            []

        Can.Tuple a b rest ->
            collectExprIdsAsList a
                ++ collectExprIdsAsList b
                ++ List.concatMap collectExprIdsAsList rest

        Can.Shader _ _ ->
            []


{-| Collect all pattern IDs from a pattern as a list (recursively).
-}
collectPatternIdsAsList : Can.Pattern -> List Int
collectPatternIdsAsList (A.At _ { id, node }) =
    id :: collectPatternNodeIdsAsList node


{-| Collect pattern IDs from a pattern node as a list.
-}
collectPatternNodeIdsAsList : Can.Pattern_ -> List Int
collectPatternNodeIdsAsList node =
    case node of
        Can.PAnything ->
            []

        Can.PVar _ ->
            []

        Can.PRecord _ ->
            []

        Can.PAlias pattern _ ->
            collectPatternIdsAsList pattern

        Can.PUnit ->
            []

        Can.PTuple a b rest ->
            collectPatternIdsAsList a
                ++ collectPatternIdsAsList b
                ++ List.concatMap collectPatternIdsAsList rest

        Can.PList patterns ->
            List.concatMap collectPatternIdsAsList patterns

        Can.PCons head tail ->
            collectPatternIdsAsList head ++ collectPatternIdsAsList tail

        Can.PBool _ _ ->
            []

        Can.PChr _ ->
            []

        Can.PStr _ _ ->
            []

        Can.PInt _ ->
            []

        Can.PCtor { args } ->
            List.concatMap (\(Can.PatternCtorArg _ _ p) -> collectPatternIdsAsList p) args



-- ============================================================================
-- CANONICAL MODULE TESTING (for pre-constructed canonical AST)
-- ============================================================================


{-| Verify unique IDs in a pre-constructed canonical module.
This is for testing expressions that can't be created from source AST,
like VarKernel expressions.
-}
expectUniqueIdsCanonical : Can.Module -> Expect.Expectation
expectUniqueIdsCanonical canModule =
    let
        -- Collect IDs as lists to detect duplicates
        ( exprIdsList, patternIdsList ) =
            collectModuleIdsAsList canModule

        allIdsList =
            exprIdsList ++ patternIdsList

        -- Find duplicates in expression IDs
        exprDuplicates =
            findDuplicates exprIdsList

        -- Find duplicates in pattern IDs
        patternDuplicates =
            findDuplicates patternIdsList

        -- Find overlap between expression and pattern IDs
        exprIdsSet =
            Set.fromList exprIdsList

        patternIdsSet =
            Set.fromList patternIdsList

        overlap =
            Set.toList (Set.intersect exprIdsSet patternIdsSet)

        -- Find negative IDs
        negativeIds =
            List.filter (\id -> id < 0) allIdsList
    in
    if not (List.isEmpty negativeIds) then
        Expect.fail
            ("Found negative IDs: "
                ++ String.join ", " (List.map String.fromInt negativeIds)
            )

    else if not (List.isEmpty exprDuplicates) then
        Expect.fail
            ("Duplicate expression IDs found: "
                ++ String.join ", " (List.map String.fromInt exprDuplicates)
            )

    else if not (List.isEmpty patternDuplicates) then
        Expect.fail
            ("Duplicate pattern IDs found: "
                ++ String.join ", " (List.map String.fromInt patternDuplicates)
            )

    else if not (List.isEmpty overlap) then
        Expect.fail
            ("Expression and pattern IDs overlap: "
                ++ String.join ", " (List.map String.fromInt overlap)
            )

    else
        Expect.pass
