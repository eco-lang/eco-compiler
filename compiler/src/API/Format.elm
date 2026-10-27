module API.Format exposing (run)

{-| The `format` command of the JSON API, reduced to one call from a source
string to formatted text or a message.

`run` hands the source to `Common.Format.format`, which owns the parsing and
layout rules. Every source is read as a module of the package `elm/core`, never
as an application module. The parser's error is not passed on: any failure
becomes the same fixed message, so a caller cannot say where formatting failed.


# Formatting

@docs run

-}

import Common.Format
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as M



-- ====== RUN ======


{-| Returns `src` reformatted, read as a module of the package `elm/core`, or
`"Something went wrong..."` if it does not parse. The parser's error is dropped.
-}
run : String -> Result String String
run src =
    Common.Format.format (M.Package Pkg.core) src
        |> Result.mapError
            (\_ ->
                "Something went wrong..."
            )
