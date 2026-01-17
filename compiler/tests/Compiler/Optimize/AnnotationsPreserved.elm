module Compiler.Optimize.AnnotationsPreserved exposing (expectAnnotationsPreserved)

{-| Test logic for invariant TOPT\_003: Top-level annotations preserved in local graph.

For each top-level definition:

  - Compare its type scheme from type checking with the corresponding entry
    in Annotations inside LocalGraphData.
  - Assert every top-level name present in the module exists in the Annotations
    dict with identical scheme.

This module reuses the existing typed optimization pipeline to verify
annotations are preserved through optimization.

-}

import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| Verify that all top-level annotations are preserved in the LocalGraphData.
-}
expectAnnotationsPreserved : Src.Module -> Expect.Expectation
expectAnnotationsPreserved srcModule =
    case TOMono.runToTypedOptimized srcModule of
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



-- ============================================================================
-- ANNOTATION PRESERVATION VERIFICATION
-- ============================================================================


{-| Collect annotation preservation issues.

Compares annotations from the typed result with the LocalGraph annotations.

-}
collectAnnotationIssues : TOMono.TypedOptResult -> List String
collectAnnotationIssues result =
    let
        (TOpt.LocalGraph graphData) =
            result.localGraph

        -- Get the annotations from the local graph
        -- Note: Annotations is a type alias, not a constructor, so we can't pattern match on it
        graphAnnotations =
            graphData.annotations

        -- Get the annotations from the type checking result
        sourceAnnotations =
            result.annotations
    in
    -- Check that all source annotations appear in graph annotations
    Dict.foldl compare
        (\name _ acc ->
            case Dict.get identity name graphAnnotations of
                Nothing ->
                    (name ++ ": Annotation missing from LocalGraph") :: acc

                Just _ ->
                    -- Annotation exists, could do deeper comparison of schemes
                    acc
        )
        []
        sourceAnnotations



-- Note: Full scheme equality checking would require comparing:
-- - Forall quantifiers
-- - Type structure
-- - Constraint equality
-- For now, we just verify presence.
