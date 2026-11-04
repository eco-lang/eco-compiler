module TestLogic.Monomorphize.LambdaSetWellFormed exposing (expectLambdaSetsWellFormed, lambdaSetIssues)

{-| Checks that every lambda-set annotation in a monomorphized program is one
the representation allows: never the empty `LSet`, and with its members, when
it lists any, in ascending order without repeats. The failure messages name
this check `LSS_001`.

A _lambda set_ is the annotation on an arrow of a `MonoType`
(`Compiler.IR.Mono.LambdaSetAnno`) naming the function values, its _members_,
that can reach that arrow. `LSet` claims its member list is complete, `LPartial`
lists some members as a lower bound, and `LTop` and `LVar` name none. LSS\_001
says that in a pruned graph `LSet []` is unrepresentable: an unconstrained slot
is read back as ⊤, never as an empty set. An empty `LSet` would claim that no
function can arrive where one does, and a later pass that trusts the claim acts
on nothing. LSS\_001 also says that `LSet` and `LPartial` member lists are
ascending-sorted without duplicates by construction; the spec key, `annoHash`
and the set operations of `Compiler.IR.Mono` rely on it, so an unsorted list
would key two equal sets apart.

The check compiles the program with `TestLogic.TestPipeline.runToGlobalOpt`
(the production pipeline: the solver engine with lambda-set specialization,
then the post-monomorphization inliner, the post-inline prune and global
optimization) and inspects two graphs: `monoGraph`, the graph the solver engine
produced, and `optimizedMonoGraph`, the graph after the later passes. In each it
reads every annotation, at any depth (inside function parameters and results,
list elements, tuple elements, record fields and custom-type arguments), in:

  - the stored demand type of every live registry entry (`reverseMapping`);
  - the type of every live node;
  - the type of every expression in a node's body, closures' parameter types
    and tail-recursive definitions' parameter types included
    (`Compiler.IR.Mono.Traverse.foldExpr` reaches the nested ones).

The P tests `Compiler.Monomorphize.Solver.LssPapMembersTest` and
`Compiler.Monomorphize.Solver.LssHonestSourcesPipelineTest` made the empty-set
half of this check on the registry types of their own fixtures; this module
makes it on every program it is given.

`lambdaSetIssues` makes the same check on a graph a test has already built, so a
P test that monomorphizes its fixture under its own configuration can apply it
there.

Among what is not checked: types held only in a `CallInfo` or a capture ABI;
that an `LVar` number is canonical (LSS\_001's walk-order numbering); and that a
set's members are the right ones (LSS\_002, `TestLogic.Monomorphize.LambdaSetIntegrity`,
checks one direction of that).

-}

import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Compiles `srcModule` with `runToGlobalOpt` and passes when no annotation in
either graph is an empty `LSet` or a member list that is not strictly
ascending. It fails with the pipeline's message when compilation fails, and
otherwise with one line per offending place, naming the graph, the place and
the annotation.
-}
expectLambdaSetsWellFormed : Src.Module -> Expectation
expectLambdaSetsWellFormed srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                issues =
                    graphIssues "solver graph" artifacts.monoGraph
                        ++ graphIssues "optimized graph" artifacts.optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" (List.take 20 issues))


{-| Returns a message for every ill-formed annotation in `graph`, as
`expectLambdaSetsWellFormed` looks for them, each prefixed with `label`. An
empty list means the graph passes.
-}
lambdaSetIssues : String -> Mono.MonoGraph -> List String
lambdaSetIssues =
    graphIssues


{-| Returns a message for every ill-formed annotation in the graph, each
prefixed with `label` and the place it was found: a registry entry or a node,
by SpecId. Removed registry entries and nodes are skipped.
-}
graphIssues : String -> Mono.MonoGraph -> List String
graphIssues label (Mono.MonoGraph g) =
    let
        registryIssues =
            Array.foldl
                (\entry ( specId, acc ) ->
                    case entry of
                        Just ( _, monoType ) ->
                            ( specId + 1
                            , typeIssues (label ++ ", registry type of spec " ++ String.fromInt specId) monoType ++ acc
                            )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                g.registry.reverseMapping
                |> Tuple.second

        nodeIssues =
            Array.foldl
                (\entry ( specId, acc ) ->
                    case entry of
                        Just node ->
                            ( specId + 1
                            , List.concatMap
                                (typeIssues (label ++ ", node " ++ String.fromInt specId))
                                (nodeTypes node)
                                ++ acc
                            )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                g.nodes
                |> Tuple.second
    in
    List.reverse registryIssues ++ List.reverse nodeIssues


{-| Returns the types a node carries: its own type, the parameter types of a
tail function, and the type of every expression in its body together with the
parameter types of the closures and tail-recursive local definitions there.
-}
nodeTypes : Mono.MonoNode -> List Mono.MonoType
nodeTypes node =
    let
        bodyTypes body =
            MonoTraverse.foldExpr (\e acc -> exprTypes e ++ acc) [] body
    in
    case node of
        Mono.MonoDefine body t ->
            t :: bodyTypes body

        Mono.MonoTailFunc params body t ->
            t :: List.map Tuple.second params ++ bodyTypes body

        Mono.MonoPortIncoming body t ->
            t :: bodyTypes body

        Mono.MonoPortOutgoing body t ->
            t :: bodyTypes body

        Mono.MonoCtor _ t ->
            [ t ]

        Mono.MonoEnum _ t ->
            [ t ]

        Mono.MonoExtern t ->
            [ t ]

        Mono.MonoManagerLeaf _ t ->
            [ t ]


{-| Returns the type of one expression, plus the parameter types of a closure
and of a tail-recursive local definition. Sub-expressions are reached by the
caller's fold, not here.
-}
exprTypes : Mono.MonoExpr -> List Mono.MonoType
exprTypes expr =
    let
        own =
            Mono.typeOf expr
    in
    case expr of
        Mono.MonoClosure info _ _ ->
            own :: List.map Tuple.second info.params

        Mono.MonoLet (Mono.MonoTailDef _ params _) _ _ ->
            own :: List.map Tuple.second params

        _ ->
            [ own ]


{-| Returns one message, prefixed with `context`, for each ill-formed
annotation in `t` at any depth.
-}
typeIssues : String -> Mono.MonoType -> List String
typeIssues context t =
    List.filterMap
        (\anno ->
            annoProblem anno
                |> Maybe.map (\problem -> "LSS_001 violation, " ++ context ++ ": " ++ problem)
        )
        (annosOf t)


{-| Returns what is wrong with one annotation, or `Nothing` when it is well
formed: an `LSet` must have a member, and the member list of an `LSet` or an
`LPartial` must be strictly ascending.
-}
annoProblem : Mono.LambdaSetAnno -> Maybe String
annoProblem anno =
    case anno of
        Mono.LSet [] ->
            Just "an empty LSet"

        Mono.LSet ms ->
            if strictlyAscending ms then
                Nothing

            else
                Just ("LSet members not strictly ascending: " ++ showMembers ms)

        Mono.LPartial ms ->
            if strictlyAscending ms then
                Nothing

            else
                Just ("LPartial members not strictly ascending: " ++ showMembers ms)

        Mono.LTop _ ->
            Nothing

        Mono.LVar _ ->
            Nothing


{-| Tells whether each member is less than the next, so the list is sorted and
has no repeats.
-}
strictlyAscending : List Int -> Bool
strictlyAscending ms =
    case ms of
        a :: ((b :: _) as rest) ->
            a < b && strictlyAscending rest

        _ ->
            True


{-| Renders a member list for a failure message.
-}
showMembers : List Int -> String
showMembers ms =
    "[" ++ String.join "," (List.map String.fromInt ms) ++ "]"


{-| Returns every lambda-set annotation in `t`, looking inside functions,
lists, tuples, records and custom-type arguments.
-}
annosOf : Mono.MonoType -> List Mono.LambdaSetAnno
annosOf t =
    case t of
        Mono.MFunction _ anno args ret ->
            anno :: (List.concatMap annosOf args ++ annosOf ret)

        Mono.MList _ el ->
            annosOf el

        Mono.MTuple _ els ->
            List.concatMap annosOf els

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> annosOf ft ++ acc) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap annosOf args

        _ ->
            []
