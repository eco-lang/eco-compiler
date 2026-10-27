module Compiler.Generate.HtmlLeadingLinesTest exposing (suite)

{-| Without this test, `Compiler.Generate.Html.sandwich` could gain or lose a
line before the embedded JavaScript while `Html.leadingLines` stayed the same,
and every source-map line for a generated HTML page would be off by the
difference without anything failing.

`leadingLines` counts lines from the end of the `<script>` tag, not from the top
of the page; why that is the right origin is stated in its docstring in
`Compiler.Generate.Html`. This test checks the count against that origin.

The fixture is one call to `sandwich` with the module name `"Main"` and a
JavaScript text whose first line is `marker` and whose second line is
`var x = 1;`.

  - The one test takes the text between the first `<script>` in the page and
    `marker`, and expects the number of `\n` characters in it to equal
    `leadingLines`. It fails with a message instead if the page has no
    `<script>` followed by `marker`.

Among what is not tested: the lines of the page above the `<script>` tag, the
rest of the page after the JavaScript, and any source map itself.

-}

import Compiler.Generate.Html as Html
import Expect
import Test exposing (Test, describe, test)


{-| A JavaScript comment used as the first line of the embedded JavaScript, so
that the test can find where that JavaScript starts in the page.
-}
marker : String
marker =
    "/*SD15-FIRST-JS-LINE*/"


{-| Checks that `Html.leadingLines` equals the number of line breaks between the
first `<script>` tag of a sandwiched page and the start of the embedded
JavaScript.
-}
suite : Test
suite =
    describe "SD-15: Html.leadingLines matches the lines before the JS inside <script>"
        [ test "leadingLines == newlines between <script> and the first JS line" <|
            \_ ->
                let
                    page =
                        Html.sandwich "Main" (marker ++ "\nvar x = 1;")

                    afterScriptTag =
                        case String.split "<script>" page of
                            _ :: rest :: _ ->
                                rest

                            _ ->
                                ""

                    beforeJs =
                        case String.split marker afterScriptTag of
                            prefix :: _ :: _ ->
                                Just prefix

                            _ ->
                                Nothing
                in
                case beforeJs of
                    Nothing ->
                        Expect.fail "sandwich output has no <script> followed by the JavaScript"

                    Just prefix ->
                        String.indices "\n" prefix
                            |> List.length
                            |> Expect.equal Html.leadingLines
        ]
