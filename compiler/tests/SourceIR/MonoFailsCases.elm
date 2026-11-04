module SourceIR.MonoFailsCases exposing (expectBeforeMonoSuite, expectRejectedSuite, expectSuite)

{-| Programs that the build's steps after `Compiler.Compile` must reject, each
with the report it must be rejected with: the monomorphization module of the
negative catalogue (`SourceIR.Suite.RejectedSuites`).

These programs get through every phase of `Compiler.Compile`; they fail in
the steps of `Compiler.Pipeline.Steps`, which `Builder.Generate` reports as a
`GenerateMonomorphizationError`, under the title `Builder.Reporting.Exit`
chooses from the message: `STAGE ARITY LIMIT` for the closure stage arity
limit, `MONOMORPHIZATION ERROR` otherwise.

`expectBeforeMonoSuite` gives the programs, less the closure program, to the
checks of the stages before monomorphization (type checking, PostSolve,
pattern-match checking, typed optimization, the pre-mono passes), which they
all pass. `expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`, the title and a fragment of the
message; `TestLogic.Reporting.ExpectedRejectionTest` checks that these steps,
under the default configuration, and no earlier stage reject each program with
that report. `expectSuite` gives a check only the programs. Each defines
`testValue`, which the test pipeline's synthetic `main` uses.

The cases, by group:

  - "Polymorphic recursion" (`MONOMORPHIZATION ERROR`, finding F13): programs
    whose specializations would grow without end, which the solver engine
    reports as polymorphic recursion, naming the function: a mutually
    recursive pair over a non-regular type (from the former polymorphic-recursion
    test of `Compiler.Monomorphize.SpecWatchdogTest`), a function calling its
    partner twice at growing types (finding F7), and growth through a pair, a
    record, a `Maybe` and a function (from the former tests of
    `Compiler.Monomorphize.Solver.EngineSpecWatchdogTest`). The tests of the
    watchdogs under small limits stay in those unit tests, since no catalogue
    run sets limits.
  - "Closure stage limit" (`STAGE ARITY LIMIT`, HEAP\_078): a closure capturing
    700 local polymorphic functions, within the limit when canonicalization
    counts it but holding 2,100 captured specializations after
    monomorphization, from the former `Compiler.Monomorphize.ClosureLimitTest`.
    It is generated source of about 2,800 lines and takes a few seconds.
  - "Unsupported expressions" (`MONOMORPHIZATION ERROR`, finding F9): a GLSL
    shader, which the native back end does not support, from the former
    rejection test of `Compiler.PreMono.ShaderTest`.

Among what is not tested: the spec watchdogs' breadth and type-node limits,
which need a configuration of their own, and the checks that run only under
`mono.validate`.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromModule
        , fromSource
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Monomorphization failure tests " followed
by `condStr`, with one test per group of cases (see `groups`). Each test
applies `expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Monomorphization failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite` without the "Closure stage limit" group, for the checks of
the stages before monomorphization, which every program here passes: type
checking, PostSolve, pattern-match checking, typed optimization and the
pre-mono passes. The standard catalogue cannot hold these programs, since
monomorphization rejects them, so only this suite runs those stages' checks
on polymorphic recursion over non-regular types and on a shader. The closure
program is left out because it takes seconds per run and adds only width.
-}
expectBeforeMonoSuite : (Src.Module -> Expectation) -> String -> Test
expectBeforeMonoSuite expectFn condStr =
    Test.describe ("Monomorphization failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn)
            (List.filter (\( name, _ ) -> name /= "Closure stage limit") groups)
        )


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Monomorphization failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Polymorphic recursion", polymorphicRecursionCases )
    , ( "Closure stage limit", closureLimitCases )
    , ( "Unsupported expressions", unsupportedCases )
    ]



-- ============================================================================
-- POLYMORPHIC RECURSION
-- ============================================================================


{-| Programs whose specializations would grow without end, which the solver
engine reports as polymorphic recursion (finding F13) at the default limits.
-}
polymorphicRecursionCases : List RejectedCase
polymorphicRecursionCases =
    [ fromModule "a non-regular type through a mutually recursive pair"
        (rejectedWithFragment "MONOMORPHIZATION ERROR" "polymorphic recursion cannot be monomorphized: Test.depth")
        (\() -> polyRecModule)
    , fromSource "polymorphic recursion through two calls (F7)"
        (rejectedWithFragment "MONOMORPHIZATION ERROR" "polymorphic recursion cannot be monomorphized: Test.branch")
        polyRecTwoCalls
    ]
        ++ List.map
            (\( shape, source ) ->
                fromSource ("growth through " ++ shape)
                    (rejectedWithFragment "MONOMORPHIZATION ERROR" "polymorphic recursion cannot be monomorphized: Test.")
                    source
            )
            growingShapes


{-| A module `Test` whose demands for specializations never end. As Elm, it
is:

    type Nested a
        = Nil
        | Deeper a (Nested (List a))

    depth : Nested a -> Int
    depth n =
        case n of
            Nil ->
                0

            Deeper _ rest ->
                helper rest

    helper : Nested (List a) -> Int
    helper n =
        depth n

    testValue : Int
    testValue =
        depth (Deeper 1 Nil)

`depth` at `Nested a` demands `helper` at the same `a`, which demands `depth`
at `Nested (List a)`, and so on with one more `List` each time. From the
former polymorphic-recursion test of `Compiler.Monomorphize.SpecWatchdogTest`.

-}
polyRecModule : Src.Module
polyRecModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ depthDef, helperDef, testValueDef ]
        [ nestedUnion ]
        []


{-| The declaration of `Nested`, whose `Deeper` constructor holds a `Nested`
of lists of its own parameter.
-}
nestedUnion : UnionDef
nestedUnion =
    { name = "Nested"
    , args = [ "a" ]
    , ctors =
        [ { name = "Nil", args = [] }
        , { name = "Deeper", args = [ tVar "a", tType "Nested" [ tType "List" [ tVar "a" ] ] ] }
        ]
    }


{-| `depth : Nested a -> Int`, which hands the tail of a `Deeper` to `helper`.
-}
depthDef : TypedDef
depthDef =
    { name = "depth"
    , args = [ pVar "n" ]
    , tipe = tLambda (tType "Nested" [ tVar "a" ]) (tType "Int" [])
    , body =
        caseExpr (varExpr "n")
            [ ( pCtor "Nil" [], intExpr 0 )
            , ( pCtor "Deeper" [ pAnything, pVar "rest" ]
              , callExpr (varExpr "helper") [ varExpr "rest" ]
              )
            ]
    }


{-| `helper : Nested (List a) -> Int`, which calls `depth` on its argument.
-}
helperDef : TypedDef
helperDef =
    { name = "helper"
    , args = [ pVar "n" ]
    , tipe = tLambda (tType "Nested" [ tType "List" [ tVar "a" ] ]) (tType "Int" [])
    , body = callExpr (varExpr "depth") [ varExpr "n" ]
    }


{-| `testValue : Int`, which calls `depth` on `Deeper 1 Nil`.
-}
testValueDef : TypedDef
testValueDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body = callExpr (varExpr "depth") [ callExpr (ctorExpr "Deeper") [ intExpr 1, ctorExpr "Nil" ] ]
    }


{-| F7: `branch : Int -> a -> Int` calls `viaList : Int -> List a -> Int`
twice in one body, at `[ x ]` and `[ [ x ] ]`, and `viaList` calls `branch`
back. From the former `Compiler.Monomorphize.Solver.EngineSpecWatchdogTest`.
The lambda-set signature inference once unified the two members' types as one
monomorphic unit, which made the type infinite and overflowed the stack before
any watchdog could trip.
-}
polyRecTwoCalls : String
polyRecTwoCalls =
    """
branch : Int -> a -> Int
branch n x =
    case n of
        0 ->
            0

        _ ->
            viaList (n - 1) [ x ] + viaList (n - 1) [ [ x ] ]


viaList : Int -> List a -> Int
viaList n xs =
    branch n xs


testValue : Int
testValue =
    branch 3 1
"""


{-| Programs whose polymorphic recursion grows the argument type through a
pair, a record, a `Maybe` and a function, each with the type growing once per
turn of a two-member cycle. From the former
`Compiler.Monomorphize.Solver.EngineSpecWatchdogTest`.
-}
growingShapes : List ( String, String )
growingShapes =
    let
        program wrapType wrapExpr =
            """
grow : Int -> a -> Int
grow n x =
    case n of
        0 ->
            0

        _ ->
            back (n - 1) (""" ++ wrapExpr ++ """)


back : Int -> """ ++ wrapType ++ """ -> Int
back n y =
    grow n y


testValue : Int
testValue =
    grow 3 1
"""
    in
    [ ( "a pair", program "( a, a )" "( x, x )" )
    , ( "a record", program "{ v : a }" "{ v = x }" )
    , ( "a Maybe", program "Maybe a" "Just x" )
    , ( "a function", program "(Int -> a)" "\\_ -> x" )
    ]



-- ============================================================================
-- CLOSURE STAGE LIMIT
-- ============================================================================


{-| A closure that becomes wider than the runtime's stage limit only after
specialization (HEAP\_078), from the former
`Compiler.Monomorphize.ClosureLimitTest`.
-}
closureLimitCases : List RejectedCase
closureLimitCases =
    [ fromSource "a closure over the limit after specialization"
        (rejectedWithFragment "STAGE ARITY LIMIT" "a closure has 2101 parameters and captured variables after specialization; Eco supports at most 2047 (HEAP_078)")
        (closureLimitSource 700)
    ]


{-| A program whose `testValue` binds `count` local identity functions `f1` …
`f(count)`, each generalized, and a lambda that calls every one of them at
`Int`, `String` and `Float`, in one list it sums; a second lambda, `direct`,
does the same. The first lambda's body is a `let`, which carries no source
region of its own, so its report takes the region of the first sub-expression
that has one; the second's body is the call itself, whose region is used
directly. Canonicalization counts one capture per local, which for 700 is
within `Compiler.IR.Runtime.HeapLimits.maxStageArity` (2047); after
specialization each local is three captured specializations, so the closure
holds 2,100 captures plus its parameter.
-}
closureLimitSource : Int -> String
closureLimitSource count =
    let
        names =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 1 count)

        defs =
            String.concat (List.map (\n -> "        " ++ n ++ " x =\n            x\n\n") names)

        uses =
            String.join "\n                    , " (List.map (\n -> "use (" ++ n ++ " 1) (" ++ n ++ " \"s\") (" ++ n ++ " 1.5)") names)
    in
    """
use : Int -> String -> Float -> Int
use a _ _ =
    a


testValue : Int
testValue =
    let
"""
        ++ defs
        ++ """        run =
            \\y ->
                let
                    z =
                        y + 1
                in
                List.foldl (+)
                    z
                    [ """
        ++ uses
        ++ """
                    ]

        direct =
            \\y ->
                List.foldl (+)
                    y
                    [ """
        ++ uses
        ++ """
                    ]
    in
    run 0 + direct 0
"""



-- ============================================================================
-- UNSUPPORTED EXPRESSIONS
-- ============================================================================


{-| A GLSL shader, which the native back end does not support (finding F9),
from the former `Compiler.PreMono.ShaderTest`: `withShader`, annotated
`Int -> Fn` with `Fn` an alias of `Int -> Int` and written with one parameter,
is a `let` around a local function whose body binds a shader.
-}
unsupportedCases : List RejectedCase
unsupportedCases =
    [ fromSource "a shader"
        (rejectedWithFragment "MONOMORPHIZATION ERROR" "unsupported: shader")
        """
type alias Fn =
    Int -> Int


withShader : Int -> Fn
withShader n =
    let
        h z =
            let
                s =
                    [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |]
            in
            z + n
    in
    h


testValue =
    withShader 1 2
"""
    ]
