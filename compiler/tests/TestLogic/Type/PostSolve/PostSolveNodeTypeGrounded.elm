module TestLogic.Type.PostSolve.PostSolveNodeTypeGrounded exposing
    ( Violation
    , check
    , formatViolations
    )

{-| Test logic for invariant POST\_010: All node type TVars come from enclosing
type schemes.

For every non-kernel expression node, every Can.TVar in its post-PostSolve
type must be traceable to one of three legitimate sources:

1. Annotation binders (Forall freeVars from TypedDef or annotations dict)
2. Inferred body TVars from unannotated let-bound defs (FreeTVars of their
   pre-PostSolve body type, representing solver let-generalization)
3. Type-class variables (number, comparable, appendable, compappend with
   optional digit suffixes) which are internal solver constraints

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)
import Set exposing (Set)


type alias Violation =
    { nodeId : Int
    , exprKind : String
    , orphanVars : List String
    , functionName : String
    , envTVars : Set String
    }


{-| Check POST\_010 across all declarations in a module.
-}
check :
    Can.Module
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> Array (Maybe Can.Type)
    -> List Violation
check (Can.Module modData) annotations nodeTypesPre nodeTypesPost =
    checkDecls modData.decls annotations nodeTypesPre nodeTypesPost Set.empty


checkDecls :
    Can.Decls
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> Array (Maybe Can.Type)
    -> Set String
    -> List Violation
checkDecls decls annotations nodeTypesPre nodeTypesPost outerEnv =
    case decls of
        Can.Declare def rest ->
            let
                defBinders =
                    getBinders def annotations nodeTypesPre

                env =
                    Set.union outerEnv defBinders
            in
            checkDefBody (defName def) def annotations nodeTypesPre nodeTypesPost env
                ++ checkDecls rest annotations nodeTypesPre nodeTypesPost outerEnv

        Can.DeclareRec def defs rest ->
            let
                allBinders =
                    List.foldl
                        (\d acc -> Set.union acc (getBinders d annotations nodeTypesPre))
                        (getBinders def annotations nodeTypesPre)
                        defs

                env =
                    Set.union outerEnv allBinders
            in
            checkDefBody (defName def) def annotations nodeTypesPre nodeTypesPost env
                ++ List.concatMap
                    (\d -> checkDefBody (defName d) d annotations nodeTypesPre nodeTypesPost env)
                    defs
                ++ checkDecls rest annotations nodeTypesPre nodeTypesPost outerEnv

        Can.SaveTheEnvironment ->
            []


{-| Extract type scheme binders from a definition.

For TypedDef: use the explicit FreeVars from the annotation.
For Def with annotations dict entry: use the Forall binders (solver-inferred scheme).
For Def without annotations dict entry: infer binders from the full inferred
function type — argument pattern types + body result type from pre-PostSolve
nodeTypes. This captures solver let-generalization including parameter TVars.

-}
getBinders : Can.Def -> Dict Name.Name Can.Annotation -> Array (Maybe Can.Type) -> Set String
getBinders def annotations nodeTypesPre =
    case def of
        Can.TypedDef _ freeVars _ _ _ ->
            Dict.keys freeVars |> Set.fromList

        Can.Def (A.At _ name) args body ->
            case Dict.get name annotations of
                Just (Can.Forall freeVars _) ->
                    Dict.keys freeVars |> Set.fromList

                Nothing ->
                    -- Infer binders from the full inferred function type:
                    -- argument pattern types + body result type.
                    let
                        bodyId =
                            getExprId body

                        bodyTVars =
                            case Array.get bodyId nodeTypesPre |> Maybe.andThen identity of
                                Just preType ->
                                    collectFreeVars preType

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
                                        case Array.get patId nodeTypesPre |> Maybe.andThen identity of
                                            Just patType ->
                                                Set.union acc (collectFreeVars patType)

                                            Nothing ->
                                                acc
                                    )
                                    Set.empty
                    in
                    Set.union bodyTVars argTVars


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


{-| Get the name from a definition.
-}
defName : Can.Def -> Name.Name
defName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Walk a definition's body expression.
-}
checkDefBody :
    Name.Name
    -> Can.Def
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> Array (Maybe Can.Type)
    -> Set String
    -> List Violation
checkDefBody funcName def annotations nodeTypesPre nodeTypesPost env =
    case def of
        Can.Def _ _ body ->
            walkExpr funcName annotations nodeTypesPre nodeTypesPost env body

        Can.TypedDef _ _ _ body _ ->
            walkExpr funcName annotations nodeTypesPre nodeTypesPost env body


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


{-| Walk an expression, checking each node's type and recursing into children.
-}
walkExpr :
    Name.Name
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> Array (Maybe Can.Type)
    -> Set String
    -> Can.Expr
    -> List Violation
walkExpr funcName annotations nodeTypesPre nodeTypesPost env (A.At _ exprInfo) =
    let
        nodeId =
            exprInfo.id

        thisViolations =
            if nodeId < 0 || isSkippable exprInfo.node then
                []

            else
                case Array.get nodeId nodeTypesPost |> Maybe.andThen identity of
                    Nothing ->
                        []

                    Just postType ->
                        let
                            freeTVars =
                                collectFreeVars postType

                            orphans =
                                Set.diff freeTVars env
                                    |> Set.filter (\v -> not (isTypeClassVar v))
                        in
                        if Set.isEmpty orphans then
                            []

                        else
                            [ { nodeId = nodeId
                              , exprKind = exprKindName exprInfo.node
                              , orphanVars = Set.toList orphans
                              , functionName = funcName
                              , envTVars = env
                              }
                            ]

        childViolations =
            walkChildren funcName annotations nodeTypesPre nodeTypesPost env exprInfo.node
    in
    thisViolations ++ childViolations


{-| Should this node be skipped by POST\_010?

We skip:

  - Kernel primitives and accessors (governed by kernel/layout invariants).
  - Leaf variables whose types are just scheme uses (local/top-level/foreign/operators).
  - Constructors (their TVars belong to the type's scheme, not the local def).
  - Container literals (List/Record/Tuple) whose internal polymorphism is harmless.
  - Lambdas whose types are entirely determined by surrounding schemes
    (dedicated lambda invariants POST\_007/008/009 check them).
  - Calls whose callee is a simple Var* head (polymorphic scheme instantiation).

POST\_010 still checks result-producing nodes like If/Case/Let/LetRec/LetDestruct,
Binop, Negate, Access, Update, and Calls with non-trivial callees.

-}
isSkippable : Can.Expr_ -> Bool
isSkippable node =
    case node of
        -- Kernel primitives: handled by kernel-specific invariants.
        Can.VarKernel _ _ _ ->
            True

        -- Leaf vars: their TVars come from their own scheme, not this def's.
        Can.VarLocal _ ->
            True

        Can.VarTopLevel _ _ ->
            True

        Can.VarForeign _ _ _ ->
            True

        Can.VarOperator _ _ _ _ ->
            True

        Can.VarDebug _ _ _ ->
            True

        -- Accessor combinators: polymorphism lives in their scheme.
        Can.Accessor _ ->
            True

        -- Constructors: polymorphism belongs to the ADT's scheme.
        Can.VarCtor _ _ _ _ _ ->
            True

        -- Container literals often carry harmless internal polymorphism,
        -- e.g. [] : List a where 'a' never escapes.
        Can.List _ ->
            True

        Can.Record _ ->
            True

        Can.Tuple _ _ _ ->
            True

        -- Lambda node types are checked by POST_007/008/009; POST_010
        -- does not need to re-verify their TVars against EnvTVars.
        Can.Lambda _ _ ->
            True

        -- Calls whose callee is a simple Var* head: the result type is
        -- just an instantiation of that scheme (top-level, foreign,
        -- kernel, operator, or ctor). Any TVars not in EnvTVars are
        -- still legitimate, because they belong to the callee's scheme.
        Can.Call fn _ ->
            case fn of
                A.At _ fnInfo ->
                    case fnInfo.node of
                        Can.VarKernel _ _ _ ->
                            True

                        Can.VarTopLevel _ _ ->
                            True

                        Can.VarForeign _ _ _ ->
                            True

                        Can.VarOperator _ _ _ _ ->
                            True

                        Can.VarCtor _ _ _ _ _ ->
                            True

                        -- Calls through a local variable (e.g. higher-order
                        -- args, combinators) we still check, because that
                        -- result type is part of the current def's behavior.
                        _ ->
                            False

        _ ->
            False


{-| Get a human-readable name for the expression kind.
-}
exprKindName : Can.Expr_ -> String
exprKindName node =
    case node of
        Can.If _ _ ->
            "If"

        Can.Case _ _ ->
            "Case"

        Can.Let _ _ ->
            "Let"

        Can.LetRec _ _ ->
            "LetRec"

        Can.LetDestruct _ _ _ ->
            "LetDestruct"

        Can.Lambda _ _ ->
            "Lambda"

        Can.Call _ _ ->
            "Call"

        Can.Binop _ _ _ _ _ _ ->
            "Binop"

        Can.VarLocal _ ->
            "VarLocal"

        Can.VarTopLevel _ _ ->
            "VarTopLevel"

        Can.VarForeign _ _ _ ->
            "VarForeign"

        Can.VarCtor _ _ _ _ _ ->
            "VarCtor"

        Can.VarOperator _ _ _ _ ->
            "VarOperator"

        Can.VarDebug _ _ _ ->
            "VarDebug"

        Can.List _ ->
            "List"

        Can.Negate _ ->
            "Negate"

        Can.Access _ _ ->
            "Access"

        Can.Update _ _ ->
            "Update"

        Can.Record _ ->
            "Record"

        Can.Tuple _ _ _ ->
            "Tuple"

        Can.Unit ->
            "Unit"

        Can.Chr _ ->
            "Chr"

        Can.Str _ ->
            "Str"

        Can.Int _ ->
            "Int"

        Can.Float _ ->
            "Float"

        Can.Shader _ _ ->
            "Shader"

        Can.VarKernel _ _ _ ->
            "VarKernel"

        Can.Accessor _ ->
            "Accessor"


{-| Recurse into child expressions, extending env for let bindings.
-}
walkChildren :
    Name.Name
    -> Dict Name.Name Can.Annotation
    -> Array (Maybe Can.Type)
    -> Array (Maybe Can.Type)
    -> Set String
    -> Can.Expr_
    -> List Violation
walkChildren funcName annotations nodeTypesPre nodeTypesPost env node =
    let
        go =
            walkExpr funcName annotations nodeTypesPre nodeTypesPost env
    in
    case node of
        Can.If branches final ->
            List.concatMap (\( cond, body ) -> go cond ++ go body) branches
                ++ go final

        Can.Case scrutinee branches ->
            go scrutinee
                ++ List.concatMap (\(Can.CaseBranch _ body) -> go body) branches

        Can.Let def body ->
            let
                defBinders =
                    getBinders def annotations nodeTypesPre

                innerEnv =
                    Set.union env defBinders
            in
            checkDefBody funcName def annotations nodeTypesPre nodeTypesPost innerEnv
                ++ walkExpr funcName annotations nodeTypesPre nodeTypesPost innerEnv body

        Can.LetRec defs body ->
            let
                allBinders =
                    List.foldl (\d acc -> Set.union acc (getBinders d annotations nodeTypesPre)) Set.empty defs

                innerEnv =
                    Set.union env allBinders
            in
            List.concatMap
                (\d -> checkDefBody funcName d annotations nodeTypesPre nodeTypesPost innerEnv)
                defs
                ++ walkExpr funcName annotations nodeTypesPre nodeTypesPost innerEnv body

        Can.LetDestruct _ bindExpr body ->
            go bindExpr ++ go body

        Can.Lambda _ body ->
            go body

        Can.Call fn args ->
            go fn ++ List.concatMap go args

        Can.Binop _ _ _ _ left right ->
            go left ++ go right

        Can.Negate expr ->
            go expr

        Can.List items ->
            List.concatMap go items

        Can.Access expr _ ->
            go expr

        Can.Update expr fields ->
            go expr
                ++ DMap.foldl A.compareLocated
                    (\_ (Can.FieldUpdate _ e) acc -> go e ++ acc)
                    []
                    fields

        Can.Record fields ->
            DMap.foldl A.compareLocated (\_ e acc -> go e ++ acc) [] fields

        Can.Tuple a b extras ->
            go a ++ go b ++ List.concatMap go extras

        -- Leaf nodes
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


{-| Format violations for test output.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "POST_010 violations found ("
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
        ++ "': orphan TVars ["
        ++ String.join ", " v.orphanVars
        ++ "] not in enclosing binders ["
        ++ String.join ", " (Set.toList v.envTVars)
        ++ "]"
