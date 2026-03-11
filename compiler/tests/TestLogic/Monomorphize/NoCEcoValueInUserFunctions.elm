module TestLogic.Monomorphize.NoCEcoValueInUserFunctions exposing
    ( Violation
    , checkNoCEcoValueInUserFunctions
    , expectNoCEcoValueInUserFunctions
    )

{-| Test logic for MONO\_021: No CEcoValue MVar in user-defined function types.

After monomorphization, no user-defined function or closure MonoType (including
parameters and results of MonoDefine, MonoTailFunc, and MonoClosure) may contain
MVar with CEcoValue constraint.

MErased is intentionally allowed in reachable specs. It appears in two cases:
(1) dead-value specializations whose value is never used (all MVars erased), and
(2) value-used specializations whose key type is still polymorphic — these are
phantom type variables never constrained by any call site. The backend crashes
loudly if MErased ever reaches an operational position (ABI/operand conversion).

Remaining CEcoValue MVar is restricted to kernel ABI types (MonoExtern,
MonoManagerLeaf, Debug kernels, and other layout-insensitive metadata) and must
never appear in layout- or ABI-defining positions for non-kernel code.

This invariant catches bugs where tail-recursive functions or local closures are
not being fully specialized during monomorphization, leaving polymorphic type
variables in positions that affect runtime layout and calling conventions.

@docs expectNoCEcoValueInUserFunctions, checkNoCEcoValueInUserFunctions, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting MONO\_021 issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_021: Verify no CEcoValue MVar appears in user-defined function types.
-}
expectNoCEcoValueInUserFunctions : Src.Module -> Expectation
expectNoCEcoValueInUserFunctions srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkNoCEcoValueInUserFunctions monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check all nodes in the MonoGraph for MONO\_021 violations.

Walks every MonoNode and every sub-expression, checking:

  - MonoDefine: the node MonoType and the body expression types
  - MonoTailFunc: the node MonoType, parameter types, and body expression types
  - MonoClosure: closure params, captures, and body expression types
  - MonoTailDef (local tail-recursive defs): parameter types and body types
  - MonoPortIncoming/MonoPortOutgoing: body expression types
  - MonoCycle: all definition body types

Kernel nodes (MonoExtern, MonoManagerLeaf) are explicitly exempted.

-}
checkNoCEcoValueInUserFunctions : Mono.MonoGraph -> List Violation
checkNoCEcoValueInUserFunctions (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, acc ++ checkNode specId node )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Check a single MonoNode for MONO\_021 violations.
-}
checkNode : Int -> Mono.MonoNode -> List Violation
checkNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkNodeType ctx "MonoDefine" monoType
                ++ checkExpr ctx expr

        Mono.MonoTailFunc params expr monoType ->
            checkNodeType ctx "MonoTailFunc" monoType
                ++ checkParamTypes ctx "MonoTailFunc" params
                ++ checkExpr ctx expr

        Mono.MonoPortIncoming expr _ ->
            checkExpr ctx expr

        Mono.MonoPortOutgoing expr _ ->
            checkExpr ctx expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( name, expr ) -> checkExpr (ctx ++ " cycle=" ++ name) expr) defs

        -- Kernel nodes: CEcoValue is allowed (MONO_021 exemption)
        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        -- Constructors and enums: no function bodies to check
        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []


{-| Check a node-level MonoType for CEcoValue in function-typed positions.

Only flags violations when the MonoType is a function type (MFunction) since
MONO\_021 specifically targets function parameter and result types.

-}
checkNodeType : String -> String -> Mono.MonoType -> List Violation
checkNodeType ctx nodeKind monoType =
    case monoType of
        Mono.MFunction _ _ ->
            let
                cEcoVars =
                    collectCEcoValueVars monoType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ nodeKind ++ " nodeType"
                  , message =
                        "MONO_021 violation: CEcoValue MVar in "
                            ++ nodeKind
                            ++ " function type\n"
                            ++ "  type: "
                            ++ Debug.toString monoType
                            ++ "\n"
                            ++ "  CEcoValue vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]

        _ ->
            []


{-| Check parameter types of a MonoTailFunc for CEcoValue.
-}
checkParamTypes : String -> String -> List ( String, Mono.MonoType ) -> List Violation
checkParamTypes ctx nodeKind params =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ nodeKind ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in parameter type\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  CEcoValue vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        params


{-| Recursively check a MonoExpr for MONO\_021 violations.

Checks closure params, MonoTailDef params, and function-typed expressions
for CEcoValue MVar that should have been resolved by monomorphization.

-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoClosure info body closureType ->
            let
                closureCtx =
                    ctx ++ " closure"
            in
            checkClosureInfo closureCtx info
                ++ checkFunctionExprType closureCtx "MonoClosure" closureType
                ++ List.concatMap (\( _, e, _ ) -> checkExpr closureCtx e) info.captures
                ++ checkExpr closureCtx body

        Mono.MonoLet def body _ ->
            let
                defViolations =
                    case def of
                        Mono.MonoDef _ bound ->
                            checkExpr ctx bound

                        Mono.MonoTailDef name params bound ->
                            checkTailDefParams ctx name params
                                ++ checkExpr (ctx ++ " taildef=" ++ name) bound
            in
            defViolations ++ checkExpr ctx body

        Mono.MonoCase _ _ decider jumps _ ->
            checkDecider ctx decider
                ++ List.concatMap (\( _, branchExpr ) -> checkExpr ctx branchExpr) jumps

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> checkExpr ctx c ++ checkExpr ctx t) branches
                ++ checkExpr ctx final

        Mono.MonoCall _ fn args _ _ ->
            checkExpr ctx fn ++ List.concatMap (checkExpr ctx) args

        Mono.MonoTailCall _ namedArgs _ ->
            List.concatMap (\( _, a ) -> checkExpr ctx a) namedArgs

        Mono.MonoDestruct _ inner _ ->
            checkExpr ctx inner

        Mono.MonoList _ items _ ->
            List.concatMap (checkExpr ctx) items

        Mono.MonoRecordCreate fields _ ->
            List.concatMap (\( _, e ) -> checkExpr ctx e) fields

        Mono.MonoRecordAccess inner _ _ ->
            checkExpr ctx inner

        Mono.MonoRecordUpdate inner updates _ ->
            checkExpr ctx inner ++ List.concatMap (\( _, e ) -> checkExpr ctx e) updates

        Mono.MonoTupleCreate _ items _ ->
            List.concatMap (checkExpr ctx) items

        -- Leaf expressions with no sub-expressions
        Mono.MonoLiteral _ _ ->
            []

        Mono.MonoVarLocal _ _ ->
            []

        Mono.MonoVarGlobal _ _ _ ->
            []

        Mono.MonoVarKernel _ _ _ _ ->
            []

        Mono.MonoUnit ->
            []


{-| Check closure info for CEcoValue in parameter types.
-}
checkClosureInfo : String -> Mono.ClosureInfo -> List Violation
checkClosureInfo ctx info =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in closure parameter type\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  CEcoValue vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        info.params


{-| Check MonoTailDef parameter types for CEcoValue.
-}
checkTailDefParams : String -> String -> List ( String, Mono.MonoType ) -> List Violation
checkTailDefParams ctx defName params =
    List.concatMap
        (\( paramName, paramType ) ->
            let
                cEcoVars =
                    collectCEcoValueVars paramType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " taildef=" ++ defName ++ " param=" ++ paramName
                  , message =
                        "MONO_021 violation: CEcoValue MVar in MonoTailDef parameter type\n"
                            ++ "  def: "
                            ++ defName
                            ++ "\n"
                            ++ "  param: "
                            ++ paramName
                            ++ "\n"
                            ++ "  type: "
                            ++ Debug.toString paramType
                            ++ "\n"
                            ++ "  CEcoValue vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]
        )
        params


{-| Check a function-typed expression for CEcoValue in its type.
-}
checkFunctionExprType : String -> String -> Mono.MonoType -> List Violation
checkFunctionExprType ctx exprKind monoType =
    case monoType of
        Mono.MFunction _ _ ->
            let
                cEcoVars =
                    collectCEcoValueVars monoType
            in
            if List.isEmpty cEcoVars then
                []

            else
                [ { context = ctx ++ " " ++ exprKind ++ " exprType"
                  , message =
                        "MONO_021 violation: CEcoValue MVar in "
                            ++ exprKind
                            ++ " expression type\n"
                            ++ "  type: "
                            ++ Debug.toString monoType
                            ++ "\n"
                            ++ "  CEcoValue vars: "
                            ++ String.join ", " cEcoVars
                  }
                ]

        _ ->
            []


{-| Check the decider tree for closures or tail-defs with CEcoValue violations.
-}
checkDecider : String -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    []

                Mono.Inline expr ->
                    checkExpr (ctx ++ " inline-leaf") expr

        Mono.Chain _ yes no ->
            checkDecider ctx yes
                ++ checkDecider ctx no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx d) edges
                ++ checkDecider ctx fallback


{-| Collect all CEcoValue MVar names from a MonoType recursively.

MErased is intentionally allowed — it marks phantom type variables that were
never constrained by any call site, or dead-value spec erasure.
-}
collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar name Mono.CEcoValue ->
            [ name ]

        Mono.MVar _ Mono.CNumber ->
            []

        Mono.MErased ->
            []

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


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "MONO_021 violations found (" ++ String.fromInt (List.length violations) ++ "):\n\n"
        ++ (violations
                |> List.map (\v -> v.context ++ ": " ++ v.message)
                |> String.join "\n\n"
           )
