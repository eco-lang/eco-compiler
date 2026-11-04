module TestLogic.Type.CachedTypeInfoTest exposing (suite)

{-| Tests invariant CANON\_006 on the standard catalogue of test programs: the
type information type checking records for a module's top-level definitions
covers every definition and agrees with the module's source.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Type.CachedTypeInfo.expectTypeInfoCached`, which runs it through
PostSolve with `TestLogic.TestPipeline.runToPostSolve`. For each program the
test establishes, as that module's docstring states in full:

  - it canonicalizes and type checks;
  - every top-level definition, recursive groups included, has an entry in
    the annotations the solver returns, and that annotation is closed;
  - an annotated definition's recorded type is its written type, with aliases
    expanded, up to a consistent renaming of type variables.

The catalogue includes `SourceIR.CachedTypeInfoCases`, the programs this check
was first written for.

"Unannotated recursive groups" pins a fixed compiler bug: in `f x = g x` and
`g x = f x`, type checking gave `f` the annotation `forall a b. a -> b` but
`g` the type `a -> b` with no quantified variable, and with a third member `h`
gave `h` only `a`. `Compiler.Type.Type.toAnnotation` runs on each member of the
recursive group in turn, and its `getVarNames` walk skips the variables the
earlier member's walk marked (`getVarNamesMark`), so their names never entered
the quantified set of a later member. Stock Elm 0.19.1 has the same bug, and
crashes when another module uses such a later member.

Among what is not tested: the type of an unannotated definition beyond its
being closed, and type information saved to or read back from disk.

It also runs over the programs of `SourceIR.MainFailsCases`, which typed
optimization rejects, and those of `SourceIR.MonoFailsCases`
(`expectBeforeMonoSuite`), which monomorphization rejects: every stage this
check looks at accepts them, and they hold what the standard catalogue cannot,
such as polymorphic recursion over a non-regular type.

-}

import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Expect exposing (Expectation)
import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.CachedTypeInfo exposing (expectTypeInfoCached)


{-| `expectTypeInfoCached` over every program of the standard catalogue, and
over the unannotated recursive groups.
-}
suite : Test
suite =
    Test.describe "Cached type info matches source (CANON_006)"
        [ StandardTestSuites.expectSuite expectTypeInfoCached "has type info matching its source"
        , MainFailsCases.expectSuite expectTypeInfoCached "has type info matching its source"
        , MonoFailsCases.expectBeforeMonoSuite expectTypeInfoCached "has type info matching its source"
        , Test.describe "Unannotated recursive groups"
            [ Test.test "a group of two" <|
                \_ -> runSource expectTypeInfoCached "f x =\n    g x\n\n\ng x =\n    f x\n"
            , Test.test "a group of three" <|
                \_ -> runSource expectTypeInfoCached "f x =\n    g x\n\n\ng x =\n    h x\n\n\nh x =\n    f x\n"
            ]
        ]


{-| Runs `expectFn` on the module `Test` whose declarations are `body`, parsed
as a module of elm/core importing `Basics`, or fails when it does not parse.
-}
runSource : (Src.Module -> Expectation) -> String -> Expectation
runSource expectFn body =
    case Parse.fromByteString (Parse.Package Pkg.core) ("module Test exposing (..)\n\nimport Basics exposing (..)\n\n\n" ++ body) of
        Ok modul ->
            expectFn modul

        Err _ ->
            Expect.fail ("fixture does not parse:\n" ++ body)
