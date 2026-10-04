module TestLogic.Monomorphize.RegistryNodeTypeConsistency exposing (expectRegistryNodeTypeConsistency, Violation)

{-| Checks that the specialization registry and the graph's nodes agree on the
type of every specialization, so that code reading a specialization's type
from the registry sees the type its node was built with.

A _specialization_ is one definition at one `MonoType`, numbered by a
`SpecId`. A monomorphized `MonoGraph` holds each specialization in two places,
both indexed by that `SpecId`: its node in `nodes`, which carries the node's
own `MonoType`, and its entry in the registry's `reverseMapping`, which pairs
the specialized global with a separately stored `MonoType`. Monomorphization
writes and updates the two at different points, and nothing in their types
keeps them equal.

`expectRegistryNodeTypeConsistency` runs a source module through
`TestLogic.TestPipeline.runToMono` and checks the graph it returns:

  - A module that fails to compile fails the check, with the pipeline's
    message.
  - Each `reverseMapping` entry that holds a specialization must have a node
    at the same `SpecId`. A missing node is reported.
  - Where both exist, the registry's type must be `==` to the node's type.
    This is plain structural equality, so any difference counts, including
    ones the types printed in the failure message do not show, such as in
    lambda-set annotations, a type variable's constraint, or a custom type's
    arguments. The two printed types can therefore look the same.

Empty `reverseMapping` slots, which pruning leaves for removed
specializations, are skipped. Every violation found is reported in one
failure, in `SpecId` order.

Among what is not checked: a node with no registry entry; the graph the
solver engine produces, which is the compiler's default (`runToMono` uses the
substitution engine); and the graph after global optimization.

@docs expectRegistryNodeTypeConsistency, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One disagreement found by the check. `context` names the specialization,
as `SpecId` followed by its number, and `message` says what is wrong with it.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Compiles `srcModule` to a monomorphized graph and passes if every
specialization in the registry has a node whose type is `==` to the registry's
type for it. Otherwise it fails, with every violation found, or with the
pipeline's message if the module does not compile.
-}
expectRegistryNodeTypeConsistency : Src.Module -> Expectation
expectRegistryNodeTypeConsistency srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkRegistryNodeTypeConsistency monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns one violation for each registry entry that has no node at its
`SpecId`, or whose type is not `==` to its node's type, in `SpecId` order.
Empty registry slots are skipped.
-}
checkRegistryNodeTypeConsistency : Mono.MonoGraph -> List Violation
checkRegistryNodeTypeConsistency (Mono.MonoGraph data) =
    Array.toIndexedList data.registry.reverseMapping
        |> List.foldl
            (\( specId, maybeEntry ) acc ->
                case maybeEntry of
                    Nothing ->
                        acc

                    Just ( _, regMonoType ) ->
                        case Array.get specId data.nodes |> Maybe.andThen identity of
                            Nothing ->
                                acc
                                    ++ [ { context = "SpecId " ++ String.fromInt specId
                                         , message =
                                            "MONO_017 violation: SpecId in registry.reverseMapping but not in graph.nodes"
                                         }
                                       ]

                            Just node ->
                                let
                                    nType =
                                        nodeType node
                                in
                                if nType /= regMonoType then
                                    acc
                                        ++ [ { context = "SpecId " ++ String.fromInt specId
                                             , message =
                                                "MONO_017 violation: registry MonoType != node MonoType\n"
                                                    ++ "  registry: "
                                                    ++ monoTypeToString regMonoType
                                                    ++ "\n"
                                                    ++ "  node:     "
                                                    ++ monoTypeToString nType
                                             }
                                           ]

                                else
                                    acc
            )
            []


{-| Returns the `MonoType` a node carries. It gives the same result as
`Mono.nodeType`.
-}
nodeType : Mono.MonoNode -> Mono.MonoType
nodeType node =
    case node of
        Mono.MonoDefine _ t ->
            t

        Mono.MonoTailFunc _ _ t ->
            t

        Mono.MonoCtor _ t ->
            t

        Mono.MonoEnum _ t ->
            t

        Mono.MonoExtern t ->
            t

        Mono.MonoManagerLeaf _ t ->
            t

        Mono.MonoPortIncoming _ t ->
            t

        Mono.MonoPortOutgoing _ t ->
            t


{-| Builds the failure message: each violation as its context, a colon and its
message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| Renders a `MonoType` as Elm-like text for a failure message.

The rendering loses information, so two different types can print the same.
Lambda-set annotations and stored hashes are left out. A custom type shows
only its name, without its module or type arguments, and a type variable
shows only its id number. Record fields come out in reverse order of their
names, compared as strings. A function's single parameter is not
parenthesised, even when it is itself a function.

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
