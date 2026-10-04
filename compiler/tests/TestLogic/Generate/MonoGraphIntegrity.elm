module TestLogic.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphClosed
    , expectMonoGraphComplete
    , expectSpecRegistryComplete
    )

{-| Structural checks on the monomorphized program graph, written as
expectations over a source module. They exist so that a graph with a dangling
reference, or with a function-typed definition that is not callable, fails a
test of its own.

Each exposed function compiles a `Src.Module` with `TestLogic.TestPipeline`
and, if the pipeline returns an error, fails with that error's message.
Otherwise it walks the resulting `Mono.MonoGraph` and fails if a check finds a
problem. The graph's `nodes` array holds one optional node per _SpecId_, the
number of a specialization (one definition at one concrete type); an index
holding `Nothing` has no node. Three of the checks read the graph that
`Pipeline.runToMono` builds, and the callability check reads the one
`Pipeline.runToGlobalOpt` returns after global optimization.

What the checks establish:

  - `expectCallableMonoNodes`: in the globally optimized graph, a `MonoDefine`
    with a function type has an expression the check counts as callable, and
    a `MonoTailFunc` has a function type.
  - `expectSpecRegistryComplete`: every SpecId that has an entry in the
    registry's `reverseMapping` has a node.
  - `expectMonoGraphClosed`: every SpecId named by a `MonoVarGlobal` in a node
    body has a node, and every `MonoVarLocal` is in scope where it occurs,
    under the scope rules that function's docstring gives.
  - `expectMonoGraphComplete`: nothing beyond the pipeline reaching a
    monomorphized graph; its list of checks is always empty.

The failures a check finds are combined with `Expect.all`, so a failing test
reports only the first of them.

Among what is not checked: that every node has a registry entry; SpecIds named
by the graph's `main`, `flagsDecoder` or `ports` fields, or from the leaves a
case's decision tree holds inline; a case's root variable and the paths in its
decision tree; and that a closure body names only its parameters and captures.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Set as Set exposing (EverySet)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through global optimization and checks that each
function-typed `MonoDefine` of the optimized graph has a callable expression
and that each `MonoTailFunc` has a function type.

A `MonoDefine` whose type is a function passes when its expression is
callable: a closure; a local, global or kernel variable whose type is a
function; a call whose result type is a function; a `let` or destructuring
whose body is callable; an `if` whose `else` branch is callable; or a `case`
whose first jump branch is callable. A jump branch is one the case's decision
tree reaches by `Jump` instead of holding it inline. Only that one branch of
an `if` or `case` is looked at, and a `case` with no jump branches counts as
not callable. A `MonoTailFunc` passes when its type is a function. Every other
node passes, as does a `MonoDefine` whose type is not a function.

-}
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                checks =
                    collectCallabilityChecks optimizedMonoGraph
            in
            case checks of
                -- `Expect.all` fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Runs `srcModule` through monomorphization and passes whenever that
succeeds. It is named for the type completeness of the graph, but it checks
nothing in the graph: its list of checks is always empty.
-}
expectMonoGraphComplete : Src.Module -> Expect.Expectation
expectMonoGraphComplete srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectCompletenessChecks monoGraph
            in
            case checks of
                -- `Expect.all` fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Runs `srcModule` through monomorphization and checks the graph for
dangling references: every SpecId named by a `MonoVarGlobal` in a node body
must have a node, and every `MonoVarLocal` must be in scope where it occurs.

A `MonoTailFunc` node's body starts with its parameters in scope, and a
`MonoDefine` or port body with nothing. A name comes into scope from a closure's
parameters and captures, a tail-recursive local definition's parameters, a
destructuring's bound name, and a case's label (the first `Name` of
`MonoCase`, not the second, which names the variable the case matches on). The
definitions of a chain of directly nested `let`s are all in scope throughout
the chain, so a definition may name a later one in the same chain. A
destructuring's path must start from a name in scope. A closure body also sees
every name in scope around the closure, so a body that names an enclosing
variable it does not capture passes.

SpecIds are not collected from the leaves a case's decision tree holds inline,
and neither a case's root variable nor the paths in its decision tree are
checked.

-}
expectMonoGraphClosed : Src.Module -> Expect.Expectation
expectMonoGraphClosed srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectClosureChecks monoGraph
            in
            case checks of
                -- `Expect.all` fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Runs `srcModule` through monomorphization and checks that every SpecId
with an entry in the registry's `reverseMapping` has a node. A node with no
registry entry is not looked for, and the registry's forward `mapping` is not
read.
-}
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectRegistryChecks monoGraph
            in
            case checks of
                -- `Expect.all` fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- CALLABILITY
-- ============================================================================


{-| Returns the failing checks `checkNodeCallability` gives for every node of
the graph, each labelled with the node's SpecId.
-}
collectCallabilityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCallabilityChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeCallability specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns one failing check, labelled with `specId`, when `node` is a
`MonoDefine` of function type whose expression `isCallableExpression` rejects,
or a `MonoTailFunc` whose type is not a function. Returns no checks for any
other node.
-}
checkNodeCallability : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
checkNodeCallability specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    if isCallableExpression expr then
                        []

                    else
                        [ \() -> Expect.fail (context ++ ": Function-typed MonoDefine has non-callable expression") ]

                _ ->
                    []

        Mono.MonoTailFunc _ _ monoType ->
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    []

                _ ->
                    [ \() -> Expect.fail (context ++ ": MonoTailFunc has non-function type") ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoPortIncoming _ _ ->
            []

        Mono.MonoPortOutgoing _ _ ->
            []


{-| Returns whether `expr` counts as producing a callable function value.

It does when `expr` is a closure; a local, global or kernel variable whose own
type is a function; or a call whose result type is a function. A `let` or
destructuring counts when its body does, an `if` when its `else` branch does,
and a `case` when the first of its jump branches does, so a `case` whose
branches are all held inline in its decision tree does not count. No other
expression counts, whatever its type.

-}
isCallableExpression : Mono.MonoExpr -> Bool
isCallableExpression expr =
    case expr of
        Mono.MonoClosure _ _ _ ->
            True

        Mono.MonoVarLocal _ monoType ->
            isFunctionType monoType

        Mono.MonoVarGlobal _ _ monoType ->
            isFunctionType monoType

        Mono.MonoVarKernel _ _ _ _ monoType ->
            isFunctionType monoType

        Mono.MonoCall _ _ _ resultType _ ->
            isFunctionType resultType

        Mono.MonoLet _ body _ ->
            isCallableExpression body

        Mono.MonoIf _ final _ ->
            isCallableExpression final

        Mono.MonoCase _ _ _ branches _ ->
            case branches of
                ( _, branchExpr ) :: _ ->
                    isCallableExpression branchExpr

                [] ->
                    False

        Mono.MonoDestruct _ inner _ ->
            isCallableExpression inner

        _ ->
            False


{-| Returns whether `monoType` is a function type (`MFunction`).
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False



-- ============================================================================
-- TYPE COMPLETENESS
-- ============================================================================


{-| Returns no checks, whatever the graph. This is the whole of the type
completeness check.
-}
collectCompletenessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCompletenessChecks (Mono.MonoGraph _) =
    []


{-| Returns the custom type references found in `monoType`, which is always
the empty list. It walks into custom type arguments, list elements, and
function parameters and results, but contributes nothing for a custom type
itself, and it does not look inside tuples or records. No check in this module
uses it.
-}
collectCustomTypeRefsFromType : Mono.MonoType -> List ( List String, String )
collectCustomTypeRefsFromType monoType =
    case monoType of
        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap collectCustomTypeRefsFromType typeArgs

        Mono.MList _ elemType ->
            collectCustomTypeRefsFromType elemType

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap collectCustomTypeRefsFromType paramTypes
                ++ collectCustomTypeRefsFromType returnType

        _ ->
            []


{-| Returns the custom type references found in the types of `expr` and its
subexpressions with `collectCustomTypeRefsFromType`, which is always the empty
list. No check in this module uses it.
-}
collectCustomTypeRefsFromExpr : Mono.MonoExpr -> List ( List String, String )
collectCustomTypeRefsFromExpr expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarLocal _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarGlobal _ _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarKernel _ _ _ _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoList _ exprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, t ) -> collectCustomTypeRefsFromType t) closureInfo.params
                ++ List.concatMap (\( _, e, _ ) -> collectCustomTypeRefsFromExpr e) closureInfo.captures
                ++ collectCustomTypeRefsFromExpr bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType _ ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr fnExpr
                ++ List.concatMap collectCustomTypeRefsFromExpr argExprs

        Mono.MonoTailCall _ args monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) args

        Mono.MonoIf branches elseExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( c, t ) -> collectCustomTypeRefsFromExpr c ++ collectCustomTypeRefsFromExpr t) branches
                ++ collectCustomTypeRefsFromExpr elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromDef def
                ++ collectCustomTypeRefsFromExpr bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) branches

        Mono.MonoRecordCreate fieldExprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr elementExprs

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns the custom type references found in `def`'s parameter types and
body, which is always the empty list. No check in this module uses it.
-}
collectCustomTypeRefsFromDef : Mono.MonoDef -> List ( List String, String )
collectCustomTypeRefsFromDef def =
    case def of
        Mono.MonoDef _ expr ->
            collectCustomTypeRefsFromExpr expr

        Mono.MonoTailDef _ params expr ->
            List.concatMap (\( _, t ) -> collectCustomTypeRefsFromType t) params
                ++ collectCustomTypeRefsFromExpr expr



-- ============================================================================
-- CLOSEDNESS
-- ============================================================================


{-| Returns one failing check for each SpecId that a node body names with
`MonoVarGlobal` but that has no node, in ascending order, followed by the
local variable failures `checkNodeLocalVarScoping` gives for every node.
-}
collectClosureChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectClosureChecks (Mono.MonoGraph data) =
    let
        definedSpecIds =
            Array.foldl
                (\maybeNode ( idx, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( idx + 1, Set.insert identity idx acc )

                        Nothing ->
                            ( idx + 1, acc )
                )
                ( 0, Set.empty )
                data.nodes
                |> Tuple.second

        referencedSpecIds =
            Array.foldl
                (\maybeNode acc ->
                    case maybeNode of
                        Nothing ->
                            acc

                        Just node ->
                            Set.union acc (collectSpecIdRefsFromNode node)
                )
                Set.empty
                data.nodes

        undefinedRefs =
            Set.diff referencedSpecIds definedSpecIds
                |> Set.toList compare

        specIdIssues =
            List.map
                (\specId -> \() -> Expect.fail ("MONO_011: Referenced SpecId " ++ String.fromInt specId ++ " is not defined in nodes"))
                undefinedRefs

        localVarIssues =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just node ->
                            ( specId + 1, checkNodeLocalVarScoping specId node ++ acc )
                )
                ( 0, [] )
                data.nodes
                |> Tuple.second
    in
    specIdIssues ++ localVarIssues


{-| Returns one failing check, labelled with `specId`, for each `MonoVarLocal`
in `node` that is out of scope. A `MonoTailFunc` body starts with its
parameters in scope, and a `MonoDefine` or port body with nothing. Other nodes
have no body and give no checks.
-}
checkNodeLocalVarScoping : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
checkNodeLocalVarScoping specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            checkExprLocalVarScoping context Set.empty expr

        Mono.MonoTailFunc params expr _ ->
            let
                boundNames =
                    List.map (\( name, _ ) -> name) params
                        |> Set.fromList identity
            in
            checkExprLocalVarScoping context boundNames expr

        Mono.MonoPortIncoming expr _ ->
            checkExprLocalVarScoping context Set.empty expr

        Mono.MonoPortOutgoing expr _ ->
            checkExprLocalVarScoping context Set.empty expr

        _ ->
            []


{-| Returns one failing check for each `MonoVarLocal` in `expr` that is
neither in `inScope` nor bound around it inside `expr`, and for each
destructuring path whose root is out of scope. `context` names the node in the
failure messages.

A closure body sees `inScope` together with the closure's parameters and
captures, while the capture expressions themselves are checked against
`inScope`. The definitions of a chain of directly nested `let`s, gathered by
`collectLetChain`, are in scope in every definition of the chain and in its
final body. A destructuring's name is in scope in its body. A case's label, the
first `Name` of `MonoCase`, is in scope in its decision tree and its jump
branches; the case's root variable is not checked.

-}
checkExprLocalVarScoping : String -> Set.EverySet String String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
checkExprLocalVarScoping context inScope expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            if Set.member identity name inScope then
                []

            else
                [ \() -> Expect.fail ("MONO_011: MonoVarLocal '" ++ name ++ "' is not in scope at " ++ context) ]

        Mono.MonoList _ exprs _ ->
            List.concatMap (checkExprLocalVarScoping context inScope) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            let
                paramNames =
                    List.map (\( name, _ ) -> name) closureInfo.params
                        |> Set.fromList identity

                captureNames =
                    List.map (\( name, _, _ ) -> name) closureInfo.captures
                        |> Set.fromList identity

                bodyScope =
                    Set.union inScope (Set.union paramNames captureNames)

                captureIssues =
                    List.concatMap (\( _, e, _ ) -> checkExprLocalVarScoping context inScope e) closureInfo.captures
            in
            captureIssues ++ checkExprLocalVarScoping context bodyScope bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            checkExprLocalVarScoping context inScope fnExpr
                ++ List.concatMap (checkExprLocalVarScoping context inScope) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> checkExprLocalVarScoping context inScope e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> checkExprLocalVarScoping context inScope c ++ checkExprLocalVarScoping context inScope t) branches
                ++ checkExprLocalVarScoping context inScope elseExpr

        Mono.MonoLet def bodyExpr _ ->
            let
                ( defs, finalBody ) =
                    collectLetChain def bodyExpr

                groupNames : Set.EverySet String String
                groupNames =
                    defs
                        |> List.map getDefName
                        |> List.foldl (Set.insert identity) Set.empty

                groupScope : Set.EverySet String String
                groupScope =
                    Set.union inScope groupNames

                defViolations : List (() -> Expect.Expectation)
                defViolations =
                    defs
                        |> List.concatMap (checkDefLocalVarScoping context groupScope)

                bodyViolations : List (() -> Expect.Expectation)
                bodyViolations =
                    checkExprLocalVarScoping context groupScope finalBody
            in
            defViolations ++ bodyViolations

        Mono.MonoDestruct (Mono.MonoDestructor name path _) bodyExpr _ ->
            let
                pathRootIssues =
                    checkPathRootInScope context inScope path

                destructScope =
                    Set.insert identity name inScope
            in
            pathRootIssues ++ checkExprLocalVarScoping context destructScope bodyExpr

        Mono.MonoCase scrutName _ decider branches _ ->
            let
                caseScope =
                    Set.insert identity scrutName inScope
            in
            checkDeciderLocalVarScoping context caseScope decider
                ++ List.concatMap (\( _, e ) -> checkExprLocalVarScoping context caseScope e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> checkExprLocalVarScoping context inScope e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            checkExprLocalVarScoping context inScope recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            checkExprLocalVarScoping context inScope recordExpr
                ++ List.concatMap (\( _, e ) -> checkExprLocalVarScoping context inScope e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (checkExprLocalVarScoping context inScope) elementExprs

        _ ->
            []


{-| Returns one failing check, mentioning `context`, when the variable `path`
starts from is not in `inScope`, and no checks otherwise.
-}
checkPathRootInScope : String -> Set.EverySet String String -> Mono.MonoPath -> List (() -> Expect.Expectation)
checkPathRootInScope context inScope path =
    let
        rootName =
            getPathRootName path
    in
    if Set.member identity rootName inScope then
        []

    else
        [ \() -> Expect.fail ("MONO_011: MonoPath root variable '" ++ rootName ++ "' is not in scope at " ++ context) ]


{-| Returns the name of the variable `path` starts from.
-}
getPathRootName : Mono.MonoPath -> String
getPathRootName path =
    case path of
        Mono.MonoRoot name _ ->
            name

        Mono.MonoIndex _ _ _ subPath ->
            getPathRootName subPath

        Mono.MonoField _ _ subPath ->
            getPathRootName subPath

        Mono.MonoUnbox _ subPath ->
            getPathRootName subPath


{-| Returns the name `def` binds.
-}
getDefName : Mono.MonoDef -> String
getDefName def =
    case def of
        Mono.MonoDef name _ ->
            name

        Mono.MonoTailDef name _ _ ->
            name


{-| Returns the definitions of the chain of `let`s that starts with
`firstDef` and continues through every `MonoLet` found directly in body
position, outermost first, together with the body the chain ends in.

The typed optimizer turns a group of mutually recursive local definitions
into directly nested `let`s, so the chain is treated as one scope. A chain of
lets that are not mutually recursive is treated as one scope too.

-}
collectLetChain :
    Mono.MonoDef
    -> Mono.MonoExpr
    -> ( List Mono.MonoDef, Mono.MonoExpr )
collectLetChain firstDef firstBody =
    let
        go defs expr =
            case expr of
                Mono.MonoLet def nextBody _ ->
                    go (defs ++ [ def ]) nextBody

                _ ->
                    ( defs, expr )
    in
    go [ firstDef ] firstBody


{-| Returns the out-of-scope failures `checkExprLocalVarScoping` gives for
the body of `def`, with the name `def` binds, and for a tail-recursive
definition its parameters, added to `inScope`.
-}
checkDefLocalVarScoping : String -> Set.EverySet String String -> Mono.MonoDef -> List (() -> Expect.Expectation)
checkDefLocalVarScoping context inScope def =
    case def of
        Mono.MonoDef name expr ->
            let
                defScope =
                    Set.insert identity name inScope
            in
            checkExprLocalVarScoping context defScope expr

        Mono.MonoTailDef name params expr ->
            let
                paramNames =
                    List.map (\( n, _ ) -> n) params
                        |> Set.fromList identity

                defScope =
                    Set.union (Set.insert identity name inScope) paramNames
            in
            checkExprLocalVarScoping context defScope expr


{-| Returns the out-of-scope failures of the expressions `decider` holds
inline in its leaves. `Jump` leaves and the paths the tree tests are not
checked.
-}
checkDeciderLocalVarScoping : String -> Set.EverySet String String -> Mono.Decider Mono.MonoChoice -> List (() -> Expect.Expectation)
checkDeciderLocalVarScoping context inScope decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    checkExprLocalVarScoping context inScope expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            checkDeciderLocalVarScoping context inScope success
                ++ checkDeciderLocalVarScoping context inScope failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDeciderLocalVarScoping context inScope d) edges
                ++ checkDeciderLocalVarScoping context inScope fallback


{-| Returns the SpecIds named by `MonoVarGlobal` in `node`'s body. Nodes
without a body name none.
-}
collectSpecIdRefsFromNode : Mono.MonoNode -> EverySet Int Int
collectSpecIdRefsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoTailFunc _ expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoCtor _ _ ->
            Set.empty

        Mono.MonoEnum _ _ ->
            Set.empty

        Mono.MonoExtern _ ->
            Set.empty

        Mono.MonoManagerLeaf _ _ ->
            Set.empty

        Mono.MonoPortIncoming expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoPortOutgoing expr _ ->
            collectSpecIdRefsFromExpr expr


{-| Returns the SpecIds named by `MonoVarGlobal` in `expr` and its
subexpressions. A case contributes only its jump branches: the expressions its
decision tree holds inline are not searched.
-}
collectSpecIdRefsFromExpr : Mono.MonoExpr -> EverySet Int Int
collectSpecIdRefsFromExpr expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            Set.insert identity specId Set.empty

        Mono.MonoList _ exprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.foldl
                (\( _, e, _ ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr bodyExpr)
                closureInfo.captures

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr fnExpr)
                argExprs

        Mono.MonoTailCall _ args _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                args

        Mono.MonoIf branches elseExpr _ ->
            List.foldl
                (\( c, t ) acc ->
                    Set.union acc (collectSpecIdRefsFromExpr c)
                        |> Set.union (collectSpecIdRefsFromExpr t)
                )
                (collectSpecIdRefsFromExpr elseExpr)
                branches

        Mono.MonoLet def bodyExpr _ ->
            Set.union
                (collectSpecIdRefsFromDef def)
                (collectSpecIdRefsFromExpr bodyExpr)

        Mono.MonoDestruct _ valueExpr _ ->
            collectSpecIdRefsFromExpr valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectSpecIdRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr recordExpr)
                updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                elementExprs

        _ ->
            Set.empty


{-| Returns the SpecIds named by `MonoVarGlobal` in the body of `def`.
-}
collectSpecIdRefsFromDef : Mono.MonoDef -> EverySet Int Int
collectSpecIdRefsFromDef def =
    case def of
        Mono.MonoDef _ expr ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoTailDef _ _ expr ->
            collectSpecIdRefsFromExpr expr



-- ============================================================================
-- REGISTRY COMPLETENESS
-- ============================================================================


{-| Returns one failing check for each SpecId with an entry in the registry's
`reverseMapping` that has no node, in ascending order.
-}
collectRegistryChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectRegistryChecks (Mono.MonoGraph data) =
    let
        definedSpecIds =
            Array.foldl
                (\maybeNode ( idx, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( idx + 1, Set.insert identity idx acc )

                        Nothing ->
                            ( idx + 1, acc )
                )
                ( 0, Set.empty )
                data.nodes
                |> Tuple.second

        registrySpecIds =
            collectRegistrySpecIds data.registry

        undefinedRegistrySpecIds =
            Set.diff registrySpecIds definedSpecIds
                |> Set.toList compare
    in
    List.map
        (\specId -> \() -> Expect.fail ("Registry contains SpecId " ++ String.fromInt specId ++ " which is not defined in nodes"))
        undefinedRegistrySpecIds


{-| Returns the SpecIds that have an entry in `registry`'s `reverseMapping`,
which is indexed by SpecId and holds `Nothing` where a SpecId has no entry.
-}
collectRegistrySpecIds : Mono.SpecializationRegistry -> EverySet Int Int
collectRegistrySpecIds registry =
    Array.toIndexedList registry.reverseMapping
        |> List.filterMap
            (\( idx, maybeEntry ) ->
                case maybeEntry of
                    Just _ ->
                        Just idx

                    Nothing ->
                        Nothing
            )
        |> Set.fromList identity
