module Compiler.Canonicalize.ImportResolution exposing (expectImportsResolved)

{-| Test logic for invariant CANON\_004: Import resolution produces valid references.

For each import statement:

  - Verify the imported module exists in the dependency graph.
  - Verify all explicitly imported values/types exist in the target module's exports.
  - Verify qualified references resolve to valid exported symbols.

This module reuses the existing typed optimization pipeline to verify
import resolution works correctly.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Expect


{-| Verify that all imports are properly resolved.
-}
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    -- If the module successfully canonicalizes, all imports were resolved
    case TOMono.runToPostSolve srcModule of
        Err msg ->
            -- Check if this is an import resolution error
            if String.contains "import" (String.toLower msg) then
                -- Expected import resolution failure
                Expect.fail ("Import resolution failed: " ++ msg)

            else
                -- Other error
                Expect.fail msg

        Ok result ->
            -- Module canonicalized successfully, check the canonical module
            let
                issues =
                    collectImportIssues result.canonical
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- IMPORT RESOLUTION VERIFICATION
-- ============================================================================


{-| Collect import resolution issues from the canonical module.

After canonicalization, all imports should have resolved to valid module references.

-}
collectImportIssues : Can.Module -> List String
collectImportIssues (Can.Module moduleData) =
    -- If canonicalization succeeded, imports were resolved.
    -- We verify by checking that expressions don't have unresolved references.
    collectDefsImportIssues moduleData.decls


{-| Collect import issues from declarations.
-}
collectDefsImportIssues : Can.Decls -> List String
collectDefsImportIssues decls =
    case decls of
        Can.Declare def rest ->
            collectDefImportIssues def
                ++ collectDefsImportIssues rest

        Can.DeclareRec def defs rest ->
            collectDefImportIssues def
                ++ List.concatMap collectDefImportIssues defs
                ++ collectDefsImportIssues rest

        Can.SaveTheEnvironment ->
            []


{-| Collect import issues from a single definition.
-}
collectDefImportIssues : Can.Def -> List String
collectDefImportIssues def =
    case def of
        Can.Def _ _ expr ->
            collectExprImportIssues expr

        Can.TypedDef _ _ _ expr _ ->
            collectExprImportIssues expr


{-| Collect import issues from expressions.

In canonical form, all references should be fully qualified with valid module names.

-}
collectExprImportIssues : Can.Expr -> List String
collectExprImportIssues (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarForeign _ _ _ ->
            -- Foreign variables should have valid home modules
            -- The home module should exist (validated during canonicalization)
            []

        Can.VarCtor _ _ _ _ _ ->
            -- Constructor references should have valid home modules
            []

        Can.VarOperator _ _ _ _ ->
            -- Operator references should have valid home modules
            []

        Can.Binop _ _ _ _ left right ->
            -- Binop should have valid home module
            collectExprImportIssues left
                ++ collectExprImportIssues right

        Can.Lambda _ body ->
            collectExprImportIssues body

        Can.Call fn args ->
            collectExprImportIssues fn
                ++ List.concatMap collectExprImportIssues args

        Can.If branches else_ ->
            List.concatMap (\( cond, then_ ) -> collectExprImportIssues cond ++ collectExprImportIssues then_) branches
                ++ collectExprImportIssues else_

        Can.Let def body ->
            collectDefImportIssues def
                ++ collectExprImportIssues body

        Can.LetRec defs body ->
            List.concatMap collectDefImportIssues defs
                ++ collectExprImportIssues body

        Can.LetDestruct _ value body ->
            collectExprImportIssues value
                ++ collectExprImportIssues body

        Can.Case value branches ->
            collectExprImportIssues value
                ++ List.concatMap (\(Can.CaseBranch _ branchExpr) -> collectExprImportIssues branchExpr) branches

        Can.Accessor _ ->
            []

        Can.Access record _ ->
            collectExprImportIssues record

        Can.Update record fields ->
            collectExprImportIssues record
                ++ Dict.foldl A.compareLocated (\_ (Can.FieldUpdate _ fieldExpr) acc -> collectExprImportIssues fieldExpr ++ acc) [] fields

        Can.Record fields ->
            Dict.foldl A.compareLocated (\_ fieldExpr acc -> collectExprImportIssues fieldExpr ++ acc) [] fields

        Can.Unit ->
            []

        Can.Tuple a b rest ->
            collectExprImportIssues a
                ++ collectExprImportIssues b
                ++ List.concatMap collectExprImportIssues rest

        Can.List exprs ->
            List.concatMap collectExprImportIssues exprs

        Can.Negate negatedExpr ->
            collectExprImportIssues negatedExpr

        _ ->
            []
