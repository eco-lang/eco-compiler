module TestLogic.Monomorphize.SpecWatchdogTest exposing (suite)

{-| Tests for the specialization watchdogs, the two limits that make
monomorphization fail with a message instead of running forever.

Monomorphization makes one copy of a function, a _specialization_ (or spec),
for each concrete type it is demanded at, and each new spec can demand more.
Elm can express a program whose demands never end, so without a limit the
monomorphizer would not finish on it. Two limits, `Config.SpecLimits`, guard
against that: the _breadth_ limit (`specBreadth`) bounds how many specs are
created for one global, and the _type-node_ limit (`specTypeNodes`) bounds the
size of a spec's demanded type, as `Mono.typeNodesWithin` counts it. The
engines skip a check whose limit is `0` or less, although
`Mono.typeNodesWithin` itself rejects every type at a limit of `0`. The
wording of a trip is `Registry.breadthLimitMessage` and
`Registry.typeNodesLimitMessage`, shared by both monomorphizer engines.

The fixture, `polyRecModule`, is an annotated mutually recursive pair over a
non-regular type: `depth : Nested a -> Int` calls
`helper : Nested (List a) -> Int`, which calls `depth` back. Each round
demands `depth` at a type with one more `List` than the last, so both the
number of `depth` specs and the size of their types grow without bound. Each
test expected to trip sets one limit and disables the other, so only one
check can trip. `benignModule`, whose `testValue` is the literal `42`, is the
control.

The tests establish:

  - `Mono.typeNodesWithin` accepts a type at a limit equal to its node count
    and rejects it at one less: one node for `Int`, three for a list of lists
    of `Int`, four for a two-argument function (the arrow, both arguments and
    the result), and four for a three-field record (the record and each
    field).
  - `Registry.createdCount` is 1 after one `getOrCreateSpecId`, still 1 after
    the same global and type again, and 2 after the same global at a second
    type.
  - The solver engine, with `Config.defaultLss`, fails on `polyRecModule` at
    `specBreadth = 8` with a message containing
    `"specialization budget exceeded"` and `"ECO_SPEC_BREADTH_LIMIT"`.
  - The solver engine fails on `polyRecModule` at `specTypeNodes = 40` with a
    message containing `"specialization type too large"` and
    `"ECO_SPEC_TYPE_NODE_LIMIT"`.
  - The substitution engine fails on `polyRecModule` at `specBreadth = 8` with
    the breadth message's two phrases.
  - The solver engine succeeds on `benignModule` at `specTypeNodes = 200` and
    `specBreadth = 8`.

Among what is not tested: the substitution engine under the type-node limit,
the global name and counts in a message, the solver engine with lambda-set
specialization off, and `Mono.typeNodesWithin` on tuples and custom types.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
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
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Registry as Registry
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The watchdog tests, in three groups: type-node counting, the registry's
created-spec count, and the two engines on `polyRecModule` and
`benignModule`.
-}
suite : Test
suite =
    Test.describe "MONO_030 spec watchdogs"
        [ Test.describe "typeNodesWithin"
            [ Test.test "single node at exact limit" <|
                \() -> Expect.equal True (Mono.typeNodesWithin 1 Mono.MInt)
            , Test.test "single node over a zero budget" <|
                \() -> Expect.equal False (Mono.typeNodesWithin 0 Mono.MInt)
            , Test.test "nested list at exact limit" <|
                \() -> Expect.equal True (Mono.typeNodesWithin 3 (Mono.mList (Mono.mList Mono.MInt)))
            , Test.test "nested list one over" <|
                \() -> Expect.equal False (Mono.typeNodesWithin 2 (Mono.mList (Mono.mList Mono.MInt)))
            , Test.test "function counts arrow + args + result" <|
                \() ->
                    let
                        fn =
                            Mono.mFunction Mono.topLegacy [ Mono.MInt, Mono.MString ] Mono.MBool
                    in
                    Expect.equal ( True, False )
                        ( Mono.typeNodesWithin 4 fn, Mono.typeNodesWithin 3 fn )
            , Test.test "wide record" <|
                \() ->
                    let
                        rec =
                            Mono.mRecord
                                (Dict.fromList [ ( "a", Mono.MInt ), ( "b", Mono.MInt ), ( "c", Mono.MInt ) ])
                    in
                    Expect.equal ( True, False )
                        ( Mono.typeNodesWithin 4 rec, Mono.typeNodesWithin 3 rec )
            ]
        , Test.describe "Registry.countByGlobal"
            [ Test.test "created specs count; probe hits do not" <|
                \() ->
                    let
                        g =
                            Mono.Global (ModuleName.Canonical ( "eco", "example" ) "Test") "f"

                        ( _, reg1 ) =
                            Registry.getOrCreateSpecId g Mono.MInt Registry.emptyRegistry

                        -- The same global and type again is a probe hit, not a creation.
                        ( _, reg2 ) =
                            Registry.getOrCreateSpecId g Mono.MInt reg1

                        -- A second type for the same global creates a second spec.
                        ( _, reg3 ) =
                            Registry.getOrCreateSpecId g Mono.MString reg2
                    in
                    Expect.equal ( 1, 1, 2 )
                        ( Registry.createdCount g reg1
                        , Registry.createdCount g reg2
                        , Registry.createdCount g reg3
                        )
            ]
        , Test.describe "poly-rec cycle trips the watchdogs (plan §1.1 repro)"
            [ Test.test "solver: breadth limit → clean LimitExceeded" <|
                \() ->
                    Pipeline.runSolverMonoWithLimits
                        { specTypeNodes = 0, specBreadth = 8 }
                        Config.defaultLss
                        polyRecModule
                        |> expectErrContaining
                            [ "specialization budget exceeded"
                            , "ECO_SPEC_BREADTH_LIMIT"
                            ]
            , Test.test "solver: type-node limit → clean LimitExceeded" <|
                \() ->
                    Pipeline.runSolverMonoWithLimits
                        { specTypeNodes = 40, specBreadth = 0 }
                        Config.defaultLss
                        polyRecModule
                        |> expectErrContaining
                            [ "specialization type too large"
                            , "ECO_SPEC_TYPE_NODE_LIMIT"
                            ]
            , Test.test "subst: breadth limit → clean Err (drain-level check)" <|
                \() ->
                    Pipeline.runSubstMonoWithLimits
                        { specTypeNodes = 0, specBreadth = 8 }
                        polyRecModule
                        |> expectErrContaining
                            [ "specialization budget exceeded"
                            , "ECO_SPEC_BREADTH_LIMIT"
                            ]
            , Test.test "benign module passes with tiny limits (no false positive)" <|
                \() ->
                    case
                        Pipeline.runSolverMonoWithLimits
                            { specTypeNodes = 200, specBreadth = 8 }
                            Config.defaultLss
                            benignModule
                    of
                        Ok _ ->
                            Expect.pass

                        Err msg ->
                            Expect.fail ("benign module tripped a watchdog: " ++ msg)
            ]
        ]


{-| Returns an expectation that `result` is an `Err` whose message contains
every one of `needles`.

When the message lacks a needle, the failure names the missing needles and
shows the message. An `Ok` fails with a fixed message. An `Err` from a stage
before monomorphization, such as a type error, fails it too, unless its
message happens to contain every needle.

-}
expectErrContaining : List String -> Result String a -> Expectation
expectErrContaining needles result =
    case result of
        Ok _ ->
            Expect.fail "expected the watchdog to trip, but monomorphization succeeded"

        Err msg ->
            case List.filter (\n -> not (String.contains n msg)) needles of
                [] ->
                    Expect.pass

                missing ->
                    Expect.fail
                        ("watchdog message missing "
                            ++ String.join ", " missing
                            ++ "\n--- got ---\n"
                            ++ msg
                        )



-- ====== FIXTURES ======


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

The test pipeline adds a `main` that uses `testValue`, which is what makes
`depth` reachable. `depth` at `Nested a` demands `helper` at the same `a`,
which demands `depth` at `Nested (List a)`, and so on with one more `List`
each time.

-}
polyRecModule : Src.Module
polyRecModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ depthDef, helperDef, mainDef ]
        [ nestedUnion ]
        []


{-| The declaration of `Nested`, whose `Deeper` constructor holds a `Nested`
of lists of its own parameter. That non-regular recursion is what lets the
demanded types keep growing.
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


{-| The definition of `depth : Nested a -> Int`, which hands the tail of a
`Deeper` to `helper`.
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


{-| The definition of `helper : Nested (List a) -> Int`, which calls `depth`
on its argument.
-}
helperDef : TypedDef
helperDef =
    { name = "helper"
    , args = [ pVar "n" ]
    , tipe = tLambda (tType "Nested" [ tType "List" [ tVar "a" ] ]) (tType "Int" [])
    , body = callExpr (varExpr "depth") [ varExpr "n" ]
    }


{-| The definition of `testValue : Int`, which calls `depth` on
`Deeper 1 Nil`. Despite its name it defines `testValue`, not `main`.
-}
mainDef : TypedDef
mainDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body = callExpr (varExpr "depth") [ callExpr (ctorExpr "Deeper") [ intExpr 1, ctorExpr "Nil" ] ]
    }


{-| A module `Test` whose only definition is `testValue : Int`, equal to `42`.
-}
benignModule : Src.Module
benignModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = intExpr 42
          }
        ]
        []
        []
