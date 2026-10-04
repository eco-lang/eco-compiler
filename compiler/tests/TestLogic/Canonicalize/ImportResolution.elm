module TestLogic.Canonicalize.ImportResolution exposing (expectImportsResolved)

{-| A test expectation for the rule that every name a module takes from an
import resolves to a definition, which in practice checks only that the module
compiles as far as PostSolve.

Canonicalization is the compiler stage that resolves each name in a module to
the module that defines it, using the interfaces of the modules it imports. A
name an import lists in its `exposing` clause that the imported module does not
export, and a reference, qualified or not, to a name that nothing in scope
provides, are canonicalization errors. So a module that canonicalizes has had
its imported references resolved.

`expectImportsResolved` runs a module through `TestLogic.TestPipeline.runToPostSolve`
(canonicalization, type checking and PostSolve, against the mock interfaces that
module describes) and fails if canonicalization or type checking fails;
PostSolve reports no failure. After a success it walks the definitions of the
canonical module looking for problems with references, but no case of the walk
ever reports one. So the expectation passes exactly when the run through
PostSolve succeeds, and it adds no check of its own to what those stages do.

An import of a module that has no interface crashes the canonicalizer when
that import is reached, rather than failing the expectation. It is not reached
if an earlier import has already failed. A kernel module's import without `as`
is dropped instead, because the module under test belongs to `eco/example`,
which is a kernel package.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` gets through canonicalization, type checking and
PostSolve.

A failure fails with the pipeline's message, prefixed with
"Import resolution failed: " when the message contains "import" in any case.
`TestLogic.TestPipeline.runToPostSolve` reports these failures by a count of
errors, so its messages do not name the imports involved. After a success the
canonical module is walked for problems with references, and the walk never
finds one.

-}
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            if String.contains "import" (String.toLower msg) then
                Expect.fail ("Import resolution failed: " ++ msg)

            else
                Expect.fail msg

        Ok result ->
            let
                issues =
                    collectImportIssues result.canonical
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- REFERENCE WALK
-- ============================================================================


{-| Returns a message for each problem with a reference found in the top-level
definitions of a canonical module. The list is always empty, because no case of
the walk reports a problem.
-}
collectImportIssues : Can.Module -> List String
collectImportIssues (Can.Module moduleData) =
    collectDefsImportIssues moduleData.decls


{-| Returns the problems found in every definition of a declaration list,
including each definition of a recursive group.
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


{-| Returns the problems found in the body of a definition. Its argument
patterns and type annotation are not looked at.
-}
collectDefImportIssues : Can.Def -> List String
collectDefImportIssues def =
    case def of
        Can.Def _ _ expr ->
            collectExprImportIssues expr

        Can.TypedDef _ _ _ expr _ ->
            collectExprImportIssues expr


{-| Returns the problems found in an expression and the expressions inside it.

No case adds a problem. The reference cases `VarForeign`, `VarCtor` and
`VarOperator`, which can name another module's value, constructor or operator,
contribute nothing, and every other case either collects from its
subexpressions or contributes nothing. Patterns are not looked at.

-}
collectExprImportIssues : Can.Expr -> List String
collectExprImportIssues (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarForeign _ _ _ ->
            []

        Can.VarCtor _ _ _ _ _ ->
            []

        Can.VarOperator _ _ _ _ ->
            []

        Can.Binop _ _ _ _ left right ->
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
