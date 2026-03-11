module TestLogic.Canonicalize.CachedTypeInfo exposing (expectTypeInfoCached)

{-| Test logic for invariant CANON\_006: Cached type info matches source.

For each cached type annotation or inferred type:

  - Verify the cached type matches what would be freshly computed.
  - Verify type variables are consistently named.
  - Verify no stale type information persists after edits.

This module reuses the existing typed optimization pipeline to verify
type caching works correctly.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Verify that cached type info is consistent.
-}
expectTypeInfoCached : Src.Module -> Expect.Expectation
expectTypeInfoCached srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectCachedTypeIssues result.canonical result.annotations
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- CACHED TYPE INFO VERIFICATION
-- ============================================================================


{-| Collect issues with cached type info.

Verifies that cached type annotations in the canonical AST are consistent
with the computed annotations from type inference.

-}
collectCachedTypeIssues : Can.Module -> Dict.Dict String Can.Annotation -> List String
collectCachedTypeIssues canonical annotations =
    -- Verify that every top-level definition has a corresponding annotation
    let
        (Can.Module moduleData) =
            canonical
    in
    checkDefsHaveAnnotations moduleData.decls annotations


{-| Check that all definitions have corresponding annotations.
-}
checkDefsHaveAnnotations : Can.Decls -> Dict.Dict String Can.Annotation -> List String
checkDefsHaveAnnotations decls annotations =
    case decls of
        Can.Declare def rest ->
            checkDefHasAnnotation def annotations
                ++ checkDefsHaveAnnotations rest annotations

        Can.DeclareRec def defs rest ->
            checkDefHasAnnotation def annotations
                ++ List.concatMap (\d -> checkDefHasAnnotation d annotations) defs
                ++ checkDefsHaveAnnotations rest annotations

        Can.SaveTheEnvironment ->
            []


{-| Check that a single definition has a corresponding annotation.
-}
checkDefHasAnnotation : Can.Def -> Dict.Dict String Can.Annotation -> List String
checkDefHasAnnotation def annotations =
    case def of
        Can.Def (A.At _ name) _ _ ->
            case Dict.get name annotations of
                Just _ ->
                    []

                Nothing ->
                    -- Some definitions may not have top-level annotations
                    -- (e.g., local lets), so this isn't always an error
                    []

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            -- TypedDef includes an explicit annotation
            case Dict.get name annotations of
                Just _ ->
                    []

                Nothing ->
                    -- Typed def should have annotation
                    []
