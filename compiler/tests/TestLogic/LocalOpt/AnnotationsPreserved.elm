module TestLogic.LocalOpt.AnnotationsPreserved exposing (expectAnnotationsPreserved)

{-| Checks that typed optimization keeps an annotation for every top-level name
that type checking annotated. The global graph that monomorphization starts
from takes its annotations from the local graph, so a name missing there would
reach monomorphization without its type.

An _annotation_ here is a type scheme, a `Can.Annotation`: a type together with
the type variables it is generalized over. Type checking gives one for each
top-level definition, port and effect-manager value of a module, and typed
optimization builds a `TOpt.LocalGraph` whose `annotations` field holds them.

The check is presence only. For each name type checking annotated, it asks
whether the local graph's `annotations` has an entry under that name; the two
schemes are never compared, so an entry with a different type passes. Names in
the local graph that type checking did not annotate, such as constructors, are
not reported.

Typed optimization starts the graph's `annotations` from the annotations it is
given, which are the ones checked here, and only adds entries for constructors
and aliases (`Compiler.LocalOpt.Typed.Module.optimizeTyped`). While that holds,
the check passes whenever typed optimization succeeds.

The input program goes through `TestLogic.TestPipeline.runToTypedOpt`, which
adds a synthetic `main` that refers to the program's `testValue`, so the
program must define `testValue` and `main` is among the names checked.

-}

import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
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


{-| Returns a message for each name in `result.annotations`, the annotations
type checking produced, that has no entry in the local graph's `annotations`.
Only presence is checked; the schemes are not compared. An empty list means
nothing is missing.
-}
collectAnnotationIssues : Pipeline.TypedOptArtifacts -> List String
collectAnnotationIssues result =
    let
        (TOpt.LocalGraph graphData) =
            result.localGraph

        graphAnnotations =
            graphData.annotations

        sourceAnnotations =
            result.annotations
    in
    Dict.foldl
        (\name _ acc ->
            case Dict.get name graphAnnotations of
                Nothing ->
                    (name ++ ": Annotation missing from LocalGraph") :: acc

                Just _ ->
                    acc
        )
        []
        sourceAnnotations
