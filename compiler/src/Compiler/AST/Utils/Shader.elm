module Compiler.AST.Utils.Shader exposing
    ( Source(..)
    , Type(..)
    , Types(..)
    , fromString
    , sourceDecoder
    , sourceEncoder
    , toJsStringBuilder
    , typesDecoder
    , typesEncoder
    , unescape
    )

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name exposing (Name)
import Data.Map exposing (Dict)
import Regex
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- SOURCE


type Source
    = Source String



-- TYPES


type Types
    = Types (Dict String Name Type) (Dict String Name Type) (Dict String Name Type)


type Type
    = Int
    | Float
    | V2
    | V3
    | V4
    | M4
    | Texture
    | Bool



-- TO BUILDER


toJsStringBuilder : Source -> String
toJsStringBuilder (Source src) =
    src



-- FROM STRING


fromString : String -> Source
fromString =
    escape >> Source


escape : String -> String
escape =
    String.foldr
        (\char acc ->
            case char of
                '\u{000D}' ->
                    acc

                '\n' ->
                    acc
                        |> String.cons 'n'
                        |> String.cons '\\'

                '"' ->
                    acc
                        |> String.cons '"'
                        |> String.cons '\\'

                '\'' ->
                    acc
                        |> String.cons '\''
                        |> String.cons '\\'

                '\\' ->
                    acc
                        |> String.cons '\\'
                        |> String.cons '\\'

                _ ->
                    String.cons char acc
        )
        ""


unescape : String -> String
unescape =
    Regex.replace
        (Regex.fromString "\\\\n|\\\\\"|\\\\'|\\\\\\\\"
            |> Maybe.withDefault Regex.never
        )
        (\{ match } ->
            case match of
                "\\n" ->
                    "\n"

                "\\\"" ->
                    "\""

                "\\'" ->
                    "'"

                "\\\\" ->
                    "\\"

                _ ->
                    match
        )



-- ENCODERS and DECODERS


sourceEncoder : Source -> Bytes.Encode.Encoder
sourceEncoder (Source src) =
    BE.string src


sourceDecoder : Bytes.Decode.Decoder Source
sourceDecoder =
    Bytes.Decode.map Source BD.string


typesEncoder : Types -> Bytes.Encode.Encoder
typesEncoder (Types attribute uniform varying) =
    Bytes.Encode.sequence
        [ BE.assocListDict compare BE.string typeEncoder attribute
        , BE.assocListDict compare BE.string typeEncoder uniform
        , BE.assocListDict compare BE.string typeEncoder varying
        ]


typesDecoder : Bytes.Decode.Decoder Types
typesDecoder =
    Bytes.Decode.map3 Types
        (BD.assocListDict identity BD.string typeDecoder)
        (BD.assocListDict identity BD.string typeDecoder)
        (BD.assocListDict identity BD.string typeDecoder)


typeEncoder : Type -> Bytes.Encode.Encoder
typeEncoder type_ =
    Bytes.Encode.unsignedInt8
        (case type_ of
            Int ->
                0

            Float ->
                1

            V2 ->
                2

            V3 ->
                3

            V4 ->
                4

            M4 ->
                5

            Texture ->
                6

            Bool ->
                7
        )


typeDecoder : Bytes.Decode.Decoder Type
typeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Int

                    1 ->
                        Bytes.Decode.succeed Float

                    2 ->
                        Bytes.Decode.succeed V2

                    3 ->
                        Bytes.Decode.succeed V3

                    4 ->
                        Bytes.Decode.succeed V4

                    5 ->
                        Bytes.Decode.succeed M4

                    6 ->
                        Bytes.Decode.succeed Texture

                    7 ->
                        Bytes.Decode.succeed Bool

                    _ ->
                        Bytes.Decode.fail
            )
