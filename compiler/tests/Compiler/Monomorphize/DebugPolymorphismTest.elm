module Compiler.Monomorphize.DebugPolymorphismTest exposing (suite)

{-| Pins that each program of `SourceIR.DebugKernelCases` holds a `Debug`
kernel reference in its monomorphized graph, so that the MONO\_009 check those
programs were written for has a reference to look at in each.

The check itself, that every direct call of a `Debug` kernel agrees with the
reference's type, runs over the whole standard catalogue, these programs
included, as `TestLogic.Monomorphize.DebugPolymorphismTest`. Here each program
is monomorphized with `TestLogic.TestPipeline.runToMono`; the test fails with
the pipeline's message if that fails, and if no node body of the graph refers
to a `Debug` kernel.

-}

import Array
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Expect
import SourceIR.DebugKernelCases as DebugKernelCases
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The one test: `expectDebugKernelRef` over the programs of
`SourceIR.DebugKernelCases`.
-}
suite : Test
suite =
    Test.describe "Debug kernel programs hold a Debug reference (MONO_009 pins)"
        [ DebugKernelCases.expectSuite expectDebugKernelRef "have a Debug kernel reference"
        ]


{-| Fails unless the monomorphized graph of `modul` holds a `Debug` kernel
reference.
-}
expectDebugKernelRef : Src.Module -> Expect.Expectation
expectDebugKernelRef modul =
    case Pipeline.runToMono modul of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            if hasDebugKernelRef monoGraph then
                Expect.pass

            else
                Expect.fail "fixture has no Debug kernel reference in its monomorphized graph"


{-| Returns whether some node body of the graph refers to a `Debug` kernel.
-}
hasDebugKernelRef : Mono.MonoGraph -> Bool
hasDebugKernelRef (Mono.MonoGraph data) =
    Array.toList data.nodes
        |> List.any
            (\maybeNode ->
                case maybeNode of
                    Just (Mono.MonoDefine body _) ->
                        MonoTraverse.foldExpr isDebugRef False body

                    Just (Mono.MonoTailFunc _ body _) ->
                        MonoTraverse.foldExpr isDebugRef False body

                    _ ->
                        False
            )


{-| Returns `True` for a `Debug` kernel reference, and `found` otherwise.
-}
isDebugRef : Mono.MonoExpr -> Bool -> Bool
isDebugRef expr found =
    case expr of
        Mono.MonoVarKernel _ _ "Debug" _ _ ->
            True

        _ ->
            found
