module TestLogic.Type.PostSolve.PostSolveInvariantHelpers exposing
    ( ExprNode
    , walkExprs
    , isGroupBExprNode
    , isVarKernel
    , freeTypeVars
    , collectExprIds
    , collectKernelExprIds
    )

{-| Shared helpers for POST\_001 and POST\_003 invariant tests.

This module provides AST traversal utilities for classifying expressions
and extracting type information needed by the synthetic provenance tests.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Data.Set as EverySet exposing (EverySet)


{-| An expression node with its ID and the Expr\_ payload.
-}
type alias ExprNode =
    { id : Int
    , node : Can.Expr_
    }


{-| Walk all expressions in a module and collect (id, Expr\_) pairs.
-}
walkExprs : Can.Module -> List ExprNode
walkExprs (Can.Module modData) =
    walkDecls modData.decls []


walkDecls : Can.Decls -> List ExprNode -> List ExprNode
walkDecls decls acc =
    case decls of
        Can.Declare def rest ->
            walkDecls rest (walkDef def acc)

        Can.DeclareRec def defs rest ->
            let
                acc1 =
                    walkDef def acc

                acc2 =
                    List.foldl (\d a -> walkDef d a) acc1 defs
            in
            walkDecls rest acc2

        Can.SaveTheEnvironment ->
            acc


walkDef : Can.Def -> List ExprNode -> List ExprNode
walkDef def acc =
    case def of
        Can.Def _ patterns expr ->
            let
                acc1 =
                    List.foldl walkPattern acc patterns
            in
            walkExpr expr acc1

        Can.TypedDef _ _ patternTypes expr _ ->
            let
                acc1 =
                    List.foldl (\( p, _ ) a -> walkPattern p a) acc patternTypes
            in
            walkExpr expr acc1


walkExpr : Can.Expr -> List ExprNode -> List ExprNode
walkExpr (A.At _ exprInfo) acc =
    let
        -- Record this expression node
        thisNode =
            { id = exprInfo.id, node = exprInfo.node }

        -- Walk children based on expression type
        childAcc =
            case exprInfo.node of
                Can.VarLocal _ ->
                    acc

                Can.VarTopLevel _ _ ->
                    acc

                Can.VarKernel _ _ ->
                    acc

                Can.VarForeign _ _ _ ->
                    acc

                Can.VarCtor _ _ _ _ _ ->
                    acc

                Can.VarDebug _ _ _ ->
                    acc

                Can.VarOperator _ _ _ _ ->
                    acc

                Can.Chr _ ->
                    acc

                Can.Str _ ->
                    acc

                Can.Int _ ->
                    acc

                Can.Float _ ->
                    acc

                Can.List exprs ->
                    List.foldl walkExpr acc exprs

                Can.Negate expr ->
                    walkExpr expr acc

                Can.Binop _ _ _ _ left right ->
                    walkExpr right (walkExpr left acc)

                Can.Lambda patterns body ->
                    let
                        pAcc =
                            List.foldl walkPattern acc patterns
                    in
                    walkExpr body pAcc

                Can.Call fn args ->
                    List.foldl walkExpr (walkExpr fn acc) args

                Can.If branches final ->
                    let
                        branchAcc =
                            List.foldl
                                (\( cond, branch ) a ->
                                    walkExpr branch (walkExpr cond a)
                                )
                                acc
                                branches
                    in
                    walkExpr final branchAcc

                Can.Let def body ->
                    walkExpr body (walkDef def acc)

                Can.LetRec defs body ->
                    let
                        defAcc =
                            List.foldl walkDef acc defs
                    in
                    walkExpr body defAcc

                Can.LetDestruct pattern valExpr body ->
                    let
                        pAcc =
                            walkPattern pattern acc

                        vAcc =
                            walkExpr valExpr pAcc
                    in
                    walkExpr body vAcc

                Can.Case scrutinee branches ->
                    let
                        scrAcc =
                            walkExpr scrutinee acc

                        branchAcc =
                            List.foldl walkBranch scrAcc branches
                    in
                    branchAcc

                Can.Accessor _ ->
                    acc

                Can.Access expr _ ->
                    walkExpr expr acc

                Can.Update expr fields ->
                    let
                        fAcc =
                            Dict.foldl A.compareLocated
                                (\_ (Can.FieldUpdate _ e) a -> walkExpr e a)
                                acc
                                fields
                    in
                    walkExpr expr fAcc

                Can.Record fields ->
                    Dict.foldl A.compareLocated
                        (\_ e a -> walkExpr e a)
                        acc
                        fields

                Can.Unit ->
                    acc

                Can.Tuple a b cs ->
                    List.foldl walkExpr
                        (walkExpr b (walkExpr a acc))
                        cs

                Can.Shader _ _ ->
                    acc
    in
    thisNode :: childAcc


walkBranch : Can.CaseBranch -> List ExprNode -> List ExprNode
walkBranch (Can.CaseBranch pattern body) acc =
    walkExpr body (walkPattern pattern acc)


walkPattern : Can.Pattern -> List ExprNode -> List ExprNode
walkPattern (A.At _ patInfo) acc =
    -- Patterns don't contribute to expression nodes, but walk their subpatterns
    case patInfo.node of
        Can.PAnything ->
            acc

        Can.PVar _ ->
            acc

        Can.PRecord _ ->
            acc

        Can.PAlias subPat _ ->
            walkPattern subPat acc

        Can.PUnit ->
            acc

        Can.PTuple a b cs ->
            List.foldl walkPattern
                (walkPattern b (walkPattern a acc))
                cs

        Can.PList patterns ->
            List.foldl walkPattern acc patterns

        Can.PCons head tail ->
            walkPattern tail (walkPattern head acc)

        Can.PBool _ _ ->
            acc

        Can.PChr _ ->
            acc

        Can.PStr _ _ ->
            acc

        Can.PInt _ ->
            acc

        Can.PCtor ctorInfo ->
            List.foldl
                (\(Can.PatternCtorArg _ _ p) a -> walkPattern p a)
                acc
                ctorInfo.args


{-| Check if an expression node is a Group B expression.

Group B expressions are those where the constraint generator allocates
a synthetic placeholder variable that PostSolve must fill:

  - Str, Chr, Float, Unit (literals)
  - List, Tuple, Record (structural)
  - Lambda, Accessor (function-like)
  - Let, LetRec, LetDestruct (binding forms)

-}
isGroupBExprNode : Can.Expr_ -> Bool
isGroupBExprNode node =
    case node of
        Can.Str _ ->
            True

        Can.Chr _ ->
            True

        Can.Float _ ->
            True

        Can.Unit ->
            True

        Can.List _ ->
            True

        Can.Tuple _ _ _ ->
            True

        Can.Record _ ->
            True

        Can.Lambda _ _ ->
            True

        Can.Accessor _ ->
            True

        Can.Let _ _ ->
            True

        Can.LetRec _ _ ->
            True

        Can.LetDestruct _ _ _ ->
            True

        _ ->
            False


{-| Check if expression is VarKernel.
-}
isVarKernel : Can.Expr_ -> Bool
isVarKernel node =
    case node of
        Can.VarKernel _ _ ->
            True

        _ ->
            False


{-| Collect all expression IDs from a module.
-}
collectExprIds : Can.Module -> EverySet Int Int
collectExprIds canModule =
    walkExprs canModule
        |> List.map .id
        |> EverySet.fromList identity


{-| Collect expression IDs that are VarKernel nodes.
-}
collectKernelExprIds : Can.Module -> EverySet Int Int
collectKernelExprIds canModule =
    walkExprs canModule
        |> List.filter (\n -> isVarKernel n.node)
        |> List.map .id
        |> EverySet.fromList identity


{-| Extract all free type variable names from a type.

(Re-implementation to avoid circular dependencies.)

-}
freeTypeVars : Can.Type -> EverySet String String
freeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            EverySet.insert identity name EverySet.empty

        Can.TType _ _ args ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                EverySet.empty
                args

        Can.TLambda a b ->
            EverySet.union (freeTypeVars a) (freeTypeVars b)

        Can.TRecord fields ext ->
            let
                extVars =
                    case ext of
                        Just name ->
                            EverySet.insert identity name EverySet.empty

                        Nothing ->
                            EverySet.empty

                fieldVars =
                    Dict.foldl compare
                        (\_ (Can.FieldType _ fieldType) acc ->
                            EverySet.union acc (freeTypeVars fieldType)
                        )
                        EverySet.empty
                        fields
            in
            EverySet.union extVars fieldVars

        Can.TUnit ->
            EverySet.empty

        Can.TTuple a b cs ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                (EverySet.union (freeTypeVars a) (freeTypeVars b))
                cs

        Can.TAlias _ _ args aliasType ->
            let
                argVars =
                    List.foldl
                        (\( _, t ) acc -> EverySet.union acc (freeTypeVars t))
                        EverySet.empty
                        args

                aliasVars =
                    case aliasType of
                        Can.Holey t ->
                            freeTypeVars t

                        Can.Filled t ->
                            freeTypeVars t
            in
            EverySet.union argVars aliasVars
