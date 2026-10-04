module Compiler.AST.TypedCanonical exposing
    ( Module(..), ModuleData
    , Expr, Expr_(..)
    , Def(..), Decls(..)
    , ExprTypes, ExprVars, NodeTypes
    )

{-| Phases that work on types need the type of each expression, not only its
syntax. This module defines a form of the canonical AST that carries them: the
_typed canonical AST_, together with the tables those types are kept in.

The typed canonical AST is the canonical AST of `Compiler.AST.Canonical` with
one change. Each top-level definition's body is an `Expr`, a node that pairs a
canonical expression with its type and, where there is one, the type checker's
variable for it. Everything else, including argument patterns, type
annotations, `let` definitions and the module's custom types, aliases and
operators, is canonical and unchanged.

The pairing is shallow. A `TypedExpr` holds a canonical `Can.Expr_`, so the
sub-expressions of a typed body are canonical expressions with no type of their
own, only a _node id_: the integer that canonicalization gives every expression
and pattern, kept in the `id` field of `Can.ExprInfo` and `Can.PatternInfo`.
The type of a sub-expression is found by looking its node id up in a table:
`ExprTypes` (or `NodeTypes`, the same type) for its type, `ExprVars` for its
type checker variable.

The module is pure data: it defines types and no functions.


# Modules

@docs Module, ModuleData


# Expressions

@docs Expr, Expr_


# Definitions

@docs Def, Decls


# Type Mapping

@docs ExprTypes, ExprVars, NodeTypes

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.Vars as Vars
import Dict exposing (Dict)



-- ====== Expressions ======


{-| A typed expression with its source region.
-}
type alias Expr =
    A.Located Expr_


{-| One canonical expression node together with its type.

`TypedExpr` is the only constructor. `tipe` is the type of the whole
expression. `tvar` is the type checker's variable for the expression, or
`Nothing` where none is recorded; a `Vars.Variable` identifies a point only
within the type checker's store that made it, as `Compiler.Type.Vars`
describes. The sub-expressions of `expr` are canonical, not typed.

-}
type Expr_
    = TypedExpr
        { expr : Can.Expr_
        , tipe : Can.Type Name
        , tvar : Maybe Vars.Variable
        }



-- ====== Definitions ======


{-| A definition of a value or function whose body is typed.

The constructors and their fields are those of `Can.Def`, which describes them;
only the body differs, being an `Expr`. In a `TypedDef`, the type paired with
each argument pattern and the final result type are the ones the annotation
gives, not types inferred for the body.

-}
type Def
    = Def (A.Located Name) (List Can.Pattern) Expr
    | TypedDef (A.Located Name) Can.FreeVars (List ( Can.Pattern, Can.Type Name )) Expr (Can.Type Name)


{-| The top-level definitions of a module, as a linked list of groups, each
definition with a typed body.

The groups are those of `Can.Decls`. `Declare` holds a definition that is not
part of a recursive group. `DeclareRec` holds a group of definitions that refer
to one another, as its first definition and the rest. `SaveTheEnvironment` ends
the list and carries nothing.

-}
type Decls
    = Declare Def Decls
    | DeclareRec Def (List Def) Decls
    | SaveTheEnvironment



-- ====== Modules ======


{-| Everything the typed canonical AST holds for one module.

The fields are those of `Can.ModuleData`, except that `decls` holds typed
definitions.

-}
type alias ModuleData =
    { name : ModuleName.Canonical
    , exports : Can.Exports
    , docs : Src.Docs
    , decls : Decls
    , unions : Dict Name Can.Union
    , aliases : Dict Name Can.Alias
    , binops : Dict Name Can.Binop
    , effects : Can.Effects
    }


{-| A module in the typed canonical AST.
-}
type Module
    = Module ModuleData



-- ====== Type Mapping ======


{-| A table of types by node id: the entry at index `i` is the type of the
expression or pattern whose node id is `i`, or `Nothing` where the table has no
type for that id.

This is a name for an `Array`, not a new type, and it is the same type as
`NodeTypes`; the two names are interchangeable.

-}
type alias ExprTypes =
    Array (Maybe (Can.Type Name))


{-| A table of types by node id, the same type as `ExprTypes`, which describes
it.

This is a name for an `Array`, not a new type.

-}
type alias NodeTypes =
    Array (Maybe (Can.Type Name))


{-| A table of type checker variables by node id: the entry at index `i` is the
variable for the node whose node id is `i`, or `Nothing` where the table has
none.

This is a name for an `Array`, not a new type. A variable identifies a point
only within the type checker's store that made it, so the table means something
only alongside that store, as `Compiler.Type.Vars` describes.

-}
type alias ExprVars =
    Array (Maybe Vars.Variable)
