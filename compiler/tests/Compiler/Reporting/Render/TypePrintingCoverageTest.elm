module Compiler.Reporting.Render.TypePrintingCoverageTest exposing (suite)

{-| Checks `Compiler.Reporting.Render.Type.Localizer.fromNames`: a localizer
built from a set of module names writes the types of those modules
unqualified, and qualifies the types of other modules.

The reports that print a type other than through the type checker's error
types, which this module also rendered once, are now cases of the negative
catalogue: the `ALIAS PROBLEM` reports of recursive aliases, printed by
`Compiler.Reporting.Render.Type.srcToDoc`, in `SourceIR.CanonicalizeFailsCases`,
and the `BAD MAIN TYPE` and `BAD MAIN` reports, printed by `canToDoc`, in
`SourceIR.MainFailsCases`. `TestLogic.Reporting.ExpectedRejectionTest` checks
their titles and the types they print.

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Dict
import Expect
import Test exposing (Test)


{-| The localizer tests, under a label that contains "coverage run" so that the
coverage loop's quick run includes them.
-}
suite : Test
suite =
    Test.describe "Type printing in reports (coverage run)"
        [ localizerTests ]


{-| `fromNames` writes the types of the named modules unqualified and
qualifies the types of other modules.
-}
localizerTests : Test
localizerTests =
    let
        localizer =
            Localizer.fromNames (Dict.fromList [ ( "Maybe", () ) ])
    in
    Test.describe "Localizer.fromNames"
        [ Test.test "a type of a named module is unqualified" <|
            \_ -> Expect.equal "Maybe" (Localizer.toChars localizer ModuleName.maybe "Maybe")
        , Test.test "a type of another module is qualified" <|
            \_ -> Expect.equal "Tuple.Pair" (Localizer.toChars localizer ModuleName.tuple "Pair")
        ]
