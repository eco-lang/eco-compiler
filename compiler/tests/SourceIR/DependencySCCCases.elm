module SourceIR.DependencySCCCases exposing
    ( chain
    , expectSuite
    , fnDep
    , independent
    , mutualRec
    , reversed
    , selfRec
    )

{-| Programs whose top-level definitions depend on each other in the basic
shapes the canonicalizer must group into strongly connected components
(CANON\_005): independent values, a chain, a chain written in reverse source
order, a function and its user, a self-recursive function, and two mutually
recursive functions with a user. They come from the former inline programs of
`Compiler.Canonicalize.DependencySCCTest`, whose generic check now runs over
the whole catalogue as `TestLogic.Canonicalize.DependencySCCTest`; that unit
test keeps the grouping expected for each program, and so imports the
programs by name.

`expectSuite` asserts nothing itself: it hands each program to the caller's
expectation, which decides what the program is run through and what counts as
passing.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithDefs` (no annotations), that ends
with a `testValue` from which its other definitions are reachable. Compared
with the unit test's first programs, `testValue` is new in each, and the two
recursive programs got a base case so that their functions return an `Int`
rather than a value of an unconstrained type. In `mutualRec` the base case is
`modBy 2 x`, which fixes the type of `ping` and `pong` to `Int -> Int`: with a
type variable in it, the annotation type checking gives `pong` would not
quantify that variable, a bug that `TestLogic.Type.CachedTypeInfoTest` pins
with an expected failure. The programs:

  - `independent`: `a = 1`, `b = 2`, `c = 3`, `testValue = ( a, b, c )`.
  - `chain`: `a = 1`, `b = a`, `c = b`, `testValue = c`.
  - `reversed`: `c = b`, `b = a`, `a = 1`, `testValue = c`, so the
    canonicalizer must reorder the source.
  - `fnDep`: `helper x = x`, `result = helper 42`, `testValue = result`.
  - `selfRec`: `loop x = if x <= 0 then 0 else loop (x - 1)`,
    `testValue = loop 3`, a recursive group of one.
  - `mutualRec`: `user = ping 1`,
    `ping x = if x <= 0 then modBy 2 x else pong (x - 1)`,
    `pong x = ping (x - 1)` and `testValue = user`, a recursive group of two
    followed by its user.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Dependency SCC programs " followed by `condStr`,
that passes `expectFn` each program in the order listed above through
`Compiler.BulkCheck.bulkCheck`, so the first failing program ends the test and
is the one reported.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Dependency SCC programs " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns one case per program, each running `expectFn` on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "independent definitions", independent )
        , ( "linear dependency chain", chain )
        , ( "dependency written after its use", reversed )
        , ( "simple function dependency", fnDep )
        , ( "self-recursive function", selfRec )
        , ( "mutually recursive functions", mutualRec )
        ]


{-| `a = 1`, `b = 2`, `c = 3` and `testValue = ( a, b, c )`.
-}
independent : Src.Module
independent =
    SB.makeModuleWithDefs "Test"
        [ ( "a", [], SB.intExpr 1 )
        , ( "b", [], SB.intExpr 2 )
        , ( "c", [], SB.intExpr 3 )
        , ( "testValue", [], SB.tuple3Expr (SB.varExpr "a") (SB.varExpr "b") (SB.varExpr "c") )
        ]


{-| `a = 1`, `b = a`, `c = b` and `testValue = c`.
-}
chain : Src.Module
chain =
    SB.makeModuleWithDefs "Test"
        [ ( "a", [], SB.intExpr 1 )
        , ( "b", [], SB.varExpr "a" )
        , ( "c", [], SB.varExpr "b" )
        , ( "testValue", [], SB.varExpr "c" )
        ]


{-| `c = b`, `b = a`, `a = 1` and `testValue = c`, each definition written
before the one it depends on.
-}
reversed : Src.Module
reversed =
    SB.makeModuleWithDefs "Test"
        [ ( "c", [], SB.varExpr "b" )
        , ( "b", [], SB.varExpr "a" )
        , ( "a", [], SB.intExpr 1 )
        , ( "testValue", [], SB.varExpr "c" )
        ]


{-| `helper x = x`, `result = helper 42` and `testValue = result`.
-}
fnDep : Src.Module
fnDep =
    SB.makeModuleWithDefs "Test"
        [ ( "helper", [ SB.pVar "x" ], SB.varExpr "x" )
        , ( "result", [], SB.callExpr (SB.varExpr "helper") [ SB.intExpr 42 ] )
        , ( "testValue", [], SB.varExpr "result" )
        ]


{-| `loop x = if x <= 0 then 0 else loop (x - 1)` and `testValue = loop 3`.
-}
selfRec : Src.Module
selfRec =
    SB.makeModuleWithDefs "Test"
        [ ( "loop", [ SB.pVar "x" ], countDown "loop" )
        , ( "testValue", [], SB.callExpr (SB.varExpr "loop") [ SB.intExpr 3 ] )
        ]


{-| `user = ping 1`, `ping x = if x <= 0 then modBy 2 x else pong (x - 1)`,
`pong x = ping (x - 1)` and `testValue = user`.
-}
mutualRec : Src.Module
mutualRec =
    SB.makeModuleWithDefs "Test"
        [ ( "user", [], SB.callExpr (SB.varExpr "ping") [ SB.intExpr 1 ] )
        , ( "ping"
          , [ SB.pVar "x" ]
          , SB.ifExpr (SB.binopsExpr [ ( SB.varExpr "x", "<=" ) ] (SB.intExpr 0))
                (SB.callExpr (SB.varExpr "modBy") [ SB.intExpr 2, SB.varExpr "x" ])
                (SB.callExpr (SB.varExpr "pong") [ xMinusOne ])
          )
        , ( "pong", [ SB.pVar "x" ], SB.callExpr (SB.varExpr "ping") [ xMinusOne ] )
        , ( "testValue", [], SB.varExpr "user" )
        ]


{-| `if x <= 0 then 0 else next (x - 1)`.
-}
countDown : String -> Src.Expr
countDown next =
    SB.ifExpr (SB.binopsExpr [ ( SB.varExpr "x", "<=" ) ] (SB.intExpr 0))
        (SB.intExpr 0)
        (SB.callExpr (SB.varExpr next) [ xMinusOne ])


{-| `x - 1`.
-}
xMinusOne : Src.Expr
xMinusOne =
    SB.binopsExpr [ ( SB.varExpr "x", "-" ) ] (SB.intExpr 1)
