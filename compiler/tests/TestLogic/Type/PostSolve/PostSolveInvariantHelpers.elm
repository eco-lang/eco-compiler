module TestLogic.Type.PostSolve.PostSolveInvariantHelpers exposing
    ( ExprNode
    , collectKernelExprIds
    , enclosingAnnotationVars
    , freeTypeVars
    , isGroupBExprNode
    , walkExprs
    )

{-| Checking a property of the types recorded for each node before and after
`Compiler.Type.PostSolve`, across a whole module, means visiting every
expression in it, knowing which definition each one sits in, and reading the
type variables out of types. This module provides those pieces.

`Compiler.Type.PostSolve` is the pass that runs after the type solver and
adjusts the types it recorded for individual nodes. Those types are indexed by
node id, the module-unique integer that every canonical expression and pattern
carries, so each expression here is identified by its id.

Most of the file is one recursive walk over the canonical AST, behind
`walkExprs`, which lists every expression node of a module as an `ExprNode`
tagged with the name of the definition it sits in. The rest are small helpers:
`collectKernelExprIds` picks out the kernel references, `isGroupBExprNode`
classifies expression forms, `freeTypeVars` reads the type variable names out
of a type, and `enclosingAnnotationVars` reads the quantified variables of a
definition's annotation.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict


{-| One expression found by `walkExprs`: its node id, its form, and the
definition it sits in.

`enclosingDef` names the innermost top-level or let-bound definition whose body
contains the node. A lambda is not a definition, so the nodes in a lambda's
body carry the name of the definition around the lambda. A `let` expression and
its body carry the same name as the code around the `let`; only the bodies of
the let-bound definitions carry those definitions' names. The value expression
of a destructuring `let`, such as `e` in `let (a, b) = e`, binds no single name,
so like the `let` body it carries the name of the code around the `let`.
`walkExprs` always sets this field to `Just`.

-}
type alias ExprNode =
    { id : Int
    , node : Can.Expr_
    , enclosingDef : Maybe Name.Name
    }


{-| Lists every expression node in the module's declarations, each with the name
of the definition it sits in.

Patterns are walked through but produce no entries. The list is built by
prepending, so a node comes before the nodes inside it, and a later
declaration's nodes come before an earlier one's.

-}
walkExprs : Can.Module -> List ExprNode
walkExprs (Can.Module modData) =
    walkDecls modData.decls []


{-| Adds to `acc` the expression nodes of every definition in `decls`, each
tagged with its enclosing definition as `ExprNode` describes.
-}
walkDecls : Can.Decls -> List ExprNode -> List ExprNode
walkDecls decls acc =
    case decls of
        Can.Declare def rest ->
            walkDecls rest (walkDef (defName def) def acc)

        Can.DeclareRec def defs rest ->
            let
                acc1 =
                    walkDef (defName def) def acc

                acc2 =
                    List.foldl (\d a -> walkDef (defName d) d a) acc1 defs
            in
            walkDecls rest acc2

        Can.SaveTheEnvironment ->
            acc


{-| Returns the name a definition binds, which is always `Just` for either kind
of definition.
-}
defName : Can.Def -> Maybe Name.Name
defName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            Just name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            Just name


{-| Adds to `acc` the expression nodes of a definition's body, tagged as
`walkExpr` describes. The definition's argument patterns are walked but add
nothing.
-}
walkDef : Maybe Name.Name -> Can.Def -> List ExprNode -> List ExprNode
walkDef scopeName def acc =
    case def of
        Can.Def _ patterns expr ->
            let
                acc1 =
                    List.foldl walkPattern acc patterns
            in
            walkExpr scopeName expr acc1

        Can.TypedDef _ _ patternTypes expr _ ->
            let
                acc1 =
                    List.foldl (\( p, _ ) a -> walkPattern p a) acc patternTypes
            in
            walkExpr scopeName expr acc1


{-| Adds to `acc` the node for the expression and every expression node inside
it, with the expression's own node at the head of the result.

Every node is tagged with `scopeName`, except those in the body of a let-bound
definition, which are tagged with that definition's name.

-}
walkExpr : Maybe Name.Name -> Can.Expr -> List ExprNode -> List ExprNode
walkExpr scopeName (A.At _ exprInfo) acc =
    let
        thisNode =
            { id = exprInfo.id, node = exprInfo.node, enclosingDef = scopeName }

        childAcc =
            case exprInfo.node of
                Can.VarLocal _ ->
                    acc

                Can.VarTopLevel _ _ ->
                    acc

                Can.VarKernel _ _ _ ->
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
                    List.foldl (walkExpr scopeName) acc exprs

                Can.Negate expr ->
                    walkExpr scopeName expr acc

                Can.Binop _ _ _ _ left right ->
                    walkExpr scopeName right (walkExpr scopeName left acc)

                Can.Lambda patterns body ->
                    let
                        pAcc =
                            List.foldl walkPattern acc patterns
                    in
                    walkExpr scopeName body pAcc

                Can.Call fn args ->
                    List.foldl (walkExpr scopeName) (walkExpr scopeName fn acc) args

                Can.If branches final ->
                    let
                        branchAcc =
                            List.foldl
                                (\( cond, branch ) a ->
                                    walkExpr scopeName branch (walkExpr scopeName cond a)
                                )
                                acc
                                branches
                    in
                    walkExpr scopeName final branchAcc

                Can.Let def body ->
                    walkExpr scopeName body (walkDef (defName def) def acc)

                Can.LetRec defs body ->
                    let
                        defAcc =
                            List.foldl (\d a -> walkDef (defName d) d a) acc defs
                    in
                    walkExpr scopeName body defAcc

                Can.LetDestruct pattern valExpr body ->
                    let
                        pAcc =
                            walkPattern pattern acc

                        vAcc =
                            walkExpr scopeName valExpr pAcc
                    in
                    walkExpr scopeName body vAcc

                Can.Case scrutinee branches ->
                    let
                        scrAcc =
                            walkExpr scopeName scrutinee acc
                    in
                    List.foldl (walkBranch scopeName) scrAcc branches

                Can.Accessor _ ->
                    acc

                Can.Access expr _ ->
                    walkExpr scopeName expr acc

                Can.Update expr fields ->
                    let
                        fAcc =
                            Data.Map.foldl A.compareLocated
                                (\_ (Can.FieldUpdate _ e) a -> walkExpr scopeName e a)
                                acc
                                fields
                    in
                    walkExpr scopeName expr fAcc

                Can.Record fields ->
                    Data.Map.foldl A.compareLocated
                        (\_ e a -> walkExpr scopeName e a)
                        acc
                        fields

                Can.Unit ->
                    acc

                Can.Tuple a b cs ->
                    List.foldl (walkExpr scopeName)
                        (walkExpr scopeName b (walkExpr scopeName a acc))
                        cs

                Can.Shader _ _ ->
                    acc
    in
    thisNode :: childAcc


{-| Adds to `acc` the expression nodes of a case branch's body, tagged as
`walkExpr` describes.
-}
walkBranch : Maybe Name.Name -> Can.CaseBranch -> List ExprNode -> List ExprNode
walkBranch scopeName (Can.CaseBranch pattern body) acc =
    walkExpr scopeName body (walkPattern pattern acc)


{-| Returns `acc` unchanged. A pattern contains no expressions, so although this
recurses through the sub-patterns, no case adds anything.
-}
walkPattern : Can.Pattern -> List ExprNode -> List ExprNode
walkPattern (A.At _ patInfo) acc =
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


{-| Returns whether an expression form is one of `Str`, `Chr`, `Float`, `Unit`,
`List`, `Tuple`, `Record`, `Lambda`, `Accessor`, `Let`, `LetRec` or
`LetDestruct`.

Despite its name, this is not the constraint generator's Group B, the forms for
which it records a synthetic placeholder variable as the node's type
(`Compiler.Type.Constrain.Typed.Expression` defines the split). Of that group
it accepts only `Str`, `Chr`, `Float` and `Unit`, and rejects `Shader` and the
variable references; the other eight forms it accepts are Group A there.

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


{-| Returns whether an expression form is a reference to a kernel function
(`VarKernel`).
-}
isVarKernel : Can.Expr_ -> Bool
isVarKernel node =
    case node of
        Can.VarKernel _ _ _ ->
            True

        _ ->
            False


{-| Returns the node ids of the kernel function references (`VarKernel`) in the
module's declarations.
-}
collectKernelExprIds : Can.Module -> EverySet Int Int
collectKernelExprIds canModule =
    walkExprs canModule
        |> List.filter (\n -> isVarKernel n.node)
        |> List.map .id
        |> EverySet.fromList identity


{-| Returns the type variables quantified by the annotation that `annotations`
holds for the definition named `maybeName`.

The result is empty when `maybeName` is `Nothing` or has no entry. The lookup is
by name alone: a node inside a let-bound definition, which `walkExprs` tags with
that definition's name, finds nothing unless `annotations` has an entry under
the let-bound name.

-}
enclosingAnnotationVars :
    Maybe Name.Name
    -> Dict.Dict Name.Name (Can.Annotation Name)
    -> EverySet String String
enclosingAnnotationVars maybeName annotations =
    case maybeName of
        Nothing ->
            EverySet.empty

        Just name ->
            case Dict.get name annotations of
                Just (Can.Forall freeVars _) ->
                    Dict.keys freeVars
                        |> List.foldl (\v acc -> EverySet.insert identity v acc) EverySet.empty

                Nothing ->
                    EverySet.empty


{-| Returns the name of every type variable that appears in a type, record
extension variables included.

For an alias it takes the variables of the alias's argument types and of its
body. A `Holey` body is written in terms of the alias's own parameters, so the
parameter names it mentions are returned as well, even when the arguments
mention no variable.

-}
freeTypeVars : Can.Type Name -> EverySet String String
freeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            EverySet.insert identity name EverySet.empty

        Can.TType _ _ args ->
            List.foldl
                (\t acc -> EverySet.union acc (freeTypeVars t))
                EverySet.empty
                args

        Can.TLambda _ a b ->
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
                    Dict.foldl
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
