module Compiler.Generate.HtmlLeadingLinesTest exposing (suite)

{-| SD-15: `Compiler.Generate.Html.leadingLines` (2) is the shift applied to
source-map generated lines when the JavaScript is embedded by `Html.sandwich`.
The page puts 14 lines before the first line of JavaScript, but the source map
travels inside the inline `<script>` (a `//# sourceMappingURL=` comment at the
end of the JavaScript), and an inline script's source map is resolved against
the script's own text, which starts right after `<script>`. Within that text
the JavaScript is preceded by exactly two lines: the empty remainder of the
`<script>` line and `try {`. So 2 is the right shift; the "does not match the
page" remark in the `leadingLines` doc compares against the wrong origin.

This test pins that relationship: `leadingLines` must equal the number of line
breaks between the end of the `<script>` tag and the first character of the
embedded JavaScript. It passes today, and fails if either the sandwich or the
constant changes without the other.

-}

import Compiler.Generate.Html as Html
import Expect
import Test exposing (Test, describe, test)


marker : String
marker =
    "/*SD15-FIRST-JS-LINE*/"


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
