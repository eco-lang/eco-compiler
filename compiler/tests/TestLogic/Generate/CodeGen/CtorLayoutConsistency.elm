module TestLogic.Generate.CodeGen.CtorLayoutConsistency exposing (expectCtorLayoutConsistency)

{-| Checks the `size` and `slot_kinds` of `eco.construct.custom` ops in
generated MLIR against the layouts the compiler computes for the constructor
the op names, so that a code path which works out a constructor's layout for
itself, and gets it wrong, can be caught.

The op's `constructor` attribute names the constructor it builds, and three
attributes describe the value: the integers `tag`, the constructor's index, and
`size`, how many fields it has, and the array `slot_kinds`, how each field is
stored, boxed (0) or as one of the unboxed kinds (1 Int, 2 Float, 3 Char). The reference
these are compared with comes from the monomorphized graph's constructor
shapes. A shape gives a constructor's name, tag and field types, and
`Compiler.Generate.MLIR.Types.computeCtorLayout` turns it into a layout, whose
kinds `Compiler.Generate.MLIR.Types.ctorSlotKinds` gives. A constructor name and tag together
can still occur in more than one shape (across the specialisations of one type,
or two types with a same-named constructor), so the pair stands for a list of
layouts.

The source module to compile is supplied by the caller. Given one,
`expectCtorLayoutConsistency` checks the following.

  - `TestLogic.TestPipeline.runToMlir` succeeds on it.
  - Every `eco.construct.custom` op, at any depth, has a string `constructor`
    attribute, integer `tag` and `size` attributes and a `slot_kinds` array.
  - Where the graph has shapes for the op's constructor name, one of them has
    the op's tag, and one of the layouts of the shapes with that name and tag
    has `size` fields and the kinds `slot_kinds`.

Among what is not tested:

  - Which specialisation of a constructor an op builds: an op whose size and
    kinds belong to another specialisation of the same constructor passes.
  - An op whose constructor name has no shape in the graph, which is skipped.
    This happens for a constructor only a kernel fusion builds, such as the
    `Just` that `Compiler.Generate.MLIR.BytesFusion.Emit` wraps a decoded
    value in.
  - The op's operands.
  - Any op other than `eco.construct.custom`. In particular, a custom value
    built by `eco.make.custom` and moved to the heap by `eco.to_heap` has no
    `size` or `slot_kinds` attribute and is not examined.

@docs expectCtorLayoutConsistency

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
every `eco.construct.custom` op in it has a `constructor` name, integer `tag`
and `size` attributes and a `slot_kinds` array, and, when the graph has shapes
for its constructor name, a tag and a size and kinds matching a layout computed
for a shape with that name and tag. It fails if `runToMlir`
fails, and otherwise with the violations found.
-}
expectCtorLayoutConsistency : Src.Module -> Expectation
expectCtorLayoutConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCtorLayoutConsistency mlirModule monoGraph)


{-| Returns a violation for each `eco.construct.custom` op in `mlirModule`, at
any depth, that lacks one of its layout attributes or whose size and kinds
match no layout computed from the constructor shapes of `monoGraph` with its
constructor name and tag. An op whose constructor name has no shape is not
reported.
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
the layouts grouped by constructor name and tag. A key holds a list because one
constructor occurs in several specialisations of its type.
-}
buildTagToLayoutMap : Mono.LayoutMap (List Mono.CtorShape) -> Dict.Dict ( String, Int ) (List Types.CtorLayout)
buildTagToLayoutMap ctorShapes =
    Mono.layoutMapFoldl
        (\_ shapes acc ->
            List.foldl addShapeToMap acc shapes
        )
        Dict.empty
        ctorShapes


{-| Adds the layout computed from `shape` to the list held under its name and
tag in `dict`.
-}
addShapeToMap : Mono.CtorShape -> Dict.Dict ( String, Int ) (List Types.CtorLayout) -> Dict.Dict ( String, Int ) (List Types.CtorLayout)
addShapeToMap shape dict =
    let
        key =
            ( Name.toElmString shape.name, shape.tag )

        existing =
            Dict.get key dict
                |> Maybe.withDefault []
    in
    Dict.insert key (Types.computeCtorLayout shape :: existing) dict


{-| Returns a violation for `op` if it lacks a string `constructor`, an
integer `tag` or `size`, or a `slot_kinds` array attribute, if `tagToLayout`
holds layouts for its constructor name but none for that name and its tag, or
if none of the layouts for its name and tag has its size and kinds. An op whose
constructor name `tagToLayout` does not hold is not reported.
-}
checkConstructOp : Dict.Dict ( String, Int ) (List Types.CtorLayout) -> MlirOp -> Maybe Violation
checkConstructOp tagToLayout op =
    case ( ( getStringAttr "constructor" op, getIntAttr "tag" op ), ( getIntAttr "size" op, getArrayAttr "slot_kinds" op |> Maybe.map (List.filterMap extractKind) ) ) of
        ( ( Just ctorName, Just tag ), ( Just size, Just kinds ) ) ->
            case Dict.get ( ctorName, tag ) tagToLayout of
                Nothing ->
                    if List.any (\( name, _ ) -> name == ctorName) (Dict.keys tagToLayout) then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "eco.construct.custom for constructor "
                                    ++ ctorName
                                    ++ " has tag="
                                    ++ String.fromInt tag
                                    ++ ", but no constructor shape of that name in the graph has that tag"
                            }

                    else
                        -- Not checked: no constructor shape in the graph has this name
                        -- (e.g. a constructor only a kernel fusion builds).
                        Nothing

                Just layouts ->
                    if List.any (layoutMatches size kinds) layouts then
                        Nothing

                    else
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "eco.construct.custom for constructor "
                                    ++ ctorName
                                    ++ " with tag="
                                    ++ String.fromInt tag
                                    ++ ", size="
                                    ++ String.fromInt size
                                    ++ ", slot_kinds=["
                                    ++ kindsToString kinds
                                    ++ "]"
                                    ++ " does not match any computed CtorLayout. "
                                    ++ "Expected one of: "
                                    ++ layoutsToString layouts
                            }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.construct.custom missing constructor, tag, size, or slot_kinds attribute"
                }


{-| Returns whether `layout` has `size` fields and the slot kinds `kinds`.
-}
layoutMatches : Int -> List Int -> Types.CtorLayout -> Bool
layoutMatches size kinds layout =
    List.length layout.fields == size && Types.ctorSlotKinds layout == kinds


{-| The integer held by one `slot_kinds` entry, or `Nothing` for an entry that
is not an integer.
-}
extractKind : MlirAttr -> Maybe Int
extractKind attr =
    case attr of
        IntAttr _ k ->
            Just k

        _ ->
            Nothing


{-| Renders a list of slot kinds for a failure message, comma-separated.
-}
kindsToString : List Int -> String
kindsToString =
    String.join "," << List.map String.fromInt


{-| Renders `layouts` for a failure message, each as `layoutToString` gives it,
separated by semicolons.
-}
layoutsToString : List Types.CtorLayout -> String
layoutsToString layouts =
    layouts
        |> List.map layoutToString
        |> String.join "; "


{-| Renders a layout for a failure message as its constructor name, tag, number
of fields and slot kinds.
-}
layoutToString : Types.CtorLayout -> String
layoutToString layout =
    "{ name="
        ++ layout.name
        ++ ", tag="
        ++ String.fromInt layout.tag
        ++ ", size="
        ++ String.fromInt (List.length layout.fields)
        ++ ", kinds=["
        ++ kindsToString (Types.ctorSlotKinds layout)
        ++ "] }"
