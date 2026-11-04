module SourceIR.WideObjectCases exposing (expectSuite)

{-| Programs that build, read and close over objects wider than the old fixed
kind bitmaps could describe, for a caller to push through whichever compiler
stage it tests.

A heap object records how each of its slots is stored (boxed, or an unboxed
`Int`, `Float` or `Char`). A Custom header bitmap describes 24 slots, the old
Elm-side record bitmap described 26, the old u64 closure bitmap held 25, and
a slot past 15 read with JavaScript's 32-bit `Bitwise` wrapped. The layouts
now have no index cap and record the kinds of the further slots in extension
words (HEAP\_019, `plans/wide-object-tail-kind-words.md`). These programs put
a field, a capture or a new argument past those boundaries.

Every program is built with `Compiler.AST.SourceBuilder`, annotates each of its
top-level values and defines `testValue`. The programs from
`makeModuleWithTypedDefs` are modules named `TestMod`; those from
`makeModuleWithTypedDefsUnionsAliases` are named `TestMod` or `Test`, as
listed. In the sketches below, `...` stands for the numbered fields,
parameters or arguments in between.

This module asserts nothing. `expectSuite` hands each program to the caller's
expectation, through `Compiler.BulkCheck`, which stops at the first case that
fails and names its label. The programs, in the order they run:

  - "Record with boxed fields past slot 15" (`TestMod`): `testValue` is a
    record literal of 17 `Int` fields `i00`..`i16` and 2 `String` fields `s0`,
    `s1`; the layout puts the Strings in slots 17 and 18.
  - "Record of 30 Int fields" (`TestMod`): a record literal of fields
    `i00`..`i29`, holding 0 to 29.
  - "Constructor of 30 Int fields" (`TestMod`): `type W = W Int ... Int` (30
    fields) and `testValue = W 0 1 ... 29`.
  - "Record of 28 mixed fields" (`TestMod`): a record literal of 14 `Int`
    fields `f00`..`f13`, 10 `Float` fields `g00`..`g09`, 2 `Char` fields `c0`,
    `c1` and 2 `String` fields `s0`, `s1`.
  - "Lambda capturing 26 Int parameters" (`TestMod`):
    `mk : Int -> ... -> Int -> (Int -> Int)` takes 26 parameters `a0`..`a25`
    and returns `\x -> x * 7 + a0 * 1 + ... + a25 * 26`;
    `testValue = List.map (mk 1 2 ... 26) [ 1, 2 ]`.
  - "Partial application with 26 Int arguments" (`TestMod`): the same `mk`
    with the lambda's `x` as a 27th parameter, so `mk 1 2 ... 26` extends
    `mk`'s closure by 26 `Int` arguments; `testValue` as above.
  - "Lambda capturing 27 Int parameters" (`TestMod`): `mk` takes 27
    parameters `a0`..`a26` and returns `[ \x -> x * 7 + a0 * 1 + ... + a26 * 27 ]`;
    `testValue = List.map (\f -> f 1) (mk 1 2 ... 27)`.
  - "Int field 24 of a 25-field constructor" (`Test`):
    `type Wide = Wide Int ... Int` (25 fields),
    `lastField : Wide -> Int` matching `Wide f0 f1 ... f24 -> f24`, and
    `testValue = lastField (Wide 0 1 ... 24)`. The call of the constructor
    function passes field 24 past the 24 slots of the header bitmap.
  - "String field 24 of a 25-field constructor" (`Test`): the same with field
    24 of type `String`, `lastField : Wide -> String` and the argument `"x"`.
  - "Polymorphic field 24 used at Int" (`Test`):
    `type Wide a = Wide Int ... Int a` (24 `Int` fields, then `a`),
    `lastField : Wide a -> a` matching as above, and
    `testValue : Int = lastField (Wide 0 1 ... 24)`.
  - "Record pattern on field 27 of a 28-Int record" (`Test`):
    `viaPat : { f00 : Int, ..., f27 : Int } -> Int` with
    `viaPat { f27, f25 } = f27 * 1000 + f25`, and
    `testValue = viaPat { f00 = 0, ..., f27 = 27 }`.

Among what is not tested: a `Float` or `Char` field past slot 24 of a
constructor; a capture or argument of a type other than `Int` past slot 25;
a tuple, which has at most three slots; an object over the size limits of
HEAP\_019, which compilation rejects; and the value any program computes,
since nothing here runs one.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , chrExpr
        , ctorExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModuleWithTypedDefs
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pRecord
        , pVar
        , qualVarExpr
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Wide objects "` followed by `condStr`, that
applies `expectFn` to the programs of this module in order and fails at the
first one it rejects, naming that program's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Wide objects " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, in the order the module docstring lists them.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map (\( label, modul ) -> { label = label, run = \_ -> expectFn modul })
        [ ( "Record with boxed fields past slot 15", wideRecord )
        , ( "Record of 30 Int fields", record30Int )
        , ( "Constructor of 30 Int fields", ctor30Int )
        , ( "Record of 28 mixed fields", recordMixed28 )
        , ( "Lambda capturing 26 Int parameters", closure26 )
        , ( "Partial application with 26 Int arguments", pap26 )
        , ( "Lambda capturing 27 Int parameters", captures27 )
        , ( "Int field 24 of a 25-field constructor", wideCtorModule tInt (intExpr 24) )
        , ( "String field 24 of a 25-field constructor", wideCtorModule (tType "String" []) (strExpr "x") )
        , ( "Polymorphic field 24 used at Int", polyWideCtor )
        , ( "Record pattern on field 27 of a 28-Int record", recordPattern27 )
        ]



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| The type `Int`, as written in an annotation.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| `prefix` followed by `i`, padded to two digits: `numbered "f" 3` is `"f03"`.
-}
numbered : String -> Int -> String
numbered prefix i =
    prefix ++ String.padLeft 2 '0' (String.fromInt i)


{-| `x * 7 + a0 * 1 + a1 * 2 + ... + aN * (N + 1)` for `N = lastIndex`.
-}
weightedSum : Int -> Src.Expr
weightedSum lastIndex =
    binopsExpr
        (( varExpr "x", "*" )
            :: ( intExpr 7, "+" )
            :: List.concatMap
                (\i -> [ ( varExpr ("a" ++ String.fromInt i), "*" ), ( intExpr (i + 1), "+" ) ])
                (List.range 0 (lastIndex - 1))
            ++ [ ( varExpr ("a" ++ String.fromInt lastIndex), "*" ) ]
        )
        (intExpr (lastIndex + 1))


{-| The curried type of `n` `Int` parameters followed by `result`.
-}
intParamsTo : Int -> Src.Type -> Src.Type
intParamsTo n result =
    List.foldr (\_ acc -> tLambda tInt acc) result (List.range 1 n)



-- ============================================================================
-- WIDE CONSTRUCTIONS
-- ============================================================================


{-| A record literal of `Int` fields `i00`..`i16` and `String` fields `s0`,
`s1`.
-}
wideRecord : Src.Module
wideRecord =
    let
        intNames =
            List.map (numbered "i") (List.range 0 16)

        strNames =
            [ "s0", "s1" ]
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe =
                tRecord
                    (List.map (\n -> ( n, tInt )) intNames
                        ++ List.map (\n -> ( n, tType "String" [] )) strNames
                    )
          , body =
                recordExpr
                    (List.indexedMap (\i n -> ( n, intExpr i )) intNames
                        ++ List.map (\n -> ( n, strExpr n )) strNames
                    )
          }
        ]


{-| A record literal of `Int` fields `i00`..`i29` holding 0 to 29.
-}
record30Int : Src.Module
record30Int =
    let
        names =
            List.map (numbered "i") (List.range 0 29)
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe = tRecord (List.map (\n -> ( n, tInt )) names)
          , body = recordExpr (List.indexedMap (\i n -> ( n, intExpr i )) names)
          }
        ]


{-| `type W = W Int ... Int` with 30 `Int` fields, and `testValue = W 0 1 ... 29`.
-}
ctor30Int : Src.Module
ctor30Int =
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe = tType "W" []
          , body = callExpr (ctorExpr "W") (List.map intExpr (List.range 0 29))
          }
        ]
        [ { name = "W"
          , args = []
          , ctors = [ { name = "W", args = List.repeat 30 tInt } ]
          }
        ]
        []


{-| A record literal of 28 fields: `Int` `f00`..`f13`, `Float` `g00`..`g09`,
`Char` `c0`, `c1` and `String` `s0`, `s1`.
-}
recordMixed28 : Src.Module
recordMixed28 =
    let
        intNames =
            List.map (numbered "f") (List.range 0 13)

        floatNames =
            List.map (numbered "g") (List.range 0 9)

        charNames =
            [ "c0", "c1" ]

        strNames =
            [ "s0", "s1" ]
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "testValue"
          , args = []
          , tipe =
                tRecord
                    (List.map (\n -> ( n, tInt )) intNames
                        ++ List.map (\n -> ( n, tType "Float" [] )) floatNames
                        ++ List.map (\n -> ( n, tType "Char" [] )) charNames
                        ++ List.map (\n -> ( n, tType "String" [] )) strNames
                    )
          , body =
                recordExpr
                    (List.indexedMap (\i n -> ( n, intExpr i )) intNames
                        ++ List.indexedMap (\i n -> ( n, floatExpr (toFloat i + 0.5) )) floatNames
                        ++ List.map (\n -> ( n, chrExpr "x" )) charNames
                        ++ List.map (\n -> ( n, strExpr n )) strNames
                    )
          }
        ]



-- ============================================================================
-- WIDE CLOSURES
-- ============================================================================


{-| `mk` of 26 `Int` parameters returning a lambda that captures all of them,
partially applied to all 26 and passed to `List.map`.
-}
closure26 : Src.Module
closure26 =
    let
        indices =
            List.range 0 25
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices
          , tipe = intParamsTo 26 (tLambda tInt tInt)
          , body = lambdaExpr [ pVar "x" ] (weightedSum 25)
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ tInt ]
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ callExpr (varExpr "mk") (List.map (\i -> intExpr (i + 1)) indices)
                    , listExpr [ intExpr 1, intExpr 2 ]
                    ]
          }
        ]


{-| `mk` of 27 `Int` parameters applied to the first 26 and passed to
`List.map`, so the closure of `mk` is extended by 26 `Int` arguments.
-}
pap26 : Src.Module
pap26 =
    let
        indices =
            List.range 0 25
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices ++ [ pVar "x" ]
          , tipe = intParamsTo 26 (tLambda tInt tInt)
          , body = weightedSum 25
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ tInt ]
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ callExpr (varExpr "mk") (List.map (\i -> intExpr (i + 1)) indices)
                    , listExpr [ intExpr 1, intExpr 2 ]
                    ]
          }
        ]


{-| `mk` of 27 `Int` parameters returning a list holding one lambda that uses
all of them, so the lambda is a closure value capturing 27 `Int`s.
-}
captures27 : Src.Module
captures27 =
    let
        indices =
            List.range 0 26
    in
    makeModuleWithTypedDefs "TestMod"
        [ { name = "mk"
          , args = List.map (\i -> pVar ("a" ++ String.fromInt i)) indices
          , tipe = intParamsTo 27 (tType "List" [ tLambda tInt tInt ])
          , body = listExpr [ lambdaExpr [ pVar "x" ] (weightedSum 26) ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ tInt ]
          , body =
                callExpr (qualVarExpr "List" "map")
                    [ lambdaExpr [ pVar "f" ] (callExpr (varExpr "f") [ intExpr 1 ])
                    , callExpr (varExpr "mk") (List.map (\i -> intExpr (i + 1)) indices)
                    ]
          }
        ]



-- ============================================================================
-- WIDE PROJECTIONS
-- ============================================================================


{-| A module `Test` declaring `type Wide = Wide Int ... Int T24` (24 `Int`
fields, then one of type `field24Type`), a `lastField : Wide -> T24` that
returns field 24 by a `case`, and `testValue = lastField (Wide 0 1 ... 23 last)`,
where `last` is `lastArg`.
-}
wideCtorModule : Src.Type -> Src.Expr -> Src.Module
wideCtorModule field24Type lastArg =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

        wideUnion : UnionDef
        wideUnion =
            { name = "Wide"
            , args = []
            , ctors = [ { name = "Wide", args = List.repeat 24 tInt ++ [ field24Type ] } ]
            }

        lastFieldDef : TypedDef
        lastFieldDef =
            { name = "lastField"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wide" []) field24Type
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = field24Type
            , body =
                callExpr (varExpr "lastField")
                    [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 23) ++ [ lastArg ]) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ lastFieldDef, testValueDef ]
        [ wideUnion ]
        []


{-| `type Wide a = Wide Int ... Int a` (24 `Int` fields, then `a`),
`lastField : Wide a -> a` returning field 24, and
`testValue : Int = lastField (Wide 0 1 ... 24)`.
-}
polyWideCtor : Src.Module
polyWideCtor =
    let
        fieldNames =
            List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

        wideUnion : UnionDef
        wideUnion =
            { name = "Wide"
            , args = [ "a" ]
            , ctors = [ { name = "Wide", args = List.repeat 24 tInt ++ [ tVar "a" ] } ]
            }

        lastFieldDef : TypedDef
        lastFieldDef =
            { name = "lastField"
            , args = [ pVar "w" ]
            , tipe = tLambda (tType "Wide" [ tVar "a" ]) (tVar "a")
            , body =
                caseExpr (varExpr "w")
                    [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "lastField")
                    [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 24)) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ lastFieldDef, testValueDef ]
        [ wideUnion ]
        []


{-| `viaPat { f27, f25 } = f27 * 1000 + f25` on a record of 28 `Int` fields
`f00`..`f27`, and `testValue = viaPat { f00 = 0, ..., f27 = 27 }`.
-}
recordPattern27 : Src.Module
recordPattern27 =
    let
        fieldNames =
            List.map (numbered "f") (List.range 0 27)

        viaPatDef : TypedDef
        viaPatDef =
            { name = "viaPat"
            , args = [ pRecord [ "f27", "f25" ] ]
            , tipe = tLambda (tRecord (List.map (\name -> ( name, tInt )) fieldNames)) tInt
            , body = binopsExpr [ ( varExpr "f27", "*" ), ( intExpr 1000, "+" ) ] (varExpr "f25")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "viaPat")
                    [ recordExpr (List.indexedMap (\i name -> ( name, intExpr i )) fieldNames) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ viaPatDef, testValueDef ]
        []
        []
