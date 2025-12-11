module Compiler.Reporting.Render.Type.Localizer exposing
    ( Localizer
    , empty
    , fromModule
    , fromNames
    , localizerDecoder
    , localizerEncoder
    , toChars
    , toDoc
    )

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- LOCALIZER


type Localizer
    = Localizer (Dict String Name Import)


type alias Import =
    { alias : Maybe Name
    , exposing_ : Exposing
    }


type Exposing
    = All
    | Only (EverySet String Name)


empty : Localizer
empty =
    Localizer Dict.empty



-- LOCALIZE


toDoc : Localizer -> IO.Canonical -> Name -> D.Doc
toDoc localizer home name =
    D.fromChars (toChars localizer home name)


toChars : Localizer -> IO.Canonical -> Name -> String
toChars (Localizer localizer) ((IO.Canonical _ home) as moduleName) name =
    case Dict.get identity home localizer of
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



-- FROM NAMES


fromNames : Dict String Name a -> Localizer
fromNames names =
    Localizer (Dict.map (\_ _ -> { alias = Nothing, exposing_ = All }) names)



-- FROM MODULE


fromModule : Src.Module -> Localizer
fromModule ((Src.Module srcData) as modul) =
    Localizer <|
        Dict.fromList identity <|
            (( Src.getName modul, { alias = Nothing, exposing_ = All } ) :: List.map toPair srcData.imports)


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



-- ENCODERS and DECODERS


localizerEncoder : Localizer -> Bytes.Encode.Encoder
localizerEncoder (Localizer localizer) =
    BE.assocListDict compare BE.string importEncoder localizer


localizerDecoder : Bytes.Decode.Decoder Localizer
localizerDecoder =
    Bytes.Decode.map Localizer (BD.assocListDict identity BD.string importDecoder)


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
