module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)

{-| Checks a compiled program for places where a list could be read with the
wrong idea of how its elements are stored. Every problem message is tagged
`[REP_BOUNDARY_003]`.

A list element is _unboxed_ when it is held as a raw machine value rather than
as a pointer to a heap object. The MLIR back end builds a list cell with its
head unboxed or boxed according to the MLIR type of the head value, and
`eco.project.list_head` reads a head back at the type the reading code
expects. Code compiled for boxed elements that is handed a list with unboxed
heads, or the reverse, misreads those heads. This module looks for two ways
that can happen in the monomorphized graph; it examines no MLIR op.

An element type is _unboxable_ here when its ABI type from
`Types.monoTypeToAbi` is unboxed, which holds for `MInt`, `MFloat`, `MChar` and
a number variable (`MVar _ CNumber`). An element type is _erased_ when it is a
boxed type variable, `MVar _ CEcoValue`.

`expectProjectionHeapLayoutConsistency` compiles a source module with
`runToMlir`, takes the optimized graph that comes back, and runs two checks on
it:

  - The call check. At each call whose callee is a global (`MonoVarGlobal`),
    each argument is paired with the callee's parameter at the same position,
    using the function type the specialization registry records for the callee.
    A pair in which both are lists and their element types differ in
    unboxability is a problem.
  - The specialization check. The registry's specializations are grouped by
    name, and a name is a problem when the list element types found in their
    types include both an unboxable one and an erased one. Two unboxable
    element types that differ, such as `MInt` and `MFloat`, are not.

Among what is not checked:

  - a call through a local variable, a closure or a kernel, and a tail call;
  - a call inside a branch inlined into a case's decision tree;
  - an argument beyond the parameters of the callee's outermost function type;
  - in the call check, a list nested inside another type, such as a tuple;
  - in the specialization check, a list inside a record, a custom type or
    another list.

The specialization check groups by the bare name, without the module, so
same-named functions from different modules share a group. It also pools the
element types of every parameter and the result of one specialization.

@docs expectProjectionHeapLayoutConsistency

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline exposing (runToMlir)


{-| Passes when neither the call check nor the specialization check finds a
problem in the optimized graph compiled from `srcModule`. Otherwise it fails
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


{-| Returns every problem the call check and the specialization check find in a
graph, those of the call check first. The specialization check also finds a
conflict between two specializations that no call connects.
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

        specIssues =
            checkSpecializationConsistency data.registry
    in
    callIssues ++ specIssues


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

A case contributes the problems in the branches it jumps to but none from its
decision tree (see `collectDeciderIssuesHelp`), so a call in a branch inlined
into the tree is not checked.

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
            collectDeciderIssues decider
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


{-| Returns the call check's problems in a case's decision tree, which are
always none. The context and the registry are ignored.
-}
collectDeciderIssues : Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssues decider =
    collectDeciderIssuesHelp decider


{-| Returns an empty list for any decision tree. It visits every node, but a
leaf contributes nothing, including a leaf that holds an inlined branch
(`Inline`), so the calls in such a branch are never checked.
-}
collectDeciderIssuesHelp : Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssuesHelp decider =
    case decider of
        Mono.Leaf _ ->
            []

        Mono.Chain _ success failure ->
            collectDeciderIssuesHelp success
                ++ collectDeciderIssuesHelp failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssuesHelp d) edges
                ++ collectDeciderIssuesHelp fallback



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
`specId`, or `Nothing` when the entry is missing, empty or not a function type.
Only the outermost function type is read, so for a curried type these are the
parameters of the first call only.
-}
lookupCalleeParamTypes : Mono.SpecializationRegistry -> Int -> Maybe (List Mono.MonoType)
lookupCalleeParamTypes registry specId =
    case Array.get specId registry.reverseMapping of
        Just (Just ( _, monoType )) ->
            case monoType of
                Mono.MFunction _ _ paramTypes _ ->
                    Just paramTypes

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the problems from pairing `args` with `paramTypes` by position.
Pairing stops at the shorter of the two lists, so an argument with no
parameter at its position is not checked.
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
-- SPECIALIZATION CONSISTENCY CHECK
-- ============================================================================


{-| Returns one problem for each name whose specializations in `registry`,
taken together, have both an unboxable list element type and an erased one.
The list element types are those `collectListElemTypes` finds, and the problem
lists every one found under that name with its SpecId.

The check treats such a pair as a sign that code compiled for the erased
element type could be handed a list whose heads are unboxed. Because names are
grouped without their module, and the element types of every parameter and of
the result are pooled, the two element types need not belong to the same
function or the same parameter. Element types that differ in any other way,
such as `MInt` beside `MFloat` or `MString`, are not a problem.

-}
checkSpecializationConsistency : Mono.SpecializationRegistry -> List String
checkSpecializationConsistency registry =
    let
        -- Keyed by bare name, so same-named globals of different modules share an entry.
        specsByGlobal =
            Array.foldl
                (\maybeEntry ( i, acc ) ->
                    case maybeEntry of
                        Just ( global, monoType ) ->
                            case collectListElemTypes monoType of
                                [] ->
                                    ( i + 1, acc )

                                elems ->
                                    let
                                        key =
                                            globalToString global

                                        entries =
                                            List.map (\e -> { specId = i, elem = e, unboxed = isUnboxableElem e }) elems

                                        existing =
                                            Dict.get key acc |> Maybe.withDefault []
                                    in
                                    ( i + 1, Dict.insert key (existing ++ entries) acc )

                        Nothing ->
                            ( i + 1, acc )
                )
                ( 0, Dict.empty )
                registry.reverseMapping
                |> Tuple.second
    in
    Dict.foldl
        (\globalName entries acc ->
            let
                hasConcreteUnboxed =
                    List.any (\e -> e.unboxed && not (isErasedElem e.elem)) entries

                hasErasedBoxed =
                    List.any (\e -> not e.unboxed && isErasedElem e.elem) entries
            in
            if hasConcreteUnboxed && hasErasedBoxed then
                let
                    detail =
                        List.map
                            (\e ->
                                "SpecId "
                                    ++ String.fromInt e.specId
                                    ++ " elem="
                                    ++ monoTypeLabel e.elem
                                    ++ " ("
                                    ++ (if e.unboxed then
                                            "unboxed"

                                        else
                                            "boxed"
                                       )
                                    ++ ")"
                            )
                            entries
                in
                ("[REP_BOUNDARY_003]: Specializations of "
                    ++ globalName
                    ++ " have conflicting list element layout: a concrete unboxed element "
                    ++ "coexists with an erased (CEcoValue) boxed element — "
                    ++ String.join ", " detail
                )
                    :: acc

            else
                acc
        )
        []
        specsByGlobal


{-| Returns the element type of every list in `monoType` that is the type
itself, or is reached through function parameter and result types and tuple
elements. The element type of a list is not searched further, and a list
inside a record or a custom type is not found.
-}
collectListElemTypes : Mono.MonoType -> List Mono.MonoType
collectListElemTypes monoType =
    case monoType of
        Mono.MList _ elemType ->
            [ elemType ]

        Mono.MFunction _ _ argTypes returnType ->
            List.concatMap collectListElemTypes argTypes
                ++ collectListElemTypes returnType

        Mono.MTuple _ elemTypes ->
            List.concatMap collectListElemTypes elemTypes

        _ ->
            []


{-| Returns the name a specialization is grouped under: a global's bare name
without its module, or `.field` for the record accessor of `field`.
-}
globalToString : Mono.Global -> String
globalToString global =
    case global of
        Mono.Global _ name ->
            name

        Mono.Accessor name ->
            "." ++ name


{-| Returns whether a list element type is erased: a type variable whose
values are always boxed (`MVar _ CEcoValue`).
-}
isErasedElem : Mono.MonoType -> Bool
isErasedElem elemType =
    case elemType of
        Mono.MVar _ Mono.CEcoValue ->
            True

        _ ->
            False


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
