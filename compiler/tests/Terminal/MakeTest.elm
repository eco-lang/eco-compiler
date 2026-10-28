module Terminal.MakeTest exposing (suite)

{-| Regression test for Terminal.Make.parseOutput: `hasExt` requires a
non-empty base name, so an `--output` of just `.js`, `.html` or `.mlir` once
failed every extension check and fell through to a native ELF target. Such a
name is now rejected.
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
