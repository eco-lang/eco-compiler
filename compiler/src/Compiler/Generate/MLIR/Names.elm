module Compiler.Generate.MLIR.Names exposing
    ( canonicalToMLIRName
    , sanitizeName
    )

{-| MLIR symbol naming utilities.

This module provides functions for converting Elm names to MLIR-safe identifiers.

-}

import System.TypeCheck.IO as IO


{-| Convert an IO.Canonical name to an MLIR-safe string.
Replaces dots with underscores.
-}
canonicalToMLIRName : IO.Canonical -> String
canonicalToMLIRName (IO.Canonical _ moduleName) =
    moduleName
        |> String.replace "." "_"


{-| Sanitize a name by escaping special characters for MLIR.
-}
sanitizeName : String -> String
sanitizeName name =
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
