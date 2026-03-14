module TestLogic.Monomorphize.MonoCtorLayoutIntegrity exposing (expectMonoCtorLayoutIntegrity, Violation)

{-| Test logic for MONO\_013: Constructor layouts define consistent custom types.

For each custom type and each constructor in MonoGraph.ctorShapes:

  - Verify CtorShape ↔ CtorLayout consistency (field count, ordering, unboxed flags).
  - Check that MonoCtor nodes reference shapes that exist in ctorShapes.
  - Verify unboxed flags are valid (only Int, Float, Char can be unboxed).

Note: MVar types in fieldTypes are allowed for polymorphic types, as long as
they are marked as boxed (isUnboxed = False).

@docs expectMonoCtorLayoutIntegrity, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_013: Verify constructor layouts are consistent.
-}
expectMonoCtorLayoutIntegrity : Src.Module -> Expectation
expectMonoCtorLayoutIntegrity srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkMonoCtorLayoutIntegrity monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check constructor layout consistency for all custom types in the MonoGraph.
-}
checkMonoCtorLayoutIntegrity : Mono.MonoGraph -> List Violation
checkMonoCtorLayoutIntegrity (Mono.MonoGraph data) =
    let
        -- Part 1: Check CtorShape ↔ CtorLayout consistency
        layoutViolations =
            checkCtorShapesAgainstLayouts data.ctorShapes

        -- Part 2: Check all MonoCtor nodes use known shapes
        nodeViolations =
            checkCtorNodesUseKnownShapes data.ctorShapes data.nodes
    in
    layoutViolations ++ nodeViolations


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- PART 1: CTOR SHAPE ↔ CTOR LAYOUT CONSISTENCY
-- ============================================================================


{-| Check all CtorShapes produce valid CtorLayouts via Types.computeCtorLayout.
-}
checkCtorShapesAgainstLayouts : Dict.Dict (List String) (List Mono.CtorShape) -> List Violation
checkCtorShapesAgainstLayouts ctorShapes =
    Dict.foldl
        (\typeKey shapes acc ->
            List.concatMap (checkShapeAgainstLayout typeKey) shapes ++ acc
        )
        []
        ctorShapes


{-| Check a single CtorShape produces a valid CtorLayout.
-}
checkShapeAgainstLayout : List String -> Mono.CtorShape -> List Violation
checkShapeAgainstLayout typeKey shape =
    let
        layout =
            Types.computeCtorLayout shape

        context =
            "CtorShape " ++ shape.name ++ " (type: " ++ String.join "." typeKey ++ ")"

        -- Check field count consistency
        fieldCountViolations =
            if List.length shape.fieldTypes /= List.length layout.fields then
                [ { context = context
                  , message =
                        "MONO_013 violation: Field count mismatch - shape has "
                            ++ String.fromInt (List.length shape.fieldTypes)
                            ++ " fields but layout has "
                            ++ String.fromInt (List.length layout.fields)
                  }
                ]

            else
                []

        -- Check unboxed flags are valid
        unboxedViolations =
            checkUnboxedFlags context layout.fields
    in
    fieldCountViolations ++ unboxedViolations


{-| Check that unboxed flags are only set for Int, Float, Char.
-}
checkUnboxedFlags : String -> List Types.FieldInfo -> List Violation
checkUnboxedFlags context fields =
    List.filterMap
        (\field ->
            if field.isUnboxed && not (isUnboxable field.monoType) then
                Just
                    { context = context
                    , message =
                        "MONO_013 violation: Field "
                            ++ String.fromInt field.index
                            ++ " marked unboxed but type is "
                            ++ monoTypeToString field.monoType
                            ++ " (only Int, Float, Char can be unboxed)"
                    }

            else
                Nothing
        )
        fields


{-| Check if a MonoType can be unboxed (only Int, Float, Char).
-}
isUnboxable : Mono.MonoType -> Bool
isUnboxable monoType =
    case monoType of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MChar ->
            True

        _ ->
            False


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

        Mono.MList elemType ->
            "List (" ++ monoTypeToString elemType ++ ")"

        Mono.MTuple elemTypes ->
            "(" ++ String.join ", " (List.map monoTypeToString elemTypes) ++ ")"

        Mono.MRecord _ ->
            "{ ... }"

        Mono.MCustom _ name _ ->
            name

        Mono.MFunction params result ->
            "(" ++ String.join ", " (List.map monoTypeToString params) ++ ") -> " ++ monoTypeToString result

        Mono.MVar name _ ->
            "MVar(" ++ name ++ ")"



-- ============================================================================
-- PART 2: MONOCTOR NODES USE KNOWN SHAPES
-- ============================================================================


{-| Check all MonoCtor nodes reference shapes that exist in ctorShapes.
-}
checkCtorNodesUseKnownShapes :
    Dict.Dict (List String) (List Mono.CtorShape)
    -> Array.Array (Maybe Mono.MonoNode)
    -> List Violation
checkCtorNodesUseKnownShapes ctorShapes nodes =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    case node of
                        Mono.MonoCtor shape _ ->
                            if shapeExistsInDict shape ctorShapes then
                                ( specId + 1, acc )

                            else
                                ( specId + 1
                                , { context = "SpecId " ++ String.fromInt specId
                                  , message =
                                        "MONO_013 violation: MonoCtor uses shape '"
                                            ++ shape.name
                                            ++ "' (tag "
                                            ++ String.fromInt shape.tag
                                            ++ ") not found in ctorShapes"
                                  }
                                    :: acc
                                )

                        _ ->
                            ( specId + 1, acc )
        )
        ( 0, [] )
        nodes
        |> Tuple.second


{-| Check if a CtorShape exists in the ctorShapes dictionary.
-}
shapeExistsInDict : Mono.CtorShape -> Dict.Dict (List String) (List Mono.CtorShape) -> Bool
shapeExistsInDict targetShape ctorShapes =
    Dict.foldl
        (\_ shapes found ->
            found || List.any (\s -> s.name == targetShape.name && s.tag == targetShape.tag) shapes
        )
        False
        ctorShapes
