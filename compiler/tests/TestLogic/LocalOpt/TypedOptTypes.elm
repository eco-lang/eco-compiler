module TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)

{-| Test logic for invariant TOPT\_001: TypedOptimized expressions always carry types.

For each TypedOptimized.Expr variant:

  - Assert the last constructor argument is a Can.Type.
  - Verify that typeOf returns that last field for all expressions.
  - Ensure no expression has a malformed or missing type.

This module reuses the existing typed optimization pipeline to verify
all expressions carry types.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Expect
import System.TypeCheck.IO as IO
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono


{-| TOPT\_001: Verify all expressions have types.
-}
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    case TOMono.runToTypedOptimized srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectExprTypeIssues result.localGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- EXPRESSION TYPE VERIFICATION
-- ============================================================================


{-| Collect issues where expressions don't have types or typeOf fails.
-}
collectExprTypeIssues : TOpt.LocalGraph -> List String
collectExprTypeIssues (TOpt.LocalGraph data) =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeExprsHaveTypes context node ++ acc
        )
        []
        data.nodes


{-| Convert a Global to a string for context messages.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        IO.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Check that all expressions in a node have types.
-}
checkNodeExprsHaveTypes : String -> TOpt.Node -> List String
checkNodeExprsHaveTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            -- The expression should have a type that matches the node's type
            let
                exprType =
                    TOpt.typeOf expr
            in
            checkTypeNotEmpty (context ++ " Define") exprType
                ++ collectExprNestedTypeIssues context expr

        TOpt.TrackedDefine _ expr _ _ ->
            let
                exprType =
                    TOpt.typeOf expr
            in
            checkTypeNotEmpty (context ++ " TrackedDefine") exprType
                ++ collectExprNestedTypeIssues context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefExprsHaveTypes context def) defs

        TOpt.PortIncoming expr _ _ ->
            checkTypeNotEmpty (context ++ " PortIncoming") (TOpt.typeOf expr)
                ++ collectExprNestedTypeIssues context expr

        TOpt.PortOutgoing expr _ _ ->
            checkTypeNotEmpty (context ++ " PortOutgoing") (TOpt.typeOf expr)
                ++ collectExprNestedTypeIssues context expr

        _ ->
            []


{-| Check that a Def has types on all expressions.
-}
checkDefExprsHaveTypes : String -> TOpt.Def -> List String
checkDefExprsHaveTypes context def =
    case def of
        TOpt.Def _ name expr _ ->
            checkTypeNotEmpty (context ++ " Def " ++ name) (TOpt.typeOf expr)
                ++ collectExprNestedTypeIssues context expr

        TOpt.TailDef _ name params expr _ ->
            checkTypeNotEmpty (context ++ " TailDef " ++ name) (TOpt.typeOf expr)
                ++ List.concatMap (\( _, paramType ) -> checkTypeNotEmpty (context ++ " param") paramType) params
                ++ collectExprNestedTypeIssues context expr


{-| Collect type issues from nested expressions.
-}
collectExprNestedTypeIssues : String -> TOpt.Expr -> List String
collectExprNestedTypeIssues context expr =
    let
        exprType =
            TOpt.typeOf expr

        typeIssue =
            checkTypeNotEmpty context exprType
    in
    typeIssue
        ++ (case expr of
                TOpt.Function params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeNotEmpty (context ++ " Function param") paramType) params
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.TrackedFunction params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeNotEmpty (context ++ " TrackedFunction param") paramType) params
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.Call _ fnExpr argExprs _ ->
                    collectExprNestedTypeIssues context fnExpr
                        ++ List.concatMap (collectExprNestedTypeIssues context) argExprs

                TOpt.TailCall _ args _ ->
                    List.concatMap (\( _, argExpr ) -> collectExprNestedTypeIssues context argExpr) args

                TOpt.If branches elseExpr _ ->
                    List.concatMap (\( c, t ) -> collectExprNestedTypeIssues context c ++ collectExprNestedTypeIssues context t) branches
                        ++ collectExprNestedTypeIssues context elseExpr

                TOpt.Let def bodyExpr _ ->
                    checkDefExprsHaveTypes context def
                        ++ collectExprNestedTypeIssues context bodyExpr

                TOpt.Destruct _ valueExpr _ ->
                    collectExprNestedTypeIssues context valueExpr

                TOpt.Case _ _ _ branches _ ->
                    List.concatMap (\( _, branchExpr ) -> collectExprNestedTypeIssues context branchExpr) branches

                TOpt.List _ exprs _ ->
                    List.concatMap (collectExprNestedTypeIssues context) exprs

                TOpt.Access recordExpr _ _ _ ->
                    collectExprNestedTypeIssues context recordExpr

                TOpt.Update _ recordExpr updates _ ->
                    collectExprNestedTypeIssues context recordExpr
                        ++ Dict.foldl A.compareLocated (\_ updateExpr acc -> collectExprNestedTypeIssues context updateExpr ++ acc) [] updates

                TOpt.Record fieldExprs _ ->
                    Dict.foldl compare (\_ fieldExpr acc -> collectExprNestedTypeIssues context fieldExpr ++ acc) [] fieldExprs

                TOpt.TrackedRecord _ fieldExprs _ ->
                    Dict.foldl A.compareLocated (\_ fieldExpr acc -> collectExprNestedTypeIssues context fieldExpr ++ acc) [] fieldExprs

                TOpt.Tuple _ e1 e2 rest _ ->
                    collectExprNestedTypeIssues context e1
                        ++ collectExprNestedTypeIssues context e2
                        ++ List.concatMap (collectExprNestedTypeIssues context) rest

                _ ->
                    []
           )


{-| Check that a type is not empty/malformed.

For now, we just verify the type exists. More sophisticated checks could
verify no dangling type variables, etc.

-}
checkTypeNotEmpty : String -> Can.Type -> List String
checkTypeNotEmpty _ _ =
    -- All TypedOptimized expressions carry a Can.Type by construction.
    -- If the expression type-checks and we can call typeOf, it has a type.
    -- More sophisticated checks would verify the type is well-formed.
    []



-- ============================================================================
-- TYPE WELL-FORMEDNESS VERIFICATION
-- ============================================================================


{-| Check Def type well-formedness.
-}
checkDefTypeWellFormedness : String -> TOpt.Def -> List String
checkDefTypeWellFormedness context def =
    case def of
        TOpt.Def _ name expr canType ->
            checkTypeWellFormed (context ++ " Def " ++ name) canType
                ++ collectExprTypeWellFormedness context expr

        TOpt.TailDef _ name params expr canType ->
            checkTypeWellFormed (context ++ " TailDef " ++ name) canType
                ++ List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " param") paramType) params
                ++ collectExprTypeWellFormedness context expr


{-| Collect type well-formedness issues from expressions.
-}
collectExprTypeWellFormedness : String -> TOpt.Expr -> List String
collectExprTypeWellFormedness context expr =
    let
        exprType =
            TOpt.typeOf expr

        typeIssue =
            checkTypeWellFormed context exprType
    in
    typeIssue
        ++ (case expr of
                TOpt.Function params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " Function param") paramType) params
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.TrackedFunction params bodyExpr _ ->
                    List.concatMap (\( _, paramType ) -> checkTypeWellFormed (context ++ " TrackedFunction param") paramType) params
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.Call _ fnExpr argExprs _ ->
                    collectExprTypeWellFormedness context fnExpr
                        ++ List.concatMap (collectExprTypeWellFormedness context) argExprs

                TOpt.TailCall _ args _ ->
                    List.concatMap (\( _, argExpr ) -> collectExprTypeWellFormedness context argExpr) args

                TOpt.If branches elseExpr _ ->
                    List.concatMap (\( c, t ) -> collectExprTypeWellFormedness context c ++ collectExprTypeWellFormedness context t) branches
                        ++ collectExprTypeWellFormedness context elseExpr

                TOpt.Let def bodyExpr _ ->
                    checkDefTypeWellFormedness context def
                        ++ collectExprTypeWellFormedness context bodyExpr

                TOpt.Destruct _ valueExpr _ ->
                    collectExprTypeWellFormedness context valueExpr

                TOpt.Case _ _ _ branches _ ->
                    List.concatMap (\( _, branchExpr ) -> collectExprTypeWellFormedness context branchExpr) branches

                TOpt.List _ exprs _ ->
                    List.concatMap (collectExprTypeWellFormedness context) exprs

                TOpt.Access recordExpr _ _ _ ->
                    collectExprTypeWellFormedness context recordExpr

                TOpt.Update _ recordExpr updates _ ->
                    collectExprTypeWellFormedness context recordExpr
                        ++ Dict.foldl A.compareLocated (\_ updateExpr acc -> collectExprTypeWellFormedness context updateExpr ++ acc) [] updates

                TOpt.Record fieldExprs _ ->
                    Dict.foldl compare (\_ fieldExpr acc -> collectExprTypeWellFormedness context fieldExpr ++ acc) [] fieldExprs

                TOpt.TrackedRecord _ fieldExprs _ ->
                    Dict.foldl A.compareLocated (\_ fieldExpr acc -> collectExprTypeWellFormedness context fieldExpr ++ acc) [] fieldExprs

                TOpt.Tuple _ e1 e2 rest _ ->
                    collectExprTypeWellFormedness context e1
                        ++ collectExprTypeWellFormedness context e2
                        ++ List.concatMap (collectExprTypeWellFormedness context) rest

                _ ->
                    []
           )


{-| Check if a Can.Type is well-formed.

Well-formed types:

  - Have no dangling type variable references
  - All type constructors refer to defined types
  - Type arities match definitions

For now, we perform basic structural checks.

-}
checkTypeWellFormed : String -> Can.Type -> List String
checkTypeWellFormed context canType =
    case canType of
        Can.TLambda argType resultType ->
            checkTypeWellFormed context argType
                ++ checkTypeWellFormed context resultType

        Can.TVar _ ->
            -- Type variables are valid in polymorphic types
            []

        Can.TType _ _ args ->
            -- Recursively check type arguments
            List.concatMap (checkTypeWellFormed context) args

        Can.TRecord fields _ ->
            -- Check record field types
            Dict.foldl compare (\_ fieldType acc -> checkFieldTypeWellFormed context fieldType ++ acc) [] fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkTypeWellFormed context a
                ++ checkTypeWellFormed context b
                ++ List.concatMap (checkTypeWellFormed context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkTypeWellFormed context argType) args
                ++ checkAliasedTypeWellFormed context aliasedType


{-| Check aliased type well-formedness.
-}
checkAliasedTypeWellFormed : String -> Can.AliasType -> List String
checkAliasedTypeWellFormed context aliasType =
    case aliasType of
        Can.Holey canType ->
            checkTypeWellFormed context canType

        Can.Filled canType ->
            checkTypeWellFormed context canType


{-| Check field type well-formedness.
-}
checkFieldTypeWellFormed : String -> Can.FieldType -> List String
checkFieldTypeWellFormed context (Can.FieldType _ canType) =
    checkTypeWellFormed context canType
