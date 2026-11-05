module TestLogic.Type.AnnotationVarsDistinctTest exposing (suite)

{-| Tests, on the standard catalogue of test programs, that the annotation of
every top-level definition names each variable of its solved type apart and
quantifies over all of them (`TestLogic.Type.AnnotationVarsDistinct`), as
Hindley-Milner generalization requires.

The catalogue's "recursive group whose later member has a variable of its own"
(`SourceIR.CachedTypeInfoCases`) pins a fixed compiler bug: in the unannotated
group `f x = g x []` and `g x y = f x`, `g : a -> List c -> b` shares `a` and
`b` with `f : a -> b`. `Compiler.Type.Type.toAnnotation` names `f` first and
marks `a` and `b`; its walk for `g` skips them, and their names were not
reserved there, so `g`'s own `c` was named `a` and `g` was annotated
`a -> List a -> b`. Another module's valid `Main.g n [ "s" ]` with `n : Int`
was then rejected (`test/scripts/cli-errors.test.js`).

It also runs over the programs of `SourceIR.MainFailsCases` and those of
`SourceIR.MonoFailsCases` (`expectBeforeMonoSuite`), which type checking
accepts.

-}

import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.AnnotationVarsDistinct exposing (expectAnnotationVarsDistinct)


suite : Test
suite =
    Test.describe "Annotations name every variable of the solved type apart"
        [ StandardTestSuites.expectSuite expectAnnotationVarsDistinct "names its annotations' variables apart"
        , MainFailsCases.expectSuite expectAnnotationVarsDistinct "names its annotations' variables apart"
        , MonoFailsCases.expectBeforeMonoSuite expectAnnotationVarsDistinct "names its annotations' variables apart"
        ]
