module Compiler.Reporting.Error exposing
    ( Error(..), Module
    , toDoc, reportToJson
    , toJson, moduleEncoder, moduleDecoder
    )

{-| A module can fail to compile in any of several phases, and each phase has its
own error type; this module gathers them into one `Error` so that a failed build
can be shown, exported and cached the same way whichever phase failed.

`Module` pairs an `Error` with what is needed to report it: the module's name,
its absolute path, its modification time and its full source text. The source is
kept because a report quotes the lines it is about.

Every phase's error becomes one or more reports, each a title, a source region
and a message (see `Compiler.Reporting.Report`). Those reports are then shown in
two ways: `toDoc` lays them out for a terminal, and `toJson` turns them into JSON.
Separately, `moduleEncoder` and `moduleDecoder` store the failed `Module` in
binary so that it can be reported again without recompiling.


# Error Types

@docs Error, Module


# Formatting for Display

@docs toDoc, reportToJson


# Serialization

@docs toJson, moduleEncoder, moduleDecoder

-}

import Builder.File as File
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore exposing (OneOrMore)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Json.Encode as E
import Compiler.Nitpick.PatternMatches as P
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Canonicalize as Canonicalize
import Compiler.Reporting.Error.Docs as Docs
import Compiler.Reporting.Error.Import as Import
import Compiler.Reporting.Error.Main as Main
import Compiler.Reporting.Error.Pattern as Pattern
import Compiler.Reporting.Error.Syntax as Syntax
import Compiler.Reporting.Error.Type as Type
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Reporting.Report as Report
import System.IO exposing (FilePath)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== Module Errors ======


{-| A module that failed, with what is needed to report its failure.

`source` is the whole text of the module, from which reports quote lines.
`modificationTime` decides the order in which `toDoc` lists failing modules.

-}
type alias Module =
    { name : ModuleName.Raw
    , absolutePath : String
    , modificationTime : File.Time
    , source : String
    , error : Error
    }


{-| Why one module failed, named by the phase that rejected it.

`BadSyntax` holds the one syntax error that stopped the module, as
`Compiler.Reporting.Error.Syntax` describes; not all of them come from the
parser itself.

`BadImports` holds the problems found with the module's imports.

`BadNames` holds the errors found while canonicalizing, that is, while resolving
every name to its definition.

`BadTypes` holds the type errors, with the `Localizer` their reports use to
print type names.

`BadMains` holds the problems with the module's `main` value, with a `Localizer`
for the same purpose.

`BadPatterns` holds both missing and redundant patterns in case expressions and
other pattern matches.

`BadDocs` holds the one problem found when the build checks a module's
documentation, which it does only when the documentation is needed.

-}
type Error
    = BadSyntax Syntax.Error
    | BadImports (NE.Nonempty Import.Error)
    | BadNames (OneOrMore Canonicalize.Error)
    | BadTypes L.Localizer (NE.Nonempty Type.Error)
    | BadMains L.Localizer (OneOrMore Main.Error)
    | BadPatterns (NE.Nonempty P.Error)
    | BadDocs Docs.Error



-- ====== Report Generation ======


{-| Returns the reports for `err`, quoting lines from `source`.
-}
toReports : Code.Source -> Error -> NE.Nonempty Report.Report
toReports source err =
    case err of
        BadSyntax syntaxError ->
            NE.singleton (Syntax.toReport source syntaxError)

        BadImports errs ->
            NE.map (Import.toReport source) errs

        BadNames errs ->
            NE.map (Canonicalize.toReport source) (OneOrMore.destruct NE.Nonempty errs)

        BadTypes localizer errs ->
            NE.map (Type.toReport source localizer) errs

        BadMains localizer errs ->
            NE.map (Main.toReport localizer source) (OneOrMore.destruct NE.Nonempty errs)

        BadPatterns errs ->
            NE.map (Pattern.toReport source) errs

        BadDocs docsErr ->
            Docs.toReports source docsErr



-- ====== Document Formatting ======


{-| Lays out the reports of every failing module for a terminal.

The modules are listed in order of modification time, oldest first. Each report
is headed by a bar holding its title and the module's path, made relative to
`root`, and consecutive modules are divided by a red line naming the module
above and the module below.

-}
toDoc : String -> Module -> List Module -> D.Doc
toDoc root err errs =
    let
        (NE.Nonempty m ms) =
            NE.Nonempty err errs
                |> NE.sortBy
                    (\{ modificationTime } ->
                        let
                            (File.Time posix) =
                                modificationTime
                        in
                        Time.posixToMillis posix
                    )
    in
    D.vcat (toDocHelp root m ms)


{-| Returns the documents for `module1` and `modules` in order, with a separator
between consecutive modules and an empty line at the end.
-}
toDocHelp : String -> Module -> List Module -> List D.Doc
toDocHelp root module1 modules =
    case modules of
        [] ->
            [ moduleToDoc root module1
            , D.fromChars ""
            ]

        module2 :: otherModules ->
            moduleToDoc root module1
                :: toSeparator module1 module2
                :: toDocHelp root module2 otherModules


{-| Returns the red divider between two modules, naming `beforeModule` above
the line, right-aligned to 80 columns, and `afterModule` below it.
-}
toSeparator : Module -> Module -> D.Doc
toSeparator beforeModule afterModule =
    let
        before : ModuleName.Raw
        before =
            beforeModule.name ++ "  ↑    "

        after : String
        after =
            "    ↓  " ++ afterModule.name
    in
    D.dullred <|
        D.vcat
            [ D.indent (80 - String.length before) (D.fromChars before)
            , D.fromChars "====o======================================================================o===="
            , D.fromChars after
            , D.empty
            , D.empty
            ]



-- ====== MODULE TO DOC ======


{-| Returns every report of one module, each headed by its path relative to
`root`.
-}
moduleToDoc : String -> Module -> D.Doc
moduleToDoc root { absolutePath, source, error } =
    let
        reports : NE.Nonempty Report.Report
        reports =
            toReports (Code.toSource source) error

        relativePath : FilePath
        relativePath =
            Utils.fpMakeRelative root absolutePath
    in
    List.map (reportToDoc relativePath) (NE.toList reports) |> D.vcat


{-| Returns one report under its message bar, followed by an empty line.
-}
reportToDoc : String -> Report.Report -> D.Doc
reportToDoc relativePath (Report.Report props) =
    D.vcat
        [ toMessageBar props.title relativePath
        , D.fromChars ""
        , props.doc
        , D.fromChars ""
        ]


{-| Returns the cyan heading line of a report: `--`, the title, a run of dashes
and the file path, padded to 80 columns when they fit and with at least one dash
when they do not.
-}
toMessageBar : String -> String -> D.Doc
toMessageBar title filePath =
    let
        usedSpace : Int
        usedSpace =
            4 + String.length title + 1 + String.length filePath
    in
    ("-- "
        ++ title
        ++ " "
        ++ String.repeat (max 1 (80 - usedSpace)) "-"
        ++ " "
        ++ filePath
    )
        |> D.fromChars
        |> D.dullcyan



-- ====== JSON Serialization ======


{-| Returns a JSON object for one failing module: its absolute `path`, its
`name`, and its reports as `problems`, each in the form `reportToJson` gives.
-}
toJson : Module -> E.Value
toJson { name, absolutePath, source, error } =
    let
        reports : NE.Nonempty Report.Report
        reports =
            toReports (Code.toSource source) error
    in
    E.object
        [ ( "path", E.string absolutePath )
        , ( "name", E.string name )
        , ( "problems", E.list reportToJson (NE.toList reports) )
        ]


{-| Returns a JSON object for one report: its `title`, its `region` as `start`
and `end` positions of `line` and `column`, and its `message` in the form
`Compiler.Reporting.Doc.encode` gives.
-}
reportToJson : Report.Report -> E.Value
reportToJson (Report.Report props) =
    E.object
        [ ( "title", E.string props.title )
        , ( "region", encodeRegion props.region )
        , ( "message", D.encode props.doc )
        ]


{-| Returns `region` as JSON `start` and `end` objects of `line` and `column`.
-}
encodeRegion : A.Region -> E.Value
encodeRegion (A.Region (A.Position sr sc) (A.Position er ec)) =
    E.object
        [ ( "start"
          , E.object
                [ ( "line", E.int sr )
                , ( "column", E.int sc )
                ]
          )
        , ( "end"
          , E.object
                [ ( "line", E.int er )
                , ( "column", E.int ec )
                ]
          )
        ]



-- ====== Binary Serialization ======


{-| Produces the binary encoding of a failed module, which `moduleDecoder`
reads back.
-}
moduleEncoder : Module -> Bytes.Encode.Encoder
moduleEncoder modul =
    Bytes.Encode.sequence
        [ ModuleName.rawEncoder modul.name
        , BE.string modul.absolutePath
        , File.timeEncoder modul.modificationTime
        , BE.string modul.source
        , errorEncoder modul.error
        ]


{-| A decoder for a failed module as `moduleEncoder` writes it.
-}
moduleDecoder : Bytes.Decode.Decoder Module
moduleDecoder =
    Bytes.Decode.map5 Module
        ModuleName.rawDecoder
        BD.string
        File.timeDecoder
        BD.string
        errorDecoder


{-| Produces the binary encoding of `error`: a one-byte tag numbering the
constructor in declaration order, from 0, followed by its contents.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder error =
    case error of
        BadSyntax syntaxError ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Syntax.errorEncoder syntaxError
                ]

        BadImports errs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.nonempty Import.errorEncoder errs
                ]

        BadNames errs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.oneOrMore Canonicalize.errorEncoder errs
                ]

        BadTypes localizer errs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , L.localizerEncoder localizer
                , BE.nonempty Type.errorEncoder errs
                ]

        BadMains localizer errs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , L.localizerEncoder localizer
                , BE.oneOrMore Main.errorEncoder errs
                ]

        BadPatterns errs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.nonempty P.errorEncoder errs
                ]

        BadDocs docsErr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , Docs.errorEncoder docsErr
                ]


{-| A decoder for an `Error` as `errorEncoder` writes it, failing on an unknown
tag.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map BadSyntax Syntax.errorDecoder

                    1 ->
                        Bytes.Decode.map BadImports (BD.nonempty Import.errorDecoder)

                    2 ->
                        Bytes.Decode.map BadNames (BD.oneOrMore Canonicalize.errorDecoder)

                    3 ->
                        Bytes.Decode.map2 BadTypes
                            L.localizerDecoder
                            (BD.nonempty Type.errorDecoder)

                    4 ->
                        Bytes.Decode.map2 BadMains
                            L.localizerDecoder
                            (BD.oneOrMore Main.errorDecoder)

                    5 ->
                        Bytes.Decode.map BadPatterns (BD.nonempty P.errorDecoder)

                    6 ->
                        Bytes.Decode.map BadDocs Docs.errorDecoder

                    _ ->
                        Bytes.Decode.fail
            )
