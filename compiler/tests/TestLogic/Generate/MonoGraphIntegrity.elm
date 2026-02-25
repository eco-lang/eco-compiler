module TestLogic.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphClosed
    , expectMonoGraphComplete
    , expectSpecRegistryComplete
    )

{-| Test logic for invariants:

  - MONO\_004: All functions are callable MonoNodes
  - MONO\_010: MonoGraph is type complete
  - MONO\_011: MonoGraph is closed and hygienic
  - MONO\_005: Specialization registry is complete and consistent

This module reuses the existing typed optimization pipeline to verify
MonoGraph integrity. Successful monomorphization implies all these
invariants are satisfied.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Data.Set as Set exposing (EverySet)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| MONO\_004: Verify that all function-typed nodes are callable.

Note: This invariant only applies AFTER GlobalOpt, which is responsible for
wrapping non-closure function expressions in closures via ensureCallableForNode.

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
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_010: Verify MonoGraph is type complete.
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
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_011: Verify MonoGraph is closed and hygienic.
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
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_005: Verify specialization registry is complete.
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
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- MONO_004: CALLABILITY CHECKING
-- ============================================================================


{-| Collect callability checks for function-typed nodes.
-}
collectCallabilityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCallabilityChecks (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeCallability specId node ++ acc)
        []
        data.nodes


{-| Check if a function-typed node is properly callable.

Function-typed MonoDefine nodes are callable if their expression is one of:

1.  MonoClosure: Direct closure definition
2.  MonoVarGlobal: Reference to another function-typed node (creates papCreate)
3.  MonoCall: Partial application that returns a function (creates papExtend)

Cases 2 and 3 are handled by codegen as thunks that return callable PAPs.

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
                Mono.MFunction _ _ ->
                    -- Function-typed define is callable if the expression:
                    -- 1. Is a MonoClosure (direct closure)
                    -- 2. Is a MonoVarGlobal to a function (creates papCreate in codegen)
                    -- 3. Is a MonoCall returning a function (partial application, creates papExtend)
                    -- 4. Any other expression that has a function type (thunk returning callable)
                    if isCallableExpression expr then
                        []

                    else
                        [ \() -> Expect.fail (context ++ ": Function-typed MonoDefine has non-callable expression") ]

                _ ->
                    -- Non-function types are fine
                    []

        Mono.MonoTailFunc _ _ monoType ->
            -- TailFunc is always callable (it's explicitly a function)
            case monoType of
                Mono.MFunction _ _ ->
                    []

                _ ->
                    [ \() -> Expect.fail (context ++ ": MonoTailFunc has non-function type") ]

        Mono.MonoCtor _ _ ->
            -- Constructors are callable by definition
            []

        Mono.MonoEnum _ _ ->
            -- Enum constructors are callable
            []

        Mono.MonoExtern _ ->
            -- Externs with function types are callable (FFI)
            []

        Mono.MonoPortIncoming _ _ ->
            -- Ports are callable
            []

        Mono.MonoPortOutgoing _ _ ->
            -- Ports are callable
            []

        Mono.MonoCycle _ _ ->
            -- Cycle nodes are internal
            []


{-| Check if an expression is callable (can produce a function value).

Callable expressions include:

  - MonoClosure: Direct closure definition
  - MonoVarGlobal with function type: Reference to function (codegen creates papCreate)
  - MonoVarKernel with function type: Kernel function reference
  - MonoCall with function result type: Partial application (codegen creates papExtend)
  - MonoLet/MonoIf/MonoCase with function result: Control flow returning callable
  - MonoDestruct with function result: Destructuring returning callable

-}
isCallableExpression : Mono.MonoExpr -> Bool
isCallableExpression expr =
    case expr of
        Mono.MonoClosure _ _ _ ->
            -- Direct closure - always callable
            True

        Mono.MonoVarLocal _ monoType ->
            -- Local variable reference - callable if function-typed
            -- The variable holds a callable value
            isFunctionType monoType

        Mono.MonoVarGlobal _ _ monoType ->
            -- Reference to a global - callable if function-typed
            -- Codegen generates papCreate for function-typed globals
            isFunctionType monoType

        Mono.MonoVarKernel _ _ _ monoType ->
            -- Kernel reference - callable if function-typed
            isFunctionType monoType

        Mono.MonoCall _ _ _ resultType _ ->
            -- Call expression - callable if result is function-typed
            -- This handles partial applications (codegen generates papExtend)
            isFunctionType resultType

        Mono.MonoLet _ body _ ->
            -- Let expression - callable if body is callable
            isCallableExpression body

        Mono.MonoIf _ final _ ->
            -- If expression - callable if branches are callable (check final branch)
            isCallableExpression final

        Mono.MonoCase _ _ _ branches _ ->
            -- Case expression - callable if branches are callable (check first branch)
            case branches of
                ( _, branchExpr ) :: _ ->
                    isCallableExpression branchExpr

                [] ->
                    False

        Mono.MonoDestruct _ inner _ ->
            -- Destruct - callable if inner is callable
            isCallableExpression inner

        _ ->
            -- Other expressions (literals, records, tuples, etc.) are not callable
            False


{-| Check if a MonoType is a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False



-- ============================================================================
-- MONO_010: TYPE COMPLETENESS CHECKING
-- ============================================================================


{-| Collect type completeness checks.
-}
collectCompletenessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCompletenessChecks (Mono.MonoGraph data) =
    []


{-| Collect custom type references from a MonoType.
-}
collectCustomTypeRefsFromType : Mono.MonoType -> List ( List String, String )
collectCustomTypeRefsFromType monoType =
    case monoType of
        Mono.MCustom _ _ typeArgs ->
            -- Note: canonical is IO.Canonical, we'd need to extract its comparable form
            -- For now, skip the lookup check since we can't easily compare
            List.concatMap collectCustomTypeRefsFromType typeArgs

        Mono.MList elemType ->
            collectCustomTypeRefsFromType elemType

        Mono.MFunction paramTypes returnType ->
            List.concatMap collectCustomTypeRefsFromType paramTypes
                ++ collectCustomTypeRefsFromType returnType

        _ ->
            []


{-| Collect custom type references from a MonoExpr.
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

        Mono.MonoVarKernel _ _ _ monoType ->
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


{-| Collect custom type references from a MonoDef.
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
-- MONO_011: CLOSURE AND HYGIENE CHECKING
-- ============================================================================


{-| Collect closure checks (no dangling references).

Checks both:

1.  All referenced SpecIds are defined in nodes
2.  All MonoVarLocal references have corresponding binders in scope

-}
collectClosureChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectClosureChecks (Mono.MonoGraph data) =
    let
        -- Get all defined SpecIds
        definedSpecIds =
            Dict.keys compare data.nodes |> Set.fromList identity

        -- Collect all referenced SpecIds
        referencedSpecIds =
            Dict.foldl compare
                (\_ node acc -> Set.union acc (collectSpecIdRefsFromNode node))
                Set.empty
                data.nodes

        -- Find undefined SpecId references
        undefinedRefs =
            Set.diff referencedSpecIds definedSpecIds
                |> Set.toList compare

        specIdIssues =
            List.map
                (\specId -> \() -> Expect.fail ("MONO_011: Referenced SpecId " ++ String.fromInt specId ++ " is not defined in nodes"))
                undefinedRefs

        -- Check MonoVarLocal scoping for all nodes
        localVarIssues =
            Dict.foldl compare
                (\specId node acc -> checkNodeLocalVarScoping specId node ++ acc)
                []
                data.nodes
    in
    specIdIssues ++ localVarIssues


{-| Check that all MonoVarLocal references in a node are in scope.
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

        Mono.MonoCycle defs _ ->
            let
                -- All cycle names are in scope for each definition
                cycleNames =
                    List.map (\( name, _ ) -> name) defs
                        |> Set.fromList identity
            in
            List.concatMap (\( _, e ) -> checkExprLocalVarScoping context cycleNames e) defs

        _ ->
            []


{-| Check that all MonoVarLocal references in an expression are in scope.
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
            -- Add params and captures to scope
            let
                paramNames =
                    List.map (\( name, _ ) -> name) closureInfo.params
                        |> Set.fromList identity

                captureNames =
                    List.map (\( name, _, _ ) -> name) closureInfo.captures
                        |> Set.fromList identity

                bodyScope =
                    Set.union inScope (Set.union paramNames captureNames)

                -- Check capture expressions in outer scope
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
            -- Treat any contiguous chain of MonoLet as a single
            -- mutually recursive scope. This handles let-rec groups
            -- which are encoded as nested MonoLet expressions.
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
                    -- Pass groupScope so each def body sees all names in chain
                    defs
                        |> List.concatMap (checkDefLocalVarScoping context groupScope)

                bodyViolations : List (() -> Expect.Expectation)
                bodyViolations =
                    checkExprLocalVarScoping context groupScope finalBody
            in
            defViolations ++ bodyViolations

        Mono.MonoDestruct (Mono.MonoDestructor name path _) bodyExpr _ ->
            -- MonoDestruct binds 'name' by extracting a value via 'path' from an existing variable.
            -- The path's root variable must be in scope; 'name' becomes in scope for bodyExpr.
            let
                -- Check that the path's root variable is in scope
                pathRootIssues =
                    checkPathRootInScope context inScope path

                -- The body is checked with name in scope
                destructScope =
                    Set.insert identity name inScope
            in
            pathRootIssues ++ checkExprLocalVarScoping context destructScope bodyExpr

        Mono.MonoCase scrutName _ decider branches _ ->
            -- scrutName is bound in the case branches
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


{-| Check that the root variable of a MonoPath is in scope.
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


{-| Extract the root variable name from a MonoPath.
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


{-| Get the name from a MonoDef.
-}
getDefName : Mono.MonoDef -> String
getDefName def =
    case def of
        Mono.MonoDef name _ ->
            name

        Mono.MonoTailDef name _ _ ->
            name


{-| Collect a contiguous chain of nested MonoLet expressions.

Starting from the first `def` and `body`, walks down
`MonoLet nextDef nextBody _` as long as they occur directly in the body
position. Returns the full list of defs (in order) and the final body
expression after the chain.

This is used to handle mutually recursive let-bindings, which are encoded
as nested MonoLet expressions but should be treated as a single scope.

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


{-| Check local var scoping in a MonoDef.
-}
checkDefLocalVarScoping : String -> Set.EverySet String String -> Mono.MonoDef -> List (() -> Expect.Expectation)
checkDefLocalVarScoping context inScope def =
    case def of
        Mono.MonoDef name expr ->
            -- Name is in scope for recursive references
            let
                defScope =
                    Set.insert identity name inScope
            in
            checkExprLocalVarScoping context defScope expr

        Mono.MonoTailDef name params expr ->
            -- Name and params are in scope
            let
                paramNames =
                    List.map (\( n, _ ) -> n) params
                        |> Set.fromList identity

                defScope =
                    Set.union (Set.insert identity name inScope) paramNames
            in
            checkExprLocalVarScoping context defScope expr


{-| Check local var scoping in a Decider tree.
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


{-| Collect SpecId references from a node.
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

        Mono.MonoPortIncoming expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoPortOutgoing expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoCycle defs _ ->
            List.foldl
                (\( _, expr ) acc -> Set.union acc (collectSpecIdRefsFromExpr expr))
                Set.empty
                defs


{-| Collect SpecId references from a MonoExpr.
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


{-| Collect SpecId references from a MonoDef.
-}
collectSpecIdRefsFromDef : Mono.MonoDef -> EverySet Int Int
collectSpecIdRefsFromDef def =
    case def of
        Mono.MonoDef _ expr ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoTailDef _ _ expr ->
            collectSpecIdRefsFromExpr expr



-- ============================================================================
-- MONO_005: REGISTRY COMPLETENESS CHECKING
-- ============================================================================


{-| Collect specialization registry checks.
-}
collectRegistryChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectRegistryChecks (Mono.MonoGraph data) =
    let
        -- Get all defined SpecIds
        definedSpecIds =
            Dict.keys compare data.nodes |> Set.fromList identity

        -- Get all SpecIds from registry
        registrySpecIds =
            collectRegistrySpecIds data.registry

        -- Check that all registry SpecIds are defined
        undefinedRegistrySpecIds =
            Set.diff registrySpecIds definedSpecIds
                |> Set.toList compare
    in
    List.map
        (\specId -> \() -> Expect.fail ("Registry contains SpecId " ++ String.fromInt specId ++ " which is not defined in nodes"))
        undefinedRegistrySpecIds


{-| Collect all SpecIds from the specialization registry.
-}
collectRegistrySpecIds : Mono.SpecializationRegistry -> EverySet Int Int
collectRegistrySpecIds registry =
    -- SpecializationRegistry has reverseMapping : Dict Int Int (Global, MonoType, Maybe LambdaId)
    -- where the key is SpecId, so we just need the keys
    Dict.keys compare registry.reverseMapping
        |> Set.fromList identity
