module Compiler.Elm.Interface exposing
    ( Interface(..), InterfaceData
    , Union(..)
    , Alias(..)
    , Binop(..), BinopData
    , DependencyInterface(..)
    , fromModule
    , public, private, privatize
    , toPublicUnion, toPublicAlias, extractUnion, extractAlias
    , interfaceEncoder, interfaceDecoder, dependencyInterfaceEncoder, dependencyInterfaceDecoder
    )

{-| Module interface representation for type checking and compilation.

An interface captures the public API surface of a compiled Elm module, including exported
values, types, type aliases, and operators. Interfaces distinguish between public and private
declarations, and between open and closed union types. This information is used for separate
compilation and dependency management.


# Interface Types

@docs Interface, InterfaceData


# Union Types

@docs Union


# Type Aliases

@docs Alias


# Binary Operators

@docs Binop, BinopData


# Dependency Interfaces

@docs DependencyInterface


# Building Interfaces

@docs fromModule


# Visibility Conversion

@docs public, private, privatize


# Extracting Public Information

@docs toPublicUnion, toPublicAlias, extractUnion, extractAlias


# Binary Encoding/Decoding

@docs interfaceEncoder, interfaceDecoder, dependencyInterfaceEncoder, dependencyInterfaceDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== INTERFACE ======


{-| Record containing the complete interface data for a module, including its package
home, exported values with their type annotations, union types, type aliases, and binary operators.
-}
type alias InterfaceData =
    { home : Pkg.Name
    , values : Dict String Name.Name Can.Annotation
    , unions : Dict String Name.Name Union
    , aliases : Dict String Name.Name Alias
    , binops : Dict String Name.Name Binop
    }


{-| Wrapper type for module interface data, representing the complete public API
surface of a compiled Elm module.
-}
type Interface
    = Interface InterfaceData


{-| Represents a union type's visibility in the interface. Open unions export all
constructors, closed unions hide constructors, and private unions are not exported.
-}
type Union
    = OpenUnion Can.Union
    | ClosedUnion Can.Union
    | PrivateUnion Can.Union


{-| Represents a type alias's visibility in the interface. Public aliases are exported,
while private aliases are only available within the defining module.
-}
type Alias
    = PublicAlias Can.Alias
    | PrivateAlias Can.Alias


{-| Record containing all information about a binary operator, including its name,
type annotation, associativity (left/right), and precedence level.
-}
type alias BinopData =
    { name : Name.Name
    , annotation : Can.Annotation
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


{-| Wrapper type for binary operator data.
-}
type Binop
    = Binop BinopData



-- ====== FROM MODULE ======


{-| Constructs an interface from a canonical module, extracting only the exported values,
types, aliases, and operators based on the module's export list.
-}
fromModule : Pkg.Name -> Can.Module -> Dict String Name.Name Can.Annotation -> Interface
fromModule home (Can.Module canData) annotations =
    Interface
        { home = home
        , values = restrict canData.exports annotations
        , unions = restrictUnions canData.exports canData.unions
        , aliases = restrictAliases canData.exports canData.aliases
        , binops = restrict canData.exports (Dict.map (\_ -> toOp annotations) canData.binops)
        }


restrict : Can.Exports -> Dict String Name.Name a -> Dict String Name.Name a
restrict exports dict =
    case exports of
        Can.ExportEverything _ ->
            dict

        Can.Export explicitExports ->
            Dict.intersection compare dict explicitExports


toOp : Dict String Name.Name Can.Annotation -> Can.Binop -> Binop
toOp types (Can.Binop_ associativity precedence name) =
    Binop
        { name = name
        , annotation = Utils.find identity name types
        , associativity = associativity
        , precedence = precedence
        }


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



-- ====== TO PUBLIC ======


{-| Converts a union type to its public representation. Open unions expose all constructors,
closed unions expose the type but hide constructors, and private unions are not exposed.
-}
toPublicUnion : Union -> Maybe Can.Union
toPublicUnion iUnion =
    case iUnion of
        OpenUnion union ->
            Just union

        ClosedUnion (Can.Union unionData) ->
            Just (Can.Union { vars = unionData.vars, alts = [], numAlts = 0, opts = unionData.opts })

        PrivateUnion _ ->
            Nothing


{-| Converts a type alias to its public representation. Returns Just for public aliases
and Nothing for private aliases.
-}
toPublicAlias : Alias -> Maybe Can.Alias
toPublicAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            Just alias

        PrivateAlias _ ->
            Nothing



-- ====== DEPENDENCY INTERFACE ======


{-| Represents how a module's interface is exposed to dependencies. Public interfaces
expose the full API, while private interfaces only expose type definitions without values.
-}
type DependencyInterface
    = Public Interface
    | Private Pkg.Name (Dict String Name.Name Can.Union) (Dict String Name.Name Can.Alias)


{-| Creates a public dependency interface, exposing the full module API including all
exported values, types, and operators.
-}
public : Interface -> DependencyInterface
public =
    Public


{-| Creates a private dependency interface, exposing only type definitions (unions and aliases)
without values or operators. Used for dependency cycles where only types are needed.
-}
private : Interface -> DependencyInterface
private (Interface i) =
    Private i.home (Dict.map (\_ -> extractUnion) i.unions) (Dict.map (\_ -> extractAlias) i.aliases)


{-| Extracts the underlying canonical union type from any union visibility wrapper,
regardless of whether it is open, closed, or private.
-}
extractUnion : Union -> Can.Union
extractUnion iUnion =
    case iUnion of
        OpenUnion union ->
            union

        ClosedUnion union ->
            union

        PrivateUnion union ->
            union


{-| Extracts the underlying canonical type alias from any alias visibility wrapper,
regardless of whether it is public or private.
-}
extractAlias : Alias -> Can.Alias
extractAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            alias

        PrivateAlias alias ->
            alias


{-| Converts a dependency interface to its private form, keeping only type definitions.
If already private, returns the interface unchanged.
-}
privatize : DependencyInterface -> DependencyInterface
privatize di =
    case di of
        Public i ->
            private i

        Private _ _ _ ->
            di



-- ====== ENCODERS and DECODERS ======


{-| Encodes an interface to binary format for serialization to disk or network transmission.
-}
interfaceEncoder : Interface -> Bytes.Encode.Encoder
interfaceEncoder (Interface i) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder i.home
        , BE.assocListDict compare BE.string Can.annotationEncoder i.values
        , BE.assocListDict compare BE.string unionEncoder i.unions
        , BE.assocListDict compare BE.string aliasEncoder i.aliases
        , BE.assocListDict compare BE.string binopEncoder i.binops
        ]


{-| Decodes an interface from binary format, reconstructing the full interface structure
from serialized bytes.
-}
interfaceDecoder : Bytes.Decode.Decoder Interface
interfaceDecoder =
    Bytes.Decode.map5 (\home_ values_ unions_ aliases_ binops_ -> Interface { home = home_, values = values_, unions = unions_, aliases = aliases_, binops = binops_ })
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
binopEncoder (Binop data) =
    Bytes.Encode.sequence
        [ BE.string data.name
        , Can.annotationEncoder data.annotation
        , Binop.associativityEncoder data.associativity
        , Binop.precedenceEncoder data.precedence
        ]


binopDecoder : Bytes.Decode.Decoder Binop
binopDecoder =
    Bytes.Decode.map4
        (\name annotation associativity precedence ->
            Binop { name = name, annotation = annotation, associativity = associativity, precedence = precedence }
        )
        BD.string
        Can.annotationDecoder
        Binop.associativityDecoder
        Binop.precedenceDecoder


{-| Encodes a dependency interface to binary format, handling both public and private
interface variants with appropriate type tags.
-}
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


{-| Decodes a dependency interface from binary format, reconstructing either a public
or private interface based on the encoded type tag.
-}
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
