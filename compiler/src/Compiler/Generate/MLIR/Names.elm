module Compiler.Generate.MLIR.Names exposing (canonicalToMLIRName, sanitizeName)

{-| Elm names become parts of MLIR symbol names, and this module rewrites them
for that place: dots in module names become underscores, and fourteen
punctuation characters are spelled out as words.

An MLIR symbol is the name of a function or global, written after `@` where it
is referred to. This compiler prints those references without quoting, so a
symbol name has to be a bare MLIR identifier, which cannot hold punctuation such
as `+` or `<`.

The two functions here rewrite the two Elm parts that go into such a name: the
module it belongs to, and the name within it. Neither mapping is one to one.
Underscores already in a name are kept, so `a+b` and `a_plus_b` give the same
string, and the package a module belongs to is dropped.

@docs canonicalToMLIRName, sanitizeName

-}

import Compiler.Elm.ModuleName as ModuleName


{-| Returns the module's raw name with every `.` replaced by `_`, so
`Html.Attributes` becomes `Html_Attributes`. The package is ignored.
-}
canonicalToMLIRName : ModuleName.Canonical -> String
canonicalToMLIRName (ModuleName.Canonical _ moduleName) =
    moduleName
        |> String.replace "." "_"


{-| Returns `name` with each of `+ - * / < > = & | ! ? : . $` spelled out as a
word between underscores, such as `_plus_` for `+` and `_dollar_` for `$`.

A name made only of letters, digits and `_` is returned unchanged. Any other
character is left as it is. The result contains none of the fourteen characters
above.

-}
sanitizeName : String -> String
sanitizeName name =
    if String.all (\c -> Char.isAlphaNum c || c == '_') name then
        name

    else
        name
            |> String.replace "+" "_plus_"
            |> String.replace "-" "_minus_"
            |> String.replace "*" "_star_"
            |> String.replace "/" "_slash_"
            |> String.replace "<" "_lt_"
            |> String.replace ">" "_gt_"
            |> String.replace "=" "_eq_"
            |> String.replace "&" "_amp_"
            |> String.replace "|" "_pipe_"
            |> String.replace "!" "_bang_"
            |> String.replace "?" "_question_"
            |> String.replace ":" "_colon_"
            |> String.replace "." "_dot_"
            |> String.replace "$" "_dollar_"
