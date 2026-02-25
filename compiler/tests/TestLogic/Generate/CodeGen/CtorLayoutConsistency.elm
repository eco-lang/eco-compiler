module TestLogic.Generate.CodeGen.CtorLayoutConsistency exposing (expectCtorLayoutConsistency, checkCtorLayoutConsistency)

{-| Test logic for CGEN\_014: MLIR Uses Only MonoGraph ctorLayouts.

eco.construct.custom ops must have tag, size, and unboxed\_bitmap attributes
that match the CtorLayout computed from MonoGraph.ctorShapes.

@docs expectCtorLayoutConsistency, checkCtorLayoutConsistency

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Data.Map as Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (MlirArtifacts, runToMlir)


{-| Verify that ctor layout consistency invariants hold for a source module.
-}
expectCtorLayoutConsistency : Src.Module -> Expectation
expectCtorLayoutConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCtorLayoutConsistency mlirModule monoGraph)


{-| Check that eco.construct.custom attributes match computed CtorLayout.

CGEN\_014: MLIR codegen must use MonoGraph.ctorLayouts for union metadata.

-}
checkCtorLayoutConsistency : MlirModule -> Mono.MonoGraph -> List Violation
checkCtorLayoutConsistency mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) =
            monoGraph

        -- Build a map from tag -> CtorLayout for all known constructors
        tagToLayout =
            buildTagToLayoutMap ctorShapes

        constructOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.filterMap (checkConstructOp tagToLayout) constructOps


{-| Build a map from tag -> CtorLayout.

Note: tags may not be globally unique across different custom types,
so we store a list of layouts per tag and check against all of them.

-}
buildTagToLayoutMap : Dict.Dict (List String) (List String) (List Mono.CtorShape) -> Dict.Dict Int Int (List Types.CtorLayout)
buildTagToLayoutMap ctorShapes =
    Dict.foldl compare
        (\_ shapes acc ->
            List.foldl addShapeToMap acc shapes
        )
        Dict.empty
        ctorShapes


addShapeToMap : Mono.CtorShape -> Dict.Dict Int Int (List Types.CtorLayout) -> Dict.Dict Int Int (List Types.CtorLayout)
addShapeToMap shape dict =
    let
        layout =
            Types.computeCtorLayout shape

        existing =
            Dict.get identity shape.tag dict
                |> Maybe.withDefault []
    in
    Dict.insert identity shape.tag (layout :: existing) dict


{-| Check a single eco.construct.custom op against known layouts.
-}
checkConstructOp : Dict.Dict Int Int (List Types.CtorLayout) -> MlirOp -> Maybe Violation
checkConstructOp tagToLayout op =
    case ( getIntAttr "tag" op, getIntAttr "size" op, getIntAttr "unboxed_bitmap" op ) of
        ( Just tag, Just size, Just bitmap ) ->
            case Dict.get identity tag tagToLayout of
                Nothing ->
                    -- No matching layout found - could be a violation or just
                    -- a constructor from an external module not in our graph
                    Nothing

                Just layouts ->
                    -- Check if any layout matches
                    if List.any (layoutMatches size bitmap) layouts then
                        Nothing

                    else
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "eco.construct.custom with tag="
                                    ++ String.fromInt tag
                                    ++ ", size="
                                    ++ String.fromInt size
                                    ++ ", bitmap="
                                    ++ String.fromInt bitmap
                                    ++ " does not match any computed CtorLayout. "
                                    ++ "Expected one of: "
                                    ++ layoutsToString layouts
                            }

        _ ->
            -- Missing required attributes
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.custom missing tag, size, or unboxed_bitmap attribute"
                }


{-| Check if a layout matches the given size and bitmap.
-}
layoutMatches : Int -> Int -> Types.CtorLayout -> Bool
layoutMatches size bitmap layout =
    List.length layout.fields == size && layout.unboxedBitmap == bitmap


layoutsToString : List Types.CtorLayout -> String
layoutsToString layouts =
    layouts
        |> List.map layoutToString
        |> String.join "; "


layoutToString : Types.CtorLayout -> String
layoutToString layout =
    "{ name="
        ++ layout.name
        ++ ", tag="
        ++ String.fromInt layout.tag
        ++ ", size="
        ++ String.fromInt (List.length layout.fields)
        ++ ", bitmap="
        ++ String.fromInt layout.unboxedBitmap
        ++ " }"
