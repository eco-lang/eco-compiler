module Compiler.PackageCompilationTest exposing (suite)

{-| Checks that the source text of elm/core's `Elm.JsArray` and `Array` modules
parses, compiles and goes on through monomorphization to MLIR. These are the
only tests in this elm-test suite that compile these two modules from their
source text.

The work is done by `Compiler.PackageCompilation`, whose docstrings own what
follows. It compiles a module on two _pathways_: the erased one, which feeds
the JavaScript back end, and the typed one, which feeds monomorphization. A
module compiles when both pathways type-check and optimize it; any
`CompileError` fails the test that asked for it.

The fixture is the source text of `Elm.JsArray`, from
`Compiler.Elm.Source.JsArray`, whose functions are bound to kernel values of
`Elm.Kernel.JsArray`, and of `Array`, from `Compiler.Elm.Source.Array`, which
imports `Elm.JsArray`, `Basics`, `Bitwise`, `List`, `Maybe` and `Tuple`. Both
are compiled as modules of elm/core (`Pkg.core`), against
`testIfaces`. Where `Array` is compiled it is compiled after
`Elm.JsArray` with `compileModulesInOrder`, which adds the compiled
`Elm.JsArray` interface to the interfaces `Array` is compiled against.

The tests establish:

  - `parseModule` accepts the `Elm.JsArray` source, and the parsed module is
    named `Elm.JsArray`.
  - `compileModule` compiles `Elm.JsArray`, and the result is named
    `Elm.JsArray` and has at least one annotation.
  - `parseModule` accepts the `Array` source, and the parsed module is named
    `Array`.
  - Compiling `Elm.JsArray` then `Array` succeeds and gives results named
    `Elm.JsArray` and `Array`, in that order.
  - The `Array` result's annotations include `repeat`, `push` and `map`.
  - Compiling `Array` on its own, against the mock `Elm.JsArray` (which lacks
    functions `Array` uses), fails in canonicalization, so the in-order
    compilation succeeding shows `Array` was compiled against the compiled
    `Elm.JsArray` interface.
  - Both pathways infer the same annotations for each module (checked by
    `compileModule` itself).
  - `monomorphize` succeeds from each of the `Elm.JsArray` values in
    `jsArrayEntries`, and, over both compiled modules, from each of the `Array`
    values in `arrayEntries`.
  - `generateMLIRFromResult` from `Elm.JsArray.initializeFromList` gives MLIR
    with a function for that entry, and from `Array.fromList` (over both
    modules) gives MLIR with functions for `fromList`, `fromListHelp`,
    `builderToArray` and `treeFromBuilder`.

Among what is not tested: the types in any annotation, only the presence of
names; anything in the MLIR beyond those function names; the CSE, CAF dedupe
and hoisting steps of the build, which `generateMLIRFromResult` does not run;
and any source that fails to compile.

-}

import Compiler.AST.Source as Src
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Source.Array as ArraySource
import Compiler.Elm.Source.JsArray as JsArraySource
import Compiler.PackageCompilation as PC
import Dict exposing (Dict)
import Expect
import Test exposing (Test)


{-| The interfaces every module here is compiled against, keyed by module name:
`Compiler.Elm.Interface.Basic.testIfaces`, which already holds `Bitwise` and
`Tuple`. It also holds a mock `Elm.JsArray`, which `compileModulesInOrder`
replaces with the compiled one before compiling `Array`.
-}
testIfaces : Dict ModuleName.Raw I.Interface
testIfaces =
    Basic.testIfaces


{-| The tests of this module, in five groups.
-}
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


{-| The tests that parse the `Elm.JsArray` source and check the parsed module's
name.
-}
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


{-| The tests that compile the `Elm.JsArray` source on its own and check the
result's module name and that it has annotations.
-}
jsArrayCompilationTests : Test
jsArrayCompilationTests =
    Test.describe "JsArray.elm compilation"
        [ Test.test "compiles JsArray.elm successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core testIfaces srcModule of
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
                        case PC.compileModule Pkg.core testIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                if Dict.isEmpty result.annotations then
                                    Expect.fail "No annotations produced"

                                else
                                    Expect.pass
        ]



-- ============================================================================
-- ARRAY PARSING TESTS
-- ============================================================================


{-| The tests that parse the `Array` source and check the parsed module's name.
-}
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


{-| The tests that compile `Elm.JsArray` then `Array` with
`compileModulesInOrder` and check the results' names and order and that
`Array` has annotations for `repeat`, `push` and `map`.
-}
multiModuleCompilationTests : Test
multiModuleCompilationTests =
    Test.describe "Multi-module compilation"
        [ Test.test "JsArray then Array compiles in dependency order" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        testIfaces
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
                        testIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                let
                                    hasRepeat =
                                        Dict.member "repeat" arrayResult.annotations

                                    hasPush =
                                        Dict.member "push" arrayResult.annotations

                                    hasMap =
                                        Dict.member "map" arrayResult.annotations
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
        , Test.test "Array.elm needs the compiled JsArray interface, not the mock" <|
            \() ->
                -- Compiled alone, `Array` sees only the mock `Elm.JsArray`, which
                -- lacks functions `Array` uses (`unsafeGet`, `initialize`, ...),
                -- so canonicalization must fail. The in-order compilation above
                -- succeeding therefore shows `Array` was compiled against the
                -- compiled `Elm.JsArray` interface.
                case PC.parseModule Pkg.core ArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core testIfaces srcModule of
                            Err (PC.CanonicalizeError _) ->
                                Expect.pass

                            Err err ->
                                Expect.fail ("expected a canonicalization error, got: " ++ PC.errorToString err)

                            Ok _ ->
                                Expect.fail "Array compiled against the mock Elm.JsArray, which lacks functions it uses"
        ]


{-| Returns `"true"` or `"false"`, for a failure message.
-}
boolToString : Bool -> String
boolToString b =
    if b then
        "true"

    else
        "false"



-- ============================================================================
-- TYPED PATHWAY TESTS - Monomorphization and MLIR
-- ============================================================================


{-| The tests that carry a compiled module's typed graph on through
monomorphization and MLIR generation, for `Elm.JsArray` compiled on its own and
for `Array` compiled after it. For each module, one test checks that
`monomorphize` succeeds and another that `generateMLIRFromResult` gives
non-empty text containing `func.func` or `eco.`.
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
                        case PC.compileModule Pkg.core testIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                expectMonomorphizeAll [ result ] jsArrayEntries
        , Test.test "JsArray.elm typed path generates MLIR successfully" <|
            \() ->
                case PC.parseModule Pkg.core JsArraySource.source of
                    Err err ->
                        Expect.fail ("Parse failed: " ++ PC.errorToString (PC.ParseError err))

                    Ok srcModule ->
                        case PC.compileModule Pkg.core testIfaces srcModule of
                            Err err ->
                                Expect.fail ("Compile failed: " ++ PC.errorToString err)

                            Ok result ->
                                case PC.generateMLIRFromResult "initializeFromList" [ result ] of
                                    Err err ->
                                        Expect.fail ("MLIR generation failed: " ++ PC.errorToString err)

                                    Ok mlirOutput ->
                                        if String.isEmpty mlirOutput then
                                            Expect.fail "MLIR output is empty"

                                        else if not (String.contains "sym_name = \"Elm_JsArray_initializeFromList_$_" mlirOutput) then
                                            Expect.fail "MLIR output has no function for the entry Elm.JsArray.initializeFromList"

                                        else
                                            Expect.pass
        , Test.test "Array.elm typed path monomorphizes successfully" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        testIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                expectMonomorphizeAll results arrayEntries

                            _ ->
                                Expect.fail "Array module not found in results"
        , Test.test "Array.elm typed path generates MLIR successfully" <|
            \() ->
                case
                    PC.compileModulesInOrder Pkg.core
                        testIfaces
                        [ JsArraySource.source
                        , ArraySource.source
                        ]
                of
                    Err ( err, moduleName ) ->
                        Expect.fail (moduleName ++ ": " ++ PC.errorToString err)

                    Ok results ->
                        case List.filter (\r -> r.moduleName == "Array") results of
                            [ arrayResult ] ->
                                case PC.generateMLIRFromResult "fromList" results of
                                    Err err ->
                                        Expect.fail ("Array MLIR generation failed: " ++ PC.errorToString err)

                                    Ok mlirOutput ->
                                        if String.isEmpty mlirOutput then
                                            Expect.fail "MLIR output is empty"

                                        else if not (List.all (\f -> String.contains ("sym_name = \"Array_" ++ f ++ "_$_") mlirOutput) [ "fromList", "fromListHelp", "builderToArray", "treeFromBuilder" ]) then
                                            Expect.fail "MLIR output lacks a function for Array.fromList or one of the Array functions it calls"

                                        else
                                            Expect.pass

                            _ ->
                                Expect.fail "Array module not found in results"
        ]


{-| The `Elm.JsArray` values the monomorphization test starts from, one run
each.
-}
jsArrayEntries : List String
jsArrayEntries =
    [ "initializeFromList", "foldl", "map", "slice", "appendN" ]


{-| The `Array` values the monomorphization test starts from, one run each.
Between them they reach most of the module: building from a list, indexing,
updating, pushing, folding, mapping, appending and slicing.
-}
arrayEntries : List String
arrayEntries =
    [ "fromList", "initialize", "get", "set", "push", "foldl", "map", "indexedMap", "append", "slice", "toIndexedList", "filter" ]


{-| Passes when `PC.monomorphize` succeeds from each of `entries`, and fails
naming every entry it failed from.
-}
expectMonomorphizeAll : List PC.CompileResult -> List String -> Expect.Expectation
expectMonomorphizeAll results entries =
    let
        failures =
            List.filterMap
                (\entry ->
                    case PC.monomorphize entry results of
                        Ok _ ->
                            Nothing

                        Err err ->
                            Just (entry ++ ": " ++ PC.errorToString err)
                )
                entries
    in
    Expect.equal [] failures
