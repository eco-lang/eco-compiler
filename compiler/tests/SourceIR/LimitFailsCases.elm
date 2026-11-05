module SourceIR.LimitFailsCases exposing (expectRejectedSuite, expectSuite)

{-| Programs that canonicalization must reject for a size over one of the
runtime's limits, each with the report it must be rejected with: the
size-limit module of the negative catalogue (`SourceIR.Suite.RejectedSuites`),
from the former `Compiler.Canonicalize.LimitErrorsTest`.

The limits are those of `Compiler.IR.Runtime.HeapLimits`: a closure's stage
arity, its parameters plus its captured variables, is at most
`maxStageArity` (2047, HEAP\_078); a constructor has at most `maxCtorFields`
fields (2040) and a record at most `maxRecordFields` (2047, HEAP\_019); and a
constructor without fields is at most at declaration index
`maxNullaryCtorIndex` (1023, HEAP\_044), so among its type's first 1024
constructors.
Canonicalization enforces them, so that a program over them is rejected with a
located report, not in the back end; a limit that only shows after
specialization is a monomorphization rejection, in `SourceIR.MonoFailsCases`.

`expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`: the title (`TOO MANY PARAMETERS`, `TOO
MANY CAPTURED VARIABLES`, `TOO MANY FIELDS` or `TOO MANY CONSTRUCTORS`) and, as the fragment, the
report's sentence naming what is too large, its size, the limit and the
invariant. `TestLogic.Reporting.ExpectedRejectionTest` checks that
canonicalization rejects each program with that report, and the size-limit
oracle (`TestLogic.Canonicalize.SizeLimitsTest`) that the report matches the
sizes it reads from the program. `expectSuite` gives a check only the
programs. The programs exactly at a limit, which must be accepted, are
`SourceIR.LimitBoundaryCases`.

The cases, each one over its limit and built with
`Compiler.AST.SourceBuilder` from generated parameter and field lists:

  - "Stage arity": a top-level function, a `let` function and a lambda of 2048
    parameters; a lambda of 2000 parameters capturing 48 locals; and a `let`
    function of 2000 parameters capturing 48 locals.
  - "Field counts": a constructor of 2041 fields; a record of 2048 fields as a
    type alias's body, as a record literal and in an annotation.
  - "Nullary constructor positions": a custom type of 1025 constructors
    without fields, and one of 1024 constructors with a field followed by one
    without.

Among what is not tested: the regions the reports carry, and arities the
compiler generates rather than the program writes.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromModule
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Size limit failure tests " followed by
`condStr`, with one test per group of cases (see `groups`). Each test applies
`expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Size limit failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Size limit failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Stage arity", arityCases )
    , ( "Field counts", fieldCases )
    , ( "Nullary constructor positions", nullaryPositionCases )
    ]



-- ============================================================================
-- STAGE ARITY (HEAP_078)
-- ============================================================================


{-| Functions and closures one slot over `HeapLimits.maxStageArity` (2047).
-}
arityCases : List RejectedCase
arityCases =
    [ fromModule "a top-level function with 2048 parameters"
        (rejectedWithFragment "TOO MANY PARAMETERS" "The function `big` has 2048 parameters, but Eco supports at most 2047 (HEAP_078).")
        (\() -> topLevelBig 2048)
    , fromModule "a let-defined function with 2048 parameters"
        (rejectedWithFragment "TOO MANY PARAMETERS" "The function `big` has 2048 parameters, but Eco supports at most 2047 (HEAP_078).")
        (\() -> letBig 2048)
    , fromModule "a lambda with 2048 parameters"
        (rejectedWithFragment "TOO MANY PARAMETERS" "This anonymous function has 2048 parameters, but Eco supports at most 2047 (HEAP_078).")
        (\() -> lambdaOf 2048)
    , fromModule "a lambda with 2000 parameters capturing 48 locals"
        (rejectedWithFragment "TOO MANY CAPTURED VARIABLES" "This anonymous function has 2048 parameters and captured variables, but Eco supports at most 2047 (HEAP_078).")
        (\() -> capturingLambda 48 2000)
    , fromModule "a local function with 2000 parameters capturing 48 locals"
        (rejectedWithFragment "TOO MANY CAPTURED VARIABLES" "The local function `inner` has 2048 parameters and captured variables, but Eco supports at most 2047 (HEAP_078).")
        (\() -> capturingLocalFunction 48 2000)
    ]


{-| Returns the variable patterns `prefix0` to `prefix(n-1)`.
-}
params : String -> Int -> List Src.Pattern
params prefix n =
    List.map (\i -> SB.pVar (prefix ++ String.fromInt i)) (List.range 0 (n - 1))


{-| A module whose top-level function `big a0 … a(n-1) = a0` takes `n`
parameters.
-}
topLevelBig : Int -> Src.Module
topLevelBig n =
    SB.makeModuleWithDefs "Test"
        [ ( "big", params "a" n, SB.varExpr "a0" ) ]


{-| A module whose value `testValue` defines `big a0 … a(n-1) = a0` in a
`let` and returns it.
-}
letBig : Int -> Src.Module
letBig n =
    SB.makeModuleWithDefs "Test"
        [ ( "testValue"
          , []
          , SB.letExpr [ SB.define "big" (params "a" n) (SB.varExpr "a0") ] (SB.varExpr "big")
          )
        ]


{-| A module whose value `f = \a0 … a(n-1) -> a0` is a lambda of `n`
parameters.
-}
lambdaOf : Int -> Src.Module
lambdaOf n =
    SB.makeModuleWithDefs "Test"
        [ ( "f", [], SB.lambdaExpr (params "a" n) (SB.varExpr "a0") ) ]


{-| The sum `c0 + … + c(captured-1) + a0`, which uses every `c`.
-}
sumOfCaptures : Int -> Src.Expr
sumOfCaptures captured =
    SB.binopsExpr
        (List.map (\i -> ( SB.varExpr ("c" ++ String.fromInt i), "+" )) (List.range 0 (captured - 1)))
        (SB.varExpr "a0")


{-| A module whose function `mk c0 … c(captured-1)` returns the lambda
`\a0 … a(arity-1) -> c0 + … + c(captured-1) + a0`, which captures every `c`.
-}
capturingLambda : Int -> Int -> Src.Module
capturingLambda captured arity =
    SB.makeModuleWithDefs "Test"
        [ ( "mk"
          , params "c" captured
          , SB.lambdaExpr (params "a" arity) (sumOfCaptures captured)
          )
        ]


{-| A module whose function `mk c0 … c(captured-1)` defines the local function
`inner a0 … a(arity-1) = c0 + … + c(captured-1) + a0`, which captures every
`c`, and returns it.
-}
capturingLocalFunction : Int -> Int -> Src.Module
capturingLocalFunction captured arity =
    SB.makeModuleWithDefs "Test"
        [ ( "mk"
          , params "c" captured
          , SB.letExpr [ SB.define "inner" (params "a" arity) (sumOfCaptures captured) ] (SB.varExpr "inner")
          )
        ]



-- ============================================================================
-- FIELD COUNTS (HEAP_019)
-- ============================================================================


{-| A constructor one field over `HeapLimits.maxCtorFields` (2040), and records
one field over `HeapLimits.maxRecordFields` (2047): as a type alias's body, as
a record literal and as a record type in an annotation.
-}
fieldCases : List RejectedCase
fieldCases =
    [ fromModule "a constructor with 2041 fields"
        (rejectedWithFragment "TOO MANY FIELDS" "The constructor `Big` has 2041 fields, but Eco supports at most 2040 (HEAP_019).")
        (\() -> SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [ wideUnion 2041 ] [])
    , fromModule "a record alias with 2048 fields"
        (rejectedWithFragment "TOO MANY FIELDS" "The record type `BigRecord` has 2048 fields, but Eco supports at most 2047 (HEAP_019).")
        (\() -> SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [] [ wideAlias 2048 ])
    , fromModule "a record literal with 2048 fields"
        (rejectedWithFragment "TOO MANY FIELDS" "This record has 2048 fields, but Eco supports at most 2047 (HEAP_019).")
        (\() -> wideRecordLiteral 2048)
    , fromModule "a record type annotation with 2048 fields"
        (rejectedWithFragment "TOO MANY FIELDS" "This record has 2048 fields, but Eco supports at most 2047 (HEAP_019).")
        (\() -> wideRecordAnnotation 2048)
    ]


{-| Returns `n` field types, `f0 : Int` to `f(n-1) : Int`.
-}
intFields : Int -> List ( String, Src.Type )
intFields n =
    List.map (\i -> ( "f" ++ String.fromInt i, SB.tType "Int" [] )) (List.range 0 (n - 1))


{-| A custom type `type Wide = Big Int … Int` whose constructor has `n` fields.
-}
wideUnion : Int -> SB.UnionDef
wideUnion n =
    { name = "Wide", args = [], ctors = [ { name = "Big", args = List.repeat n (SB.tType "Int" []) } ] }


{-| A record type alias `type alias BigRecord = { f0 : Int, … }` of `n` fields.
-}
wideAlias : Int -> SB.AliasDef
wideAlias n =
    { name = "BigRecord", args = [], tipe = SB.tRecord (intFields n) }


{-| A module whose value `r = { f0 = 0, … }` is a record literal of `n` fields.
-}
wideRecordLiteral : Int -> Src.Module
wideRecordLiteral n =
    SB.makeModuleWithDefs "Test"
        [ ( "r", [], SB.recordExpr (List.map (\i -> ( "f" ++ String.fromInt i, SB.intExpr i )) (List.range 0 (n - 1))) ) ]


{-| A module whose function `get : { f0 : Int, … } -> Int` is annotated with a
record type of `n` fields.
-}
wideRecordAnnotation : Int -> Src.Module
wideRecordAnnotation n =
    SB.makeModuleWithTypedDefs "Test"
        [ { name = "get"
          , args = [ SB.pVar "r" ]
          , tipe = SB.tLambda (SB.tRecord (intFields n)) (SB.tType "Int" [])
          , body = SB.accessExpr (SB.varExpr "r") "f0"
          }
        ]



-- ============================================================================
-- NULLARY CONSTRUCTOR POSITIONS (HEAP_044)
-- ============================================================================


{-| A constructor without fields one position past
`HeapLimits.maxNullaryCtorIndex` (1023): the last of 1025 constructors that
have no fields, and one without fields after 1024 that each have a field. The
constructors with fields have no such limit; only the one without is reported.
-}
nullaryPositionCases : List RejectedCase
nullaryPositionCases =
    [ fromModule "a custom type of 1025 constructors without fields"
        (rejectedWithFragment "TOO MANY CONSTRUCTORS" "The constructor `C1024` has no fields and is constructor 1025 of its type, but Eco supports a constructor without fields only among the first 1024 (HEAP_044).")
        (\() -> SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [ manyCtors 1025 [] ] [])
    , fromModule "a constructor without fields after 1024 constructors with a field"
        (rejectedWithFragment "TOO MANY CONSTRUCTORS" "The constructor `Last` has no fields and is constructor 1025 of its type, but Eco supports a constructor without fields only among the first 1024 (HEAP_044).")
        (\() ->
            let
                withFields =
                    manyCtors 1024 [ SB.tType "Int" [] ]
            in
            SB.makeModuleWithTypedDefsUnionsAliases "Test"
                []
                [ { withFields | ctors = withFields.ctors ++ [ { name = "Last", args = [] } ] } ]
                []
        )
    ]


{-| A custom type `type Many = C0 args | … | C(n-1) args`, every constructor
taking `args`.
-}
manyCtors : Int -> List Src.Type -> SB.UnionDef
manyCtors n args =
    { name = "Many", args = [], ctors = List.map (\i -> { name = "C" ++ String.fromInt i, args = args }) (List.range 0 (n - 1)) }
