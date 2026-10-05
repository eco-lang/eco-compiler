module TestLogic.Generate.DebugPolymorphismTest exposing (suite)

{-| A `Debug` kernel function such as `Debug.log` accepts a value of any type,
and MONO\_009 says its references keep the kernel's type variables as
`CEcoValue` variables, whatever types it is used at.
`TestLogic.Generate.DebugPolymorphism.expectDebugPolymorphismResolved` checks
that every direct call of a `Debug` kernel agrees with the reference's type: a
parameter agrees with the type passed, a kept variable agreeing with anything.
These tests run it on small programs that call the `Debug` kernels at concrete
and at `number` types.

Each program refers to the kernels as `Elm.Kernel.Debug.log`,
`Elm.Kernel.Debug.toString` and `Elm.Kernel.Debug.todo`, as
`SourceIR.KernelIntrinsicCases` does, since the test interfaces have no
`Debug` module. Each defines a top-level `testValue`, the value the test
pipeline builds the program around. Every test first makes sure the graph
holds a `Debug` kernel reference, so that none passes vacuously.

The tests establish:

  - "log at Int": `Debug.log "tag" 42`.
  - "toString at Float": `Debug.toString 1.5`.
  - "toString on a tuple holding a record": `Debug.toString ( 1, { x = 2.5 } )`.
    (A kernel reference has one type per module, the type of its first use,
    so each program uses each kernel at one type.)
  - "toString in a polymorphic function": `show x = Debug.toString x` used at
    `Int` and at `String`; both specializations of `show` keep the kernel's
    variable.
  - "todo in a case branch": `Debug.todo` in a `case` branch, so the reference
    may be held inline in the decision tree.
  - "log in a number function at Float": `bump n = Debug.log "n" (n + 1)` with
    no annotation, so `n` is a `number`, used as `bump 5.5`. The reference's
    variables must get fresh ids (`Specialize.freshenDebugAbi`): kept at the
    `number` variable's id, `Compiler.Monomorphize.Prune` closed it to `Int`
    although the specialization passes a `Float` (MONO\_009), which also gave a
    `Debug.toString` passed as a function value a kernel declaration taking
    `i64` while the closure received `Float`s.

Among what is not tested: the values the `Debug` functions print or return,
since nothing is run.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect
import Test exposing (Test)
import TestLogic.Generate.DebugPolymorphism exposing (expectDebugPolymorphismResolved)
import TestLogic.TestPipeline as Pipeline


{-| The tests of this module, the six in `debugTests`.
-}
suite : Test
suite =
    Test.describe "Debug kernel functions handle polymorphism (MONO_009)"
        [ debugTests
        ]


{-| `Elm.Kernel.Debug.<name>` as an expression.
-}
debugKernel : String -> Src.Expr
debugKernel name =
    SB.qualVarExpr "Elm.Kernel.Debug" name


{-| The six tests the module docstring lists.
-}
debugTests : Test
debugTests =
    Test.describe "Debug polymorphism resolution"
        [ Test.test "log at Int" <|
            \_ ->
                expectWithDebug
                    (SB.makeKernelModule "testValue"
                        (SB.callExpr (debugKernel "log") [ SB.strExpr "tag", SB.intExpr 42 ])
                    )
        , Test.test "toString at Float" <|
            \_ ->
                expectWithDebug
                    (SB.makeKernelModule "testValue"
                        (SB.callExpr (debugKernel "toString") [ SB.floatExpr 1.5 ])
                    )
        , Test.test "toString on a tuple holding a record" <|
            \_ ->
                expectWithDebug
                    (SB.makeKernelModule "testValue"
                        (SB.callExpr (debugKernel "toString")
                            [ SB.tupleExpr (SB.intExpr 1) (SB.recordExpr [ ( "x", SB.floatExpr 2.5 ) ]) ]
                        )
                    )
        , Test.test "todo in a case branch" <|
            \_ ->
                expectWithDebug
                    (SB.makeModuleWithDefs "CaseDebug"
                        [ ( "pick"
                          , [ SB.pVar "k" ]
                          , SB.caseExpr (SB.varExpr "k")
                                [ ( SB.pInt 0, SB.intExpr 10 )
                                , ( SB.pInt 1, SB.intExpr 20 )
                                , ( SB.pAnything, SB.callExpr (debugKernel "todo") [ SB.strExpr "bad k" ] )
                                ]
                          )
                        , ( "testValue", [], SB.callExpr (SB.varExpr "pick") [ SB.intExpr 1 ] )
                        ]
                    )
        , Test.test "toString in a polymorphic function" <|
            \_ ->
                expectWithDebug
                    (SB.makeModuleWithDefs "PolyDebug"
                        [ ( "show", [ SB.pVar "x" ], SB.callExpr (debugKernel "toString") [ SB.varExpr "x" ] )
                        , ( "testValue"
                          , []
                          , SB.tupleExpr
                                (SB.callExpr (SB.varExpr "show") [ SB.intExpr 1 ])
                                (SB.callExpr (SB.varExpr "show") [ SB.strExpr "s" ])
                          )
                        ]
                    )
        , Test.test "log in a number function at Float" <|
            \_ ->
                expectWithDebug
                    (SB.makeModuleWithDefs "NumDebug"
                        [ ( "bump"
                          , [ SB.pVar "n" ]
                          , SB.callExpr (debugKernel "log")
                                [ SB.strExpr "n", SB.binopsExpr [ ( SB.varExpr "n", "+" ) ] (SB.intExpr 1) ]
                          )
                        , ( "testValue", [], SB.callExpr (SB.varExpr "bump") [ SB.floatExpr 5.5 ] )
                        ]
                    )
        ]


{-| Fails unless the monomorphized graph of `modul` holds a `Debug` kernel
reference, and otherwise applies `expectDebugPolymorphismResolved`.
-}
expectWithDebug : Src.Module -> Expect.Expectation
expectWithDebug modul =
    case Pipeline.runToMono modul of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            if hasDebugKernelRef monoGraph then
                expectDebugPolymorphismResolved modul

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


isDebugRef : Mono.MonoExpr -> Bool -> Bool
isDebugRef expr found =
    case expr of
        Mono.MonoVarKernel _ _ "Debug" _ _ ->
            True

        _ ->
            found
