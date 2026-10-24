module Compiler.Generate.Html exposing (sandwich, leadingLines)

{-| Turns a compiled program into a single HTML page that a browser can open
directly.

The page carries the whole generated JavaScript in one inline `<script>`, and
then starts the program of one module by calling `Elm.<module>.init` with the
page's `<pre id="elm">` element as its node. If running the script or
starting the program throws, the page puts an "Initialization Error" heading
above that element, shows the error's text inside it, and throws the error
again.

Because the JavaScript sits inside the page rather than at the top of a file of
its own, line numbers in a source map made for it need shifting by the lines of
page above it. `leadingLines` is the shift this module supplies for that.

@docs sandwich, leadingLines

-}

import Compiler.Data.Name exposing (Name)


{-| The number of lines by which source-map line numbers are shifted when the
JavaScript is placed in the page `sandwich` builds.

It is 2. The page puts 14 lines before the first line of JavaScript, but the
source map travels inside the inline `<script>` (the `//# sourceMappingURL=`
comment at the end of the JavaScript), and an inline script's source map is
taken to count lines from the script's own text, which starts right after
`<script>`. In that text two lines come before the JavaScript: the empty rest
of the `<script>` line and `try {`. `HtmlLeadingLinesTest` keeps the two in
step. That browsers count from the script's text this way was reasoned from
how inline scripts are compiled, not checked in a browser (none was available
when this was written).

-}
leadingLines : Int
leadingLines =
    2


{-| Returns the HTML page that runs `javascript` and then starts the program
of the module named `moduleName`, with `moduleName` also as the page's title.

`javascript` must define `Elm.<moduleName>` with an `init` function, which
nothing here checks; if it does not, the page shows the resulting error as an
initialization error. `moduleName` is inserted as it is, without escaping.

-}
sandwich : Name -> String -> String
sandwich moduleName javascript =
    """<!DOCTYPE HTML>
<html>
<head>
  <meta charset="UTF-8">
  <title>""" ++ moduleName ++ """</title>
  <style>body { padding: 0; margin: 0; }</style>
</head>

<body>

<pre id="elm"></pre>

<script>
try {
""" ++ javascript ++ """

  var app = Elm.""" ++ moduleName ++ """.init({ node: document.getElementById("elm") });
}
catch (e)
{
  // display initialization errors (e.g. bad flags, infinite recursion)
  var header = document.createElement("h1");
  header.style.fontFamily = "monospace";
  header.innerText = "Initialization Error";
  var pre = document.getElementById("elm");
  document.body.insertBefore(header, pre);
  pre.innerText = e;
  throw e;
}
</script>

</body>
</html>"""
