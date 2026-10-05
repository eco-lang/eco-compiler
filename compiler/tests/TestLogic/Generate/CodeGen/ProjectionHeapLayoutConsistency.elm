module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)

{-| Checks a compiled program for places where a list could be read with the
wrong idea of how its elements are stored. Every problem message is tagged
`[REP_BOUNDARY_003]`.

A list element is _unboxed_ when it is held as a raw machine value rather than
as a pointer to a heap object. The MLIR back end builds a list cell with its
head unboxed or boxed according to the MLIR type of the head value, and
`eco.project.list_head` reads a head back at the type the reading code
expects. Code compiled for boxed elements that is handed a list with unboxed
heads, or the reverse, misreads those heads. This module looks for that at
the calls of the monomorphized graph; it examines no MLIR op.

An element type is _unboxable_ here when its ABI type from
`Types.monoTypeToAbi` is unboxed, which holds for `MInt`, `MFloat`, `MChar` and
a number variable (`MVar _ CNumber`).

`expectProjectionHeapLayoutConsistency` compiles a source module with
`runToMlir`, takes the optimized graph that comes back, and checks every call
whose callee is a global (`MonoVarGlobal`): each argument is paired with the
callee's parameter at the same position, using the function type the
specialization registry records for the callee with the parameters of all its
stages in order. A pair in which both are lists and their element types differ
in unboxability is a problem. Calls are found at any depth, including in case
branches held inline in a decision tree.

There is deliberately no check across specializations. One function may
legitimately have a specialization for `List Int` and another for a list of an
erased variable: `count [ 1, 2 ] + count []` gives both, and each is separate
code that only ever receives lists of its own element type. Only a call can
hand a list to code expecting the other layout.

Among what is not checked:

  - a call through a local variable, a closure or a kernel, and a tail call;
  - a list nested inside another type, such as a tuple.

@docs expectProjectionHeapLayoutConsistency

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Expect exposing (Expectation)
import TestLogic.TestPipeline exposing (runToMlir)


{-| Passes when the call check finds no problem in the optimized graph compiled from `srcModule`. Otherwise it fails
with every problem found, one per line, or with the error when compilation
fails.
-}
expectProjectionHeapLayoutConsistency : Src.Module -> Expectation
expectProjectionHeapLayoutConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { monoGraph } ->
            let
                issues =
                    checkListElemConsistency monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- MAIN CHECK
-- ============================================================================


{-| Returns every problem the call check finds in a graph.
-}
checkListElemConsistency : Mono.MonoGraph -> List String
checkListElemConsistency (Mono.MonoGraph data) =
    let
        callIssues =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just node ->
                            ( specId + 1, checkNode specId data.registry node ++ acc )
                )
                ( 0, [] )
                data.nodes
                |> Tuple.second
    in
    callIssues


{-| Returns the call check's problems in the body of one node, each labelled
with `specId`, the node's own SpecId. Only a define, a tail function and a port
have a body; any other node gives none.
-}
checkNode : Int -> Mono.SpecializationRegistry -> Mono.MonoNode -> List String
checkNode specId registry node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoTailFunc _ expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoPortIncoming expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoPortOutgoing expr _ ->
            collectCallIssues ctx registry expr

        _ ->
            []



-- ============================================================================
-- EXPRESSION WALKER
-- ============================================================================


{-| Returns the call check's problems at every call in `expr` and in its
subexpressions, each prefixed with `ctx`.

A case contributes the problems in the branches it jumps to and in the
branches held inline in its decision tree.

-}
collectCallIssues : String -> Mono.SpecializationRegistry -> Mono.MonoExpr -> List String
collectCallIssues ctx registry expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ _ ->
            checkCallSite ctx registry funcExpr args
                ++ collectCallIssues ctx registry funcExpr
                ++ List.concatMap (collectCallIssues ctx registry) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectCallIssues ctx registry e) closureInfo.captures
                ++ collectCallIssues ctx registry bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefIssues ctx registry def
                ++ collectCallIssues ctx registry bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectCallIssues ctx registry c ++ collectCallIssues ctx registry t) branches
                ++ collectCallIssues ctx registry elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderIssues ctx registry decider
                ++ List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectCallIssues ctx registry valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectCallIssues ctx registry) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectCallIssues ctx registry recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectCallIssues ctx registry recordExpr
                ++ List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectCallIssues ctx registry) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) args

        _ ->
            []


{-| Returns the call check's problems in the body of a let-bound definition.
-}
collectDefIssues : String -> Mono.SpecializationRegistry -> Mono.MonoDef -> List String
collectDefIssues ctx registry def =
    case def of
        Mono.MonoDef _ expr ->
            collectCallIssues ctx registry expr

        Mono.MonoTailDef _ _ expr ->
            collectCallIssues ctx registry expr


{-| Returns the call check's problems in the branch bodies held `Inline` at
the leaves of a case's decision tree.
-}
collectDeciderIssues : String -> Mono.SpecializationRegistry -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssues ctx registry decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            collectCallIssues ctx registry expr

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ success failure ->
            collectDeciderIssues ctx registry success
                ++ collectDeciderIssues ctx registry failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssues ctx registry d) edges
                ++ collectDeciderIssues ctx registry fallback



-- ============================================================================
-- CALL SITE CHECK
-- ============================================================================


{-| Returns the problems at one call of `funcExpr` with `args`: each list
argument whose element type differs in unboxability from that of the callee's
parameter at the same position.

Only a callee that is a global specialization (`MonoVarGlobal`) whose registry
entry has a function type is checked; any other callee gives none.

-}
checkCallSite : String -> Mono.SpecializationRegistry -> Mono.MonoExpr -> List Mono.MonoExpr -> List String
checkCallSite ctx registry funcExpr args =
    case funcExpr of
        Mono.MonoVarGlobal _ calleeSpecId _ ->
            case lookupCalleeParamTypes registry calleeSpecId of
                Nothing ->
                    []

                Just calleeParamTypes ->
                    checkArgListTypes ctx calleeSpecId calleeParamTypes args

        _ ->
            []


{-| Returns the parameter types of the function type the registry records for
`specId`, or `Nothing` when the entry is missing or not a function type. The
parameters of every stage of a curried type are returned in order, so an
argument that a call passes beyond the first stage still meets its parameter.
-}
lookupCalleeParamTypes : Mono.SpecializationRegistry -> Int -> Maybe (List Mono.MonoType)
lookupCalleeParamTypes registry specId =
    case Array.get specId registry.reverseMapping of
        Just (Just ( _, (Mono.MFunction _ _ _ _) as monoType )) ->
            Just (flattenParams monoType)

        _ ->
            Nothing


{-| Returns the parameter types of every stage of a function type, outermost
first; a non-function type has none.
-}
flattenParams : Mono.MonoType -> List Mono.MonoType
flattenParams monoType =
    case monoType of
        Mono.MFunction _ _ paramTypes resultType ->
            paramTypes ++ flattenParams resultType

        _ ->
            []


{-| Returns the problems from pairing `args` with `paramTypes` by position.
Pairing stops at the shorter of the two lists; a call has no more arguments
than the flattened parameters of a well-typed callee.
-}
checkArgListTypes : String -> Int -> List Mono.MonoType -> List Mono.MonoExpr -> List String
checkArgListTypes ctx calleeSpecId paramTypes args =
    List.map2
        (\paramType argExpr ->
            checkListArgConsistency ctx calleeSpecId paramType (Mono.typeOf argExpr)
        )
        paramTypes
        args
        |> List.concat


{-| Returns a problem when `calleeParamType` and `callerArgType` are both lists
whose element types differ in unboxability, and nothing otherwise. A list
nested inside either type is not looked at. The message names the call's
context `ctx` and the callee's SpecId `calleeSpecId`.
-}
checkListArgConsistency : String -> Int -> Mono.MonoType -> Mono.MonoType -> List String
checkListArgConsistency ctx calleeSpecId calleeParamType callerArgType =
    case ( calleeParamType, callerArgType ) of
        ( Mono.MList _ calleeElem, Mono.MList _ callerElem ) ->
            let
                calleeUnboxed =
                    isUnboxableElem calleeElem

                callerUnboxed =
                    isUnboxableElem callerElem
            in
            if calleeUnboxed /= callerUnboxed then
                [ ctx
                    ++ " [REP_BOUNDARY_003]: List element unboxability mismatch at call to SpecId "
                    ++ String.fromInt calleeSpecId
                    ++ ": caller has Mono.mList "
                    ++ monoTypeLabel callerElem
                    ++ " ("
                    ++ (if callerUnboxed then
                            "unboxed"

                        else
                            "boxed"
                       )
                    ++ ") but callee expects Mono.mList "
                    ++ monoTypeLabel calleeElem
                    ++ " ("
                    ++ (if calleeUnboxed then
                            "unboxed"

                        else
                            "boxed"
                       )
                    ++ ")"
                ]

            else
                []

        _ ->
            []



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Returns whether a list element type is unboxable: whether its ABI type is
unboxed, which holds for `MInt`, `MFloat`, `MChar` and a number variable.
-}
isUnboxableElem : Mono.MonoType -> Bool
isUnboxableElem elemType =
    Types.isUnboxable (Types.monoTypeToAbi elemType)


{-| Returns a short label for an element type in a problem message. A type
variable's label leaves out its id, a list's label wraps its element's, and
any type without a label of its own is `composite`.
-}
monoTypeLabel : Mono.MonoType -> String
monoTypeLabel t =
    case t of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MChar ->
            "MChar"

        Mono.MBool ->
            "MBool"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MVar _ Mono.CEcoValue ->
            "MVar CEcoValue"

        Mono.MVar _ Mono.CNumber ->
            "MVar CNumber"

        Mono.MList _ inner ->
            "Mono.mList (" ++ monoTypeLabel inner ++ ")"

        _ ->
            "composite"
