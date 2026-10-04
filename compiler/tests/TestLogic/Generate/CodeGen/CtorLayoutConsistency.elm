module TestLogic.Generate.CodeGen.CtorLayoutConsistency exposing (expectCtorLayoutConsistency)

{-| Checks the `size` and `unboxed_bitmap` of `eco.construct.custom` ops in
generated MLIR against the layouts the compiler computes for constructors with
the same tag, so that a code path which works out a constructor's layout for
itself, and gets it wrong, can be caught.

Three integer attributes of that op describe the value it builds: `tag` says
which constructor it is, `size` how many fields it has, and `unboxed_bitmap`
how each field is stored, boxed or as one of the unboxed kinds. The reference
these are compared with comes from the monomorphized graph's constructor
shapes. A shape gives a constructor's name, tag and field types, and
`Compiler.Generate.MLIR.Types.computeCtorLayout` turns it into a layout; that
function owns the encoding of the bitmap. The same tag occurs in more than one shape,
both across custom types and across the specialisations of one type, so a tag
stands for a list of layouts.

The source module to compile is supplied by the caller. Given one,
`expectCtorLayoutConsistency` checks the following.

  - `TestLogic.TestPipeline.runToMlir` succeeds on it.
  - Every `eco.construct.custom` op, at any depth, has integer `tag`, `size`
    and `unboxed_bitmap` attributes.
  - Where the graph has shapes with an op's tag, one of their layouts has
    `size` fields and the bitmap `unboxed_bitmap`.

Among what is not tested:

  - Which constructor an op builds. Matching is by tag alone, so an op whose
    size and bitmap belong to another constructor with the same tag passes.
  - An op whose tag has no shape in the graph, which is skipped.
  - The op's `constructor` attribute and its operands.
  - Any op other than `eco.construct.custom`. In particular, a custom value
    built by `eco.make.custom` and moved to the heap by `eco.to_heap` has no
    `size` or `unboxed_bitmap` attribute and is not examined.

@docs expectCtorLayoutConsistency

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
every `eco.construct.custom` op in it has integer `tag`, `size` and
`unboxed_bitmap` attributes and either a tag with no shape in the graph or a
size and bitmap matching a layout computed for a shape with that tag. It fails
if `runToMlir` fails, and otherwise with the first violation found.
-}
expectCtorLayoutConsistency : Src.Module -> Expectation
expectCtorLayoutConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCtorLayoutConsistency mlirModule monoGraph)


{-| Returns a violation for each `eco.construct.custom` op in `mlirModule`, at
any depth, that lacks one of its layout attributes or whose size and bitmap
match no layout computed from the constructor shapes of `monoGraph` with its
tag. An op whose tag has no shape is not reported.
-}
checkCtorLayoutConsistency : MlirModule -> Mono.MonoGraph -> List Violation
checkCtorLayoutConsistency mlirModule monoGraph =
    let
        (Mono.MonoGraph { ctorShapes }) =
            monoGraph

        tagToLayout =
            buildTagToLayoutMap ctorShapes

        constructOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.filterMap (checkConstructOp tagToLayout) constructOps


{-| Computes the layout of every constructor shape in `ctorShapes` and returns
the layouts grouped by tag. A tag holds a list because the same tag occurs in
different custom types and in different specialisations of one type.
-}
buildTagToLayoutMap : Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict Int (List Types.CtorLayout)
buildTagToLayoutMap ctorShapes =
    Mono.layoutMapFoldl
        (\_ shapes acc ->
            List.foldl addShapeToMap acc shapes
        )
        Dict.empty
        ctorShapes


{-| Adds the layout computed from `shape` to the list held under its tag in
`dict`.
-}
addShapeToMap : Mono.CtorShape -> Dict.Dict Int (List Types.CtorLayout) -> Dict.Dict Int (List Types.CtorLayout)
addShapeToMap shape dict =
    let
        layout =
            Types.computeCtorLayout shape

        existing =
            Dict.get shape.tag dict
                |> Maybe.withDefault []
    in
    Dict.insert shape.tag (layout :: existing) dict


{-| Returns a violation for `op` if it lacks an integer `tag`, `size` or
`unboxed_bitmap` attribute, or if `tagToLayout` holds layouts for its tag and
none of them has its size and bitmap. Returns `Nothing` for an op whose tag
`tagToLayout` does not hold.
-}
checkConstructOp : Dict.Dict Int (List Types.CtorLayout) -> MlirOp -> Maybe Violation
checkConstructOp tagToLayout op =
    case ( getIntAttr "tag" op, getIntAttr "size" op, getIntAttr "unboxed_bitmap" op ) of
        ( Just tag, Just size, Just bitmap ) ->
            case Dict.get tag tagToLayout of
                Nothing ->
                    -- Not checked: no constructor shape in the graph has this tag.
                    Nothing

                Just layouts ->
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
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.custom missing tag, size, or unboxed_bitmap attribute"
                }


{-| Returns whether `layout` has `size` fields and the bitmap `bitmap`.
-}
layoutMatches : Int -> Int -> Types.CtorLayout -> Bool
layoutMatches size bitmap layout =
    List.length layout.fields == size && layout.unboxedBitmap == bitmap


{-| Renders `layouts` for a failure message, each as `layoutToString` gives it,
separated by semicolons.
-}
layoutsToString : List Types.CtorLayout -> String
layoutsToString layouts =
    layouts
        |> List.map layoutToString
        |> String.join "; "


{-| Renders a layout for a failure message as its constructor name, tag, number
of fields and bitmap.
-}
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
