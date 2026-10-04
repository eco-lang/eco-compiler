module TestLogic.LocalOpt.DeciderExhaustive exposing
    ( expectDeciderComplete
    , expectDeciderNoNestedPatterns
    )

{-| Checks meant to show that the typed optimizer turns every `case` into a
decision tree that covers every value and whose tests need no nested matching.
As written, neither check can fail once the module has compiled: each passes
whenever `TestLogic.TestPipeline.runToTypedOpt` returns `Ok`.

In the typed optimized IR (`Compiler.AST.TypedOptimized`) a `case` holds a
_decider_, a tree of tests on the value being matched. A `Leaf` holds the
chosen branch, either inline or as the number of a branch kept beside the tree.
A `Chain` runs a list of tests, each at a _path_, and continues in one subtree
if all of them pass and in the other if not. A `FanOut` switches on the value at
one path, with a subtree per test and a fallback subtree. A path is the steps
from the matched value to a part of it (`Compiler.AST.DecisionTree.TypedPath`),
so a nested pattern becomes tests at longer paths.

Both expectations take one source module, run it to typed optimization, fail
with the pipeline's message if that returns `Err`, and otherwise walk every
decider they reach in the module's local graph:

  - `expectDeciderNoNestedPatterns` hands every path tested at a `Chain` or
    `FanOut` to a check meant to reject a path that needs nested matching. That
    check returns no failure for any path.
  - `expectDeciderComplete` is meant to reject a decider that leaves some value
    unmatched. Its walk recurses through `Chain` and `FanOut` and returns no
    failure at a `Leaf`, so no decider can fail it.

Among what is not tested: whether any decider covers every value, or whether
two of its tests overlap; anything about the paths; and a `case` nested in a
branch held inline in a `Leaf`, or in the body of a value of a recursive group
(the second field of a `Cycle` node), which the walks do not enter.

-}

import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Reporting.Annotation as A
import Data.Map
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and hands the paths tested by the
deciders it reaches to a check for nested matching. A `case` inside a branch
held inline in a `Leaf`, or in a value body of a `Cycle`, is not reached. The
path check finds nothing in any path, so this passes whenever
`TestLogic.TestPipeline.runToTypedOpt` returns `Ok`, and fails with the
pipeline's message when it returns `Err`.
-}
expectDeciderNoNestedPatterns : Src.Module -> Expect.Expectation
expectDeciderNoNestedPatterns srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                checks =
                    collectNestedPatternChecks result.localGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Runs `srcModule` to typed optimization and walks the deciders it reaches
to check that each covers every value. A `case` inside a branch held inline in
a `Leaf`, or in a value body of a `Cycle`, is not reached. The walk reports
nothing for any decider, so this passes whenever
`TestLogic.TestPipeline.runToTypedOpt` returns `Ok`, and fails with the
pipeline's message when it returns `Err`.
-}
expectDeciderComplete : Src.Module -> Expect.Expectation
expectDeciderComplete srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                checks =
                    collectExhaustivenessChecks result.localGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- NESTED PATTERNS
-- ============================================================================


{-| Returns the nested-pattern checks of every node in the graph. Each node's
name, from `globalToString`, is passed down as context, though no check uses
it.
-}
collectNestedPatternChecks : TOpt.LocalGraph Name -> List (() -> Expect.Expectation)
collectNestedPatternChecks (TOpt.LocalGraph data) =
    Data.Map.foldl TOpt.compareGlobal
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeNestedPatterns context node ++ acc
        )
        []
        data.nodes


{-| Returns a global as its module name and its own name joined by a dot, as
in `Module.name`, without the package.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Returns the nested-pattern checks of one node: those of the body of a
definition or port, or of each `Def` of a `Cycle`. A `Cycle`'s value bodies
(its second field) and the nodes that hold no expression give none.
-}
checkNodeNestedPatterns : String -> TOpt.Node Name -> List (() -> Expect.Expectation)
checkNodeNestedPatterns context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprNestedPatternIssues context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprNestedPatternIssues context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefNestedPatterns context def) defs

        TOpt.PortIncoming expr _ _ ->
            collectExprNestedPatternIssues context expr

        TOpt.PortOutgoing expr _ _ ->
            collectExprNestedPatternIssues context expr

        _ ->
            []


{-| Returns the nested-pattern checks of a definition's body, with
`" Def <name>"` or `" TailDef <name>"` added to `context`.
-}
checkDefNestedPatterns : String -> TOpt.Def Name -> List (() -> Expect.Expectation)
checkDefNestedPatterns context def =
    case def of
        TOpt.Def _ name expr _ ->
            collectExprNestedPatternIssues (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name _ expr _ _ ->
            collectExprNestedPatternIssues (context ++ " TailDef " ++ name) expr


{-| Returns the nested-pattern checks of the deciders reached in `expr` and its
sub-expressions. A `case` gives those of its decider and of the branches kept
beside the decider; a branch held inline in a `Leaf` is not entered.
-}
collectExprNestedPatternIssues : String -> TOpt.Expr Name -> List (() -> Expect.Expectation)
collectExprNestedPatternIssues context expr =
    case expr of
        TOpt.Case _ _ decider branches _ ->
            checkDeciderNestedPatterns context decider
                ++ List.concatMap (\( _, branchExpr ) -> collectExprNestedPatternIssues context branchExpr) branches

        TOpt.Function _ _ bodyExpr _ ->
            collectExprNestedPatternIssues context bodyExpr

        TOpt.TrackedFunction _ _ bodyExpr _ ->
            collectExprNestedPatternIssues context bodyExpr

        TOpt.Call _ fnExpr argExprs _ ->
            collectExprNestedPatternIssues context fnExpr
                ++ List.concatMap (collectExprNestedPatternIssues context) argExprs

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> collectExprNestedPatternIssues context argExpr) args

        TOpt.If branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprNestedPatternIssues context c ++ collectExprNestedPatternIssues context t) branches
                ++ collectExprNestedPatternIssues context elseExpr

        TOpt.Let def bodyExpr _ ->
            checkDefNestedPatterns context def
                ++ collectExprNestedPatternIssues context bodyExpr

        TOpt.Destruct _ valueExpr _ ->
            collectExprNestedPatternIssues context valueExpr

        TOpt.List _ exprs _ ->
            List.concatMap (collectExprNestedPatternIssues context) exprs

        TOpt.Access recordExpr _ _ _ ->
            collectExprNestedPatternIssues context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            collectExprNestedPatternIssues context recordExpr
                ++ Data.Map.foldl A.compareLocated (\_ updateExpr acc -> collectExprNestedPatternIssues context updateExpr ++ acc) [] updates

        TOpt.Record fieldExprs _ ->
            Dict.foldl (\_ fieldExpr acc -> collectExprNestedPatternIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.TrackedRecord _ fieldExprs _ ->
            Data.Map.foldl A.compareLocated (\_ fieldExpr acc -> collectExprNestedPatternIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.Tuple _ e1 e2 rest _ ->
            collectExprNestedPatternIssues context e1
                ++ collectExprNestedPatternIssues context e2
                ++ List.concatMap (collectExprNestedPatternIssues context) rest

        _ ->
            []


{-| Returns `checkPathForNesting`'s checks for every path tested in `decider`,
at each `Chain` and `FanOut`. A `Leaf` gives none, and a branch held inline in
it is not entered.
-}
checkDeciderNestedPatterns : String -> TOpt.Decider (TOpt.Choice Name) -> List (() -> Expect.Expectation)
checkDeciderNestedPatterns context decider =
    case decider of
        TOpt.Leaf _ ->
            []

        TOpt.Chain tests success failure ->
            let
                pathIssues =
                    List.concatMap (\( path, _ ) -> checkPathForNesting context path) tests
            in
            pathIssues
                ++ checkDeciderNestedPatterns context success
                ++ checkDeciderNestedPatterns context failure

        TOpt.FanOut path tests fallback ->
            checkPathForNesting context path
                ++ List.concatMap (\( _, subDecider ) -> checkDeciderNestedPatterns context subDecider) tests
                ++ checkDeciderNestedPatterns context fallback


{-| Returns the checks for one decider path: none, whatever the path. Both
arguments are ignored, so no path can make `expectDeciderNoNestedPatterns`
fail.
-}
checkPathForNesting : String -> DT.Path -> List (() -> Expect.Expectation)
checkPathForNesting _ _ =
    []



-- ============================================================================
-- EXHAUSTIVENESS
-- ============================================================================


{-| Returns the coverage checks of every node in the graph. Each node's name,
from `globalToString`, is passed down as context, though no check uses it.
-}
collectExhaustivenessChecks : TOpt.LocalGraph Name -> List (() -> Expect.Expectation)
collectExhaustivenessChecks (TOpt.LocalGraph data) =
    Data.Map.foldl TOpt.compareGlobal
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeExhaustiveness context node ++ acc
        )
        []
        data.nodes


{-| Returns the coverage checks of one node: those of the body of a definition
or port, or of each `Def` of a `Cycle`. A `Cycle`'s value bodies (its second
field) and the nodes that hold no expression give none.
-}
checkNodeExhaustiveness : String -> TOpt.Node Name -> List (() -> Expect.Expectation)
checkNodeExhaustiveness context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprExhaustivenessIssues context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprExhaustivenessIssues context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefExhaustiveness context def) defs

        TOpt.PortIncoming expr _ _ ->
            collectExprExhaustivenessIssues context expr

        TOpt.PortOutgoing expr _ _ ->
            collectExprExhaustivenessIssues context expr

        _ ->
            []


{-| Returns the coverage checks of a definition's body, with `" Def <name>"`
or `" TailDef <name>"` added to `context`.
-}
checkDefExhaustiveness : String -> TOpt.Def Name -> List (() -> Expect.Expectation)
checkDefExhaustiveness context def =
    case def of
        TOpt.Def _ name expr _ ->
            collectExprExhaustivenessIssues (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name _ expr _ _ ->
            collectExprExhaustivenessIssues (context ++ " TailDef " ++ name) expr


{-| Returns the coverage checks of the deciders reached in `expr` and its
sub-expressions. A `case` gives those of its decider and of the branches kept
beside the decider; a branch held inline in a `Leaf` is not entered.
-}
collectExprExhaustivenessIssues : String -> TOpt.Expr Name -> List (() -> Expect.Expectation)
collectExprExhaustivenessIssues context expr =
    case expr of
        TOpt.Case _ _ decider branches _ ->
            checkDeciderExhaustiveness decider
                ++ List.concatMap (\( _, branchExpr ) -> collectExprExhaustivenessIssues context branchExpr) branches

        TOpt.Function _ _ bodyExpr _ ->
            collectExprExhaustivenessIssues context bodyExpr

        TOpt.TrackedFunction _ _ bodyExpr _ ->
            collectExprExhaustivenessIssues context bodyExpr

        TOpt.Call _ fnExpr argExprs _ ->
            collectExprExhaustivenessIssues context fnExpr
                ++ List.concatMap (collectExprExhaustivenessIssues context) argExprs

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> collectExprExhaustivenessIssues context argExpr) args

        TOpt.If branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprExhaustivenessIssues context c ++ collectExprExhaustivenessIssues context t) branches
                ++ collectExprExhaustivenessIssues context elseExpr

        TOpt.Let def bodyExpr _ ->
            checkDefExhaustiveness context def
                ++ collectExprExhaustivenessIssues context bodyExpr

        TOpt.Destruct _ valueExpr _ ->
            collectExprExhaustivenessIssues context valueExpr

        TOpt.List _ exprs _ ->
            List.concatMap (collectExprExhaustivenessIssues context) exprs

        TOpt.Access recordExpr _ _ _ ->
            collectExprExhaustivenessIssues context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            collectExprExhaustivenessIssues context recordExpr
                ++ Data.Map.foldl A.compareLocated (\_ updateExpr acc -> collectExprExhaustivenessIssues context updateExpr ++ acc) [] updates

        TOpt.Record fieldExprs _ ->
            Dict.foldl (\_ fieldExpr acc -> collectExprExhaustivenessIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.TrackedRecord _ fieldExprs _ ->
            Data.Map.foldl A.compareLocated (\_ fieldExpr acc -> collectExprExhaustivenessIssues context fieldExpr ++ acc) [] fieldExprs

        TOpt.Tuple _ e1 e2 rest _ ->
            collectExprExhaustivenessIssues context e1
                ++ collectExprExhaustivenessIssues context e2
                ++ List.concatMap (collectExprExhaustivenessIssues context) rest

        _ ->
            []


{-| Returns the coverage checks of `decider`: none, for any decider. It
recurses into both subtrees of each `Chain` and into every subtree and the
fallback of each `FanOut`, and gives no check at a `Leaf`; neither the tests nor
the paths are looked at.
-}
checkDeciderExhaustiveness : TOpt.Decider (TOpt.Choice Name) -> List (() -> Expect.Expectation)
checkDeciderExhaustiveness decider =
    case decider of
        TOpt.Leaf _ ->
            []

        TOpt.Chain _ success failure ->
            checkDeciderExhaustiveness success
                ++ checkDeciderExhaustiveness failure

        TOpt.FanOut _ tests fallback ->
            List.concatMap (\( _, subDecider ) -> checkDeciderExhaustiveness subDecider) tests
                ++ checkDeciderExhaustiveness fallback
