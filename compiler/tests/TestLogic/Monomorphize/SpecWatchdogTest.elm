module TestLogic.Monomorphize.SpecWatchdogTest exposing (suite)

{-| MONO_030 spec watchdogs
(`plans/lss-fidelity-1-watchdogs-budget-accounting.md` §1).

The poly-rec fixture is the plan §1.1 repro: an ANNOTATED, MUTUALLY RECURSIVE
cycle over a non-regular type. This is legal Elm — only SELF-recursion is
rejected (a def's own annotation is not a scheme for its own body); each
member of an annotated cycle sees the OTHER members' annotations as
generalized schemes — and its mono demand chain
`Nested Int → Nested (List Int) → …` never terminates. Without the watchdogs
BOTH engines diverge on it (verified natively 2026-08-18: `eco make` to MLIR
hangs until killed); with tiny limits they must fail loudly with the shared
`Registry` message instead.

Limits are chosen so exactly one check can trip per test: `specBreadth = 8`
with the node check disabled, and `specTypeNodes = 40` with the breadth
check disabled (the demand type at round k is `Nested (List^k Int) -> Int`,
≈ k+4 nodes, so the depth arm trips after a few dozen fast rounds).
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
import Compiler.Monomorphize.Registry as Registry
import Dict
import Expect exposing (Expectation)
import System.TypeCheck.IO as IO
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


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
                            Mono.Global (IO.Canonical ( "eco", "example" ) "Test") "f"

                        ( _, reg1 ) =
                            Registry.getOrCreateSpecId g Mono.MInt Registry.emptyRegistry

                        -- Same key again: a HIT — count must not move.
                        ( _, reg2 ) =
                            Registry.getOrCreateSpecId g Mono.MInt reg1

                        -- New type: a second CREATED spec for the same global.
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


{-| The §1.1 repro, DSL form:

    type Nested a = Nil | Deeper a (Nested (List a))

    depth : Nested a -> Int
    depth n = case n of
        Nil -> 0
        Deeper _ rest -> helper rest

    helper : Nested (List a) -> Int
    helper n = depth n

    testValue : Int
    testValue = depth (Deeper 1 Nil)

(`testValue` is the SourceIR test standard's root — the harness synthesizes
`main` around it. The `1 +` of the plan's source-file fixture is dropped —
only the demand chain matters, not the arithmetic.)
-}
polyRecModule : Src.Module
polyRecModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ depthDef, helperDef, mainDef ]
        [ nestedUnion ]
        []


nestedUnion : UnionDef
nestedUnion =
    { name = "Nested"
    , args = [ "a" ]
    , ctors =
        [ { name = "Nil", args = [] }
        , { name = "Deeper", args = [ tVar "a", tType "Nested" [ tType "List" [ tVar "a" ] ] ] }
        ]
    }


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


helperDef : TypedDef
helperDef =
    { name = "helper"
    , args = [ pVar "n" ]
    , tipe = tLambda (tType "Nested" [ tType "List" [ tVar "a" ] ]) (tType "Int" [])
    , body = callExpr (varExpr "depth") [ varExpr "n" ]
    }


mainDef : TypedDef
mainDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body = callExpr (varExpr "depth") [ callExpr (ctorExpr "Deeper") [ intExpr 1, ctorExpr "Nil" ] ]
    }


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
