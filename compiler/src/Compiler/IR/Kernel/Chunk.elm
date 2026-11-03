module Compiler.IR.Kernel.Chunk exposing
    ( Chunk(..), Content(..), Foreigns
    , countFields
    , chunkEncoder, chunkDecoder
    )

{-| A kernel module is a JavaScript file that implements part of an Elm package
by hand. `Compiler.Parse.Kernel` parses such a file into _chunks_: the pieces the
JavaScript back end must rename as it emits the file, and the plain text
between them. This module holds the parsed form, which the optimized program
representations carry and the build caches, so that they need not depend on the
parser.


# Types

@docs Chunk, Content, Foreigns


# Field Analysis

@docs countFields


# Binary Encoding/Decoding

@docs chunkEncoder, chunkDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Core.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.IR.Source as Src
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== CHUNK ======


{-| One piece of a parsed kernel file: either JavaScript text copied as it is, or
something the back end writes in place of a kernel tag.

`JS` is the text between two tags, or before the first or after the last. It may
be empty.

`ElmVar` is an Elm value imported in the header, with the canonical name of its
module.

`JsVar` is a value of another kernel module imported in the header. It carries
the kernel prefix (`Elm` or `Eco`), the rest of the module name (`File` for
`Eco.Kernel.File`), and the value's name.

`ElmField` is the Elm record field named after `__$`.

`JsField` and `JsEnum` are numbers standing for names. Within one file, each
distinct `__name` that starts with a lower case letter gets the next field
number, from 0, in order of first appearance. Tags starting with a digit are
numbered the same way, with a separate count for each leading digit, so `__1a`
and `__2a` may both be 0.

`Debug` and `Prod` are the `__DEBUG` and `__PROD` markers, which the back end
renders differently in development and production mode.

-}
type Chunk
    = JS String
    | ElmVar ModuleName.Canonical Name
    | JsVar Name Name Name
    | ElmField Name
    | JsField Int
    | JsEnum Int
    | Debug
    | Prod



-- ====== COUNT FIELDS ======


{-| Returns, for each record field named by an `ElmField` chunk in `chunks`, how
many times it occurs.
-}
countFields : List Chunk -> Dict Name Int
countFields chunks =
    List.foldr addField Dict.empty chunks


{-| Returns `fields` with the count of the chunk's field raised by one, starting at 1,
when the chunk is an `ElmField`, and `fields` unchanged otherwise.
-}
addField : Chunk -> Dict Name Int -> Dict Name Int
addField chunk fields =
    case chunk of
        JS _ ->
            fields

        ElmVar _ _ ->
            fields

        JsVar _ _ _ ->
            fields

        ElmField f ->
            Dict.update
                f
                (Maybe.map ((+) 1)
                    >> Maybe.withDefault 1
                    >> Just
                )
                fields

        JsField _ ->
            fields

        JsEnum _ ->
            fields

        Debug ->
            fields

        Prod ->
            fields



-- ====== FILE CONTENT ======


{-| A parsed kernel file: the imports from its header comment, in source order,
and the chunks of its body.
-}
type Content
    = Content (List (Src.C1 Src.Import)) (List Chunk)


{-| The package each Elm module visible to a kernel file comes from, keyed by
module name.

A module imported in the header that is missing from it is taken to be in the
kernel file's own package.

-}
type alias Foreigns =
    Dict ModuleName.Raw Pkg.Name



-- ====== ENCODERS and DECODERS ======


{-| Produces the binary encoding of a chunk, which `chunkDecoder` reads back.

Each chunk starts with a tag byte. A `JsVar` has tag 8 when its kernel prefix is
`Eco` and tag 2 for any other prefix, which `chunkDecoder` reads back as `Elm`.

-}
chunkEncoder : Chunk -> Bytes.Encode.Encoder
chunkEncoder chunk =
    case chunk of
        JS javascript ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string javascript
                ]

        ElmVar home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , ModuleName.canonicalEncoder home
                , BE.string name
                ]

        JsVar kernelPrefix home name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8
                    (if kernelPrefix == "Eco" then
                        8

                     else
                        2
                    )
                , BE.string home
                , BE.string name
                ]

        ElmField name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string name
                ]

        JsField int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.int int
                ]

        JsEnum int ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.int int
                ]

        Debug ->
            Bytes.Encode.unsignedInt8 6

        Prod ->
            Bytes.Encode.unsignedInt8 7


{-| The decoder for a chunk written by `chunkEncoder`. It fails on an unknown tag
byte.
-}
chunkDecoder : Bytes.Decode.Decoder Chunk
chunkDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map JS BD.string

                    1 ->
                        Bytes.Decode.map2 ElmVar
                            ModuleName.canonicalDecoder
                            BD.string

                    2 ->
                        Bytes.Decode.map2 (JsVar "Elm")
                            BD.string
                            BD.string

                    3 ->
                        Bytes.Decode.map ElmField BD.string

                    4 ->
                        Bytes.Decode.map JsField BD.int

                    5 ->
                        Bytes.Decode.map JsEnum BD.int

                    6 ->
                        Bytes.Decode.succeed Debug

                    7 ->
                        Bytes.Decode.succeed Prod

                    8 ->
                        Bytes.Decode.map2 (JsVar "Eco")
                            BD.string
                            BD.string

                    _ ->
                        Bytes.Decode.fail
            )
