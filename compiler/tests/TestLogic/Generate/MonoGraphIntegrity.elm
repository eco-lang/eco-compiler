module TestLogic.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , localVarScopingChecks
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
  - `expectMonoGraphComplete`: every custom type the graph uses has an entry
    in its `ctorShapes` table, and so does every custom type in the field
    types of those entries.

The failures a check finds are combined with `Expect.all`, so a failing test
reports only the first of them.

Among what is not checked: that every node has a registry entry; SpecIds named
by the graph's `main`, `flagsDecoder` or `ports` fields; the paths in a case's
decision tree; and that a `ctorShapes` entry lists all of a type's
constructors.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Data.Set as Set exposing (EverySet)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through global optimization and checks that each
function-typed `MonoDefine` of the optimized graph has a callable expression
and that each `MonoTailFunc` has a function type.

A `MonoDefine` whose type is a function passes when its expression is
callable: a closure; a local, global or kernel variable whose type is a
function; a call whose result type is a function; a `let` or destructuring
whose body is callable; an `if` all of whose branches are callable; or a
`case` all of whose branches, jumped to or held inline in its decision tree,
are callable. A `MonoTailFunc` passes when its type is a function. Every other
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


{-| Runs `srcModule` through monomorphization and checks the graph's type
completeness (MONO\_010): every custom type used by a node, and every custom
type in a constructor field of the `ctorShapes` table, has an entry in that
table, as `collectCompletenessChecks` describes.
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
`MonoDefine` or port body with nothing. A name comes into scope from a
tail-recursive local definition's parameters and a destructuring's bound name.
A closure is closed: its body sees only its parameters and captures, so a body
that names an enclosing variable it does not capture fails. The definitions of
a chain of directly nested `let`s are all in scope throughout the chain, but a
definition may name a later one only when the two are mutually recursive (the
later one leads back to it). A destructuring's path, and a case's root
variable (the second `Name` of `MonoCase`; the first is only a label), must be
in scope.

SpecIds are collected from every expression, including the branches a case's
decision tree holds inline; the paths in a decision tree are not checked.

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
destructuring counts when its body does, an `if` when every one of its
branches does, and a `case` when it has at least one branch and every branch
does, both those its decision tree jumps to and those it holds inline. No
other expression counts, whatever its type.

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

        Mono.MonoIf branches final _ ->
            List.all (\( _, branch ) -> isCallableExpression branch) branches
                && isCallableExpression final

        Mono.MonoCase _ _ decider jumps _ ->
            let
                branchExprs =
                    List.map Tuple.second jumps ++ inlineLeaves decider
            in
            not (List.isEmpty branchExprs) && List.all isCallableExpression branchExprs

        Mono.MonoDestruct _ inner _ ->
            isCallableExpression inner

        _ ->
            False


{-| Returns the branch bodies a decision tree holds `Inline` at its leaves.
-}
inlineLeaves : Mono.Decider Mono.MonoChoice -> List Mono.MonoExpr
inlineLeaves decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            [ expr ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ success failure ->
            inlineLeaves success ++ inlineLeaves failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> inlineLeaves d) edges ++ inlineLeaves fallback


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


{-| Returns one failing check for each custom type the graph uses that has no
entry in its `ctorShapes` table. (An entry may be empty: a type implemented by
the runtime, such as `Html`, declares no constructors.)

A custom type is used when it occurs, at any depth (inside lists, tuples,
records, functions and other custom types' arguments), in a type stored in a
node, at the positions `MonoTraverse.anyNodeType` reaches, or in a field type
of a constructor shape already in the table, so the table must be closed under
the types of the fields it describes.

-}
collectCompletenessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCompletenessChecks (Mono.MonoGraph data) =
    let
        hasShapes monoType =
            Mono.layoutMapMember monoType data.ctorShapes

        missingIn monoType =
            List.filter (not << hasShapes) (customTypesIn monoType [])

        nodeIssues =
            Array.toIndexedList data.nodes
                |> List.filterMap
                    (\( specId, maybeNode ) ->
                        maybeNode
                            |> Maybe.andThen
                                (\node ->
                                    if MonoTraverse.anyNodeType (\t -> not (List.isEmpty (missingIn t))) node then
                                        Just
                                            (\() ->
                                                Expect.fail
                                                    ("MONO_010: SpecId "
                                                        ++ String.fromInt specId
                                                        ++ " uses a custom type with no constructor shapes in ctorShapes"
                                                    )
                                            )

                                    else
                                        Nothing
                                )
                    )

        shapeIssues =
            Mono.layoutMapFoldl
                (\owner shapes acc ->
                    List.concatMap (.fieldTypes >> List.concatMap missingIn) shapes
                        |> List.map
                            (\missing ->
                                \() ->
                                    Expect.fail
                                        ("MONO_010: a constructor field of "
                                            ++ Mono.monoTypeToDebugString owner
                                            ++ " has type "
                                            ++ Mono.monoTypeToDebugString missing
                                            ++ ", which has no constructor shapes in ctorShapes"
                                        )
                            )
                        |> (\issues -> issues ++ acc)
                )
                []
                data.ctorShapes
    in
    nodeIssues ++ shapeIssues


{-| Adds to `acc` every `MCustom` type in `monoType`, the type itself included,
at any depth.
-}
customTypesIn : Mono.MonoType -> List Mono.MonoType -> List Mono.MonoType
customTypesIn monoType acc =
    case monoType of
        Mono.MCustom _ _ _ typeArgs ->
            List.foldl customTypesIn (monoType :: acc) typeArgs

        Mono.MList _ elemType ->
            customTypesIn elemType acc

        Mono.MTuple _ elemTypes ->
            List.foldl customTypesIn acc elemTypes

        Mono.MRecord _ fields ->
            List.foldl customTypesIn acc (Dict.values fields)

        Mono.MFunction _ _ paramTypes returnType ->
            List.foldl customTypesIn (customTypesIn returnType acc) paramTypes

        _ ->
            acc



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
                |> Set.toList

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


{-| Returns one failing check for each out-of-scope local reference in any
node of `graph`, as `checkNodeLocalVarScoping` finds them: the local-variable
half of `expectMonoGraphClosed`, for a graph a test has already built (for
example the output of a post-monomorphization pass), with no SpecId check.
-}
localVarScopingChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
localVarScopingChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, acc ++ checkNodeLocalVarScoping specId node )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


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

A closure body sees only the closure's parameters and captures, while the
capture expressions themselves are checked against `inScope`. The definitions
of a chain of directly nested `let`s, gathered by `collectLetChain`, are in
scope in every definition of the chain and in its final body, and
`checkLetChainOrder` checks their forward references. A destructuring's name
is in scope in its body. A case's root variable, the second `Name` of
`MonoCase`, must be in scope.

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

                -- A closure is closed: its body sees only its parameters and
                -- captures, not the scope around it.
                bodyScope =
                    Set.union paramNames captureNames

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

                forwardViolations : List (() -> Expect.Expectation)
                forwardViolations =
                    checkLetChainOrder context defs

                bodyViolations : List (() -> Expect.Expectation)
                bodyViolations =
                    checkExprLocalVarScoping context groupScope finalBody
            in
            defViolations ++ forwardViolations ++ bodyViolations

        Mono.MonoDestruct (Mono.MonoDestructor name path _) bodyExpr _ ->
            let
                pathRootIssues =
                    checkPathRootInScope context inScope path

                destructScope =
                    Set.insert identity name inScope
            in
            pathRootIssues ++ checkExprLocalVarScoping context destructScope bodyExpr

        Mono.MonoCase _ rootName decider branches _ ->
            let
                rootIssues =
                    if Set.member identity rootName inScope then
                        []

                    else
                        [ \() -> Expect.fail ("MONO_011: case root variable '" ++ rootName ++ "' is not in scope at " ++ context) ]
            in
            rootIssues
                ++ checkDeciderLocalVarScoping context inScope decider
                ++ List.concatMap (\( _, e ) -> checkExprLocalVarScoping context inScope e) branches

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
into directly nested `let`s, so the chain is treated as one scope, and
`checkLetChainOrder` rejects a forward reference outside such a group.

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


{-| Returns one failing check for each definition of a `let` chain that names
a later definition of the chain which does not, directly or through others,
name it back.

The typed optimizer orders local definitions by dependency, so a definition
may name a later one only when the two are mutually recursive, that is, when
the later one leads back to it.

-}
checkLetChainOrder : String -> List Mono.MonoDef -> List (() -> Expect.Expectation)
checkLetChainOrder context defs =
    let
        names : List String
        names =
            List.map getDefName defs

        refsOf : Mono.MonoDef -> EverySet String String
        refsOf def =
            MonoTraverse.foldExpr
                (\e acc ->
                    case e of
                        Mono.MonoVarLocal name _ ->
                            if List.member name names then
                                Set.insert identity name acc

                            else
                                acc

                        _ ->
                            acc
                )
                Set.empty
                (defBody def)

        refs : Dict.Dict String (EverySet String String)
        refs =
            Dict.fromList (List.map (\def -> ( getDefName def, refsOf def )) defs)

        reaches : String -> String -> Bool
        reaches from target =
            reachesHelp refs [ from ] Set.empty target

        laterNames : Int -> List String
        laterNames i =
            List.drop (i + 1) names
    in
    List.indexedMap
        (\i def ->
            let
                name =
                    getDefName def

                myRefs =
                    Dict.get name refs |> Maybe.withDefault Set.empty
            in
            laterNames i
                |> List.filter (\later -> Set.member identity later myRefs && not (reaches later name))
                |> List.map
                    (\later ->
                        \() ->
                            Expect.fail
                                ("MONO_011: let definition '"
                                    ++ name
                                    ++ "' names the later definition '"
                                    ++ later
                                    ++ "', which does not name it back, at "
                                    ++ context
                                )
                    )
        )
        defs
        |> List.concat


{-| Returns whether `target` can be reached from the names in `frontier` by
following `refs`, not revisiting the names in `seen`.
-}
reachesHelp : Dict.Dict String (EverySet String String) -> List String -> EverySet String String -> String -> Bool
reachesHelp refs frontier seen target =
    case frontier of
        [] ->
            False

        next :: rest ->
            if Set.member identity next seen then
                reachesHelp refs rest seen target

            else
                let
                    nextRefs =
                        Dict.get next refs |> Maybe.withDefault Set.empty
                in
                if Set.member identity target nextRefs then
                    True

                else
                    reachesHelp refs (Set.toList nextRefs ++ rest) (Set.insert identity next seen) target


{-| Returns the body of `def`.
-}
defBody : Mono.MonoDef -> Mono.MonoExpr
defBody def =
    case def of
        Mono.MonoDef _ expr ->
            expr

        Mono.MonoTailDef _ _ expr ->
            expr


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
subexpressions, at any depth, including the branches a case's decision tree
holds inline.
-}
collectSpecIdRefsFromExpr : Mono.MonoExpr -> EverySet Int Int
collectSpecIdRefsFromExpr expr =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoVarGlobal _ specId _ ->
                    Set.insert identity specId acc

                _ ->
                    acc
        )
        Set.empty
        expr



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
                |> Set.toList
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
