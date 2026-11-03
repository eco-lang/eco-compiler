module Compiler.Error exposing
    ( Error(..)
    , errorEncoder, errorDecoder
    )

{-| A module can fail to compile in any of several passes, and each pass has its
own error type; this module gathers them into one `Error`, so that the compiler
can return any of them and the build can cache it. Reporting a failed module is
the build's job (`Builder.Reporting.ModuleError`).


# Error Type

@docs Error


# Serialization

@docs errorEncoder, errorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Canonicalize.Error as Canonicalize
import Compiler.Canonicalize.ImportError as Import
import Compiler.Docs.Error as Docs
import Compiler.LocalOpt.Error as Main
import Compiler.Nitpick.PatternMatches as P
import Compiler.Parse.Error as Syntax
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Type.Error as Type
import Data.NonEmptyList as NE
import Data.OneOrMore exposing (OneOrMore)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== Errors ======


{-| Why one module failed, named by the phase that rejected it.

`BadSyntax` holds the one syntax error that stopped the module, as
`Compiler.Parse.Error` describes; not all of them come from the
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



-- ====== Binary Serialization ======


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
