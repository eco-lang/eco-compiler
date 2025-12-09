module Compiler.Elm.Interface exposing
    ( Alias(..)
    , Binop(..)
    , DependencyInterface(..)
    , Interface(..)
    , Union(..)
    , dependencyInterfaceDecoder
    , dependencyInterfaceEncoder
    , extractAlias
    , extractUnion
    , fromModule
    , interfaceDecoder
    , interfaceEncoder
    , private
    , privatize
    , public
    , toPublicAlias
    , toPublicUnion
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Bytes.Decode
import Utils.Bytes.Encode as BE
import Bytes.Encode
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- INTERFACE


type Interface
    = Interface Pkg.Name (Dict String Name.Name Can.Annotation) (Dict String Name.Name Union) (Dict String Name.Name Alias) (Dict String Name.Name Binop)


type Union
    = OpenUnion Can.Union
    | ClosedUnion Can.Union
    | PrivateUnion Can.Union


type Alias
    = PublicAlias Can.Alias
    | PrivateAlias Can.Alias


type Binop
    = Binop Name.Name Can.Annotation Binop.Associativity Binop.Precedence



-- FROM MODULE


fromModule : Pkg.Name -> Can.Module -> Dict String Name.Name Can.Annotation -> Interface
fromModule home (Can.Module _ exports _ _ unions aliases binops _) annotations =
    Interface home
        (restrict exports annotations)
        (restrictUnions exports unions)
        (restrictAliases exports aliases)
        (restrict exports (Dict.map (\_ -> toOp annotations) binops))


restrict : Can.Exports -> Dict String Name.Name a -> Dict String Name.Name a
restrict exports dict =
    case exports of
        Can.ExportEverything _ ->
            dict

        Can.Export explicitExports ->
            Dict.intersection compare dict explicitExports


toOp : Dict String Name.Name Can.Annotation -> Can.Binop -> Binop
toOp types (Can.Binop_ associativity precedence name) =
    Binop name (Utils.find identity name types) associativity precedence


restrictUnions : Can.Exports -> Dict String Name.Name Can.Union -> Dict String Name.Name Union
restrictUnions exports unions =
    case exports of
        Can.ExportEverything _ ->
            Dict.map (\_ -> OpenUnion) unions

        Can.Export explicitExports ->
            Dict.merge compare
                (\_ _ result -> result)
                (\k (A.At _ export) union result ->
                    case export of
                        Can.ExportUnionOpen ->
                            Dict.insert identity k (OpenUnion union) result

                        Can.ExportUnionClosed ->
                            Dict.insert identity k (ClosedUnion union) result

                        _ ->
                            crash "impossible exports discovered in restrictUnions"
                )
                (\k union result -> Dict.insert identity k (PrivateUnion union) result)
                explicitExports
                unions
                Dict.empty


restrictAliases : Can.Exports -> Dict String Name.Name Can.Alias -> Dict String Name.Name Alias
restrictAliases exports aliases =
    case exports of
        Can.ExportEverything _ ->
            Dict.map (\_ alias -> PublicAlias alias) aliases

        Can.Export explicitExports ->
            Dict.merge compare
                (\_ _ result -> result)
                (\k _ alias result -> Dict.insert identity k (PublicAlias alias) result)
                (\k alias result -> Dict.insert identity k (PrivateAlias alias) result)
                explicitExports
                aliases
                Dict.empty



-- TO PUBLIC


toPublicUnion : Union -> Maybe Can.Union
toPublicUnion iUnion =
    case iUnion of
        OpenUnion union ->
            Just union

        ClosedUnion (Can.Union vars _ _ opts) ->
            Just (Can.Union vars [] 0 opts)

        PrivateUnion _ ->
            Nothing


toPublicAlias : Alias -> Maybe Can.Alias
toPublicAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            Just alias

        PrivateAlias _ ->
            Nothing



-- DEPENDENCY INTERFACE


type DependencyInterface
    = Public Interface
    | Private Pkg.Name (Dict String Name.Name Can.Union) (Dict String Name.Name Can.Alias)


public : Interface -> DependencyInterface
public =
    Public


private : Interface -> DependencyInterface
private (Interface pkg _ unions aliases _) =
    Private pkg (Dict.map (\_ -> extractUnion) unions) (Dict.map (\_ -> extractAlias) aliases)


extractUnion : Union -> Can.Union
extractUnion iUnion =
    case iUnion of
        OpenUnion union ->
            union

        ClosedUnion union ->
            union

        PrivateUnion union ->
            union


extractAlias : Alias -> Can.Alias
extractAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            alias

        PrivateAlias alias ->
            alias


privatize : DependencyInterface -> DependencyInterface
privatize di =
    case di of
        Public i ->
            private i

        Private _ _ _ ->
            di



-- ENCODERS and DECODERS


interfaceEncoder : Interface -> Bytes.Encode.Encoder
interfaceEncoder (Interface home values unions aliases binops) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder home
        , BE.assocListDict compare BE.string Can.annotationEncoder values
        , BE.assocListDict compare BE.string unionEncoder unions
        , BE.assocListDict compare BE.string aliasEncoder aliases
        , BE.assocListDict compare BE.string binopEncoder binops
        ]


interfaceDecoder : Bytes.Decode.Decoder Interface
interfaceDecoder =
    Bytes.Decode.map5 Interface
        Pkg.nameDecoder
        (BD.assocListDict identity BD.string Can.annotationDecoder)
        (BD.assocListDict identity BD.string unionDecoder)
        (BD.assocListDict identity BD.string aliasDecoder)
        (BD.assocListDict identity BD.string binopDecoder)


unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder union_ =
    case union_ of
        OpenUnion union ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Can.unionEncoder union
                ]

        ClosedUnion union ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Can.unionEncoder union
                ]

        PrivateUnion union ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Can.unionEncoder union
                ]


unionDecoder : Bytes.Decode.Decoder Union
unionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map OpenUnion Can.unionDecoder

                    1 ->
                        Bytes.Decode.map ClosedUnion Can.unionDecoder

                    2 ->
                        Bytes.Decode.map PrivateUnion Can.unionDecoder

                    _ ->
                        Bytes.Decode.fail
            )


aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder aliasValue =
    case aliasValue of
        PublicAlias alias_ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Can.aliasEncoder alias_
                ]

        PrivateAlias alias_ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Can.aliasEncoder alias_
                ]


aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map PublicAlias Can.aliasDecoder

                    1 ->
                        Bytes.Decode.map PrivateAlias Can.aliasDecoder

                    _ ->
                        Bytes.Decode.fail
            )


binopEncoder : Binop -> Bytes.Encode.Encoder
binopEncoder (Binop name annotation associativity precedence) =
    Bytes.Encode.sequence
        [ BE.string name
        , Can.annotationEncoder annotation
        , Binop.associativityEncoder associativity
        , Binop.precedenceEncoder precedence
        ]


binopDecoder : Bytes.Decode.Decoder Binop
binopDecoder =
    Bytes.Decode.map4 Binop
        BD.string
        Can.annotationDecoder
        Binop.associativityDecoder
        Binop.precedenceDecoder


dependencyInterfaceEncoder : DependencyInterface -> Bytes.Encode.Encoder
dependencyInterfaceEncoder dependencyInterface =
    case dependencyInterface of
        Public i ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , interfaceEncoder i
                ]

        Private pkg unions aliases ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Pkg.nameEncoder pkg
                , BE.assocListDict compare BE.string Can.unionEncoder unions
                , BE.assocListDict compare BE.string Can.aliasEncoder aliases
                ]


dependencyInterfaceDecoder : Bytes.Decode.Decoder DependencyInterface
dependencyInterfaceDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Public interfaceDecoder

                    1 ->
                        Bytes.Decode.map3 Private
                            Pkg.nameDecoder
                            (BD.assocListDict identity BD.string Can.unionDecoder)
                            (BD.assocListDict identity BD.string Can.aliasDecoder)

                    _ ->
                        Bytes.Decode.fail
            )
