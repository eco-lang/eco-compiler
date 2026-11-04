module TestLogic.MonoOpt.FingerprintCoverageTest exposing (suite)

{-| Checks `Compiler.MonoOpt.AbiCloning.instanceFingerprint` on every closure
of every program in the standard catalogue after global optimization, so that
the fingerprint is rendered for the closure bodies and call stamps real
programs produce.

ABI cloning compares fingerprints only when one member has two instances with
different lambda ids in one layout group, a copy the post-monomorphization
inliner rarely leaves, so without this test most of the renderer would run on
no input at all. Taking the closures after global optimization means their
calls carry the stamps ABI cloning gives them (closure kinds, capture ABIs,
fast evaluators), which the fingerprint renders.

For each program, `TestLogic.TestPipeline.runToGlobalOpt` must succeed, and
for each closure found anywhere in the optimized graph's nodes, the
fingerprint of the closure must equal the fingerprint of the same closure with
its own lambda id moved to another home module, the uid kept. The fingerprint
leaves out the home module of lambda ids, and keeps the uid only to number
the ids in order of first appearance, so references to the closure from inside
its own body (a self-recursive call's stamp) still match. Replacing the uid
alone would not keep the fingerprint: such a reference would then name an id
the closure no longer has. The programs are those `SourceIR.Suite.StandardTestSuites.expectSuite`
supplies.

Among what is not tested: that closures with different code render
differently, and copies whose ids differ in uid, which would need the
references to them renumbered as well.

-}

import Array
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Compiler.MonoOpt.AbiCloning as AbiCloning
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The catalogue, under a label that contains "coverage run" so that the
coverage loop's quick run includes it.
-}
suite : Test
suite =
    Test.describe "Closure fingerprints (coverage run)"
        [ StandardTestSuites.expectSuite expectCopyInvariant "fingerprints ignore the home of a closure's id" ]


{-| Passes when `srcModule` goes through global optimization and every
closure's fingerprint is unchanged by a fresh lambda id; otherwise fails
naming the first closure whose fingerprints differ.
-}
expectCopyInvariant : Src.Module -> Expectation
expectCopyInvariant srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err message ->
            Expect.fail message

        Ok artifacts ->
            let
                (Mono.MonoGraph graph) =
                    artifacts.optimizedMonoGraph

                closures =
                    Array.foldl
                        (\maybeNode acc ->
                            case maybeNode of
                                Just node ->
                                    List.foldl (\e a -> MonoTraverse.foldExprAccFirst collect a e) acc (nodeExprs node)

                                Nothing ->
                                    acc
                        )
                        []
                        graph.nodes

                mismatches =
                    List.filter
                        (\( info, body ) ->
                            AbiCloning.instanceFingerprint info body
                                /= AbiCloning.instanceFingerprint { info | lambdaId = freshId info.lambdaId } body
                        )
                        closures
            in
            case mismatches of
                [] ->
                    Expect.pass

                ( info, body ) :: _ ->
                    Expect.fail ("fingerprint depends on the home of the closure's id: " ++ AbiCloning.instanceFingerprint info body)


{-| Adds `expr` to the list when it is a closure.
-}
collect : List ( Mono.ClosureInfo, Mono.MonoExpr ) -> Mono.MonoExpr -> List ( Mono.ClosureInfo, Mono.MonoExpr )
collect acc expr =
    case expr of
        Mono.MonoClosure info body _ ->
            ( info, body ) :: acc

        _ ->
            acc


{-| The expressions a node holds.
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

        _ ->
            []


{-| The same lambda id in another home module.
-}
freshId : Mono.LambdaId -> Mono.LambdaId
freshId (Mono.AnonymousLambda _ uid) =
    Mono.AnonymousLambda (ModuleName.Canonical ( "eco", "elsewhere" ) "Elsewhere") uid
