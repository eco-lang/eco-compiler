module Compiler.TypedCanonical.Build exposing
    ( fromCanonical
    , toTypedExpr
    )

{-| Build TypedCanonical AST from Canonical AST and type information.

This module transforms the canonical AST into a typed canonical AST by
annotating each expression with its inferred type from the type checker.


# Module Transformation

@docs fromCanonical


# Expression Transformation

@docs toTypedExpr

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (Decls(..), Def(..), ExprTypes, ExprVars, Module(..))
import Compiler.Reporting.Annotation as A
import Utils.Crash exposing (crash)



-- ====== MODULE CONSTRUCTION ======


{-| Build a TypedCanonical module from a canonical module and expression type map.

Takes a fully canonicalized module and a dictionary mapping expression IDs to
their inferred types (as produced by `Solve.runWithExprVars`). Returns a
`TypedCanonical.Module` where every expression is paired with its type.

-}
fromCanonical : Can.Module -> ExprTypes -> ExprVars -> Module
fromCanonical (Can.Module canData) exprTypes exprVars =
    let
        typedDecls =
            toTypedDecls exprTypes exprVars canData.decls
    in
    Module
        { name = canData.name
        , exports = canData.exports
        , docs = canData.docs
        , decls = typedDecls
        , unions = canData.unions
        , aliases = canData.aliases
        , binops = canData.binops
        , effects = canData.effects
        }



-- ====== DECLS TRANSFORMATION ======


toTypedDecls : ExprTypes -> ExprVars -> Can.Decls -> Decls
toTypedDecls exprTypes exprVars decls =
    case decls of
        Can.Declare def rest ->
            Declare (toTypedDef exprTypes exprVars def)
                (toTypedDecls exprTypes exprVars rest)

        Can.DeclareRec def defs rest ->
            DeclareRec
                (toTypedDef exprTypes exprVars def)
                (List.map (toTypedDef exprTypes exprVars) defs)
                (toTypedDecls exprTypes exprVars rest)

        Can.SaveTheEnvironment ->
            SaveTheEnvironment



-- ====== DEF TRANSFORMATION ======


toTypedDef : ExprTypes -> ExprVars -> Can.Def -> Def
toTypedDef exprTypes exprVars def =
    case def of
        Can.Def name args body ->
            Def name args (toTypedExpr exprTypes exprVars body)

        Can.TypedDef name freeVars typedArgs body resultType ->
            TypedDef name freeVars typedArgs (toTypedExpr exprTypes exprVars body) resultType



-- ====== EXPRESSION TRANSFORMATION ======


{-| Convert a canonical expression to a typed expression using the type map.

This is the key function for accessing types of subexpressions during
optimization. When the optimizer encounters a `Can.Expr` child (e.g., in
`Can.Lambda args body`), it uses this to wrap it with its type.

Synthetic expressions (id < 0) will crash as they should not exist in valid ASTs.

-}
toTypedExpr : ExprTypes -> ExprVars -> Can.Expr -> TCan.Expr
toTypedExpr exprTypes exprVars (A.At region info) =
    let
        tipe : Can.Type
        tipe =
            case Array.get info.id exprTypes |> Maybe.andThen identity of
                Just t ->
                    t

                Nothing ->
                    -- For expressions with placeholder IDs (-1), crash
                    if info.id < 0 then
                        crash "TypedCanonical.Build.toTypedExpr: placeholder ID"

                    else
                        crash ("Missing type for expr id " ++ String.fromInt info.id)

        tvar =
            Array.get info.id exprVars |> Maybe.andThen identity
    in
    A.At region (TCan.TypedExpr { expr = info.node, tipe = tipe, tvar = tvar })
