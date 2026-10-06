module TestLogic.Canonicalize.LimitErrorsTest exposing (suite)

{-| Eco limits a closure's stage arity to 2047 (`HEAP_078`): a function or
lambda with more parameters, or a lambda whose parameters plus captured
variables exceed it, must be rejected by canonicalization with a located
`TooLarge` error (bug B18, decision D5 and §S.9 of
`plans/wide-object-tail-kind-words.md`), not fail late in the backend. Eco also
limits a constructor to 2040 fields and a record to 2047 fields (`HEAP_019`,
Phase 3D, decision 3D-D4), with the same kind of error. These tests check that
each such shape is reported as the right `TooLarge` variant, that a function,
constructor and record at exactly the limit are accepted, and that the reports
name the definition and the limit.

Each test builds a small source module with `Compiler.AST.SourceBuilder`,
whose parameter lists are built with `List.range`, and hands it to an
expectation from `TestLogic.Canonicalize.LimitErrors`, which canonicalizes it
and looks only at the errors, matching the `TooLarge` constructor and its
`TooLargeWhat`, actual count and limit.

The tests establish:

  - a top-level function with 2048 parameters is one `TooLarge` with
    `TooManyParams "big"`, 2048 and 2047;
  - the same function defined in a `let` is the same error;
  - a lambda with 2048 parameters is a `TooLarge` with `TooManyLambdaParams`;
  - a lambda with 2000 parameters capturing 48 locals is a `TooLarge` with
    `TooManyClosureSlots Nothing`, 2048 and 2047;
  - a function with 2047 parameters is accepted;
  - the report of the 2048-parameter error is titled `TOO MANY PARAMETERS`
    and names `big` and the limit 2047;
  - a constructor with 2041 fields is a `TooLarge` with
    `TooManyCtorFields "Big"`, 2041 and 2040;
  - a record type alias with 2048 fields is a `TooLarge` with
    `TooManyRecordFields (Just "BigRecord")`, 2048 and 2047;
  - a record literal with 2048 fields, and a record type annotation with 2048
    fields, are each a `TooLarge` with `TooManyRecordFields Nothing`;
  - a constructor with 2040 fields and a record alias with 2047 fields are
    accepted;
  - the report of the 2041-field constructor is titled `TOO MANY FIELDS` and
    names `Big`, the limit 2040 and `HEAP_019`.

Among what is not tested: the region the error carries, and compiler-generated
arity.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Reporting.Error.Canonicalize as CanError
import Expect
import Test exposing (Test)
import TestLogic.Canonicalize.LimitErrors
    exposing
        ( expectCanonicalizes
        , expectFirstReportContains
        , expectTooLarge
        )


{-| The whole suite.
-}
suite : Test
suite =
    Test.describe "Front-end limit diagnostics (B18, D5)"
        [ Test.test "a top-level function with 2048 parameters is TooLarge TooManyParams" <|
            \_ ->
                expectTooLarge (CanError.TooManyParams "big") 2048 2047 (topLevelBig 2048)
        , Test.test "a let-defined function with 2048 parameters is TooLarge TooManyParams" <|
            \_ ->
                expectTooLarge (CanError.TooManyParams "big") 2048 2047 (letBig 2048)
        , Test.test "a lambda with 2048 parameters is TooLarge TooManyLambdaParams" <|
            \_ ->
                expectTooLarge CanError.TooManyLambdaParams 2048 2047 (lambdaOf 2048)
        , Test.test "a lambda with 2000 parameters capturing 48 locals is TooLarge TooManyClosureSlots" <|
            \_ ->
                expectTooLarge (CanError.TooManyClosureSlots Nothing) 2048 2047 (capturingLambda 48 2000)
        , Test.test "a function with 2047 parameters is accepted" <|
            \_ ->
                expectCanonicalizes (topLevelBig 2047)
        , Test.test "the TooLarge report names the function and the limit" <|
            \_ ->
                expectFirstReportContains [ "TOO MANY PARAMETERS", "big", "2047" ] (topLevelBig 2048)
        , Test.test "a ctor with 2041 fields is TooLarge TooManyCtorFields" <|
            \_ ->
                expectTooLarge (CanError.TooManyCtorFields "Big") 2041 2040 (wideCtor 2041)
        , Test.test "a record alias with 2048 fields is TooLarge TooManyRecordFields" <|
            \_ ->
                expectTooLarge (CanError.TooManyRecordFields (Just "BigRecord")) 2048 2047 (wideRecordAlias 2048)
        , Test.test "a record literal with 2048 fields is TooLarge TooManyRecordFields Nothing" <|
            \_ ->
                expectTooLarge (CanError.TooManyRecordFields Nothing) 2048 2047 (wideRecordLiteral 2048)
        , Test.test "a record type annotation with 2048 fields is TooLarge TooManyRecordFields Nothing" <|
            \_ ->
                expectTooLarge (CanError.TooManyRecordFields Nothing) 2048 2047 (wideRecordAnnotation 2048)
        , Test.test "a ctor with 2040 fields and a record alias with 2047 fields are accepted" <|
            \_ ->
                expectCanonicalizes (wideCtorAndAlias 2040 2047)
        , Test.test "the limits match HeapLimits" <|
            \_ ->
                Expect.equal ( HeapLimits.maxCtorFields, HeapLimits.maxRecordFields ) ( 2040, 2047 )
        , Test.test "the TooLarge field report says TOO MANY FIELDS" <|
            \_ ->
                expectFirstReportContains [ "TOO MANY FIELDS", "Big", "2041", "2040", "HEAP_019" ] (wideCtor 2041)
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


{-| A module whose function `mk c0 … c(captured-1)` returns the lambda
`\a0 … a(arity-1) -> c0 + … + c(captured-1) + a0`, which captures every `c`.
-}
capturingLambda : Int -> Int -> Src.Module
capturingLambda captured arity =
    let
        capturedTerms =
            List.map (\i -> ( SB.varExpr ("c" ++ String.fromInt i), "+" )) (List.range 0 (captured - 1))
    in
    SB.makeModuleWithDefs "Test"
        [ ( "mk"
          , params "c" captured
          , SB.lambdaExpr (params "a" arity) (SB.binopsExpr capturedTerms (SB.varExpr "a0"))
          )
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


{-| A module declaring only `wideUnion n`.
-}
wideCtor : Int -> Src.Module
wideCtor n =
    SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [ wideUnion n ] []


{-| A module declaring only `wideAlias n`.
-}
wideRecordAlias : Int -> Src.Module
wideRecordAlias n =
    SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [] [ wideAlias n ]


{-| A module declaring `wideUnion ctorFields` and `wideAlias recordFields`.
-}
wideCtorAndAlias : Int -> Int -> Src.Module
wideCtorAndAlias ctorFields recordFields =
    SB.makeModuleWithTypedDefsUnionsAliases "Test" [] [ wideUnion ctorFields ] [ wideAlias recordFields ]


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
