module SourceIR.DebugKernelCases exposing (expectSuite)

{-| Programs that call the `Debug` kernels, `log`, `toString` and `todo`, at
concrete types, from a polymorphic function, in a `case` branch, and from a
function whose parameter is a `number`, so that monomorphization must keep the
kernels' type variables as `CEcoValue` variables (MONO\_009). They come from
the former unit test `Compiler.Monomorphize.DebugPolymorphismTest`, whose check
now runs over the whole catalogue as
`TestLogic.Monomorphize.DebugPolymorphismTest`; that unit test now only pins
that each program here has a `Debug` kernel reference in its monomorphized
graph.

This module asserts nothing itself. `expectSuite` hands each program to the
caller's expectation, which decides what the program is run through and what
counts as passing.

Each program refers to the kernels as `Elm.Kernel.Debug.log`,
`Elm.Kernel.Debug.toString` and `Elm.Kernel.Debug.todo`, as
`SourceIR.KernelIntrinsicCases` does, since the test interfaces have no
`Debug` module. Each defines a top-level `testValue`. A kernel reference has
one type per module, the type of its first use, so each program uses each
kernel at one type. The cases, by label:

  - "log at Int": `testValue = Debug.log "tag" 42`.
  - "toString at Float": `testValue = Debug.toString 1.5`.
  - "toString on a tuple holding a record":
    `testValue = Debug.toString ( 1, { x = 2.5 } )`.
  - "todo in a case branch": `pick k` returns `10` for `0`, `20` for `1` and
    `Debug.todo "bad k"` otherwise, so the reference may be held inline in the
    decision tree; `testValue = pick 1`.
  - "toString in a polymorphic function": `show x = Debug.toString x` used at
    `Int` and at `String`; both specializations of `show` keep the kernel's
    variable.
  - "log in a number function at Float": `bump n = Debug.log "n" (n + 1)` with
    no annotation, so `n` is a `number`, used as `bump 5.5`. The reference's
    variables must get fresh ids (`Specialize.freshenDebugAbi`): kept at the
    `number` variable's id, `Compiler.Monomorphize.Prune` closed it to `Int`
    although the specialization passes a `Float`, which also gave a
    `Debug.toString` passed as a function value a kernel declaration taking
    `i64` while the closure received `Float`s.

The first three are built with `Compiler.AST.SourceBuilder.makeKernelModule`,
the others with `makeModuleWithDefs`.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Debug kernel programs " followed by `condStr`, that
passes `expectFn` each program in order through `Compiler.BulkCheck.bulkCheck`,
so the first failing program ends the test and is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Debug kernel programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul }) programs


{-| `Elm.Kernel.Debug.<name>` as an expression.
-}
debugKernel : String -> Src.Expr
debugKernel name =
    SB.qualVarExpr "Elm.Kernel.Debug" name


{-| The programs, by label.
-}
programs : List ( String, Src.Module )
programs =
    [ ( "log at Int"
      , SB.makeKernelModule "testValue"
            (SB.callExpr (debugKernel "log") [ SB.strExpr "tag", SB.intExpr 42 ])
      )
    , ( "toString at Float"
      , SB.makeKernelModule "testValue"
            (SB.callExpr (debugKernel "toString") [ SB.floatExpr 1.5 ])
      )
    , ( "toString on a tuple holding a record"
      , SB.makeKernelModule "testValue"
            (SB.callExpr (debugKernel "toString")
                [ SB.tupleExpr (SB.intExpr 1) (SB.recordExpr [ ( "x", SB.floatExpr 2.5 ) ]) ]
            )
      )
    , ( "todo in a case branch"
      , SB.makeModuleWithDefs "Test"
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
    , ( "toString in a polymorphic function"
      , SB.makeModuleWithDefs "Test"
            [ ( "show", [ SB.pVar "x" ], SB.callExpr (debugKernel "toString") [ SB.varExpr "x" ] )
            , ( "testValue"
              , []
              , SB.tupleExpr
                    (SB.callExpr (SB.varExpr "show") [ SB.intExpr 1 ])
                    (SB.callExpr (SB.varExpr "show") [ SB.strExpr "s" ])
              )
            ]
      )
    , ( "log in a number function at Float"
      , SB.makeModuleWithDefs "Test"
            [ ( "bump"
              , [ SB.pVar "n" ]
              , SB.callExpr (debugKernel "log")
                    [ SB.strExpr "n", SB.binopsExpr [ ( SB.varExpr "n", "+" ) ] (SB.intExpr 1) ]
              )
            , ( "testValue", [], SB.callExpr (SB.varExpr "bump") [ SB.floatExpr 5.5 ] )
            ]
      )
    ]
