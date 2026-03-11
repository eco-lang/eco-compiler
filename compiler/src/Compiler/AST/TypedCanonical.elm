module Compiler.AST.TypedCanonical exposing
    ( Module(..), ModuleData
    , Expr, Expr_(..)
    , Def(..), Decls(..)
    , ExprTypes, NodeTypes
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

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



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
    , unions : Dict Name Can.Union
    , aliases : Dict Name Can.Alias
    , binops : Dict Name Can.Binop
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
    Array (Maybe Can.Type)


{-| Dictionary mapping node IDs to their canonical types.

Node IDs include both expression IDs and pattern IDs, providing a unified
mapping for all typed AST nodes. This is produced by the solver after
constraint solving.

-}
type alias NodeTypes =
    Array (Maybe Can.Type)



-- ====== Construction ======
