module Builder.Reporting.Exit.Help exposing
    ( Report, report, docReport, jsonReport, compilerReport
    , reportToDoc, reportToJson
    , toStdout, toStderr
    )

{-| Helpers for building and outputting error reports from the build system.

This module provides utilities for constructing and rendering error reports,
supporting both human-readable terminal output and JSON serialization for
editor integrations.


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


{-| Represents an error report that can be displayed to the user or serialized to JSON.
-}
type Report
    = CompilerReport String Error.Module (List Error.Module)
    | Report String (Maybe String) D.Doc


{-| Creates a report from a title, optional file path, introductory text, and additional documentation sections.
-}
report : String -> Maybe String -> String -> List D.Doc -> Report
report title path startString others =
    D.stack (D.reflow startString :: others) |> Report title path


{-| Creates a report from pre-formatted documentation instead of a plain string.
-}
docReport : String -> Maybe String -> D.Doc -> List D.Doc -> Report
docReport title path startDoc others =
    D.stack (startDoc :: others) |> Report title path


{-| Creates a report with a single documentation block, typically used for JSON-focused errors.
-}
jsonReport : String -> Maybe String -> D.Doc -> Report
jsonReport =
    Report


{-| Creates a report from compiler errors, including the root directory and one or more error modules.
-}
compilerReport : String -> Error.Module -> List Error.Module -> Report
compilerReport =
    CompilerReport



-- ====== TO DOC ======


{-| Converts a report to a formatted document for terminal output.
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


{-| Converts a report to JSON format for machine consumption.
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


{-| Writes a formatted document to stdout, using ANSI colors if connected to a terminal.
-}
toStdout : D.Doc -> Task Never ()
toStdout doc =
    toHandle IO.stdout doc


{-| Writes a formatted document to stderr, using ANSI colors if connected to a terminal.
-}
toStderr : D.Doc -> Task Never ()
toStderr doc =
    toHandle IO.stderr doc


toHandle : IO.Handle -> D.Doc -> Task Never ()
toHandle handle doc =
    IO.isTerminal handle
        |> Task.andThen
            (\isTerminal ->
                if isTerminal then
                    D.toAnsi handle doc

                else
                    IO.write handle (D.toString doc)
            )
