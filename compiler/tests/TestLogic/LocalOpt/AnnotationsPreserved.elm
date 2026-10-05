module TestLogic.LocalOpt.AnnotationsPreserved exposing (expectAnnotationsPreserved)

{-| Checks that the local graph typed optimization builds has an annotation for
every top-level value it holds, and that it kept the annotation of every
top-level name type checking annotated. The global graph that monomorphization
starts from takes its annotations from the local graph, so a name missing there
would reach monomorphization without its type.

An _annotation_ here is a type scheme, a `Can.Annotation`: a type together with
the type variables it is generalized over. Type checking gives one for each
top-level definition, port and effect-manager value of a module, and typed
optimization builds a `TOpt.LocalGraph` whose `annotations` field holds them.

There are two checks:

  - Every value node of the local graph (a `Define`, `TrackedDefine`,
    `PortIncoming` or `PortOutgoing`, and each name a `Cycle` defines) has an
    entry in the graph's `annotations`. This covers nodes typed optimization
    creates or renames itself, which type checking never saw.
  - For each name type checking annotated, the graph's `annotations` holds the
    same scheme, so typed optimization neither dropped nor overwrote it.

Typed optimization starts the graph's `annotations` from the annotations it is
given (`Compiler.LocalOpt.Typed.Module.optimizeTyped`), so the second check
fails only if a later step removes or replaces an entry; the first is the one
that can catch a node added without a type.

The input program goes through `TestLogic.TestPipeline.runToTypedOpt`, which
adds a synthetic `main` that refers to the program's `testValue`, so the
program must define `testValue` and `main` is among the names checked.

-}

import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Data.Map
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Builds an expectation that runs `srcModule` through typed optimization and
passes when the local graph has an annotation under every name type checking
annotated.

It fails with the pipeline's own message when any stage up to and including
typed optimization fails, and otherwise with one line per missing name.

-}
expectAnnotationsPreserved : Src.Module -> Expect.Expectation
expectAnnotationsPreserved srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectAnnotationIssues result
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| Returns a message for each value node of the local graph with no entry in
the graph's `annotations`, and for each name in `result.annotations`, the
annotations type checking produced, whose entry in the graph's `annotations` is
missing or different. An empty list means nothing is wrong.
-}
collectAnnotationIssues : Pipeline.TypedOptArtifacts -> List String
collectAnnotationIssues result =
    let
        (TOpt.LocalGraph graphData) =
            result.localGraph

        graphAnnotations =
            graphData.annotations

        unannotatedNodes =
            Data.Map.foldl
                (\(TOpt.Global _ name) node acc ->
                    List.filter (\n -> not (Dict.member n graphAnnotations)) (valueNames name node)
                        |> List.map (\n -> n ++ ": value node has no annotation in the LocalGraph")
                        |> (\new -> new ++ acc)
                )
                []
                graphData.nodes

        lostOrChanged =
            Dict.foldl
                (\name ann acc ->
                    case Dict.get name graphAnnotations of
                        Nothing ->
                            (name ++ ": Annotation missing from LocalGraph") :: acc

                        Just graphAnn ->
                            if graphAnn == ann then
                                acc

                            else
                                (name ++ ": LocalGraph annotation differs from the type checker's") :: acc
                )
                []
                result.annotations
    in
    unannotatedNodes ++ lostOrChanged


{-| Returns the top-level value names a node of the local graph, stored under
`name`, defines: `name` itself for a definition or a port, and every name a
`Cycle` defines. Constructors, aliases, kernels, links and managers define
none here.
-}
valueNames : String -> TOpt.Node Name -> List String
valueNames name node =
    case node of
        TOpt.Define _ _ _ ->
            [ name ]

        TOpt.TrackedDefine _ _ _ _ ->
            [ name ]

        TOpt.PortIncoming _ _ _ ->
            [ name ]

        TOpt.PortOutgoing _ _ _ ->
            [ name ]

        TOpt.Cycle names values defs _ ->
            names
                ++ List.map Tuple.first values
                ++ List.map
                    (\def ->
                        case def of
                            TOpt.Def _ n _ _ ->
                                n

                            TOpt.TailDef _ n _ _ _ _ ->
                                n
                    )
                    defs

        _ ->
            []
