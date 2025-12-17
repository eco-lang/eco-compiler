module API.Format exposing (run)

{-| Format Elm source code according to the standard style guide. This module
provides a programmatic interface to the Elm formatter, parsing source code and
pretty-printing it with consistent indentation, spacing, and line breaks.


# Formatting

@docs run

-}

import Common.Format
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as M
import Compiler.Parse.SyntaxVersion as SV



-- RUN


run : String -> Result String String
run src =
    Common.Format.format SV.Guida (M.Package Pkg.core) src
        |> Result.mapError
            (\_ ->
                -- FIXME missings errs
                "Something went wrong..."
            )
