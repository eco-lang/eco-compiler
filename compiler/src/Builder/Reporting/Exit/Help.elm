module Builder.Reporting.Exit.Help exposing
    ( Report, report, docReport, jsonReport, compilerReport
    , reportToDoc, reportToJson
    , toStdout, toStderr
    )

{-| Every error the build tool reports is turned into one `Report`, and this
module defines that value and the two ways it leaves the program: as a document
for a person to read, or as a JSON object for a program such as an editor.

A report is one of two kinds. Most are a titled message, optionally about one
file, which this module lays out under a cyan bar of dashes naming the title and
the file. The other kind holds the errors of modules that failed to compile, and
for those the layout and the JSON both come from `Compiler.Reporting.Error`.

The output functions write a document to standard output or standard error, with
its colours as ANSI escape sequences when the program is attached to a
terminal. `System.IO.isTerminal` currently answers `True` whatever is attached,
so in practice the escape sequences are always written.


# Report Construction

@docs Report, report, docReport, jsonReport, compilerReport


# Conversion

@docs reportToDoc, reportToJson


# Output

@docs toStdout, toStderr

-}

import Compiler.Json.Encode as E
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error as Error
import Maybe.Extra as Maybe
import System.IO as IO
import Task exposing (Task)



-- ====== REPORT ======


{-| An error report, ready to be laid out for a terminal or encoded as JSON.

`CompilerReport` holds the project root, against which module paths are shown,
and the failing modules, at least one of them.

`Report` holds a title, the path of the file the error concerns if there is
one, and the message.

-}
type Report
    = CompilerReport String Error.Module (List Error.Module)
    | Report String (Maybe String) D.Doc


{-| Creates a report titled `title` about the file at `path`, if any. The
message is `startString`, filled into a paragraph, followed by `others`, with an
empty line between each part.
-}
report : String -> Maybe String -> String -> List D.Doc -> Report
report title path startString others =
    D.stack (D.reflow startString :: others) |> Report title path


{-| Creates a report as `report` does, but with the opening paragraph given as a
ready-made document `startDoc` rather than a string to be filled.
-}
docReport : String -> Maybe String -> D.Doc -> List D.Doc -> Report
docReport title path startDoc others =
    D.stack (startDoc :: others) |> Report title path


{-| Creates a report from a title, an optional file path and the whole message
as one document. Nothing about it is specific to JSON.
-}
jsonReport : String -> Maybe String -> D.Doc -> Report
jsonReport =
    Report


{-| Creates a report of modules that failed to compile. The first argument is
the project root, against which the modules' paths are shown in the terminal
layout.
-}
compilerReport : String -> Error.Module -> List Error.Module -> Report
compilerReport =
    CompilerReport



-- ====== TO DOC ======


{-| Lays out a report for a terminal.

A titled report becomes a cyan bar, an empty line, the message, and a trailing
empty line. The bar reads `-- TITLE ----- path` and is padded with dashes to
80 columns, with at least one dash however long the title and path are. A report of failing modules
is laid out as `Compiler.Reporting.Error.toDoc` describes.

-}
reportToDoc : Report -> D.Doc
reportToDoc report_ =
    case report_ of
        CompilerReport root e es ->
            Error.toDoc root e es

        Report title maybePath message ->
            let
                makeDashes : Int -> String
                makeDashes n =
                    String.repeat (max 1 (80 - n)) "-"

                errorBarEnd : String
                errorBarEnd =
                    case maybePath of
                        Nothing ->
                            makeDashes (4 + String.length title)

                        Just path ->
                            makeDashes (5 + String.length title + String.length path)
                                ++ " "
                                ++ path

                errorBar : D.Doc
                errorBar =
                    D.dullcyan
                        (D.fromChars "--"
                            |> D.plus (D.fromChars title)
                            |> D.plus (D.fromChars errorBarEnd)
                        )
            in
            D.stack [ errorBar, message, D.fromChars "" ]



-- ====== TO JSON ======


{-| Encodes a report as JSON.

A report of failing modules becomes `{"type": "compile-errors", "errors": [...]}`,
one entry per module as `Compiler.Reporting.Error.toJson` gives it; the project
root is not included. A titled report becomes `{"type": "error", ...}` with its
`path` (`null` when it has none), `title` and `message`, the message encoded as
`Compiler.Reporting.Doc.encode` describes.

-}
reportToJson : Report -> E.Value
reportToJson report_ =
    case report_ of
        CompilerReport _ e es ->
            E.object
                [ ( "type", E.string "compile-errors" )
                , ( "errors", E.list Error.toJson (e :: es) )
                ]

        Report title maybePath message ->
            E.object
                [ ( "type", E.string "error" )
                , ( "path", Maybe.unwrap E.null E.string maybePath )
                , ( "title", E.string title )
                , ( "message", D.encode message )
                ]



-- ====== OUTPUT ======


{-| Writes `doc` to standard output, with ANSI colours if `System.IO.isTerminal`
answers `True` and as plain text otherwise. It currently always answers `True`.
-}
toStdout : D.Doc -> Task Never ()
toStdout doc =
    toHandle IO.stdout doc


{-| Writes `doc` to standard error, with ANSI colours if `System.IO.isTerminal`
answers `True` and as plain text otherwise. It currently always answers `True`.
-}
toStderr : D.Doc -> Task Never ()
toStderr doc =
    toHandle IO.stderr doc


{-| Writes `doc` to `handle`, with ANSI colours if `System.IO.isTerminal`
answers `True` and as plain text otherwise.

The question is not asked about `handle`, and `isTerminal` currently always
answers `True`, so the escape sequences are written even to a file or a pipe.

-}
toHandle : IO.Handle -> D.Doc -> Task Never ()
toHandle handle doc =
    IO.isTerminal
        |> Task.andThen
            (\isTerminal ->
                if isTerminal then
                    D.toAnsi handle doc

                else
                    IO.write handle (D.toString doc)
            )
