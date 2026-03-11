module Compiler.Reporting.Render.Type.Localizer exposing
    ( Localizer
    , empty, fromModule, fromNames
    , toDoc, toChars
    , localizerEncoder, localizerDecoder
    )

{-| Context-aware type name formatting for error messages.

This module determines how to display qualified type names in error messages
based on the imports and module context. It automatically chooses the shortest
unambiguous name representation, using bare names when they're in scope,
aliases when available, or fully qualified names when necessary.


# Localizer

@docs Localizer


# Construction

@docs empty, fromModule, fromNames


# Rendering

@docs toDoc, toChars


# Serialization

@docs localizerEncoder, localizerDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== LOCALIZER ======


{-| Tracks import context to determine how to display qualified type names.
Encapsulates information about module imports, aliases, and exposed types.
-}
type Localizer
    = Localizer (Dict Name Import)


type alias Import =
    { alias : Maybe Name
    , exposing_ : Exposing
    }


type Exposing
    = All
    | Only (EverySet String Name)


{-| Creates an empty localizer with no import information. Type names will be
displayed fully qualified.
-}
empty : Localizer
empty =
    Localizer Dict.empty



-- ====== LOCALIZE ======


{-| Converts a qualified type name to a Doc using the shortest unambiguous form
based on the import context (bare name, aliased name, or fully qualified).
-}
toDoc : Localizer -> IO.Canonical -> Name -> D.Doc
toDoc localizer home name =
    D.fromChars (toChars localizer home name)


{-| Converts a qualified type name to a String using the shortest unambiguous form
based on the import context (bare name, aliased name, or fully qualified).
-}
toChars : Localizer -> IO.Canonical -> Name -> String
toChars (Localizer localizer) ((IO.Canonical _ home) as moduleName) name =
    case Dict.get home localizer of
        Nothing ->
            home ++ "." ++ name

        Just import_ ->
            case import_.exposing_ of
                All ->
                    name

                Only set ->
                    if EverySet.member identity name set then
                        name

                    else if name == Name.list && moduleName == ModuleName.list then
                        "List"

                    else
                        Maybe.withDefault home import_.alias ++ "." ++ name



-- ====== FROM NAMES ======


{-| Creates a localizer from a dictionary of names, treating all as fully exposed.
Useful when all names are in scope without qualification.
-}
fromNames : Dict Name a -> Localizer
fromNames names =
    Localizer (Dict.map (\_ _ -> { alias = Nothing, exposing_ = All }) names)



-- ====== FROM MODULE ======


{-| Creates a localizer from a source module, extracting import information to
determine how types should be displayed based on the module's import statements.
-}
fromModule : Src.Module -> Localizer
fromModule ((Src.Module srcData) as modul) =
    (( Src.getName modul, { alias = Nothing, exposing_ = All } ) :: List.map toPair srcData.imports) |> Dict.fromList |> Localizer


toPair : Src.Import -> ( Name, Import )
toPair (Src.Import ( _, A.At _ name ) alias_ ( _, exposing_ )) =
    ( name
    , Import (Maybe.map Src.c2Value alias_) (toExposing exposing_)
    )


toExposing : Src.Exposing -> Exposing
toExposing exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            All

        Src.Explicit (A.At _ exposedList) ->
            Only (List.foldr addType EverySet.empty (List.map Src.c2Value exposedList))


addType : Src.Exposed -> EverySet String Name -> EverySet String Name
addType exposed types =
    case exposed of
        Src.Lower _ ->
            types

        Src.Upper (A.At _ name) _ ->
            EverySet.insert identity name types

        Src.Operator _ _ ->
            types



-- ====== ENCODERS and DECODERS ======


{-| Encodes a Localizer to bytes for serialization.
-}
localizerEncoder : Localizer -> Bytes.Encode.Encoder
localizerEncoder (Localizer localizer) =
    BE.stdDict BE.string importEncoder localizer


{-| Decodes a Localizer from bytes for deserialization.
-}
localizerDecoder : Bytes.Decode.Decoder Localizer
localizerDecoder =
    Bytes.Decode.map Localizer (BD.stdDict BD.string importDecoder)


importEncoder : Import -> Bytes.Encode.Encoder
importEncoder import_ =
    Bytes.Encode.sequence
        [ BE.maybe BE.string import_.alias
        , exposingEncoder import_.exposing_
        ]


importDecoder : Bytes.Decode.Decoder Import
importDecoder =
    Bytes.Decode.map2 Import
        (BD.maybe BD.string)
        exposingDecoder


exposingEncoder : Exposing -> Bytes.Encode.Encoder
exposingEncoder exposing_ =
    case exposing_ of
        All ->
            Bytes.Encode.unsignedInt8 0

        Only set ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.everySet compare BE.string set
                ]


exposingDecoder : Bytes.Decode.Decoder Exposing
exposingDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\type_ ->
                case type_ of
                    0 ->
                        Bytes.Decode.succeed All

                    1 ->
                        Bytes.Decode.map Only (BD.everySet identity BD.string)

                    _ ->
                        Bytes.Decode.fail
            )
