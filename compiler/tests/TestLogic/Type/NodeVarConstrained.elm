module TestLogic.Type.NodeVarConstrained exposing
    ( Violation
    , check
    , formatViolations
    )

{-| Test logic for invariant TYPE\_007: Recorded node variables are constrained.

Every type variable registered via NodeIds.recordNodeVar for a Group A
expression must resolve (after solving) to a type that is grounded in the
enclosing annotation's binders. Group A expressions are those dispatched to
specialised constraint helpers that call recordNodeVar:

    Int, Negate, Binop, Call, If, Case, Access, Update

A bare TVar whose name does not appear in any enclosing annotation's binders
indicates a solver variable that was recorded but never unified with anything.

Group B expressions (Str, Chr, Float, Unit, List, Tuple, Record, Lambda,
Accessor, Let/LetRec/LetDestruct) use recordSyntheticExprVar instead and are
handled by PostSolve — they are NOT in scope for TYPE\_007.

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)
import Set exposing (Set)


{-| A violation of TYPE\_007.
-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , spuriousVar : String
    , functionName : String
    , binders : List String
    }


{-| Check TYPE\_007 across all declarations in a module.

For each annotated declaration, walk its expression tree and check that
every Group A expression's node type is grounded in the enclosing
annotation's binders.

-}
check :
    Can.Module
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> List Violation
check (Can.Module modData) annotations nodeTypes =
    checkDecls modData.decls annotations nodeTypes


checkDecls :
    Can.Decls
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
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


checkDef :
    Can.Def
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
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


{-| Extract binder names from an annotation, if one exists.
-}
annotationBinders : Name.Name -> Dict Name.Name Can.Annotation -> Set String
annotationBinders name annotations =
    case Dict.get name annotations of
        Just (Can.Forall freeVars _) ->
            Dict.keys freeVars |> Set.fromList

        Nothing ->
            Set.empty


{-| Get the expression ID from a canonical expression.
-}
getExprId : Can.Expr -> Int
getExprId (A.At _ info) =
    info.id


{-| Get the pattern ID from a canonical pattern.
-}
getPatternId : Can.Pattern -> Int
getPatternId (A.At _ patInfo) =
    patInfo.id


{-| Walk into a let-bound definition using the enclosing binders,
or the def's own binders if it has a typed annotation.

For unannotated Def, infer let-generalized binders from the full inferred
function type: argument pattern types + body result type from nodeTypes.
This makes all scheme TVars (a, b, c, etc.) visible when checking Group A
nodes inside the body, including TVars that only appear in parameter types.

-}
walkDef :
    Name.Name
    -> Set String
    -> Can.Def
    -> Array (Maybe Can.Type)
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


{-| Walk an expression tree, checking If and Case nodes.
-}
checkExpr :
    Name.Name
    -> Set String
    -> Can.Expr
    -> Array (Maybe Can.Type)
    -> List Violation
checkExpr funcName binders (A.At _ exprInfo) nodeTypes =
    let
        nodeId =
            exprInfo.id

        -- Check this node if it's a Group A expression (uses recordNodeVar)
        thisViolations =
            case exprInfo.node of
                Can.Int _ ->
                    checkNodeType funcName binders nodeId "Int" nodeTypes

                Can.Negate _ ->
                    checkNodeType funcName binders nodeId "Negate" nodeTypes

                Can.Binop _ _ _ _ _ _ ->
                    checkNodeType funcName binders nodeId "Binop" nodeTypes

                Can.Call fn _ ->
                    -- Skip direct kernel calls: their TVars come from kernel schemes.
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
                    -- Group B or leaf — not checked by TYPE_007
                    []

        -- Recurse into children
        childViolations =
            walkChildren funcName binders exprInfo.node nodeTypes
    in
    thisViolations ++ childViolations


{-| Is this TVar name a type-class variable?

Elm's solver produces constrained type variables for numeric/comparison type
classes. These never appear in Forall binders. Recognise by name prefix.

-}
isTypeClassVar : String -> Bool
isTypeClassVar name =
    String.startsWith "number" name
        || String.startsWith "comparable" name
        || String.startsWith "appendable" name
        || String.startsWith "compappend" name


{-| Check whether a node's resolved type contains spurious free variables.
-}
checkNodeType :
    Name.Name
    -> Set String
    -> Int
    -> String
    -> Array (Maybe Can.Type)
    -> List Violation
checkNodeType funcName binders nodeId exprKind nodeTypes =
    if nodeId < 0 then
        []

    else
        case Array.get nodeId nodeTypes |> Maybe.andThen identity of
            Nothing ->
                -- Missing node type; TYPE_003 covers this
                []

            Just resolvedType ->
                let
                    freeVarsInType =
                        collectFreeVars resolvedType

                    spurious =
                        Set.diff freeVarsInType binders
                            |> Set.filter (\v -> not (isTypeClassVar v))
                in
                if Set.isEmpty spurious then
                    []

                else
                    -- Only report if the resolved type is a BARE TVar
                    -- (structured types with extra vars are a different issue)
                    case resolvedType of
                        Can.TVar varName ->
                            if Set.member varName binders then
                                []

                            else
                                [ { nodeId = nodeId
                                  , exprKind = exprKind
                                  , spuriousVar = varName
                                  , functionName = funcName
                                  , binders = Set.toList binders
                                  }
                                ]

                        _ ->
                            -- Structured type — not a bare unconstrained var
                            []


{-| Collect all free TVar names from a canonical type.
-}
collectFreeVars : Can.Type -> Set String
collectFreeVars tipe =
    case tipe of
        Can.TVar name ->
            Set.singleton name

        Can.TLambda a b ->
            Set.union (collectFreeVars a) (collectFreeVars b)

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Set.union (collectFreeVars arg) acc) Set.empty args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> Set.union (collectFreeVars ft) acc) Set.empty fields

        Can.TUnit ->
            Set.empty

        Can.TTuple a b extras ->
            List.foldl (\t acc -> Set.union (collectFreeVars t) acc)
                (Set.union (collectFreeVars a) (collectFreeVars b))
                extras

        Can.TAlias _ _ _ (Can.Holey aliased) ->
            collectFreeVars aliased

        Can.TAlias _ _ _ (Can.Filled aliased) ->
            collectFreeVars aliased


{-| Recursively walk child expressions.
-}
walkChildren :
    Name.Name
    -> Set String
    -> Can.Expr_
    -> Array (Maybe Can.Type)
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
            go expr ++ DMap.foldl A.compareLocated (\_ (Can.FieldUpdate _ e) acc -> go e ++ acc) [] fields

        Can.Record fields ->
            DMap.foldl A.compareLocated (\_ e acc -> go e ++ acc) [] fields

        Can.Tuple a b extras ->
            go a ++ go b ++ List.concatMap go extras

        -- Leaf nodes: no children to walk
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


{-| Format violations for test output.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "TYPE_007 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ String.join "\n\n" (List.map formatOne violations)


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
