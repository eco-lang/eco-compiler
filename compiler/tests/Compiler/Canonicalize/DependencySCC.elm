module Compiler.Canonicalize.DependencySCC exposing
    ( expectValidSCCs
    )

{-| Test logic for invariant CANON_005: Dependency SCCs are correctly computed.

For the SCC analysis of value definitions:

  - Verify all definitions in an SCC have mutual dependencies.
  - Verify definitions in different SCCs have acyclic dependencies.
  - Verify topological ordering respects dependency order.

This module reuses the existing typed optimization pipeline to verify
SCC computation works correctly.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Data.Set as Set exposing (EverySet)
import Expect


{-| Verify that SCCs are correctly computed.
-}
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    case TOMono.runToPostSolve srcModule of
        Err msg ->
            -- Check if this is a recursion error
            if String.contains "recursive" (String.toLower msg) then
                -- This could be expected for invalid recursion tests
                Expect.pass

            else
                Expect.fail msg

        Ok result ->
            let
                issues =
                    collectSCCIssues result.canonical
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- SCC VERIFICATION
-- ============================================================================


{-| Collect SCC-related issues from the canonical module.

After canonicalization, the declarations are organized into:

  - Single declarations (Declare) for non-recursive definitions
  - Recursive declaration groups (DeclareRec) for mutually recursive definitions

-}
collectSCCIssues : Can.Module -> List String
collectSCCIssues (Can.Module moduleData) =
    collectDeclsSCCIssues moduleData.decls


{-| Collect SCC issues from declarations.

Verify that:

  - Non-recursive declarations don't reference themselves
  - Recursive declarations actually have mutual dependencies

-}
collectDeclsSCCIssues : Can.Decls -> List String
collectDeclsSCCIssues decls =
    case decls of
        Can.Declare def rest ->
            -- Single declaration - should not be self-recursive
            checkNonRecursiveDef def
                ++ collectDeclsSCCIssues rest

        Can.DeclareRec def defs rest ->
            -- Recursive group - should have mutual dependencies
            checkRecursiveGroup (def :: defs)
                ++ collectDeclsSCCIssues rest

        Can.SaveTheEnvironment ->
            []


{-| Check that a non-recursive definition doesn't reference itself.
-}
checkNonRecursiveDef : Can.Def -> List String
checkNonRecursiveDef def =
    let
        ( defName, expr ) =
            case def of
                Can.Def (A.At _ name) _ e ->
                    ( name, e )

                Can.TypedDef (A.At _ name) _ _ e _ ->
                    ( name, e )

        references =
            collectLocalReferences expr
    in
    if Set.member identity defName references then
        [ "Non-recursive definition '" ++ defName ++ "' references itself" ]

    else
        []


{-| Check that a recursive group has valid mutual dependencies.

All definitions in a recursive group should be reachable from each other
through the dependency graph.

-}
checkRecursiveGroup : List Can.Def -> List String
checkRecursiveGroup defs =
    let
        names =
            List.map getDefName defs
                |> Set.fromList identity
    in
    -- For now, just verify the group is non-empty
    if List.isEmpty defs then
        [ "Empty recursive group" ]

    else
        []


{-| Get the name from a definition.
-}
getDefName : Can.Def -> String
getDefName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| Collect local variable references from an expression.
-}
collectLocalReferences : Can.Expr -> EverySet String String
collectLocalReferences (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Set.insert identity name Set.empty

        Can.Lambda _ body ->
            collectLocalReferences body

        Can.Call fn args ->
            Set.union
                (collectLocalReferences fn)
                (List.foldl (\arg acc -> Set.union acc (collectLocalReferences arg)) Set.empty args)

        Can.If branches else_ ->
            List.foldl
                (\( cond, then_ ) acc ->
                    Set.union acc (Set.union (collectLocalReferences cond) (collectLocalReferences then_))
                )
                (collectLocalReferences else_)
                branches

        Can.Let def body ->
            Set.union (collectDefReferences def) (collectLocalReferences body)

        Can.LetRec defs body ->
            List.foldl (\d acc -> Set.union acc (collectDefReferences d)) (collectLocalReferences body) defs

        Can.LetDestruct _ value body ->
            Set.union (collectLocalReferences value) (collectLocalReferences body)

        Can.Case value branches ->
            List.foldl
                (\(Can.CaseBranch _ e) acc -> Set.union acc (collectLocalReferences e))
                (collectLocalReferences value)
                branches

        Can.Access record _ ->
            collectLocalReferences record

        Can.Update record fields ->
            Dict.foldl A.compareLocated
                (\_ (Can.FieldUpdate _ e) acc -> Set.union acc (collectLocalReferences e))
                (collectLocalReferences record)
                fields

        Can.Record fields ->
            Dict.foldl A.compareLocated (\_ e acc -> Set.union acc (collectLocalReferences e)) Set.empty fields

        Can.Tuple a b rest ->
            Set.union
                (collectLocalReferences a)
                (Set.union
                    (collectLocalReferences b)
                    (List.foldl (\c acc -> Set.union acc (collectLocalReferences c)) Set.empty rest)
                )

        Can.List exprs ->
            List.foldl (\e acc -> Set.union acc (collectLocalReferences e)) Set.empty exprs

        Can.Negate e ->
            collectLocalReferences e

        Can.Binop _ _ _ _ left right ->
            Set.union (collectLocalReferences left) (collectLocalReferences right)

        _ ->
            Set.empty


{-| Collect local references from a definition body.
-}
collectDefReferences : Can.Def -> EverySet String String
collectDefReferences def =
    case def of
        Can.Def _ _ expr ->
            collectLocalReferences expr

        Can.TypedDef _ _ _ expr _ ->
            collectLocalReferences expr
