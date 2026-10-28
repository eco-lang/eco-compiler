module Terminal.MakeTest exposing (suite)

{-| Regression test for Terminal.Make.parseOutput: `hasExt` requires a
non-empty base name, so an `--output` of just `.js`, `.html` or `.mlir` fails
every extension check and falls through to a native ELF target instead of being
rejected.

EXPECTED TO FAIL until the bug is fixed.

-}

import Expect
import Terminal.Make as Make
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Terminal.Make.parseOutput rejects a bare extension"
        (List.map
            (\name ->
                test name <|
                    \_ ->
                        Make.parseOutput name
                            |> Expect.equal Nothing
            )
            [ ".js", ".html", ".mlir" ]
        )
