module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue, Violation)

{-| Checks a monomorphized test program for numeric type variables left
unresolved in specializations whose key types are concrete.

A _specialization_ is one copy of a definition made for one type, its _key
type_, and the graph's specialization registry records each by its SpecId. A
key type is _fully monomorphic_ when it holds no type variable (`MVar`) of
either constraint. Only those specializations are checked; one whose key still
holds a variable is skipped.

`expectFullyMonomorphicNoCEcoValue` compiles a program with
`TestLogic.TestPipeline.runToMono` and searches each such specialization for an
`MVar _ CNumber`, a variable known to be a number but not yet resolved to `Int`
or `Float`. Despite the module's name, an `MVar _ CEcoValue`, a variable whose
values are always boxed, is accepted wherever it appears.

Most of the module is one walk over a node and its body. It looks at the node's
type and parameter types, and in the body at the type of each expression,
closure and tail-recursive local parameter types, and expressions inlined into
a case's decision tree. Each type is searched to any depth. `MonoExtern` nodes
(what a kernel definition, among others, becomes), effect-manager leaf nodes,
kernel variables and accessor values are exempt, and constructor and enum nodes
have only their own type checked.

Among what is not checked: the types in destructuring paths and decision-tree
paths, and the ABI types recorded on closures and calls.

On the graph `runToMono` returns, this check finds nothing. The substitution
engine's `Compiler.Monomorphize.Prune.pruneUnreachableSpecs` turns every
`MVar _ CNumber` in each kept node into `MInt`, at every position this walk
visits, and crashes if one survives. So the expectation passes whenever
compilation succeeds, and a failed resolution shows as a crash rather than a
test failure.

@docs expectFullyMonomorphicNoCEcoValue, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One type found holding an `MVar _ CNumber`.

`context` names the specialization by its SpecId and key type, then any
enclosing closure, tail-recursive local definition or inlined decision-tree
leaf, then the position the type was found in. `message` gives the position,
the whole type and the ids of the offending variables, under a heading that
speaks of a `CEcoValue` variable although the variables listed are `CNumber`
ones.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMono` and passes
when no specialization with a fully monomorphic key type holds an
`MVar _ CNumber` in any position checked; an `MVar _ CEcoValue` is accepted.
If `runToMono` returns an error, it fails with that error, and otherwise with a
count and list of the violations. As the module docstring explains, on a
graph from `runToMono` it finds no violation.
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


{-| Returns the violations in every specialization of the graph whose key type is
fully monomorphic, in SpecId order. An empty registry slot, which is a pruned
specialization, and a SpecId with no node are skipped.
-}
checkFullyMonomorphicNoCEcoValue : Mono.MonoGraph -> List Violation
checkFullyMonomorphicNoCEcoValue (Mono.MonoGraph data) =
    Array.toIndexedList data.registry.reverseMapping
        |> List.foldl
            (\( specId, maybeEntry ) acc ->
                case maybeEntry of
                    Nothing ->
                        acc

                    Just ( _, keyMonoType ) ->
                        if not (isFullyMonomorphic keyMonoType) then
                            acc

                        else
                            case Array.get specId data.nodes |> Maybe.andThen identity of
                                Nothing ->
                                    acc

                                Just node ->
                                    acc ++ checkNodeAllTypes specId keyMonoType node
            )
            []



-- ============================================================================
-- FULLY MONOMORPHIC CHECK
-- ============================================================================


{-| Returns whether `monoType` holds no type variable of either constraint.
-}
isFullyMonomorphic : Mono.MonoType -> Bool
isFullyMonomorphic monoType =
    not (Mono.containsAnyMVar monoType)



-- ============================================================================
-- NODE-LEVEL CHECK
-- ============================================================================


{-| Returns the violations in `node`, the node of specialization `specId` with key
type `keyType`, each with a context naming both.

A `MonoExtern` node (what a kernel definition, among others, becomes) or an
effect-manager leaf is not checked. A constructor or enum node has only its own
type checked. Any other node has its type, its parameter types if it is a
tail-recursive function, and its body checked.

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

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoCtor _ monoType ->
            checkType ctx "ctor type" monoType

        Mono.MonoEnum _ monoType ->
            checkType ctx "enum type" monoType



-- ============================================================================
-- EXPRESSION-LEVEL CHECK
-- ============================================================================


{-| Returns the violations in `expr` and all of its subexpressions. Their context
is `ctx`, followed by the word `closure` inside a closure, by `taildef=` and
the name inside a tail-recursive local definition, and by `inline-leaf` inside
an expression inlined into a case's decision tree.

It checks each expression's own type, closure and tail-recursive parameter
types, and expressions inlined into a case's decision tree. A kernel variable,
an accessor value and `()` contribute nothing, and destructuring paths are not
looked into. A let-bound value's type and a case branch's type are checked both
as such and as the expression's own type, so one variable can be reported twice.

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

        Mono.MonoVarKernel _ _ _ _ _ ->
            -- Exempt, unlike every other variable reference.
            []

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns the violations in the expressions inlined at the leaves of `decider`,
with the word `inline-leaf` added to `ctx`. A jump leaf contributes nothing, since
its branch is in the case's branch list, and the paths the tree tests are not
checked.
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


{-| Returns one violation if `monoType` holds an `MVar _ CNumber` at any depth,
and none otherwise. Its context is `ctx` followed by `position`.
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


{-| Returns the violations in the types of `params`, each with a position naming
its parameter.
-}
checkParamTypes : String -> List ( String, Mono.MonoType ) -> List Violation
checkParamTypes ctx params =
    List.concatMap
        (\( paramName, paramType ) ->
            checkType ctx ("param=" ++ paramName) paramType
        )
        params


{-| Returns the ids of the `MVar _ CNumber` variables in `monoType`, searched
through lists, functions, tuples, records and custom type arguments, one entry
per occurrence.

Despite the name, an `MVar _ CEcoValue` is not collected: it stands for a boxed
value and may remain in a type. A `CNumber` variable is one that the closing in
`Compiler.Monomorphize.Prune.pruneUnreachableSpecs` should have made `MInt`.

-}
collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MVar mvarId Mono.CNumber ->
            [ String.fromInt (Id.toComparable mvarId) ]

        Mono.MList _ inner ->
            collectCEcoValueVars inner

        Mono.MFunction _ _ args result ->
            List.concatMap collectCEcoValueVars args
                ++ collectCEcoValueVars result

        Mono.MTuple _ elems ->
            List.concatMap collectCEcoValueVars elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectCEcoValueVars fieldType) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap collectCEcoValueVars args

        _ ->
            []



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Returns the failure message for `violations`: a heading with their count,
then each violation's context and message, separated by blank lines.
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


{-| Returns a short rendering of `monoType` for messages. A custom type shows
only its name, a type variable only its id, and a function no lambda set; a
record's fields appear in reverse alphabetical order.
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

        Mono.MList _ elementType ->
            "List " ++ monoTypeToString elementType

        Mono.MTuple _ elements ->
            "(" ++ String.join ", " (List.map monoTypeToString elements) ++ ")"

        Mono.MRecord _ fields ->
            let
                fieldStrs =
                    Dict.foldl
                        (\name ty acc -> (name ++ " : " ++ monoTypeToString ty) :: acc)
                        []
                        fields
            in
            "{ " ++ String.join ", " fieldStrs ++ " }"

        Mono.MCustom _ _ name _ ->
            name

        Mono.MFunction _ _ params result ->
            let
                paramStr =
                    case params of
                        [ single ] ->
                            monoTypeToString single

                        multiple ->
                            "(" ++ String.join ", " (List.map monoTypeToString multiple) ++ ")"
            in
            paramStr ++ " -> " ++ monoTypeToString result

        Mono.MVar mvarId _ ->
            String.fromInt (Id.toComparable mvarId)
