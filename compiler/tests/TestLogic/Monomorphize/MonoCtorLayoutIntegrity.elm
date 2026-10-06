module TestLogic.Monomorphize.MonoCtorLayoutIntegrity exposing (expectMonoCtorLayoutIntegrity, Violation)

{-| Checks the constructor shapes of a monomorphized graph against the custom
types they come from and against the constructor nodes that use them, so that
a shape list missing a constructor, or a constructor node whose shape is not
the one listed for its own type, fails a test. The violation messages call
this invariant MONO\_013.

A _constructor shape_ (`Mono.CtorShape`) is a constructor's name, its tag, and
the types of its fields after monomorphization; the graph's `ctorShapes`
table holds a list of shapes for each custom type, keyed by layout (lambda-set
annotations ignored). Code generation builds a constructor's heap layout from
its shape alone (`Compiler.Generate.MLIR.Types.computeCtorLayout`), so a shape
that disagrees with the type it is listed under, or with a node that builds
the constructor, gives the heap object the wrong layout.

The fixture is whatever source module the caller passes.
`expectMonoCtorLayoutIntegrity` runs it through `TestPipeline.runToMono`,
the production pipeline (see that function's docstring), and fails with its message if `runToMono` returns an error.
Otherwise it applies two checks to the resulting graph and fails with every
violation found:

  - Every key of `ctorShapes` is a custom type whose declaration the global
    type environment holds, and the shapes listed under it are its
    constructors, in declaration order, by name, each with as many field
    types as the constructor has arguments, and with distinct tags.
  - Every `MonoCtor` node's shape is listed under the custom type it
    constructs, which is the node's `MonoType`: some shape there has the
    node's name and tag, and field types equal, ignoring lambda-set
    annotations, to the node shape's.

Among what is not tested: the heap layout itself, which
`Types.computeCtorLayout` derives from a shape by construction (one field per
field type, unboxed exactly when `Types.canUnbox` accepts the type);
anything inside an expression body, such as a call of a constructor or a
pattern match on one; and the graph after global optimization.

@docs expectMonoCtorLayoutIntegrity, Violation

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Monomorphize.Analysis as Analysis
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One failed check. `context` names what was checked: the shape list of a
custom type, or a constructor node as `SpecId` and its position in the graph's
node array.
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

        Ok { globalTypeEnv, monoGraph } ->
            let
                violations =
                    checkMonoCtorLayoutIntegrity globalTypeEnv monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns the violations of both checks on a graph: those of the shape
lists first, then those of the constructor nodes.
-}
checkMonoCtorLayoutIntegrity : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> List Violation
checkMonoCtorLayoutIntegrity typeEnv (Mono.MonoGraph data) =
    checkShapeListsAgainstUnions typeEnv data.ctorShapes
        ++ checkCtorNodesUseTheirShapes data.ctorShapes data.nodes


{-| Joins violations into one failure message, each as its context, a colon
and its message, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- PART 1: SHAPE LISTS MATCH THEIR CUSTOM TYPES
-- ============================================================================


{-| Returns the violations of every shape list in `ctorShapes`, each against
the declaration of the custom type it is listed under.
-}
checkShapeListsAgainstUnions : TypeEnv.GlobalTypeEnv -> Mono.LayoutMap (List Mono.CtorShape) -> List Violation
checkShapeListsAgainstUnions typeEnv ctorShapes =
    Mono.layoutMapFoldl
        (\keyType shapes acc ->
            checkShapeList typeEnv keyType shapes ++ acc
        )
        []
        ctorShapes


{-| Returns the violations of the shapes listed under `keyType`: a key that is
not a declared custom type, constructors missing, extra or out of order, a
field count that differs from the constructor's argument count, and repeated
tags.
-}
checkShapeList : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> List Mono.CtorShape -> List Violation
checkShapeList typeEnv keyType shapes =
    let
        context =
            "ctorShapes[" ++ Mono.monoTypeToDebugString keyType ++ "]"

        violation message =
            { context = context, message = "MONO_013 violation: " ++ message }
    in
    case keyType of
        Mono.MCustom _ home typeName _ ->
            case Analysis.lookupUnion typeEnv home typeName of
                Nothing ->
                    [ violation "no declaration for this custom type in the global type environment" ]

                Just (Can.Union union) ->
                    let
                        declared =
                            List.map (\(Can.Ctor c) -> ( c.name, c.numArgs )) union.alts

                        listed =
                            List.map (\shape -> ( shape.name, List.length shape.fieldTypes )) shapes

                        tags =
                            List.map .tag shapes
                    in
                    (if declared == listed then
                        []

                     else
                        [ violation
                            ("shapes (name, field count) "
                                ++ Debug.toString listed
                                ++ " differ from the declared constructors "
                                ++ Debug.toString declared
                            )
                        ]
                    )
                        ++ (if List.length (distinctInts tags) == List.length tags then
                                []

                            else
                                [ violation ("repeated constructor tags " ++ Debug.toString tags) ]
                           )

        _ ->
            [ violation "key is not a custom type" ]


{-| Returns `xs` with repeats removed, in no particular order.
-}
distinctInts : List Int -> List Int
distinctInts =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []



-- ============================================================================
-- PART 2: MONOCTOR NODES USE THEIR OWN TYPE'S SHAPE
-- ============================================================================


{-| Returns a violation for each `MonoCtor` node in `nodes` whose shape is not
listed, with equal field types, under the custom type it constructs (its
`MonoType`), naming the node as `SpecId` and its position in `nodes`. Empty
slots and other kinds of node are skipped.
-}
checkCtorNodesUseTheirShapes :
    Mono.LayoutMap (List Mono.CtorShape)
    -> Array.Array (Maybe Mono.MonoNode)
    -> List Violation
checkCtorNodesUseTheirShapes ctorShapes nodes =
    List.concatMap
        (\( specId, maybeNode ) ->
            case maybeNode of
                Just (Mono.MonoCtor shape monoType) ->
                    checkCtorNode ctorShapes specId shape monoType

                _ ->
                    []
        )
        (Array.toIndexedList nodes)


{-| Returns the violations of one `MonoCtor` node, whose `MonoType` is the
custom type it constructs, as `checkCtorNodesUseTheirShapes` describes them.
-}
checkCtorNode : Mono.LayoutMap (List Mono.CtorShape) -> Int -> Mono.CtorShape -> Mono.MonoType -> List Violation
checkCtorNode ctorShapes specId shape customType =
    let
        violation message =
            { context = "SpecId " ++ String.fromInt specId
            , message =
                "MONO_013 violation: MonoCtor '"
                    ++ shape.name
                    ++ "' (tag "
                    ++ String.fromInt shape.tag
                    ++ ") "
                    ++ message
            }

        sameShape listed =
            (listed.name == shape.name)
                && (listed.tag == shape.tag)
                && (List.length listed.fieldTypes == List.length shape.fieldTypes)
                && List.all identity (List.map2 Mono.eqKeyLayout listed.fieldTypes shape.fieldTypes)
    in
    case Mono.layoutMapGet customType ctorShapes of
        Nothing ->
            [ violation ("constructs " ++ Mono.monoTypeToDebugString customType ++ ", which has no entry in ctorShapes") ]

        Just listedShapes ->
            if List.any sameShape listedShapes then
                []

            else
                [ violation
                    ("is not listed, with these field types, under its own type "
                        ++ Mono.monoTypeToDebugString customType
                        ++ ": node fields "
                        ++ Debug.toString shape.fieldTypes
                    )
                ]
