module TestLogic.Monomorphize.MonoCtorLayoutIntegrity exposing (expectMonoCtorLayoutIntegrity, Violation)

{-| Checks the constructor shapes of a monomorphized graph, so that a
constructor node whose name and tag no listed shape has, or a shape whose heap
layout unboxes a field that cannot be unboxed, fails a test. The violation
messages call this invariant MONO\_013.

Two terms are owned elsewhere. A _constructor shape_ (`Mono.CtorShape`) is a
constructor's name, its tag, and the types of its fields after
monomorphization; the graph's `ctorShapes` table holds lists of shapes keyed
by type. A _constructor layout_ (`Types.CtorLayout`) is what
`Types.computeCtorLayout` makes of a shape: one entry per field, each saying
whether the field is stored unboxed.

The fixture is whatever source module the caller passes.
`expectMonoCtorLayoutIntegrity` runs it through `TestPipeline.runToMono`,
which monomorphizes with the substitution engine (see that function's
docstring), and fails with its message if `runToMono` returns an error.
Otherwise it applies two checks to the resulting graph and fails with every
violation they find:

  - Every shape in `ctorShapes`, under every type key, is given to
    `Types.computeCtorLayout`. The layout must have as many fields as the shape
    has field types, and a field may be marked unboxed only if its type is
    `Int`, `Float` or `Char`. As `computeCtorLayout` stands, neither check can
    fail: it makes one field per field type, and unboxes a field only when
    `Types.canUnbox` accepts its type, which it does for the same three types.
  - Every `MonoCtor` node in the graph must have a shape whose name and tag
    match those of some shape in `ctorShapes`. The match ignores the type key a
    shape is listed under and its field types, so a shape with the same name
    and tag listed under any custom type satisfies it.

Among what is not tested: the order of a layout's fields, its unboxed bitmap
and count, the boxing of fields from the twenty-fifth on, whether a shape
agrees with the constructor's source definition, and anything inside an
expression body, such as a call of a constructor or a pattern match on one.

@docs expectMonoCtorLayoutIntegrity, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One failed check. `context` names what was checked: a constructor shape
with the type it is listed under, or a constructor node as `SpecId` and its
position in the graph's node array.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Runs `srcModule` through `TestPipeline.runToMono` and passes if the
resulting graph's constructor shapes meet both checks the module docstring
describes. It fails with the pipeline's error if `runToMono` returns one, and
otherwise with every violation found, each as its context and message,
separated by blank lines.
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


{-| Returns the violations of both checks on a graph: those of the shapes'
layouts first, then those of the constructor nodes.
-}
checkMonoCtorLayoutIntegrity : Mono.MonoGraph -> List Violation
checkMonoCtorLayoutIntegrity (Mono.MonoGraph data) =
    let
        layoutViolations =
            checkCtorShapesAgainstLayouts data.ctorShapes

        nodeViolations =
            checkCtorNodesUseKnownShapes data.ctorShapes data.nodes
    in
    layoutViolations ++ nodeViolations


{-| Joins violations into one failure message, each as its context, a colon
and its message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- PART 1: CTOR SHAPE ↔ CTOR LAYOUT CONSISTENCY
-- ============================================================================


{-| Returns the layout violations of every shape in `ctorShapes`, giving each
shape's type key, as `Mono.monoTypeToDebugString` prints it, in its context.
-}
checkCtorShapesAgainstLayouts : Mono.LayoutMap (List Mono.CtorShape) -> List Violation
checkCtorShapesAgainstLayouts ctorShapes =
    Mono.layoutMapFoldl
        (\keyType shapes acc ->
            List.concatMap (checkShapeAgainstLayout (Mono.monoTypeToDebugString keyType)) shapes ++ acc
        )
        []
        ctorShapes


{-| Returns the violations of the layout `Types.computeCtorLayout` makes of
`shape`: a field count that differs from the shape's, and any field marked
unboxed whose type cannot be. `typeKey` is the printed type the shape is
listed under, and is used only in the context.
-}
checkShapeAgainstLayout : String -> Mono.CtorShape -> List Violation
checkShapeAgainstLayout typeKey shape =
    let
        layout =
            Types.computeCtorLayout shape

        context =
            "CtorShape " ++ shape.name ++ " (type: " ++ typeKey ++ ")"

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

        unboxedViolations =
            checkUnboxedFlags context layout.fields
    in
    fieldCountViolations ++ unboxedViolations


{-| Returns one violation, with `context`, for each of `fields` that is marked
unboxed although `isUnboxable` rejects its type.
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


{-| Tells whether a field of this type may be stored unboxed, which is so for
`Int`, `Float` and `Char` and for nothing else. It is a copy of the rule, not a
call of `Types.canUnbox`, which currently accepts the same three types.
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


{-| Returns a short, Elm-like rendering of a type for a failure message. A
record prints as `{ ... }`, a custom type as its bare name without its
arguments, and a type variable as `MVar(n)`, where `n` is its id.
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

        Mono.MList _ elemType ->
            "List (" ++ monoTypeToString elemType ++ ")"

        Mono.MTuple _ elemTypes ->
            "(" ++ String.join ", " (List.map monoTypeToString elemTypes) ++ ")"

        Mono.MRecord _ _ ->
            "{ ... }"

        Mono.MCustom _ _ name _ ->
            name

        Mono.MFunction _ _ params result ->
            "(" ++ String.join ", " (List.map monoTypeToString params) ++ ") -> " ++ monoTypeToString result

        Mono.MVar mvarId _ ->
            "MVar(" ++ String.fromInt (Id.toComparable mvarId) ++ ")"



-- ============================================================================
-- PART 2: MONOCTOR NODES USE KNOWN SHAPES
-- ============================================================================


{-| Returns a violation for each `MonoCtor` node in `nodes` whose shape
`shapeExistsInDict` does not find in `ctorShapes`, naming the node as `SpecId`
and its position in `nodes`. Empty slots and other kinds of node are skipped.
-}
checkCtorNodesUseKnownShapes :
    Mono.LayoutMap (List Mono.CtorShape)
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


{-| Tells whether any shape in `ctorShapes`, under any type key, has the name
and tag of `targetShape`. Field types are not compared.
-}
shapeExistsInDict : Mono.CtorShape -> Mono.LayoutMap (List Mono.CtorShape) -> Bool
shapeExistsInDict targetShape ctorShapes =
    Mono.layoutMapFoldl
        (\_ shapes found ->
            found || List.any (\s -> s.name == targetShape.name && s.tag == targetShape.tag) shapes
        )
        False
        ctorShapes
