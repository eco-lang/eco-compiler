module Compiler.AST.TypedCanonical exposing
    ( Module(..), ModuleData
    , Expr, Expr_(..)
    , Def(..), Decls(..)
    , ExprTypes, NodeTypes
    , fromCanonical, toTypedExpr
    )

{-| The TypedCanonical AST pairs each canonical expression with its inferred type.

This module provides a typed view of the canonical AST where every expression
carries a `Can.Type` annotation. It is built by zipping the canonical AST with
the expression types produced by the type checker.


# Modules

@docs Module, ModuleData


# Expressions

@docs Expr, Expr_


# Definitions

@docs Def, Decls


# Type Mapping

@docs ExprTypes, NodeTypes


# Construction

@docs fromCanonical, toTypedExpr

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ====== Expressions ======


{-| A typed expression with source location annotation.
-}
type alias Expr =
    A.Located Expr_


{-| A typed expression node containing the original canonical expression and its type.
-}
type Expr_
    = TypedExpr
        { expr : Can.Expr_
        , tipe : Can.Type
        }



-- ====== Definitions ======


{-| A typed definition.

  - `Def` - A definition without a type annotation
  - `TypedDef` - A definition with a type annotation and free type variables

-}
type Def
    = Def (A.Located Name) (List Can.Pattern) Expr
    | TypedDef (A.Located Name) Can.FreeVars (List ( Can.Pattern, Can.Type )) Expr Can.Type


{-| A linked list of typed top-level declarations in a module.

  - `Declare` - A non-recursive definition
  - `DeclareRec` - A group of mutually recursive definitions
  - `SaveTheEnvironment` - Sentinel marking the end of declarations

-}
type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment



-- ====== Modules ======


{-| Internal data for a typed canonical module.
-}
type alias ModuleData =
    { name : IO.Canonical
    , exports : Can.Exports
    , docs : Src.Docs
    , decls : Decls
    , unions : Dict String Name Can.Union
    , aliases : Dict String Name Can.Alias
    , binops : Dict String Name Can.Binop
    , effects : Can.Effects
    }


{-| A typed canonical Elm module.
-}
type Module
    = Module ModuleData



-- ====== Type Mapping ======


{-| Dictionary mapping node IDs (expressions and patterns) to their canonical types.
This is produced by the solver after constraint solving.

This is an alias for `NodeTypes` to maintain backwards compatibility.

-}
type alias ExprTypes =
    Dict Int Int Can.Type


{-| Dictionary mapping node IDs to their canonical types.

Node IDs include both expression IDs and pattern IDs, providing a unified
mapping for all typed AST nodes. This is produced by the solver after
constraint solving.

-}
type alias NodeTypes =
    Dict Int Int Can.Type



-- ====== Construction ======


{-| Build a TypedCanonical module from a canonical module and expression type map.

Takes a fully canonicalized module and a dictionary mapping expression IDs to
their inferred types (as produced by `Solve.runWithExprVars`). Returns a
`TypedCanonical.Module` where every expression is paired with its type.

-}
fromCanonical : Can.Module -> ExprTypes -> Module
fromCanonical (Can.Module canData) exprTypes =
    let
        typedDecls =
            toTypedDecls exprTypes canData.decls
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


toTypedDecls : ExprTypes -> Can.Decls -> Decls
toTypedDecls exprTypes decls =
    case decls of
        Can.Declare def rest ->
            Declare (toTypedDef exprTypes def)
                (toTypedDecls exprTypes rest)

        Can.DeclareRec def defs rest ->
            DeclareRec
                (toTypedDef exprTypes def)
                (List.map (toTypedDef exprTypes) defs)
                (toTypedDecls exprTypes rest)

        Can.SaveTheEnvironment ->
            SaveTheEnvironment


toTypedDef : ExprTypes -> Can.Def -> Def
toTypedDef exprTypes def =
    case def of
        Can.Def name args body ->
            Def name args (toTypedExpr exprTypes body)

        Can.TypedDef name freeVars typedArgs body resultType ->
            TypedDef name freeVars typedArgs (toTypedExpr exprTypes body) resultType


{-| Convert a canonical expression to a typed expression using the type map.

This is the key function for accessing types of subexpressions during
optimization. When the optimizer encounters a `Can.Expr` child (e.g., in
`Can.Lambda args body`), it uses this to wrap it with its type.

Synthetic expressions (id < 0) will crash as they should not exist in valid ASTs.

-}
toTypedExpr : ExprTypes -> Can.Expr -> Expr
toTypedExpr exprTypes (A.At region info) =
    let
        tipe : Can.Type
        tipe =
            case Dict.get identity info.id exprTypes of
                Just t ->
                    t

                Nothing ->
                    -- For expressions with placeholder IDs (-1), crash
                    if info.id < 0 then
                        Utils.Crash.crash "TypedCanonical.toTypedExpr: placeholder ID"

                    else
                        crash ("Missing type for expr id " ++ String.fromInt info.id)
    in
    A.At region (TypedExpr { expr = info.node, tipe = tipe })
