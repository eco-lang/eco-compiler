module TestLogic.Canonicalize.DependencySCC exposing (expectValidSCCs)

{-| A checker for how canonicalization groups a module's top-level
definitions, meant to catch a canonicalizer that groups them wrongly. What it
actually checks is much narrower, as set out below.

The canonicalizer sorts a module's top-level definitions into the strongly
connected components (SCCs) of their dependency graph, and gives the module
its declarations as a chain of them. A definition in a component of its own
that does not depend on itself is a `Can.Declare`. A group of definitions that
depend on each other, or a single definition that depends on itself, is one
`Can.DeclareRec`. `Compiler.Canonicalize.Module` owns this grouping, and the
rule that decides which cycles among definitions with no arguments are
errors.

`expectValidSCCs` runs a source module through
`TestLogic.TestPipeline.runToPostSolve` and walks the canonical declarations.
It reports two things:

  - a `Declare`d definition whose body names the definition as a local
    variable (`Can.VarLocal`);
  - a `DeclareRec` group with no definitions.

Neither arises from a module that canonicalizes. A body cannot name its own
definition as a local variable, because a local binding that reuses a
top-level name is a `Shadowing` error, and a reference to a top-level
definition is a `Can.VarTopLevel`, which the walk does not collect. A
`DeclareRec` always carries at least one definition. So the expectation
passes when the pipeline succeeds. A pipeline failure passes only if its
message contains "recursive", and the messages `TestLogic.TestPipeline` gives
for a canonicalization or type checking failure carry only a count of
errors, so such a failure fails the expectation.

Among what is not checked: that the definitions of a `DeclareRec` group
depend on each other, that there is no cycle between definitions in
different groups, and the order of the groups.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Data.Set as Set exposing (EverySet)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through `TestLogic.TestPipeline.runToPostSolve` and
checks its canonical declarations.

The expectation fails, with one line per problem, if a `Can.Declare`d
definition's body names the definition as a local variable or a
`Can.DeclareRec` group is empty; otherwise it passes. If the pipeline fails,
the expectation passes when the failure message contains "recursive", in any
letter case, and fails with the message otherwise.

-}
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            if String.contains "recursive" (String.toLower msg) then
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


{-| Returns one message for each problem `collectDeclsSCCIssues` finds in the
declarations of a canonical module.
-}
collectSCCIssues : Can.Module -> List String
collectSCCIssues (Can.Module moduleData) =
    collectDeclsSCCIssues moduleData.decls


{-| Returns a message for each `Can.Declare`d definition in `decls` whose
body names the definition as a local variable, and for each empty
`Can.DeclareRec` group.
-}
collectDeclsSCCIssues : Can.Decls -> List String
collectDeclsSCCIssues decls =
    case decls of
        Can.Declare def rest ->
            checkNonRecursiveDef def
                ++ collectDeclsSCCIssues rest

        Can.DeclareRec def defs rest ->
            checkRecursiveGroup (def :: defs)
                ++ collectDeclsSCCIssues rest

        Can.SaveTheEnvironment ->
            []


{-| Returns a message if the body of `def` names the definition as a local
variable, and no message otherwise.

Only `Can.VarLocal` names are looked for. A reference to a top-level
definition, its own included, is a `Can.VarTopLevel` and is not seen.

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


{-| Returns a message if `defs` is empty, and no message otherwise. The
dependencies between the definitions are not examined.
-}
checkRecursiveGroup : List Can.Def -> List String
checkRecursiveGroup defs =
    if List.isEmpty defs then
        [ "Empty recursive group" ]

    else
        []


{-| Returns the names of the local variables (`Can.VarLocal`) that an
expression references.

Every node with sub-expressions is descended into, including the bodies of
`let` definitions. Patterns are not looked at, and every other leaf, such as
`Can.VarTopLevel` or `Can.VarForeign`, contributes nothing.

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


{-| Returns the names of the local variables referenced in the body of
`def`. Its argument patterns are not looked at.
-}
collectDefReferences : Can.Def -> EverySet String String
collectDefReferences def =
    case def of
        Can.Def _ _ expr ->
            collectLocalReferences expr

        Can.TypedDef _ _ _ expr _ ->
            collectLocalReferences expr
