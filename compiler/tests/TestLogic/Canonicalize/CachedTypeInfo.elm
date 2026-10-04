module TestLogic.Canonicalize.CachedTypeInfo exposing (expectTypeInfoCached)

{-| An expectation for test programs, named for the property that the type
information computed for a module matches the module's source. It checks less
than its name says: it passes whenever the module gets through type checking
and PostSolve.

`expectTypeInfoCached` runs a source module through
`TestLogic.TestPipeline.runToPostSolve`, which canonicalizes it against the
pipeline's mock interfaces, type checks it with node ids recorded and runs
PostSolve. A stage that fails gives `Err`, and the expectation fails with its
message. A stage that crashes is not caught.

After a successful run, the expectation walks the module's top-level
definitions and looks each one's name up in the annotations, the types that
solving returned for the module's top-level names. The lookup reports no issue
whether or not the name is found, so nothing after a successful run can fail the
expectation.

Among what is not checked:

  - that every definition has an annotation;
  - that an annotation agrees with the definition's written type annotation, or
    with the type a fresh type check would give;
  - how type variables are named;
  - the node types, before or after PostSolve;
  - anything stored on disk, or what happens after a module is edited.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` gets through `TestLogic.TestPipeline.runToPostSolve`,
and fails with the pipeline's message when a stage fails.

The issues found by `collectCachedTypeIssues` would also fail it, but that list
is always empty.

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


{-| Returns the issues found by looking up each top-level definition of
`canonical` in `annotations`. The list is always empty, because
`checkDefHasAnnotation` reports nothing.
-}
collectCachedTypeIssues : Can.Module -> Dict.Dict String (Can.Annotation Name) -> List String
collectCachedTypeIssues canonical annotations =
    let
        (Can.Module moduleData) =
            canonical
    in
    checkDefsHaveAnnotations moduleData.decls annotations


{-| Returns the issues `checkDefHasAnnotation` reports for each definition in
`decls`, the members of a recursive group included. The list is always empty.
-}
checkDefsHaveAnnotations : Can.Decls -> Dict.Dict String (Can.Annotation Name) -> List String
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


{-| Looks the name of `def` up in `annotations` and returns no issue, whether
the name is found or not and whether or not `def` carries a type annotation.
-}
checkDefHasAnnotation : Can.Def -> Dict.Dict String (Can.Annotation Name) -> List String
checkDefHasAnnotation def annotations =
    case def of
        Can.Def (A.At _ name) _ _ ->
            case Dict.get name annotations of
                Just _ ->
                    []

                Nothing ->
                    []

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            case Dict.get name annotations of
                Just _ ->
                    []

                Nothing ->
                    []
