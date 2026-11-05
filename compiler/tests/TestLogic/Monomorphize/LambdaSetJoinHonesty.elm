module TestLogic.Monomorphize.LambdaSetJoinHonesty exposing (expectHonestJoins)

{-| Checks that where branches of an `if` or a `case` join two function values,
the lambda set the join claims is not smaller than what its branches bring:
no join is a _false singleton_, and more generally no join is a complete set
that leaves out a member a branch is known to carry, or that claims
completeness while a branch's members are unknown. The failure messages name
this check `LSS_026`.

A _lambda set_ is the annotation on an arrow of a `MonoType`
(`Compiler.IR.Mono.LambdaSetAnno`) naming the function values, its _members_,
that can reach that arrow. `LSet ms` claims that `ms` is complete, `LPartial ms`
that at least `ms` arrive, and `LTop` and `LVar` name none (consumers treat an
`LVar` as ⊤). A complete one-member set is what later passes devirtualize: a
call through it becomes a direct call to the member, so a set that leaves out
a function which really arrives makes a wrong program, not a slow one.

LSS\_026 (honest empty-as-source) is the rule that a resolution which reaches a
source slot nothing wrote, while it carries members, resolves to ⊤ and never to
a set: a dangling inflow is unknown, not empty. Its pipeline witness,
`Compiler.Monomorphize.Solver.LssHonestSourcesPipelineTest`, pins it on
`pickG c f = if c then f else incr`: the join of the parameter `f` with the
global `incr` must not read back as `{incr}`. That test checks the one result
of the one caller it knows about; this module states the property at every
join of every program.

The _head annotation_ of an expression is the one on the outermost arrow of its
type (`Mono.headAnno`), and an expression whose type is not a function has
none. A _join_ is a `MonoIf` or a `MonoCase` whose own type is a function; its
_branches_ are, for an `if`, every branch body and the final `else`, and for a
`case`, every body in its jump list and every body its decision tree holds
inline. A join whose head annotation is `LSet js` is checked against each
branch's head annotation:

  - `LSet ms` or `LPartial ms` passes when every member of `ms` is in `js`;
  - `LTop` or `LVar` fails: the branch's members are unknown, so `js` claims a
    completeness it does not have, which is the case LSS\_026 forbids.

A join whose own head annotation is `LTop`, `LVar` or `LPartial` claims no
completeness and always passes.

`expectHonestJoins` compiles the program with
`TestLogic.TestPipeline.runToGlobalOpt` and inspects two graphs from that one
run: `monoGraph`, the graph the solver engine produced, and
`optimizedMonoGraph`, the graph after the post-monomorphization inliner, the
post-inline prune and global optimization. Each message names its graph, so a
dishonest join the solver makes is told apart from one the later passes make.

Among what is not checked:

  - joins that are not an `if` or a `case`, such as two call sites of one
    function, which share a specialization through the registry's join of
    demands (LSS\_010);
  - annotations other than the head of the join's type, such as the arrows of
    a function value's result or of a function inside a record;
  - whether a member in `js` can really arrive (an over-large set is sound).

-}

import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Data.NonEmptyList as NE
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Compiles `srcModule` with `runToGlobalOpt` and passes when no join in the
solver engine's graph or the optimized graph claims a complete set its branches
do not support. It fails with the pipeline's message when compilation fails,
and otherwise with one line per dishonest branch.
-}
expectHonestJoins : Src.Module -> Expectation
expectHonestJoins srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            case collectViolations "solver graph" artifacts.monoGraph ++ collectViolations "optimized graph" artifacts.optimizedMonoGraph of
                [] ->
                    Expect.pass

                issues ->
                    Expect.fail (String.join "\n" (List.take 20 issues))


{-| Returns a message for each dishonest join branch in the graph's nodes,
reported against `label` and the SpecId of the node it is in. Removed nodes are
skipped.
-}
collectViolations : String -> Mono.MonoGraph -> List String
collectViolations label (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1
                    , List.foldl (\body a -> MonoTraverse.foldExpr (checkJoin label specId) a body) acc (nodeBodies node)
                    )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second
        |> List.reverse


{-| Returns the expressions a node holds: its body for a definition, a tail
function or a port, and none for a constructor, an enum, an extern or a
manager leaf.
-}
nodeBodies : Mono.MonoNode -> List Mono.MonoExpr
nodeBodies node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ _ ->
            []

        Mono.MonoEnum _ _ _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Adds to `acc` a message for each branch of `expr` that does not support the
complete set at the head of `expr`'s type, when `expr` is a join with such a
set. Any other expression leaves `acc` unchanged.
-}
checkJoin : String -> Int -> Mono.MonoExpr -> List String -> List String
checkJoin label specId expr acc =
    case joinBranches expr of
        Nothing ->
            acc

        Just ( kind, branches ) ->
            case Mono.typeOf expr of
                Mono.MFunction _ (Mono.LSet js) _ _ ->
                    List.foldl
                        (\( index, branch ) a ->
                            case branchProblem js (Mono.typeOf branch) of
                                Nothing ->
                                    a

                                Just problem ->
                                    ("LSS_026 violation, "
                                        ++ label
                                        ++ ", spec "
                                        ++ String.fromInt specId
                                        ++ ": "
                                        ++ kind
                                        ++ " join claims LSet "
                                        ++ showMembers js
                                        ++ " but branch "
                                        ++ String.fromInt index
                                        ++ " "
                                        ++ problem
                                    )
                                        :: a
                        )
                        acc
                        (List.indexedMap Tuple.pair branches)

                _ ->
                    acc


{-| Returns why a branch of type `branchType` does not support the complete set
`js` at its join, or `Nothing` when it does. A branch whose type is not a
function cannot occur under a function-typed join and is not judged.
-}
branchProblem : List Int -> Mono.MonoType -> Maybe String
branchProblem js branchType =
    case branchType of
        Mono.MFunction _ anno _ _ ->
            case anno of
                Mono.LSet ms ->
                    missing js ms |> Maybe.map (\m -> "carries LSet " ++ showMembers ms ++ ", whose member " ++ String.fromInt m ++ " the join leaves out")

                Mono.LPartial ms ->
                    missing js ms |> Maybe.map (\m -> "carries LPartial " ++ showMembers ms ++ ", whose member " ++ String.fromInt m ++ " the join leaves out")

                Mono.LTop _ ->
                    Just "has unknown members (LTop)"

                Mono.LVar n ->
                    Just ("has unknown members (LVar " ++ String.fromInt n ++ ")")

        _ ->
            Nothing


{-| Returns the first member of `ms` that `js` does not hold.
-}
missing : List Int -> List Int -> Maybe Int
missing js ms =
    List.head (List.filter (\m -> not (List.member m js)) ms)


{-| Returns the kind and the branch bodies of a join: every branch and the final
`else` of an `if`, and every jump-list body and inline decision-tree leaf of a
`case`. Any other expression gives `Nothing`.
-}
joinBranches : Mono.MonoExpr -> Maybe ( String, List Mono.MonoExpr )
joinBranches expr =
    case expr of
        Mono.MonoIf branches final _ ->
            Just ( "if", List.map Tuple.second branches ++ [ final ] )

        Mono.MonoCase _ _ decider jumps _ ->
            Just ( "case", List.map Tuple.second jumps ++ inlineLeaves decider )

        _ ->
            Nothing


{-| Returns the branch bodies a decision tree holds `Inline` at its leaves.
-}
inlineLeaves : Mono.Decider Mono.MonoChoice -> List Mono.MonoExpr
inlineLeaves decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ yes no ->
            inlineLeaves yes ++ inlineLeaves no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> inlineLeaves d) (NE.toList edges) ++ inlineLeaves fallback


{-| Renders a member list for a failure message.
-}
showMembers : List Int -> String
showMembers ms =
    "[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
