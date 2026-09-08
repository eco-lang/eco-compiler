module Compiler.Generate.MLIR.Names exposing (canonicalToMLIRName, sanitizeName)

{-| MLIR symbol naming utilities.

This module provides functions for converting Elm names to MLIR-safe identifiers.

@docs canonicalToMLIRName, sanitizeName

-}

import Compiler.Elm.ModuleName as ModuleName


{-| Convert an ModuleName.Canonical name to an MLIR-safe string.
Replaces dots with underscores.
-}
canonicalToMLIRName : ModuleName.Canonical -> String
canonicalToMLIRName (ModuleName.Canonical _ moduleName) =
    moduleName
        |> String.replace "." "_"


{-| Sanitize a name by escaping special characters for MLIR.
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
