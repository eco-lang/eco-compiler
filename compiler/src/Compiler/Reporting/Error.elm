module Compiler.Reporting.Error exposing
    ( Error(..), Module
    , toDoc, reportToJson
    , toJson, moduleEncoder, moduleDecoder
    )

{-| Error reporting infrastructure for the Elm compiler.

This module defines the core error types that can arise during compilation
and provides functions to format them for display or serialize them for caching.


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
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
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
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== Module Errors ======


{-| Represents a module that failed to compile, along with its error context.

Contains the module name, file path, modification time, source code, and the
specific error that occurred during compilation.

-}
type alias Module =
    { name : ModuleName.Raw
    , absolutePath : String
    , modificationTime : File.Time
    , source : String
    , error : Error
    }


{-| Errors that can occur during different phases of compilation.

Each variant corresponds to a specific compiler phase:

  - `BadSyntax` - Parse errors in source code
  - `BadImports` - Problems resolving imports
  - `BadNames` - Name resolution and canonicalization errors
  - `BadTypes` - Type checking errors
  - `BadMains` - Invalid main function definitions
  - `BadPatterns` - Non-exhaustive pattern matches
  - `BadDocs` - Malformed documentation comments

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
-- Converts an Error to one or more Report objects for display.


toReports : SyntaxVersion -> Code.Source -> Error -> NE.Nonempty Report.Report
toReports syntaxVersion source err =
    case err of
        BadSyntax syntaxError ->
            NE.singleton (Syntax.toReport syntaxVersion source syntaxError)

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


{-| Format compilation errors for terminal display.

Sorts modules by modification time and formats each error with a visual
separator. Returns a Doc that can be rendered with color to the terminal.

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



-- MODULE TO DOC


moduleToDoc : String -> Module -> D.Doc
moduleToDoc root { absolutePath, source, error } =
    let
        reports : NE.Nonempty Report.Report
        reports =
            toReports (SV.fileSyntaxVersion absolutePath) (Code.toSource source) error

        relativePath : Utils.FilePath
        relativePath =
            Utils.fpMakeRelative root absolutePath
    in
    List.map (reportToDoc relativePath) (NE.toList reports) |> D.vcat


reportToDoc : String -> Report.Report -> D.Doc
reportToDoc relativePath (Report.Report props) =
    D.vcat
        [ toMessageBar props.title relativePath
        , D.fromChars ""
        , props.doc
        , D.fromChars ""
        ]


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


{-| Serialize a module's errors to JSON format.

Produces a JSON object with the module path, name, and a list of problems.
Used by editor integrations and build tools to consume compiler errors.

-}
toJson : Module -> E.Value
toJson { name, absolutePath, source, error } =
    let
        reports : NE.Nonempty Report.Report
        reports =
            toReports (SV.fileSyntaxVersion absolutePath) (Code.toSource source) error
    in
    E.object
        [ ( "path", E.string absolutePath )
        , ( "name", E.string name )
        , ( "problems", E.list reportToJson (NE.toList reports) )
        ]


{-| Convert a single report to JSON format.

Produces a JSON object with the error title, source region (line/column positions),
and formatted message. Used by `toJson` to serialize individual error reports.

-}
reportToJson : Report.Report -> E.Value
reportToJson (Report.Report props) =
    E.object
        [ ( "title", E.string props.title )
        , ( "region", encodeRegion props.region )
        , ( "message", D.encode props.doc )
        ]


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


{-| Encode a module's error for binary caching.
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


{-| Decode a module's error from binary cache.
-}
moduleDecoder : Bytes.Decode.Decoder Module
moduleDecoder =
    Bytes.Decode.map5 Module
        ModuleName.rawDecoder
        BD.string
        File.timeDecoder
        BD.string
        errorDecoder


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
