module Common.Format exposing (format)

{-| The built-in Elm source formatter: it turns the text of a module into the
same module laid out in one standard style.

It reuses the compiler's own module parser rather than having one of its own,
and then prints the parsed module through the formatter's layout engine. A
layout is a `Common.Format.Box.Box`, built by `Common.Format.Render.Box` and
turned into text by `Common.Format.Box.render`.

Only parsing is done. The effect rules that the compiler checks after parsing
are not checked, so a module that parses is formatted even if it would not
compile.


# Formatting

@docs format

-}

import Common.Format.Box as Box
import Common.Format.Render.Box as Render
import Compiler.Parse.Module as M
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Error.Syntax as E


{-| Returns `src`, a module of a project of `projectType`, reformatted.

The whole of `src` must parse as a module. A parse failure gives the parser's
error, and text left over after the last declaration that could be read gives
`E.ModuleBadEnd` at the row and column where reading stopped.

-}
format : M.ProjectType -> String -> Result E.Module String
format projectType src =
    P.fromByteString (M.chompModule projectType) E.ModuleBadEnd src
        |> Result.map render


{-| Returns the text of `modu`, with a newline appended.

A module without a `module` line is given `module Main exposing (...)`, and
the usual spacing between top-level declarations is two blank lines.

-}
render : M.Module -> String
render modu =
    Box.render (Render.formatModule True 2 modu) ++ "\n"
