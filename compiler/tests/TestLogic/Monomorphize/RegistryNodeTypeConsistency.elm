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
`TestLogic.TestPipeline.runToMono` (the production pipeline: the solver engine
with lambda-set specialization) and checks the graph it returns:

  - A module that fails to compile fails the check, with the pipeline's
    message.
  - Each `reverseMapping` entry that holds a specialization must have a node
    at the same `SpecId`. A missing node is reported.
  - Where both exist, the registry's type must have the node type's layout
    (`sameLayout`: `Mono.eqLayout` with type variables compared by constraint
    only), including how a function type groups its parameters into stages. Lambda-set annotations are not compared: under the solver
    engine a registry key records the set of the DEMAND that created the
    specialization while the node records its own zonked type, which can be
    ⊤ (seen: key `LSet [2]`, node `LTop 18`, for a partially applied
    two-argument function). Whether MONO\_017 should also bind the
    annotations is an open question
    (plans/staging-honesty-and-production-test-pipeline.md §4).
  - A constructor specialization (`MonoCtor` node) is registered at the
    function type it was requested at (`Int -> Box`) while its node holds the
    constructed type (`Box`), as MONO\_017 states for constructors: the
    registry type's parameters must have the layouts of the shape's field
    types and its final result the node type's layout. Lambda-set analysis
    reads a constructor's payload sets from those parameters.

Empty `reverseMapping` slots, which pruning leaves for removed
specializations, are skipped. Every violation found is reported in one
failure, in `SpecId` order.

Among what is not checked: a node with no registry entry, and the graph after
global optimization.

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

                            Just (Mono.MonoCtor shape nType) ->
                                if ctorRowMatches shape.fieldTypes nType regMonoType then
                                    acc

                                else
                                    acc
                                        ++ [ { context = "SpecId " ++ String.fromInt specId
                                             , message =
                                                "MONO_017 violation (constructor): registry MonoType is not the function from the fields to the node MonoType\n"
                                                    ++ "  registry: "
                                                    ++ monoTypeToString regMonoType
                                                    ++ "\n"
                                                    ++ "  node:     "
                                                    ++ monoTypeToString nType
                                             }
                                           ]

                            Just node ->
                                let
                                    nType =
                                        nodeType node
                                in
                                if not (sameLayout nType regMonoType) then
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


{-| A constructor's registry row is the function type it was requested at:
its parameters, across however many stages, are the shape's field types, and
its final result is the node's constructed type. A constructor without fields
is registered at the constructed type itself.
-}
ctorRowMatches : List Mono.MonoType -> Mono.MonoType -> Mono.MonoType -> Bool
ctorRowMatches fieldTypes nodeT regT =
    case fieldTypes of
        [] ->
            sameLayout nodeT regT

        _ ->
            case regT of
                Mono.MFunction _ _ args result ->
                    if List.length args > List.length fieldTypes then
                        False

                    else
                        sameLayoutList args (List.take (List.length args) fieldTypes)
                            && ctorRowMatches (List.drop (List.length args) fieldTypes) nodeT result

                _ ->
                    False


{-| `Mono.eqLayout`, except that two type variables with the same constraint
are the same whatever their ids: an unresolved (erased) variable has no layout
of its own, and the solver engine numbers the one in a phantom argument
differently in a registry key and in the node it keys (seen: `Box` keyed at
`MVar 4`, its node at `MVar 124`).
-}
sameLayout : Mono.MonoType -> Mono.MonoType -> Bool
sameLayout a b =
    case ( a, b ) of
        ( Mono.MFunction _ _ argsA retA, Mono.MFunction _ _ argsB retB ) ->
            sameLayoutList argsA argsB && sameLayout retA retB

        ( Mono.MList _ xa, Mono.MList _ xb ) ->
            sameLayout xa xb

        ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
            sameLayoutList xsa xsb

        ( Mono.MRecord _ fieldsA, Mono.MRecord _ fieldsB ) ->
            Dict.keys fieldsA
                == Dict.keys fieldsB
                && sameLayoutList (Dict.values fieldsA) (Dict.values fieldsB)

        ( Mono.MCustom _ homeA nameA argsA, Mono.MCustom _ homeB nameB argsB ) ->
            nameA == nameB && homeA == homeB && sameLayoutList argsA argsB

        ( Mono.MVar _ constraintA, Mono.MVar _ constraintB ) ->
            constraintA == constraintB

        _ ->
            a == b


sameLayoutList : List Mono.MonoType -> List Mono.MonoType -> Bool
sameLayoutList xs ys =
    List.length xs == List.length ys && List.all identity (List.map2 sameLayout xs ys)


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
