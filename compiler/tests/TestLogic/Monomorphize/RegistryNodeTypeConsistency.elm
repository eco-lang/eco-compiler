module TestLogic.Monomorphize.RegistryNodeTypeConsistency exposing
    ( expectRegistryNodeTypeConsistency
    , Violation
    )

{-| Test logic for MONO\_017: Registry type matches node type.

For every SpecId in SpecializationRegistry.reverseMapping, the stored
MonoType must equal the type of the corresponding MonoNode.

This invariant catches the "two type shapes floating around" bug where:

  - Call sites create SpecIds using one MonoType shape
  - Node bodies are recorded with a different shape
  - Registry type diverges from actual node type

@docs expectRegistryNodeTypeConsistency, Violation

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_017: Verify registry type matches node type.
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


{-| Check registry type consistency for all entries in the MonoGraph.
-}
checkRegistryNodeTypeConsistency : Mono.MonoGraph -> List Violation
checkRegistryNodeTypeConsistency (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId ( _, regMonoType, _ ) acc ->
            case Dict.get identity specId data.nodes of
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
        data.registry.reverseMapping


{-| Extract the MonoType from any MonoNode variant.
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

        Mono.MonoCycle _ t ->
            t


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


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
                    Dict.foldl compare
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
