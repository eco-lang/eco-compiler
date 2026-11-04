module TestLogic.MonoOpt.PostPruneGraphClosed exposing (expectClosedAfterPrune)

{-| Checks MONO\_011 on the graph after the post-inline prune: the graph is
closed and hygienic, and the prune left no unreachable specialization behind,
in its nodes or in its registry. The failure messages name this check
`MONO_011`.

A _specialization_ (spec) is one node of the `MonoGraph`, numbered by its
SpecId, the index of its slot in `nodes`; it is _live_ while that slot holds a
node. The post-monomorphization inliner (`Compiler.MonoOpt.InlineSimplify`)
copies bodies into their callers and can leave a spec with no remaining
reference; the post-inline prune (`Compiler.Monomorphize.Prune.pruneAfterInline`)
then empties the slot of every spec not reachable from the roots: `main`'s spec,
the decoder spec of every port that has one, and the flags decoder's spec. The
risk is the prune removing a spec that a live body still names, or the inliner
leaving a local that is no longer bound where it is used.

`TestLogic.Generate.MonoGraphIntegrity.expectMonoGraphClosed` checks closedness
on the graph `runToMono` returns, before the inliner and the post-inline prune.
A build checks the pruned graph only under `mono.validate`
(`Compiler.Pipeline.Steps.checkPruned`), which is off by default and so off in
the test pipeline. The P test `Compiler.Monomorphize.PostInlinePruneTest` checks
the dangling-reference half on three fixtures (its T5); this module checks every
program it is given.

The graphs are built as a default build builds them. The program is compiled
with `TestLogic.TestPipeline.runToGlobalOpt`; the _pruned graph_ is its
`monoGraph` put through `Steps.inline` and `Steps.prune` under
`TestPipeline.productionConfig`, the two steps `runToGlobalOpt` runs before
global optimization, and the _optimized graph_ is its `optimizedMonoGraph`.

What a graph must satisfy:

  - _closed_: every SpecId a live node's body names with `MonoVarGlobal`, at any
    depth, is live. The references are collected here with
    `Compiler.IR.Mono.Traverse.foldExpr`, not with the `collectSpecEdges` the
    prune walks, so a reference shape that collector misses shows up here as a
    dangling one;
  - _hygienic_: every `MonoVarLocal` is in scope where it occurs, under the rules
    of `MonoGraphIntegrity.localVarScopingChecks`;
  - _pruned_ (pruned graph only): every live spec is reachable from the roots
    over those same references; with no `main` this is not checked, as the
    prune then keeps every node;
  - _registry agrees_ (pruned graph only): a spec has a `reverseMapping` entry
    exactly when it is live.

`expectClosedAfterPrune` checks both graphs from one pipeline run. Global
optimization may add specs of its own and does not prune again, so on the
optimized graph only closedness and hygiene are required.

Among what is not checked: the ports' and flags decoder's SpecIds themselves
(they are roots, not references); `callEdges`; and that a removed spec was
really dead, beyond its not being named by a live body.

-}

import Array exposing (Array)
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Compiler.Pipeline.Steps as Steps
import Expect exposing (Expectation)
import Set exposing (Set)
import TestLogic.Generate.MonoGraphIntegrity as Integrity
import TestLogic.TestPipeline as Pipeline


{-| Compiles `srcModule` with `runToGlobalOpt`, rebuilds the pruned graph from
its monomorphized graph, and passes when the pruned graph is closed, hygienic,
pruned and agrees with its registry, and the optimized graph is closed and
hygienic. It fails with the pipeline's message when compilation fails.
-}
expectClosedAfterPrune : Src.Module -> Expectation
expectClosedAfterPrune srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                config =
                    Pipeline.productionConfig

                pruned =
                    Steps.prune config (Tuple.first (Steps.inline config artifacts.monoGraph))

                optimized =
                    artifacts.optimizedMonoGraph
            in
            expectAll
                (closedIssues "pruned graph" pruned
                    ++ unreachableIssues pruned
                    ++ registryIssues pruned
                    ++ closedIssues "optimized graph" optimized
                )
                (Integrity.localVarScopingChecks pruned ++ Integrity.localVarScopingChecks optimized)


{-| Passes when there are no messages and every scoping check passes; otherwise
fails with the first twenty messages, or with the first failing scoping check.
-}
expectAll : List String -> List (() -> Expectation) -> Expectation
expectAll issues scopingChecks =
    case issues of
        [] ->
            case scopingChecks of
                -- `Expect.all` fails when it is given no checks.
                [] ->
                    Expect.pass

                _ ->
                    Expect.all scopingChecks ()

        _ ->
            Expect.fail (String.join "\n" (List.take 20 issues))


{-| Returns, for each live spec, the SpecIds its body names with `MonoVarGlobal`
at any depth, and `Nothing` for an empty slot.
-}
references : Mono.MonoGraph -> Array (Maybe (List Int))
references (Mono.MonoGraph g) =
    Array.map (Maybe.map nodeRefs) g.nodes


{-| Returns the SpecIds a node's body names with `MonoVarGlobal`; a node with
no body names none.
-}
nodeRefs : Mono.MonoNode -> List Int
nodeRefs node =
    let
        refsIn body =
            MonoTraverse.foldExpr
                (\e acc ->
                    case e of
                        Mono.MonoVarGlobal _ specId _ ->
                            specId :: acc

                        _ ->
                            acc
                )
                []
                body
    in
    case node of
        Mono.MonoDefine body _ ->
            refsIn body

        Mono.MonoTailFunc _ body _ ->
            refsIn body

        Mono.MonoPortIncoming body _ ->
            refsIn body

        Mono.MonoPortOutgoing body _ ->
            refsIn body

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Returns whether the spec numbered `specId` is live.
-}
isLive : Mono.MonoGraph -> Int -> Bool
isLive (Mono.MonoGraph g) specId =
    case Array.get specId g.nodes of
        Just (Just _) ->
            True

        _ ->
            False


{-| Returns a message, prefixed with `label`, for each pair of a live spec and a
SpecId its body names that is not live.
-}
closedIssues : String -> Mono.MonoGraph -> List String
closedIssues label graph =
    Array.foldl
        (\entry ( specId, acc ) ->
            case entry of
                Just targets ->
                    ( specId + 1
                    , List.foldl
                        (\t a ->
                            if isLive graph t then
                                a

                            else
                                ("MONO_011 violation, "
                                    ++ label
                                    ++ ": spec "
                                    ++ String.fromInt specId
                                    ++ " names spec "
                                    ++ String.fromInt t
                                    ++ ", which has no node"
                                )
                                    :: a
                        )
                        acc
                        targets
                    )

                Nothing ->
                    ( specId + 1, acc )
        )
        ( 0, [] )
        (references graph)
        |> Tuple.second
        |> List.reverse


{-| Returns a message for each live spec that is not reachable from the roots
over the references of live bodies. Returns none for a graph with no `main`.
-}
unreachableIssues : Mono.MonoGraph -> List String
unreachableIssues ((Mono.MonoGraph g) as graph) =
    case g.main of
        Nothing ->
            []

        Just (Mono.StaticMain mainSpecId) ->
            let
                roots =
                    mainSpecId
                        :: List.filterMap .decoderSpecId g.ports
                        ++ (Maybe.map List.singleton g.flagsDecoder |> Maybe.withDefault [])

                reached =
                    reach (references graph) roots Set.empty
            in
            Array.foldl
                (\entry ( specId, acc ) ->
                    case entry of
                        Just _ ->
                            ( specId + 1
                            , if Set.member specId reached then
                                acc

                              else
                                ("MONO_011 violation, pruned graph: spec "
                                    ++ String.fromInt specId
                                    ++ " is live but unreachable from the roots"
                                )
                                    :: acc
                            )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                g.nodes
                |> Tuple.second
                |> List.reverse


{-| Returns `seen` with every SpecId reachable from `pending` over `refs` added.
-}
reach : Array (Maybe (List Int)) -> List Int -> Set Int -> Set Int
reach refs pending seen =
    case pending of
        [] ->
            seen

        s :: rest ->
            if Set.member s seen then
                reach refs rest seen

            else
                reach refs
                    (Maybe.withDefault [] (Maybe.andThen identity (Array.get s refs)) ++ rest)
                    (Set.insert s seen)


{-| Returns a message for each SpecId whose `reverseMapping` entry and node
disagree: an entry with no node, or a node with no entry.
-}
registryIssues : Mono.MonoGraph -> List String
registryIssues ((Mono.MonoGraph g) as graph) =
    let
        size =
            max (Array.length g.nodes) (Array.length g.registry.reverseMapping)
    in
    List.filterMap
        (\specId ->
            let
                registered =
                    case Array.get specId g.registry.reverseMapping of
                        Just (Just _) ->
                            True

                        _ ->
                            False

                live =
                    isLive graph specId
            in
            if registered == live then
                Nothing

            else if registered then
                Just ("MONO_011 violation, pruned graph: spec " ++ String.fromInt specId ++ " has a registry entry but no node")

            else
                Just ("MONO_011 violation, pruned graph: spec " ++ String.fromInt specId ++ " has a node but no registry entry")
        )
        (List.range 0 (size - 1))
