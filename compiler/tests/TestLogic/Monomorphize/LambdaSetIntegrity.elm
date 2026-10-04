module TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity, expectLambdaSetIntegrityArrowId)

{-| Checks that no closure in a monomorphized program is missing from the
lambda set its own type claims for it.

A _lambda set_ is the annotation on the arrow of a function type that names
the function values, its _members_, that can flow through that arrow
(`Compiler.AST.Monomorphized` defines the annotations). An `LSet` claims that
its member list is complete, and later passes act on that claim: a call
through a set with one member can be stamped for a direct call to that member.
A closure whose own member id is missing from the `LSet` on its type is a
_lost member_, and such a pass treats calls to it as calls to something else.
The failure messages name this check `LSS_002`.

The check compiles the test program it is given with
`TestLogic.TestPipeline.runToGlobalOptLssOn`: the solver engine with
lambda-set specialization on, then the post-monomorphization inliner and
global optimization. It inspects `optimizedMonoGraph`, the graph those last
two passes produce.

In every node of that graph it visits every closure (`MonoClosure`), including
closures nested in other closures' bodies and captures, in let definitions and
in case branches. A closure whose `srcLambda` is `Nothing` is skipped.
Otherwise its _member id_ is its `lssMember`, the id the solver engine
registered this instance under, or, when that is `Nothing`, its raw
`srcLambda` id. The annotation checked is the _head annotation_ of the
closure's own type, the one on its outermost arrow (`Mono.headAnno`). An
`LSet` passes only if it contains the member id. `LTop` (widened: the members
are not all known), `LVar` (not yet determined) and `LPartial` (at least these
members) make no claim that the set is complete, so they always pass.

Among what is not checked:

  - closures whose `srcLambda` is `Nothing`, which include closures the
    inliner builds for a partial inline;
  - whether an `LSet` holds a member that cannot actually flow there;
  - annotations on arrows other than the head of a closure's own type, and on
    function values that are not closures, such as references to globals;
  - the graph as it was before the inliner and global optimization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Compiles a test program with `runToGlobalOptLssOn` and passes when no
closure in the optimized graph is a lost member of its head annotation. It
fails with the pipeline's message when compilation fails, and otherwise with
one line per lost member.
-}
expectLambdaSetIntegrity : Src.Module -> Expect.Expectation
expectLambdaSetIntegrity =
    integrityWith Pipeline.runToGlobalOptLssOn


{-| Does what `expectLambdaSetIntegrity` does, through
`runToGlobalOptLssArrowIdOn`. `TestLogic.TestPipeline` binds that name to the
same function as `runToGlobalOptLssOn`, so the two checks compile and inspect
the program identically.
-}
expectLambdaSetIntegrityArrowId : Src.Module -> Expect.Expectation
expectLambdaSetIntegrityArrowId =
    integrityWith Pipeline.runToGlobalOptLssArrowIdOn


{-| Runs `runner` on `srcModule` and passes when its `optimizedMonoGraph` has
no lost members. It fails with the runner's message when the runner fails, and
otherwise with the violation messages joined one per line.
-}
integrityWith : (Src.Module -> Result String Pipeline.GlobalOptArtifacts) -> Src.Module -> Expect.Expectation
integrityWith runner srcModule =
    case runner srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectViolations optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| Returns a message for each lost member in the graph's nodes. A node is
numbered by its index in `nodes`, which is its SpecId, and a removed node
(`Nothing`) is skipped.
-}
collectViolations : Mono.MonoGraph -> List String
collectViolations (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1
                    , List.foldl (checkExprTree specId) acc (nodeExprs node)
                    )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the expressions a node holds: its body for a definition, a tail
function or a port, and none for a constructor, an enum, an extern or a
manager leaf.
-}
nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Adds to `acc` a message for each lost member among the closures anywhere
in `root`, reported against `specId`.
-}
checkExprTree : Int -> Mono.MonoExpr -> List String -> List String
checkExprTree specId root acc =
    MonoTraverse.foldExpr (checkOne specId) acc root


{-| Adds to `acc` a message when `expr` is a closure with a `srcLambda` whose
member id is missing from the `LSet` at the head of its own type. Any other
expression or annotation leaves `acc` unchanged.

The message labels the member id `srcLambda` even when it is the closure's
`lssMember`.

-}
checkOne : Int -> Mono.MonoExpr -> List String -> List String
checkOne specId expr acc =
    case expr of
        Mono.MonoClosure info _ closType ->
            case info.srcLambda of
                Nothing ->
                    acc

                Just m ->
                    let
                        mid =
                            case info.lssMember of
                                Just q ->
                                    q

                                Nothing ->
                                    Id.toComparable m
                    in
                    case Mono.headAnno closType of
                        Mono.LTop _ ->
                            acc

                        Mono.LVar _ ->
                            acc

                        Mono.LPartial _ ->
                            acc

                        Mono.LSet members ->
                            if List.member mid members then
                                acc

                            else
                                ("LSS_002 violation in spec "
                                    ++ String.fromInt specId
                                    ++ ": closure with srcLambda #"
                                    ++ String.fromInt mid
                                    ++ " has head annotation LSet ["
                                    ++ String.join "," (List.map String.fromInt members)
                                    ++ "] which does not contain it"
                                )
                                    :: acc

        _ ->
            acc
