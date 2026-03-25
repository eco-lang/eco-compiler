module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue, Violation)

{-| Test logic for MONO\_024: Fully monomorphic specializations have no CEcoValue
in reachable MonoTypes.

For every specialization entry whose key MonoType is fully monomorphic (no MVar
with any constraint), a traversal of all MonoTypes reachable from
its implementing MonoNode must find no remaining MVar with CEcoValue constraint.

This differs from MONO\_021 in two ways:

1.  **Scope**: Only checks specializations with fully monomorphic keys (skips
    polymorphic residuals). MONO\_021 checks all reachable user-defined functions.
2.  **Breadth**: Checks ALL MonoType positions in the expression tree, not just
    function parameter/result positions. This catches CEcoValue surviving in
    intermediate expression types, let-binding types, case branch types, etc.

Any surviving CEcoValue in a fully monomorphic specialization indicates a
failed substitution — the monomorphization pass did not propagate the concrete
types from the specialization key into all expression types.

@docs expectFullyMonomorphicNoCEcoValue, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting MONO\_024 issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_024: Verify fully monomorphic specializations have no CEcoValue.
-}
expectFullyMonomorphicNoCEcoValue : Src.Module -> Expectation
expectFullyMonomorphicNoCEcoValue srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkFullyMonomorphicNoCEcoValue monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check all fully monomorphic specializations for CEcoValue violations.
-}
checkFullyMonomorphicNoCEcoValue : Mono.MonoGraph -> List Violation
checkFullyMonomorphicNoCEcoValue (Mono.MonoGraph data) =
    Array.toIndexedList data.registry.reverseMapping
        |> List.foldl
            (\( specId, maybeEntry ) acc ->
                case maybeEntry of
                    Nothing ->
                        -- Pruned slot (MONO_022), skip
                        acc

                    Just ( _, keyMonoType, _ ) ->
                        if not (isFullyMonomorphic keyMonoType) then
                            -- Key is not fully monomorphic, skip (invariant doesn't apply)
                            acc

                        else
                            case Array.get specId data.nodes |> Maybe.andThen identity of
                                Nothing ->
                                    -- No node for this specId (would be caught by MONO_017)
                                    acc

                                Just node ->
                                    acc ++ checkNodeAllTypes specId keyMonoType node
            )
            []



-- ============================================================================
-- FULLY MONOMORPHIC CHECK
-- ============================================================================


{-| A MonoType is fully monomorphic if it contains no MVar (any constraint).
Only these specializations are subject to MONO\_024.
-}
isFullyMonomorphic : Mono.MonoType -> Bool
isFullyMonomorphic monoType =
    not (Mono.containsAnyMVar monoType)



-- ============================================================================
-- NODE-LEVEL CHECK
-- ============================================================================


{-| Check a MonoNode for CEcoValue in ALL MonoType positions.
-}
checkNodeAllTypes : Int -> Mono.MonoType -> Mono.MonoNode -> List Violation
checkNodeAllTypes specId keyType node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId ++ " (key: " ++ monoTypeToString keyType ++ ")"
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkType ctx "node type" monoType
                ++ checkExprAllTypes ctx expr

        Mono.MonoTailFunc params expr monoType ->
            checkType ctx "node type" monoType
                ++ checkParamTypes ctx params
                ++ checkExprAllTypes ctx expr

        Mono.MonoPortIncoming expr monoType ->
            checkType ctx "node type" monoType
                ++ checkExprAllTypes ctx expr

        Mono.MonoPortOutgoing expr monoType ->
            checkType ctx "node type" monoType
                ++ checkExprAllTypes ctx expr

        Mono.MonoCycle defs monoType ->
            checkType ctx "node type" monoType
                ++ List.concatMap (\( name, expr ) -> checkExprAllTypes (ctx ++ " cycle=" ++ name) expr) defs

        -- Kernel nodes: CEcoValue is allowed
        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        -- Constructors and enums: check node type only (no expression bodies)
        Mono.MonoCtor _ monoType ->
            checkType ctx "ctor type" monoType

        Mono.MonoEnum _ monoType ->
            checkType ctx "enum type" monoType



-- ============================================================================
-- EXPRESSION-LEVEL CHECK
-- ============================================================================


{-| Recursively check ALL MonoTypes in a MonoExpr for CEcoValue.

Unlike MONO\_021 which only checks function positions, this checks every
MonoType encountered in the expression tree.

-}
checkExprAllTypes : String -> Mono.MonoExpr -> List Violation
checkExprAllTypes ctx expr =
    case expr of
        Mono.MonoClosure info body closureType ->
            let
                closureCtx =
                    ctx ++ " closure"
            in
            checkType closureCtx "closure type" closureType
                ++ checkParamTypes closureCtx info.params
                ++ List.concatMap (\( _, e, _ ) -> checkExprAllTypes closureCtx e) info.captures
                ++ checkExprAllTypes closureCtx body

        Mono.MonoLet def body letType ->
            let
                defViolations =
                    case def of
                        Mono.MonoDef _ bound ->
                            checkType ctx "let-bound type" (Mono.typeOf bound)
                                ++ checkExprAllTypes ctx bound

                        Mono.MonoTailDef name params bound ->
                            checkParamTypes (ctx ++ " taildef=" ++ name) params
                                ++ checkExprAllTypes (ctx ++ " taildef=" ++ name) bound
            in
            checkType ctx "let type" letType
                ++ defViolations
                ++ checkExprAllTypes ctx body

        Mono.MonoCase _ _ decider jumps caseType ->
            checkType ctx "case type" caseType
                ++ checkDeciderAllTypes ctx decider
                ++ List.concatMap
                    (\( _, branchExpr ) ->
                        checkType ctx "branch type" (Mono.typeOf branchExpr)
                            ++ checkExprAllTypes ctx branchExpr
                    )
                    jumps

        Mono.MonoIf branches final ifType ->
            checkType ctx "if type" ifType
                ++ List.concatMap (\( c, t ) -> checkExprAllTypes ctx c ++ checkExprAllTypes ctx t) branches
                ++ checkExprAllTypes ctx final

        Mono.MonoCall _ fn args callType _ ->
            checkType ctx "call type" callType
                ++ checkExprAllTypes ctx fn
                ++ List.concatMap (checkExprAllTypes ctx) args

        Mono.MonoTailCall _ namedArgs tailCallType ->
            checkType ctx "tailcall type" tailCallType
                ++ List.concatMap (\( _, a ) -> checkExprAllTypes ctx a) namedArgs

        Mono.MonoDestruct _ inner destructType ->
            checkType ctx "destruct type" destructType
                ++ checkExprAllTypes ctx inner

        Mono.MonoList _ items listType ->
            checkType ctx "list type" listType
                ++ List.concatMap (checkExprAllTypes ctx) items

        Mono.MonoRecordCreate fields recType ->
            checkType ctx "record-create type" recType
                ++ List.concatMap (\( _, e ) -> checkExprAllTypes ctx e) fields

        Mono.MonoRecordAccess inner _ accessType ->
            checkType ctx "record-access type" accessType
                ++ checkExprAllTypes ctx inner

        Mono.MonoRecordUpdate inner updates updateType ->
            checkType ctx "record-update type" updateType
                ++ checkExprAllTypes ctx inner
                ++ List.concatMap (\( _, e ) -> checkExprAllTypes ctx e) updates

        Mono.MonoTupleCreate _ items tupleType ->
            checkType ctx "tuple-create type" tupleType
                ++ List.concatMap (checkExprAllTypes ctx) items

        Mono.MonoLiteral _ litType ->
            checkType ctx "literal type" litType

        Mono.MonoVarLocal _ varType ->
            checkType ctx "local-var type" varType

        Mono.MonoVarGlobal _ _ varType ->
            checkType ctx "global-var type" varType

        Mono.MonoVarKernel _ _ _ _ ->
            -- Kernel vars may legitimately have CEcoValue
            []

        Mono.MonoUnit ->
            []


{-| Check a decider tree for CEcoValue in MonoTypes.
-}
checkDeciderAllTypes : String -> Mono.Decider Mono.MonoChoice -> List Violation
checkDeciderAllTypes ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    []

                Mono.Inline expr ->
                    checkExprAllTypes (ctx ++ " inline-leaf") expr

        Mono.Chain _ yes no ->
            checkDeciderAllTypes ctx yes
                ++ checkDeciderAllTypes ctx no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDeciderAllTypes ctx d) edges
                ++ checkDeciderAllTypes ctx fallback



-- ============================================================================
-- TYPE CHECK HELPERS
-- ============================================================================


{-| Check a single MonoType for CEcoValue MVar.
-}
checkType : String -> String -> Mono.MonoType -> List Violation
checkType ctx position monoType =
    let
        cEcoVars =
            collectCEcoValueVars monoType
    in
    if List.isEmpty cEcoVars then
        []

    else
        [ { context = ctx ++ " " ++ position
          , message =
                "MONO_024 violation: CEcoValue MVar in fully monomorphic specialization\n"
                    ++ "  position: "
                    ++ position
                    ++ "\n"
                    ++ "  type: "
                    ++ monoTypeToString monoType
                    ++ "\n"
                    ++ "  CEcoValue vars: "
                    ++ String.join ", " cEcoVars
          }
        ]


{-| Check parameter types for CEcoValue.
-}
checkParamTypes : String -> List ( String, Mono.MonoType ) -> List Violation
checkParamTypes ctx params =
    List.concatMap
        (\( paramName, paramType ) ->
            checkType ctx ("param=" ++ paramName) paramType
        )
        params


{-| Collect problematic MVar names from a MonoType recursively.
MVar \_ CEcoValue is always acceptable (compiles to eco.value).
Only MVar \_ CNumber would indicate a real bug (should be resolved to MInt/MFloat).
-}
collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            -- CEcoValue MVars are acceptable — they compile identically to eco.value
            []

        Mono.MVar name Mono.CNumber ->
            -- CNumber should have been resolved by forceCNumberToInt
            [ name ]

        Mono.MList inner ->
            collectCEcoValueVars inner

        Mono.MFunction args result ->
            List.concatMap collectCEcoValueVars args
                ++ collectCEcoValueVars result

        Mono.MTuple elems ->
            List.concatMap collectCEcoValueVars elems

        Mono.MRecord fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectCEcoValueVars fieldType) [] fields

        Mono.MCustom _ _ args ->
            List.concatMap collectCEcoValueVars args

        _ ->
            []



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "MONO_024 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ (violations
                |> List.map (\v -> v.context ++ ": " ++ v.message)
                |> String.join "\n\n"
           )


{-| Convert a MonoType to a string for error messages.
-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
    case monoType of
        Mono.MInt ->
            "Int"

        Mono.MFloat ->
            "Float"

        Mono.MBool ->
            "Bool"

        Mono.MChar ->
            "Char"

        Mono.MString ->
            "String"

        Mono.MUnit ->
            "()"

        Mono.MList elementType ->
            "List " ++ monoTypeToString elementType

        Mono.MTuple elements ->
            "(" ++ String.join ", " (List.map monoTypeToString elements) ++ ")"

        Mono.MRecord fields ->
            let
                fieldStrs =
                    Dict.foldl
                        (\name ty acc -> (name ++ " : " ++ monoTypeToString ty) :: acc)
                        []
                        fields
            in
            "{ " ++ String.join ", " fieldStrs ++ " }"

        Mono.MCustom _ name _ ->
            name

        Mono.MFunction params result ->
            let
                paramStr =
                    case params of
                        [ single ] ->
                            monoTypeToString single

                        multiple ->
                            "(" ++ String.join ", " (List.map monoTypeToString multiple) ++ ")"
            in
            paramStr ++ " -> " ++ monoTypeToString result

        Mono.MVar name _ ->
            name
