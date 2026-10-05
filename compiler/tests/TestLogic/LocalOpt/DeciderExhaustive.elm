module TestLogic.LocalOpt.DeciderExhaustive exposing
    ( expectDeciderComplete
    , expectDeciderPathsConsistent
    )

{-| Structural checks on the decision trees the typed optimizer builds for
`case` expressions.

In the typed optimized IR (`Compiler.AST.TypedOptimized`) a `case` holds a
_decider_, a tree of tests on the value being matched, and a list of _jump
targets_, branches kept beside the tree because more than one leaf leads to
them. A `Leaf` holds the chosen branch, either inline or as `Jump i`, the
number of a jump target. A `Chain` runs a list of tests, each at a _path_, and
continues in one subtree if all of them pass and in the other if not. A
`FanOut` switches on the value at one path, with a subtree per test and a
fallback subtree. A path is the steps from the matched value to a part of it
(`Compiler.AST.DecisionTree.TypedPath`), so a nested pattern becomes tests at
longer paths.

Both expectations take one source module, run it to typed optimization, fail
with the pipeline's message if that returns `Err`, and otherwise check every
`case` in the module's local graph: in definition and port bodies, in the
function definitions and the values of a recursive group (`Cycle`), and in
branches held inline in a `Leaf` as well as in jump targets.

  - `expectDeciderComplete` checks that every `Jump i` in a decider names an
    existing jump target of its `case`. It also checks that the tests of each `FanOut` are pairwise
    different, and that an `IsCtor` test's constructor index is below the
    number of constructors it records.
  - `expectDeciderPathsConsistent` checks that every test made at one path
    within a decider is of one kind: constructor tests of one type (same home
    module and constructor count), list tests, tuple tests, or literals of one
    type. A path names one sub-value, which has one type, so two kinds at one
    path mean a path that reaches the wrong part of the value.

A jump target that no leaf names is allowed: the optimizer keeps a branch that
no value reaches (a redundant pattern) as a jump target, and
`TestLogic.TestPipeline` does not run the redundancy check
(`Compiler.Nitpick.PatternMatches`) that rejects such programs in a build;
several catalogue programs have one.

Among what is not tested: that the tree is exhaustive in the sense of covering
every value of the scrutinee's type (every `FanOut` and `Chain` has a fallback
by construction, so this cannot be read off the tree's shape), that the paths
match the scrutinee's type, and that each leaf selects the branch the source
`case` would.

-}

import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and passes when, in every `case`,
the decider and the jump targets match up and every `FanOut`'s tests are
different and well formed, as the module docstring describes. Fails with the
pipeline's message when `TestLogic.TestPipeline.runToTypedOpt` returns `Err`,
and otherwise with one line per problem.
-}
expectDeciderComplete : Src.Module -> Expect.Expectation
expectDeciderComplete =
    expectNoIssues completenessIssues


{-| Runs `srcModule` to typed optimization and passes when, in every `case`,
all the tests made at any one path are of one kind, as the module docstring
describes. Fails with the pipeline's message when
`TestLogic.TestPipeline.runToTypedOpt` returns `Err`, and otherwise with one
line per problem.
-}
expectDeciderPathsConsistent : Src.Module -> Expect.Expectation
expectDeciderPathsConsistent =
    expectNoIssues pathConsistencyIssues


{-| Runs `srcModule` to typed optimization and applies `check` to every `case`
in the local graph, with the name of the node it is in. Passes when no check
reports anything.
-}
expectNoIssues : (String -> CaseParts -> List String) -> Src.Module -> Expect.Expectation
expectNoIssues check srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            case List.concatMap (\( ctx, parts ) -> check ctx parts) (collectCases result.localGraph) of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail (String.join "\n" issues)


{-| The decider of one `case` and its jump targets.
-}
type alias CaseParts =
    { decider : TOpt.Decider (TOpt.Choice Name)
    , jumps : List ( Int, TOpt.Expr Name )
    }



-- ============================================================================
-- COMPLETENESS
-- ============================================================================


{-| Returns the completeness problems of one `case`, each prefixed with `ctx`:
a `Jump` to a missing target, two equal tests in one `FanOut`, and an `IsCtor` test whose index is not below its constructor
count.
-}
completenessIssues : String -> CaseParts -> List String
completenessIssues ctx { decider, jumps } =
    let
        targets =
            List.map Tuple.first jumps

        jumpedTo =
            jumpLeaves decider

        dangling =
            List.filter (\i -> not (List.member i targets)) jumpedTo
                |> List.map (\i -> ctx ++ ": a leaf jumps to target " ++ String.fromInt i ++ ", which the case does not have")
    in
    dangling ++ testIssues ctx decider


{-| Returns the target of every `Jump` leaf in `decider`.
-}
jumpLeaves : TOpt.Decider (TOpt.Choice Name) -> List Int
jumpLeaves decider =
    case decider of
        TOpt.Leaf (TOpt.Jump i) ->
            [ i ]

        TOpt.Leaf (TOpt.Inline _) ->
            []

        TOpt.Chain _ success failure ->
            jumpLeaves success ++ jumpLeaves failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> jumpLeaves d) edges ++ jumpLeaves fallback


{-| Returns the problems with the tests of `decider`: a `FanOut` that makes
the same test twice, and an `IsCtor` test, anywhere, whose index is not below
its constructor count.
-}
testIssues : String -> TOpt.Decider (TOpt.Choice Name) -> List String
testIssues ctx decider =
    case decider of
        TOpt.Leaf _ ->
            []

        TOpt.Chain tests success failure ->
            List.concatMap (\( _, t ) -> ctorIndexIssue ctx t) tests
                ++ testIssues ctx success
                ++ testIssues ctx failure

        TOpt.FanOut path edges fallback ->
            let
                keys =
                    List.map (\( t, _ ) -> DT.testToComparable t) edges

                duplicated =
                    List.length keys /= List.length (unique keys)
            in
            (if duplicated then
                [ ctx ++ ": a FanOut at " ++ pathToString path ++ " makes the same test twice: " ++ String.join ", " keys ]

             else
                []
            )
                ++ List.concatMap (\( t, _ ) -> ctorIndexIssue ctx t) edges
                ++ List.concatMap (\( _, d ) -> testIssues ctx d) edges
                ++ testIssues ctx fallback


{-| Returns a problem when `test` is an `IsCtor` test whose index is not below
the number of constructors it records.
-}
ctorIndexIssue : String -> DT.Test -> List String
ctorIndexIssue ctx test =
    case test of
        DT.IsCtor _ name index numAlts _ ->
            if Index.toMachine index < numAlts then
                []

            else
                [ ctx
                    ++ ": IsCtor "
                    ++ name
                    ++ " has index "
                    ++ String.fromInt (Index.toMachine index)
                    ++ " but only "
                    ++ String.fromInt numAlts
                    ++ " constructors"
                ]

        _ ->
            []


{-| Returns `xs` without repeated elements, keeping the first of each.
-}
unique : List String -> List String
unique xs =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                acc ++ [ x ]
        )
        []
        xs



-- ============================================================================
-- PATH CONSISTENCY
-- ============================================================================


{-| Returns a problem, prefixed with `ctx`, for each path at which the decider
makes tests of more than one kind, as `testKind` classifies them.
-}
pathConsistencyIssues : String -> CaseParts -> List String
pathConsistencyIssues ctx { decider } =
    pathTests decider
        |> List.foldl
            (\( path, test ) acc ->
                Dict.update (pathToString path)
                    (\existing -> Just (unique (testKind test :: Maybe.withDefault [] existing)))
                    acc
            )
            Dict.empty
        |> Dict.foldl
            (\path kinds acc ->
                if List.length kinds > 1 then
                    (ctx ++ ": tests of different kinds at " ++ path ++ ": " ++ String.join ", " kinds) :: acc

                else
                    acc
            )
            []


{-| Returns every test `decider` makes, with the path it is made at.
-}
pathTests : TOpt.Decider (TOpt.Choice Name) -> List ( DT.Path, DT.Test )
pathTests decider =
    case decider of
        TOpt.Leaf _ ->
            []

        TOpt.Chain tests success failure ->
            tests ++ pathTests success ++ pathTests failure

        TOpt.FanOut path edges fallback ->
            List.map (\( t, _ ) -> ( path, t )) edges
                ++ List.concatMap (\( _, d ) -> pathTests d) edges
                ++ pathTests fallback


{-| Returns the kind of value `test` applies to: for `IsCtor`, the home module
of the type and its constructor count; otherwise list, tuple, or the literal's
type.
-}
testKind : DT.Test -> String
testKind test =
    case test of
        DT.IsCtor (ModuleName.Canonical _ moduleName) _ _ numAlts _ ->
            "ctor of a " ++ String.fromInt numAlts ++ "-constructor type in " ++ moduleName

        DT.IsCons ->
            "list"

        DT.IsNil ->
            "list"

        DT.IsTuple ->
            "tuple"

        DT.IsInt _ ->
            "Int"

        DT.IsChr _ ->
            "Char"

        DT.IsStr _ ->
            "String"

        DT.IsBool _ ->
            "Bool"


{-| Returns a path as the scrutinee `$` followed by its steps, outermost last:
`.i` for the field at position `i` and `.unbox` for an `Unbox`. Container hints
are left out, since one sub-value can be reached with different hints.
-}
pathToString : DT.Path -> String
pathToString path =
    case path of
        DT.Empty ->
            "$"

        DT.Index index _ inner ->
            pathToString inner ++ "." ++ String.fromInt (Index.toMachine index)

        DT.Unbox inner ->
            pathToString inner ++ ".unbox"



-- ============================================================================
-- WALK
-- ============================================================================


{-| Returns every `case` in the graph, with the name of the node it is in, in
the expressions `nodeExprs` gives and at any depth below them.
-}
collectCases : TOpt.LocalGraph Name -> List ( String, CaseParts )
collectCases (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\global node acc ->
            let
                ctx =
                    globalToString global
            in
            List.concatMap (casesIn ctx) (nodeExprs node) ++ acc
        )
        []
        data.nodes


{-| Returns the expressions a node holds: the body of a definition or port,
and the bodies of the function definitions and the values of a `Cycle`.
-}
nodeExprs : TOpt.Node Name -> List (TOpt.Expr Name)
nodeExprs node =
    case node of
        TOpt.Define expr _ _ ->
            [ expr ]

        TOpt.TrackedDefine _ expr _ _ ->
            [ expr ]

        TOpt.Cycle _ values defs _ ->
            List.map Tuple.second values ++ List.map defBody defs

        TOpt.PortIncoming expr _ _ ->
            [ expr ]

        TOpt.PortOutgoing expr _ _ ->
            [ expr ]

        _ ->
            []


{-| Returns the body of a definition.
-}
defBody : TOpt.Def Name -> TOpt.Expr Name
defBody def =
    case def of
        TOpt.Def _ _ expr _ ->
            expr

        TOpt.TailDef _ _ _ expr _ _ ->
            expr


{-| Returns every `case` in `expr`, `expr` itself included, labelled `ctx`.
-}
casesIn : String -> TOpt.Expr Name -> List ( String, CaseParts )
casesIn ctx expr =
    (case expr of
        TOpt.Case _ _ decider jumps _ ->
            [ ( ctx, { decider = decider, jumps = jumps } ) ]

        _ ->
            []
    )
        ++ List.concatMap (casesIn ctx) (children expr)


{-| Returns the immediate sub-expressions of `expr`. For a `case`, these are the
expressions at the decider's `Inline` leaves followed by the jump targets.
-}
children : TOpt.Expr Name -> List (TOpt.Expr Name)
children expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            [ defBody def, body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            inlineLeaves decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Data.Map.values fields

        TOpt.Record fields _ ->
            Dict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


{-| Returns the expressions at the `Inline` leaves of a decider.
-}
inlineLeaves : TOpt.Decider (TOpt.Choice Name) -> List (TOpt.Expr Name)
inlineLeaves decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ success failure ->
            inlineLeaves success ++ inlineLeaves failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> inlineLeaves d) edges ++ inlineLeaves fallback


{-| Returns a global as its module name and its own name joined by a dot, as
in `Module.name`, without the package.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name
