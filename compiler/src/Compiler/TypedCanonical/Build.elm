module Compiler.TypedCanonical.Build exposing
    ( fromCanonical
    , toTypedExpr
    )

{-| Type checking leaves the type of each expression in tables kept apart from
the canonical AST, and this module joins the two: it produces the typed
canonical AST of `Compiler.AST.TypedCanonical` from a canonical module and those
tables.

The tables are indexed by _node id_, the integer that canonicalization gives
each expression: `ExprTypes` holds each node's type and `ExprVars` its type
checker variable, as `Compiler.AST.TypedCanonical` describes. Wrapping one
expression is a lookup of its node id in both tables.

The typed canonical AST is shallow, and so is this module's work.
`fromCanonical` wraps only the body of each top-level definition; everything
below that body stays a canonical expression. `toTypedExpr` wraps a single
expression, and is exposed so that a sub-expression can be wrapped at the moment
its type is needed, with the same tables.

Wrapping an expression whose type is missing from the table crashes; there is
no error value.


# Module Transformation

@docs fromCanonical


# Expression Transformation

@docs toTypedExpr

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (Decls(..), Def(..), ExprTypes, ExprVars, Module(..))
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Utils.Crash exposing (crash)



-- ====== MODULE CONSTRUCTION ======


{-| Returns the typed canonical form of a canonical module, looking types up in
`exprTypes` and type checker variables in `exprVars`.

Everything but the declarations is copied unchanged. In the declarations, each
definition's body is wrapped by `toTypedExpr`, so the call crashes if the type
of any body is missing; the expressions inside the bodies are not looked up.

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


{-| Returns the typed form of a chain of declarations, keeping its groups and
order and typing each definition with `toTypedDef`.
-}
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


{-| Returns the typed form of one definition: the same name, arguments and, for
an annotated definition, the same annotation types, with the body wrapped by
`toTypedExpr`.
-}
toTypedDef : ExprTypes -> ExprVars -> Can.Def -> Def
toTypedDef exprTypes exprVars def =
    case def of
        Can.Def name args body ->
            Def name args (toTypedExpr exprTypes exprVars body)

        Can.TypedDef name freeVars typedArgs body resultType ->
            TypedDef name freeVars typedArgs (toTypedExpr exprTypes exprVars body) resultType



-- ====== EXPRESSION TRANSFORMATION ======


{-| Returns one canonical expression paired with its type from `exprTypes` and
its type checker variable from `exprVars`, both found by its node id. Its
region is kept, and its sub-expressions stay canonical.

The variable is `Nothing` where `exprVars` has none. A missing type crashes,
with a message of its own when the node id is negative.

-}
toTypedExpr : ExprTypes -> ExprVars -> Can.Expr -> TCan.Expr
toTypedExpr exprTypes exprVars (A.At region info) =
    let
        tipe : Can.Type Name
        tipe =
            case Array.get info.id exprTypes |> Maybe.andThen identity of
                Just t ->
                    t

                Nothing ->
                    if info.id < 0 then
                        crash "TypedCanonical.Build.toTypedExpr: placeholder ID"

                    else
                        crash ("Missing type for expr id " ++ String.fromInt info.id)

        tvar =
            Array.get info.id exprVars |> Maybe.andThen identity
    in
    A.At region (TCan.TypedExpr { expr = info.node, tipe = tipe, tvar = tvar })
