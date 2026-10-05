module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue, Violation)

{-| Checks that a specialization whose key type is concrete has a concrete
signature: no type variable, of either constraint, in the types that the key
determines.

A _specialization_ is one copy of a definition made for one type, its _key
type_, and the graph's specialization registry records each by its SpecId. A
key type is _fully monomorphic_ when it holds no type variable (`MVar`) of
either constraint. Only those specializations are checked; one whose key still
holds a variable is skipped.

`expectFullyMonomorphicNoCEcoValue` compiles a program with
`TestLogic.TestPipeline.runToMono` and, in each such specialization, searches
its _signature_ for an `MVar _ CEcoValue` (a variable whose values are always
boxed) or an `MVar _ CNumber` (a variable known only to be a number): the
node's own type, the parameter types of a `MonoTailFunc`, and, for a
`MonoDefine` whose body is a closure, that closure's type and parameter types.
A constructor or enum node has its own type checked. A variable in any of
these means the specialization's key was computed wrongly or its substitution
was not applied to the node, which invariant MONO\_024 rules out. Each type is
searched to any depth.

Among what is not checked: the types inside a body. MONO\_024 as written asks
for no `CEcoValue` variable anywhere in the node, but correct output has them
there: an empty list or a `let`-bound function whose type is never constrained
(`let add x y = x`, whose `y` stays a variable), and the result of a comparison
operator in the programs that hit the known TYPE\_007/POST\_010 typing gap. A
`CNumber` variable cannot survive anywhere, because
`Compiler.Monomorphize.Prune.pruneUnreachableSpecs` turns each one into `MInt`
and crashes if one is left. `MonoExtern` nodes and effect-manager leaves are
not checked.

@docs expectFullyMonomorphicNoCEcoValue, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One signature type found holding a type variable.

`context` names the specialization by its SpecId and key type, then `closure`
for a type of the node's closure, then the position the type was found in.
`message` gives the position, the whole type and the ids of the variables, a
`CNumber` one marked `(number)`.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` with `TestLogic.TestPipeline.runToMono` and passes
when no specialization with a fully monomorphic key type holds a type variable
in its signature, as the module docstring describes. If `runToMono` returns an
error, it fails with that error, and otherwise with a count and list of the
violations.
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
                                    acc ++ checkNodeSignature specId keyMonoType node
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


{-| Returns the violations in the signature of `node`, the node of
specialization `specId` with key type `keyType`, each with a context naming
both.

A `MonoExtern` node (what a kernel definition, among others, becomes) or an
effect-manager leaf is not checked. A constructor or enum node has its own type
checked. Any other node has its type checked, with the parameter types of a
`MonoTailFunc`, and the type and parameter types of the closure a `MonoDefine`
is, when it is one.

-}
checkNodeSignature : Int -> Mono.MonoType -> Mono.MonoNode -> List Violation
checkNodeSignature specId keyType node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId ++ " (key: " ++ monoTypeToString keyType ++ ")"
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkType ctx "node type" monoType
                ++ (case expr of
                        Mono.MonoClosure info _ closureType ->
                            checkType (ctx ++ " closure") "closure type" closureType
                                ++ checkParamTypes (ctx ++ " closure") info.params

                        _ ->
                            []
                   )

        Mono.MonoTailFunc params _ monoType ->
            checkType ctx "node type" monoType
                ++ checkParamTypes ctx params

        Mono.MonoPortIncoming _ monoType ->
            checkType ctx "node type" monoType

        Mono.MonoPortOutgoing _ monoType ->
            checkType ctx "node type" monoType

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoCtor _ monoType ->
            checkType ctx "ctor type" monoType

        Mono.MonoEnum _ monoType ->
            checkType ctx "enum type" monoType



-- ============================================================================
-- TYPE CHECK HELPERS
-- ============================================================================


{-| Returns one violation if `monoType` holds an `MVar` of either constraint at
any depth, and none otherwise. Its context is `ctx` followed by `position`.
-}
checkType : String -> String -> Mono.MonoType -> List Violation
checkType ctx position monoType =
    let
        vars =
            collectTypeVars monoType
    in
    if List.isEmpty vars then
        []

    else
        [ { context = ctx ++ " " ++ position
          , message =
                "MONO_024 violation: type variable in the signature of a fully monomorphic specialization\n"
                    ++ "  position: "
                    ++ position
                    ++ "\n"
                    ++ "  type: "
                    ++ monoTypeToString monoType
                    ++ "\n"
                    ++ "  type variables: "
                    ++ String.join ", " vars
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


{-| Returns the ids of the type variables in `monoType`, searched through lists,
functions, tuples, records and custom type arguments, one entry per
occurrence. A `CNumber` variable's id is followed by `(number)`.
-}
collectTypeVars : Mono.MonoType -> List String
collectTypeVars monoType =
    case monoType of
        Mono.MVar mvarId Mono.CEcoValue ->
            [ String.fromInt (Id.toComparable mvarId) ]

        Mono.MVar mvarId Mono.CNumber ->
            [ String.fromInt (Id.toComparable mvarId) ++ " (number)" ]

        Mono.MList _ inner ->
            collectTypeVars inner

        Mono.MFunction _ _ args result ->
            List.concatMap collectTypeVars args
                ++ collectTypeVars result

        Mono.MTuple _ elems ->
            List.concatMap collectTypeVars elems

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectTypeVars fieldType) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap collectTypeVars args

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
