module TestLogic.Type.PostSolve.PostSolveNodeTypeGrounded exposing
    ( Violation
    , check
    , formatViolations
    )

{-| Checks that, after PostSolve, an expression's type mentions no type variable
that nothing in scope accounts for.

Such a variable is quantified by no type scheme enclosing the expression. The
test suite treats any such variable as a defect in PostSolve, and this module
finds the nodes where one occurs.

A node type is the type recorded for one expression or pattern, held in an
array indexed by the node's id. `check` takes two such arrays for one module:
`nodeTypesPre`, the node types before PostSolve, and `nodeTypesPost`, the node
types after it. Only the post-PostSolve types are checked. The pre-PostSolve
types are used only to find binders: those of a definition that has no scheme,
and those of a `LetDestruct` pattern. A node whose id is negative, or that has
no post-PostSolve type, is not checked.

The check rests on an environment: the set of type-variable names in scope at a
node. Each top-level declaration starts from an empty environment, and a
definition adds its binders for its own body and, in a `let`, for the `let`
body. A definition's binders are:

  - for a `TypedDef`, the variables of its annotation;
  - for a `Def` whose name has an entry in `annotations`, the variables that
    scheme quantifies over;
  - for any other `Def`, the free variables of the pre-PostSolve types of its
    argument patterns and of its body.

Every member of a recursive group (`DeclareRec` or `LetRec`) sees the binders
of all the members. A `LetDestruct` adds the free variables of its pattern's
pre-PostSolve type, for both the destructured expression and the body. Lambda
arguments and case patterns add nothing.

A checked node fails, and becomes a `Violation`, when its post-PostSolve type
mentions a variable that is neither in the environment nor a type-class
variable. A type-class variable is any name that starts with `number`,
`comparable`, `appendable` or `compappend`. This is a prefix match, so a
variable named `numberOfX` is exempt too.

Some kinds of node are not checked themselves, although the nodes inside them
are: kernel, local, top-level, foreign, operator, debug and constructor
variables; accessors; list, record and tuple literals; lambdas; and calls whose
function is a kernel, top-level, foreign, operator or constructor variable. A
call through any other function, such as a local variable, is checked.

The variables of a type are its `TVar`s and its records' extension variables.
A `Filled` alias contributes the variables of its body, and a `Holey` alias
those of its arguments, which its body's parameters stand for.

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)
import Set exposing (Set)


{-| One checked expression whose post-PostSolve type mentions type variables
that are neither in the environment nor type-class variables.

`orphanVars` are those variables, in ascending order, and `envTVars` is the
environment at the node. `functionName` is the top-level definition the node is
in, even when the node is inside a `let`-bound definition. `exprKind` is the
name of the node's `Can.Expr_` constructor, such as `"Case"`.

-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , orphanVars : List String
    , functionName : String
    , envTVars : Set String
    }


{-| Returns a `Violation` for each checked node in the module that fails, given
the module's `annotations` and its node types before and after PostSolve. An
empty list means the module passes.
-}
check :
    Can.Module
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> Array (Maybe (Can.Type Name))
    -> List Violation
check (Can.Module modData) annotations nodeTypesPre nodeTypesPost =
    checkDecls modData.decls annotations nodeTypesPre nodeTypesPost Set.empty


{-| Returns the violations in a chain of top-level declarations. Each
declaration is checked under `outerEnv` extended by its own binders, or, for a
recursive group, by the binders of every member.
-}
checkDecls :
    Can.Decls
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> Array (Maybe (Can.Type Name))
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


{-| Returns the names of the type variables a definition binds.

A `TypedDef` binds the variables of its annotation. A `Def` whose name has an
entry in `annotations` binds the variables that scheme quantifies over. Any
other `Def` binds the free variables of the pre-PostSolve types of its argument
patterns and its body; an argument or body with no pre-PostSolve type
contributes nothing.

-}
getBinders : Can.Def -> Dict Name.Name (Can.Annotation Name) -> Array (Maybe (Can.Type Name)) -> Set String
getBinders def annotations nodeTypesPre =
    case def of
        Can.TypedDef _ freeVars _ _ _ ->
            Dict.keys freeVars |> Set.fromList

        Can.Def (A.At _ name) args body ->
            case Dict.get name annotations of
                Just (Can.Forall freeVars _) ->
                    Dict.keys freeVars |> Set.fromList

                Nothing ->
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


{-| Returns the name a definition defines.
-}
defName : Can.Def -> Name.Name
defName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Returns the violations in a definition's body, checked under `env` and
attributed to the top-level definition `funcName`. The argument patterns are
not walked.
-}
checkDefBody :
    Name.Name
    -> Can.Def
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> Array (Maybe (Can.Type Name))
    -> Set String
    -> List Violation
checkDefBody funcName def annotations nodeTypesPre nodeTypesPost env =
    case def of
        Can.Def _ _ body ->
            walkExpr funcName annotations nodeTypesPre nodeTypesPost env body

        Can.TypedDef _ _ _ body _ ->
            walkExpr funcName annotations nodeTypesPre nodeTypesPost env body


{-| Returns `True` for a type-variable name that starts with `number`,
`comparable`, `appendable` or `compappend`. It is a prefix match, so `number2`
and `numberOfX` both count.
-}
isTypeClassVar : String -> Bool
isTypeClassVar name =
    String.startsWith "number" name
        || String.startsWith "comparable" name
        || String.startsWith "appendable" name
        || String.startsWith "compappend" name


{-| Returns the violations in an expression under `env`: one for the expression
itself if it is checked and fails, followed by those of the expressions inside
it. The expressions inside are walked whether or not the expression itself is
checked.
-}
walkExpr :
    Name.Name
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> Array (Maybe (Can.Type Name))
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


{-| Returns `True` for a node whose own type is not checked.

These are kernel, local, top-level, foreign, operator, debug and constructor
variables; accessors; list, record and tuple literals; lambdas; and calls whose
function is a kernel, top-level, foreign, operator or constructor variable. A
call through anything else, such as a local variable, a lambda or another call,
is not skipped, and neither is any other kind of node.

-}
isSkippable : Can.Expr_ -> Bool
isSkippable node =
    case node of
        Can.VarKernel _ _ _ ->
            True

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

        Can.Accessor _ ->
            True

        Can.VarCtor _ _ _ _ _ ->
            True

        Can.List _ ->
            True

        Can.Record _ ->
            True

        Can.Tuple _ _ _ ->
            True

        Can.Lambda _ _ ->
            True

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

                        -- A call through a local or debug variable is
                        -- checked, although those variables standing alone
                        -- are not.
                        _ ->
                            False

        _ ->
            False


{-| Returns the name of a node's `Can.Expr_` constructor, for reports.
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


{-| Returns the violations in the expressions directly inside a node, including
the bodies of its `let`-bound definitions. For a `let`, `env` is extended by
the binders of its definitions or destructured pattern; every other node's
children are checked under `env` unchanged.
-}
walkChildren :
    Name.Name
    -> Dict Name.Name (Can.Annotation Name)
    -> Array (Maybe (Can.Type Name))
    -> Array (Maybe (Can.Type Name))
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

        Can.LetDestruct pat bindExpr body ->
            let
                patBinders =
                    case Array.get (getPatternId pat) nodeTypesPre |> Maybe.andThen identity of
                        Just patType ->
                            collectFreeVars patType

                        Nothing ->
                            Set.empty

                innerEnv =
                    Set.union env patBinders
            in
            walkExpr funcName annotations nodeTypesPre nodeTypesPost innerEnv bindExpr
                ++ walkExpr funcName annotations nodeTypesPre nodeTypesPost innerEnv body

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
                ++ DMap.foldl
                    (\_ (Can.FieldUpdate _ e) acc -> go e ++ acc)
                    []
                    fields

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


{-| Returns the names of the `TVar`s in a type, a record's extension variable
included. A `Filled` alias contributes the variables of its body. A `Holey`
alias's body is written in the alias's own parameter names, so it contributes
the variables of its arguments, which those parameters stand for.
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


{-| Returns a failure message for `violations`: a header line giving their
count, then one line per violation, separated by blank lines. Each line names
the expression kind, node id and enclosing top-level definition, then lists
the orphan variables and the environment.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "POST_010 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ String.join "\n\n" (List.map formatOne violations)


{-| Returns the one-line description of a violation that `formatViolations`
uses.
-}
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
