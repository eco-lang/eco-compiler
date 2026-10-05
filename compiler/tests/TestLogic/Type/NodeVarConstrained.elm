module TestLogic.Type.NodeVarConstrained exposing
    ( Violation
    , check
    , formatViolations
    )

{-| Finds expressions whose solved type is a type variable that nothing
constrained, so that a solver variable recorded for an expression and then
never tied to anything does not go unnoticed.

While generating constraints, the typed type checker records a solver variable
for the type of each expression node, against the node's id. For the
expression kinds called Group A it does so with
`Compiler.Type.Constrain.Typed.NodeIds.recordNodeVar`; which kinds are in
Group A is decided by `Compiler.Type.Constrain.Typed.Expression`. If no
constraint ever ties such a variable to anything, solving leaves it free, and
the node's type can come out as a bare type variable that is not a type
variable of any enclosing definition. `check` looks for those nodes in a
per-node type array, indexed by node id.

A type variable is accepted at a node if it is a binder there or a type-class
variable. The binders at a node are the type variables of the definitions that
enclose it:

  - At a top-level definition with an annotation, they are the type variables
    the annotation declares. At one without, they are the type variables of
    the scheme held for its name in the annotations given to `check`, and
    there are none if it has no entry.
  - A let-bound definition adds to the enclosing binders, for its own body
    only. With an annotation it adds the type variables the annotation
    declares. Without one it adds the type variables that `collectFreeVars`
    finds in the node types of its body and of its argument patterns, which
    stand in for its inferred type.

A type-class variable is one whose name starts with `number`, `comparable`,
`appendable` or `compappend`. The test is a prefix match, the same one
`Compiler.Data.Name.isNumberType` and its siblings make.

Only a node whose whole type is a bare type variable can fail. A structured
type such as `List a` passes whatever variables it contains.

The kinds checked are `Int`, `Negate`, `Binop`, `If`, `Case`, `Access`,
`Update`, and `Call` except a call whose function is a kernel reference. The
other Group A kinds (`Accessor`, `List`, `Tuple`, `Record`, `Lambda`, `Let`,
`LetRec` and `LetDestruct`) are not checked themselves, but the expressions
inside them are.

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)
import Set exposing (Set)


{-| One expression that failed the check: its type is a bare type variable,
`spuriousVar`, that is neither a binder at the node nor a type-class variable.

`exprKind` names the kind of expression, such as `"If"`. `functionName` is the
top-level definition the expression is in, also when it lies inside a
let-bound definition. `binders` are the binders at the node, in ascending
order.

-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , spuriousVar : String
    , functionName : String
    , binders : List String
    }


{-| Returns every expression in a module's top-level definitions that fails the
check, given the schemes of the top-level definitions by name and the type of
each node, indexed by node id. An empty list means the module passes.

A node with a negative id, or with no type in the array, passes.

-}
check :
    Can.Module
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> List Violation
check (Can.Module modData) annotations nodeTypes =
    checkDecls modData.decls annotations nodeTypes


{-| Returns the violations in every definition of a declaration list, including
each member of a recursive group.
-}
checkDecls :
    Can.Decls
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> List Violation
checkDecls decls annotations nodeTypes =
    case decls of
        Can.Declare def rest ->
            checkDef def annotations nodeTypes
                ++ checkDecls rest annotations nodeTypes

        Can.DeclareRec def defs rest ->
            checkDef def annotations nodeTypes
                ++ List.concatMap (\d -> checkDef d annotations nodeTypes) defs
                ++ checkDecls rest annotations nodeTypes

        Can.SaveTheEnvironment ->
            []


{-| Returns the violations in one top-level definition. Its binders are the type
variables its annotation declares or, when it has none, the type variables of
its scheme in `annotations`.
-}
checkDef :
    Can.Def
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> List Violation
checkDef def annotations nodeTypes =
    case def of
        Can.Def (A.At _ name) _ body ->
            let
                binders =
                    annotationBinders name annotations
            in
            checkExpr name binders body nodeTypes

        Can.TypedDef (A.At _ name) freeVars _ body _ ->
            let
                binders =
                    Dict.keys freeVars |> Set.fromList
            in
            checkExpr name binders body nodeTypes


{-| Returns the type variables of the scheme `annotations` holds for `name`, or
none if it holds none.
-}
annotationBinders : Name.Name -> Dict Name.Name (Can.Annotation Name) -> Set String
annotationBinders name annotations =
    case Dict.get name annotations of
        Just (Can.Forall freeVars _) ->
            Dict.keys freeVars |> Set.fromList

        Nothing ->
            Set.empty


{-| Returns an expression's node id.
-}
getExprId : Can.Expr -> Int
getExprId (A.At _ info) =
    info.id


{-| Returns a pattern's node id.
-}
getPatternId : Can.Pattern -> Int
getPatternId (A.At _ patInfo) =
    patInfo.id


{-| Returns the violations in the body of a let-bound definition, checked with
`enclosingBinders` extended for that body.

A definition with an annotation adds the type variables the annotation
declares. One without adds the type variables `collectFreeVars` returns for the
node types of its body and of its argument patterns, so that a variable of its
inferred type counts as a binder even when it appears only in a parameter's
type.

-}
walkDef :
    Name.Name
    -> Set String
    -> Can.Def
    -> Array (Maybe (Can.Type Name))
    -> List Violation
walkDef enclosingFunc enclosingBinders def nodeTypes =
    case def of
        Can.Def (A.At _ _) args body ->
            let
                bodyId =
                    getExprId body

                bodyTVars =
                    case Array.get bodyId nodeTypes |> Maybe.andThen identity of
                        Just bodyType ->
                            collectFreeVars bodyType

                        Nothing ->
                            Set.empty

                argTVars =
                    args
                        |> List.foldl
                            (\pat acc ->
                                let
                                    patId =
                                        getPatternId pat
                                in
                                case Array.get patId nodeTypes |> Maybe.andThen identity of
                                    Just patType ->
                                        Set.union acc (collectFreeVars patType)

                                    Nothing ->
                                        acc
                            )
                            Set.empty

                localBinders =
                    Set.union bodyTVars argTVars

                defBinders =
                    Set.union enclosingBinders localBinders
            in
            checkExpr enclosingFunc defBinders body nodeTypes

        Can.TypedDef (A.At _ _) freeVars _ body _ ->
            let
                defBinders =
                    Dict.keys freeVars |> Set.fromList |> Set.union enclosingBinders
            in
            checkExpr enclosingFunc defBinders body nodeTypes


{-| Returns the violations in an expression and everything inside it. The
expression itself is checked if it is an `Int`, `Negate`, `Binop`, `If`,
`Case`, `Access` or `Update`, or a `Call` whose function is not a kernel
reference.
-}
checkExpr :
    Name.Name
    -> Set String
    -> Can.Expr
    -> Array (Maybe (Can.Type Name))
    -> List Violation
checkExpr funcName binders (A.At _ exprInfo) nodeTypes =
    let
        nodeId =
            exprInfo.id

        thisViolations =
            case exprInfo.node of
                Can.Int _ ->
                    checkNodeType funcName binders nodeId "Int" nodeTypes

                Can.Negate _ ->
                    checkNodeType funcName binders nodeId "Negate" nodeTypes

                Can.Binop _ _ _ _ _ _ ->
                    checkNodeType funcName binders nodeId "Binop" nodeTypes

                Can.Call fn _ ->
                    -- A direct kernel call is exempt, whatever its type.
                    case fn of
                        A.At _ fnInfo ->
                            case fnInfo.node of
                                Can.VarKernel _ _ _ ->
                                    []

                                _ ->
                                    checkNodeType funcName binders nodeId "Call" nodeTypes

                Can.If _ _ ->
                    checkNodeType funcName binders nodeId "If" nodeTypes

                Can.Case _ _ ->
                    checkNodeType funcName binders nodeId "Case" nodeTypes

                Can.Access _ _ ->
                    checkNodeType funcName binders nodeId "Access" nodeTypes

                Can.Update _ _ ->
                    checkNodeType funcName binders nodeId "Update" nodeTypes

                _ ->
                    []

        childViolations =
            walkChildren funcName binders exprInfo.node nodeTypes
    in
    thisViolations ++ childViolations


{-| Tells whether a type variable is exempt as a type-class variable: one whose
name starts with `number`, `comparable`, `appendable` or `compappend`. Being a
prefix match, it also exempts a name such as `numberOfItems`.
-}
isTypeClassVar : String -> Bool
isTypeClassVar name =
    String.startsWith "number" name
        || String.startsWith "comparable" name
        || String.startsWith "appendable" name
        || String.startsWith "compappend" name


{-| Returns a violation for node `nodeId` if its type in `nodeTypes` is a bare
type variable that is neither in `binders` nor a type-class variable, and
nothing otherwise. `exprKind` is only copied into the violation.

A negative id passes, as does a node with no type in the array. A structured
type passes whatever variables it contains.

-}
checkNodeType :
    Name.Name
    -> Set String
    -> Int
    -> String
    -> Array (Maybe (Can.Type Name))
    -> List Violation
checkNodeType funcName binders nodeId exprKind nodeTypes =
    if nodeId < 0 then
        []

    else
        case Array.get nodeId nodeTypes |> Maybe.andThen identity of
            Nothing ->
                []

            Just (Can.TVar varName) ->
                if Set.member varName binders || isTypeClassVar varName then
                    []

                else
                    [ { nodeId = nodeId
                      , exprKind = exprKind
                      , spuriousVar = varName
                      , functionName = funcName
                      , binders = Set.toList binders
                      }
                    ]

            Just _ ->
                []


{-| Returns the names of the type variables in a type, the extension variable
of an extensible record included. A `Filled` alias is looked through to its
body. A `Holey` alias's body is written in the alias's own parameter names, so
for it the variables of its arguments are collected instead: those are what
the parameters stand for at this use.
-}
collectFreeVars : Can.Type Name -> Set String
collectFreeVars tipe =
    case tipe of
        Can.TVar name ->
            Set.singleton name

        Can.TLambda _ a b ->
            Set.union (collectFreeVars a) (collectFreeVars b)

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Set.union (collectFreeVars arg) acc) Set.empty args

        Can.TRecord fields maybeExt ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> Set.union (collectFreeVars ft) acc)
                (case maybeExt of
                    Just ext ->
                        Set.singleton ext

                    Nothing ->
                        Set.empty
                )
                fields

        Can.TUnit ->
            Set.empty

        Can.TTuple a b extras ->
            List.foldl (\t acc -> Set.union (collectFreeVars t) acc)
                (Set.union (collectFreeVars a) (collectFreeVars b))
                extras

        Can.TAlias _ _ args (Can.Holey _) ->
            List.foldl (\( _, arg ) acc -> Set.union (collectFreeVars arg) acc) Set.empty args

        Can.TAlias _ _ _ (Can.Filled aliased) ->
            collectFreeVars aliased


{-| Returns the violations in the expressions directly inside a node and
everything inside them, checked with `binders`. A let-bound definition is the
exception: its body is checked by `walkDef`, with binders of its own. Patterns
are not visited.
-}
walkChildren :
    Name.Name
    -> Set String
    -> Can.Expr_
    -> Array (Maybe (Can.Type Name))
    -> List Violation
walkChildren funcName binders node nodeTypes =
    let
        go expr =
            checkExpr funcName binders expr nodeTypes
    in
    case node of
        Can.If branches final ->
            List.concatMap (\( cond, body ) -> go cond ++ go body) branches
                ++ go final

        Can.Case scrutinee branches ->
            go scrutinee
                ++ List.concatMap (\(Can.CaseBranch _ body) -> go body) branches

        Can.Lambda _ body ->
            go body

        Can.Call func args ->
            go func ++ List.concatMap go args

        Can.Let def body ->
            walkDef funcName binders def nodeTypes ++ go body

        Can.LetRec defs body ->
            List.concatMap (\d -> walkDef funcName binders d nodeTypes) defs ++ go body

        Can.LetDestruct _ bindExpr body ->
            go bindExpr ++ go body

        Can.Binop _ _ _ _ left right ->
            go left ++ go right

        Can.Negate expr ->
            go expr

        Can.List items ->
            List.concatMap go items

        Can.Access expr _ ->
            go expr

        Can.Update expr fields ->
            go expr ++ DMap.foldl (\_ (Can.FieldUpdate _ e) acc -> go e ++ acc) [] fields

        Can.Record fields ->
            DMap.foldl (\_ e acc -> go e ++ acc) [] fields

        Can.Tuple a b extras ->
            go a ++ go b ++ List.concatMap go extras

        Can.VarLocal _ ->
            []

        Can.VarTopLevel _ _ ->
            []

        Can.VarKernel _ _ _ ->
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

        Can.Accessor _ ->
            []

        Can.Unit ->
            []

        Can.Shader _ _ ->
            []


{-| Renders violations as a test failure message: a header with their count,
then one indented line per violation giving its expression kind, node id,
definition, variable and binders.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "TYPE_007 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ String.join "\n\n" (List.map formatOne violations)


{-| Renders one violation as an indented line of the failure message.
-}
formatOne : Violation -> String
formatOne v =
    "  "
        ++ v.exprKind
        ++ " expression (node "
        ++ String.fromInt v.nodeId
        ++ ") in function '"
        ++ v.functionName
        ++ "': resolved to bare TVar \""
        ++ v.spuriousVar
        ++ "\" which is not in annotation binders ["
        ++ String.join ", " v.binders
        ++ "]"
