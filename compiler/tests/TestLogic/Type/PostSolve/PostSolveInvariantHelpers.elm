module TestLogic.Type.PostSolve.PostSolveInvariantHelpers exposing
    ( ExprNode
    , collectKernelExprIds
    , enclosingAnnotationVars
    , freeTypeVars
    , groupBLiteralType
    , orphanPlaceholderVars
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
tagged with the definitions it sits in. The rest are small helpers:
`collectKernelExprIds` picks out the kernel references, `groupBLiteralType`
gives the type of a literal PostSolve types structurally, `freeTypeVars` reads
the type variable names out of a type, `enclosingAnnotationVars` reads the
type variables in scope at a node from the annotations around it, and
`orphanPlaceholderVars` finds placeholder variables nothing constrained.

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict


{-| One expression found by `walkExprs`: its node id, its form, and the
definitions it sits in.

`enclosingDef` names the innermost top-level or let-bound definition whose body
contains the node. A lambda is not a definition, so the nodes in a lambda's
body carry the name of the definition around the lambda. A `let` expression and
its body carry the same name as the code around the `let`; only the bodies of
the let-bound definitions carry those definitions' names. The value expression
of a destructuring `let`, such as `e` in `let (a, b) = e`, binds no single name,
so like the `let` body it carries the name of the code around the `let`.
`walkExprs` always sets this field to `Just`.

`topLevelDef` names the top-level definition the node sits in, however deeply
nested in let-bound definitions. `declaredVars` holds the type variables that
the annotations of the enclosing definitions declare: the top-level one's, if
it has an annotation, and those of each annotated let-bound definition whose
body holds the node.

-}
type alias ExprNode =
    { id : Int
    , node : Can.Expr_
    , enclosingDef : Maybe Name.Name
    , topLevelDef : Name.Name
    , declaredVars : EverySet String String
    }


{-| Where a walk is: the innermost definition, the top-level definition, and
the type variables the enclosing annotations declare.
-}
type alias Scope =
    { enclosingDef : Maybe Name.Name
    , topLevelDef : Name.Name
    , declaredVars : EverySet String String
    }


{-| Lists every expression node in the module's declarations, each with the name
of the definition it sits in.

Patterns produce no entries. The list is built by
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
            walkDecls rest (walkDef (topLevelScope def) def acc)

        Can.DeclareRec def defs rest ->
            let
                acc1 =
                    walkDef (topLevelScope def) def acc

                acc2 =
                    List.foldl (\d a -> walkDef (topLevelScope d) d a) acc1 defs
            in
            walkDecls rest acc2

        Can.SaveTheEnvironment ->
            acc


{-| Returns the name a definition binds.
-}
defName : Can.Def -> Name.Name
defName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Returns the type variables a definition's annotation declares, none for an
unannotated definition.
-}
defDeclaredVars : Can.Def -> EverySet String String
defDeclaredVars def =
    case def of
        Can.Def _ _ _ ->
            EverySet.empty

        Can.TypedDef _ freeVars _ _ _ ->
            Dict.keys freeVars |> EverySet.fromList identity


{-| The scope of the body of the top-level definition `def`.
-}
topLevelScope : Can.Def -> Scope
topLevelScope def =
    { enclosingDef = Just (defName def)
    , topLevelDef = defName def
    , declaredVars = defDeclaredVars def
    }


{-| The scope of the body of the let-bound definition `def`, inside `scope`.
-}
letScope : Scope -> Can.Def -> Scope
letScope scope def =
    { enclosingDef = Just (defName def)
    , topLevelDef = scope.topLevelDef
    , declaredVars = EverySet.union scope.declaredVars (defDeclaredVars def)
    }


{-| Adds to `acc` the expression nodes of a definition's body, walked in
`scope`.
-}
walkDef : Scope -> Can.Def -> List ExprNode -> List ExprNode
walkDef scope def acc =
    case def of
        Can.Def _ _ expr ->
            walkExpr scope expr acc

        Can.TypedDef _ _ _ expr _ ->
            walkExpr scope expr acc


{-| Adds to `acc` the node for the expression and every expression node inside
it, with the expression's own node at the head of the result.

Every node is tagged with `scope`, except those in the body of a let-bound
definition, which are tagged with that definition's scope.

-}
walkExpr : Scope -> Can.Expr -> List ExprNode -> List ExprNode
walkExpr scope (A.At _ exprInfo) acc =
    let
        thisNode =
            { id = exprInfo.id
            , node = exprInfo.node
            , enclosingDef = scope.enclosingDef
            , topLevelDef = scope.topLevelDef
            , declaredVars = scope.declaredVars
            }

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
                    List.foldl (walkExpr scope) acc exprs

                Can.Negate expr ->
                    walkExpr scope expr acc

                Can.Binop _ _ _ _ left right ->
                    walkExpr scope right (walkExpr scope left acc)

                Can.Lambda _ body ->
                    walkExpr scope body acc

                Can.Call fn args ->
                    List.foldl (walkExpr scope) (walkExpr scope fn acc) args

                Can.If branches final ->
                    let
                        branchAcc =
                            List.foldl
                                (\( cond, branch ) a ->
                                    walkExpr scope branch (walkExpr scope cond a)
                                )
                                acc
                                branches
                    in
                    walkExpr scope final branchAcc

                Can.Let def body ->
                    walkExpr scope body (walkDef (letScope scope def) def acc)

                Can.LetRec defs body ->
                    let
                        defAcc =
                            List.foldl (\d a -> walkDef (letScope scope d) d a) acc defs
                    in
                    walkExpr scope body defAcc

                Can.LetDestruct _ valExpr body ->
                    walkExpr scope body (walkExpr scope valExpr acc)

                Can.Case scrutinee branches ->
                    let
                        scrAcc =
                            walkExpr scope scrutinee acc
                    in
                    List.foldl (walkBranch scope) scrAcc branches

                Can.Accessor _ ->
                    acc

                Can.Access expr _ ->
                    walkExpr scope expr acc

                Can.Update expr fields ->
                    let
                        fAcc =
                            Data.Map.foldl
                                (\_ (Can.FieldUpdate _ e) a -> walkExpr scope e a)
                                acc
                                fields
                    in
                    walkExpr scope expr fAcc

                Can.Record fields ->
                    Data.Map.foldl
                        (\_ e a -> walkExpr scope e a)
                        acc
                        fields

                Can.Unit ->
                    acc

                Can.Tuple a b cs ->
                    List.foldl (walkExpr scope)
                        (walkExpr scope b (walkExpr scope a acc))
                        cs

                Can.Shader _ _ ->
                    acc
    in
    thisNode :: childAcc


{-| Adds to `acc` the expression nodes of a case branch's body, tagged as
`walkExpr` describes.
-}
walkBranch : Scope -> Can.CaseBranch -> List ExprNode -> List ExprNode
walkBranch scope (Can.CaseBranch _ body) acc =
    walkExpr scope body acc


{-| Returns the type of a string, character or float literal or of unit, the
Group B forms that `Compiler.Type.PostSolve` types structurally, and `Nothing`
for every other form.
-}
groupBLiteralType : Can.Expr_ -> Maybe (Can.Type Name)
groupBLiteralType node =
    case node of
        Can.Str _ ->
            Just (Can.TType ModuleName.string Name.string [])

        Can.Chr _ ->
            Just (Can.TType ModuleName.char Name.char [])

        Can.Float _ ->
            Just (Can.TType ModuleName.basics Name.float [])

        Can.Unit ->
            Just Can.TUnit

        _ ->
            Nothing


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


{-| Returns the type variables in scope at `exprNode` from annotations: those
quantified by the scheme `annotations` holds for its top-level definition, and
those declared by the annotations of the definitions around it
(`declaredVars`).

The solver's annotations hold top-level names only, so the scheme looked up is
always the top-level one. The type variables an unannotated let-bound
definition is generalized over are not included.

-}
enclosingAnnotationVars :
    ExprNode
    -> Dict.Dict Name.Name (Can.Annotation Name)
    -> EverySet String String
enclosingAnnotationVars exprNode annotations =
    case Dict.get exprNode.topLevelDef annotations of
        Just (Can.Forall freeVars _) ->
            Dict.keys freeVars
                |> List.foldl (\v acc -> EverySet.insert identity v acc) exprNode.declaredVars

        Nothing ->
            exprNode.declaredVars


{-| Returns the name of every type variable that appears in a type, record
extension variables included.

For an alias it takes the variables of the alias's argument types, and of its
body when that is `Filled`. A `Holey` body is written in terms of the alias's
own parameter names, which the arguments stand for, so it is not read.

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
                        Can.Holey _ ->
                            EverySet.empty

                        Can.Filled t ->
                            freeTypeVars t
            in
            EverySet.union argVars aliasVars


{-| Returns the _orphan placeholder variables_ of a solved module, with the id
of the node each is at: the type variables that are the whole pre-PostSolve
type of a node typed through a synthetic placeholder (an id in
`syntheticExprIds`) and that occur in no other node's pre-PostSolve type.

Constraint generation ties every placeholder to the type its context expects,
and that expected type is also the type, or part of the type, of the node
around it. The solver names one variable the same wherever it occurs in the
node types, so a placeholder variable seen at its own node alone is one that
no constraint reached: the leftover the placeholder invariants forbid.

The body of a definition, top-level or let-bound, is the exception and is
skipped: its expected type is the definition's own type, which no node
records, so in `y = x` the reference to `x` can rightly be the only node with
its variable.

The check can miss an orphan whose name another, unrelated variable also has
in the node types. The solver's naming does not always keep names unique
(variables first named for a top-level annotation are not counted as taken
when the node types are named), and such a collision hides the orphan.

-}
orphanPlaceholderVars :
    Can.Module
    -> EverySet Int Int
    -> Array (Maybe (Can.Type Name))
    -> List ( Int, String )
orphanPlaceholderVars ((Can.Module modData) as canonical) syntheticExprIds nodeTypesPre =
    let
        defBodyIds =
            walkExprs canonical
                |> List.concatMap
                    (\exprNode ->
                        case exprNode.node of
                            Can.Let def _ ->
                                [ defBodyId def ]

                            Can.LetRec defs _ ->
                                List.map defBodyId defs

                            _ ->
                                []
                    )
                |> List.append (topLevelBodyIds modData.decls)
                |> EverySet.fromList identity

        candidates =
            EverySet.diff syntheticExprIds defBodyIds
                |> EverySet.toList
                |> List.filterMap
                    (\exprId ->
                        case Array.get exprId nodeTypesPre |> Maybe.andThen identity of
                            Just (Can.TVar name) ->
                                Just ( exprId, name )

                            _ ->
                                Nothing
                    )

        -- How many nodes mention each variable.
        occurrences =
            Array.foldl
                (\maybeType acc ->
                    case maybeType of
                        Just tipe ->
                            EverySet.foldr
                                (\name counts -> Dict.update name (\n -> Just (Maybe.withDefault 0 n + 1)) counts)
                                acc
                                (freeTypeVars tipe)

                        Nothing ->
                            acc
                )
                Dict.empty
                nodeTypesPre
    in
    List.filter
        (\( _, name ) -> (Dict.get name occurrences |> Maybe.withDefault 0) <= 1)
        candidates


{-| Returns the body ids of the top-level definitions in `decls`.
-}
topLevelBodyIds : Can.Decls -> List Int
topLevelBodyIds decls =
    case decls of
        Can.Declare def rest ->
            defBodyId def :: topLevelBodyIds rest

        Can.DeclareRec def defs rest ->
            List.map defBodyId (def :: defs) ++ topLevelBodyIds rest

        Can.SaveTheEnvironment ->
            []


{-| Returns the node id of a definition's body.
-}
defBodyId : Can.Def -> Int
defBodyId def =
    case def of
        Can.Def _ _ (A.At _ info) ->
            info.id

        Can.TypedDef _ _ _ (A.At _ info) _ ->
            info.id
