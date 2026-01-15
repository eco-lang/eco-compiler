module Compiler.PackageCompilationTest exposing (suite)

{-| Tests for compiling elm/\* package modules from source strings.

These tests verify that modules like Array.elm and JsArray.elm from elm/core
can be compiled correctly, exactly as they would be when used as project
dependencies.

-}

import Compiler.AST.Source as Src
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.Interface.Bitwise as Bitwise
import Compiler.Elm.Interface.Tuple as TupleInterface
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Source.Array as ArraySource
import Compiler.Elm.Source.JsArray as JsArraySource
import Compiler.PackageCompilation as PC
import Data.Map as Dict exposing (Dict)
import Expect
import Test exposing (Test)


{-| Extended test interfaces including Bitwise and Tuple for Array.elm.
-}
extendedTestIfaces : Dict String ModuleName.Raw I.Interface
extendedTestIfaces =
    Basic.testIfaces
        |> Dict.insert identity "Bitwise" Bitwise.bitwiseInterface
        |> Dict.insert identity "Tuple" TupleInterface.tupleInterface


suite : Test
suite =
    Test.describe "Package compilation from source strings"
        [ jsArrayParsingTests
        , jsArrayCompilationTests
        , arrayParsingTests
        , multiModuleCompilationTests
        , typedPathwayTests
        ]



-- ============================================================================
-- JSARRAY PARSING TESTS
-- ============================================================================


jsArrayParsingTests : Test
jsArrayParsingTests =
    Test.describe "JsArray.elm parsing"
        [ Test.test "parses JsArray.elm source successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Ok _ ->
                        Expect.pass

                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))
        , Test.test "parsed module has correct name" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Ok srcModule ->
                        Expect.equal (Src.getName srcModule) "Elm.JsArray"

                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))
        ]



-- ============================================================================
-- JSARRAY COMPILATION TESTS
-- ============================================================================


jsArrayCompilationTests : Test
jsArrayCompilationTests =
    Test.describe "JsArray.elm compilation"
        [ Test.test "compiles JsArray.elm successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core extendedTestIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                Expect.equal result.moduleName "Elm.JsArray"
        , Test.test "JsArray.elm compilation produces annotations" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core extendedTestIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                -- Check that we have some annotations
                                if Dict.isEmpty result.annotations then
                                    Expect.fail "No annotations produced"

                                else
                                    Expect.pass
        ]



-- ============================================================================
-- ARRAY PARSING TESTS
-- ============================================================================


arrayParsingTests : Test
arrayParsingTests =
    Test.describe "Array.elm parsing"
        [ Test.test "parses Array.elm source successfully" <|
            \() ->
                case PC.parseModule Pkg.core ArraySource.source of
                    Ok _ ->
                        Expect.pass

                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))
        , Test.test "parsed Array module has correct name" <|
            \() ->
                case PC.parseModule Pkg.core ArraySource.source of
                    Ok srcModule ->
                        Expect.equal (Src.getName srcModule) "Array"

                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))
        ]



-- ============================================================================
-- MULTI-MODULE COMPILATION TESTS
-- ============================================================================


multiModuleCompilationTests : Test
multiModuleCompilationTests =
    Test.describe "Multi-module compilation"
        [ Test.test "JsArray then Array compiles in dependency order" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        extendedTestIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        results
                            |> List.map .moduleName
                            |> Expect.equal [ "Elm.JsArray", "Array" ]
        , Test.test "Array.elm compilation produces interface" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        extendedTestIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                -- Verify Array exports exist by checking annotations
                                let
                                    hasRepeat =
                                        Dict.member identity "repeat" arrayResult.annotations

                                    hasPush =
                                        Dict.member identity "push" arrayResult.annotations

                                    hasMap =
                                        Dict.member identity "map" arrayResult.annotations
                                in
                                if hasRepeat && hasPush && hasMap then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("Missing expected functions. "
                                            ++ "repeat: "
                                            ++ boolToString hasRepeat
                                            ++ ", push: "
                                            ++ boolToString hasPush
                                            ++ ", map: "
                                            ++ boolToString hasMap
                                        )

                            _ ->
                                Expect.fail "Array module not found in results"
        , Test.test "Array.elm uses JsArray interface correctly" <|
            \() ->
                -- This test verifies that the interface threading works:
                -- Array imports JsArray, so JsArray must be compiled first
                -- and its interface added to the environment
                case
                    PC.compileModulesInOrder Pkg.core
                        extendedTestIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        -- If we got here, the interface threading worked
                        Expect.equal (List.length results) 2
        ]


boolToString : Bool -> String
boolToString b =
    if b then
        "true"

    else
        "false"



-- ============================================================================
-- TYPED PATHWAY TESTS - Monomorphization and MLIR
-- ============================================================================


{-| Tests that verify the typed pathway continues through Monomorphization and MLIR generation.

The erased path reaches Optimized, and the typed path reaches TypedOptimized in the
standard compilation tests above. These tests extend the typed path only to verify
it can also pass through Monomorphization and MLIR generation.

If both pathways pass the optimization phase, then the typed path should also pass
its later stages.

-}
typedPathwayTests : Test
typedPathwayTests =
    Test.describe "Typed pathway through Monomorphization and MLIR"
        [ Test.test "JsArray.elm typed path monomorphizes successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core extendedTestIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                -- Both pathways passed optimization, now verify typed path monomorphizes
                                case PC.monomorphize result of
                                    Err err ->
                                        Expect.fail ("Monomorphization failed: " ++ PC.errorToString err)

                                    Ok _ ->
                                        Expect.pass
        , Test.test "JsArray.elm typed path generates MLIR successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core extendedTestIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                case PC.generateMLIRFromResult result of
                                    Err err ->
                                        Expect.fail ("MLIR generation failed: " ++ PC.errorToString err)

                                    Ok mlirOutput ->
                                        if String.isEmpty mlirOutput then
                                            Expect.fail "MLIR output is empty"

                                        else if not (String.contains "func.func" mlirOutput || String.contains "eco." mlirOutput) then
                                            Expect.fail "MLIR output doesn't contain expected operations"

                                        else
                                            Expect.pass
        , Test.test "Array.elm typed path monomorphizes successfully" <|
            \() ->
                -- Array depends on JsArray, so compile both in order
                case
                    PC.compileModulesInOrder Pkg.core
                        extendedTestIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                -- Both pathways passed optimization, now verify typed path monomorphizes
                                case PC.monomorphize arrayResult of
                                    Err err ->
                                        Expect.fail ("Array monomorphization failed: " ++ PC.errorToString err)

                                    Ok _ ->
                                        Expect.pass

                            _ ->
                                Expect.fail "Array module not found in results"
        , Test.test "Array.elm typed path generates MLIR successfully" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        extendedTestIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                case PC.generateMLIRFromResult arrayResult of
                                    Err err ->
                                        Expect.fail ("Array MLIR generation failed: " ++ PC.errorToString err)

                                    Ok mlirOutput ->
                                        if String.isEmpty mlirOutput then
                                            Expect.fail "MLIR output is empty"

                                        else if not (String.contains "func.func" mlirOutput || String.contains "eco." mlirOutput) then
                                            Expect.fail "MLIR output doesn't contain expected operations"

                                        else
                                            Expect.pass

                            _ ->
                                Expect.fail "Array module not found in results"
        ]
