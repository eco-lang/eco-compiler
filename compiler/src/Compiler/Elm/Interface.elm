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

{-| What a compiled module offers to the modules that import it, recorded so
that they can be compiled against it.

An interface belongs to one module. It records the package the module is in,
the type annotation of each value the module exposes, each infix operator it
exposes, and every custom type and type alias it declares, exposed or not.
Values and operators are cut down to what the module's `exposing` list
exposes, but no type is left out. Each type carries its visibility instead. A
custom type is _open_ (exposed with its constructors, as `Type(..)`),
_closed_ (exposed without them) or _private_ (not exposed), and a type alias
is _public_ or _private_. With `exposing (..)` every custom type is open and
every alias public.

`fromModule` stores every type with its complete declaration, constructors
included, whatever its visibility. The visibility is what decides how much of
a type a module importing this one may see, which `toPublicUnion` and
`toPublicAlias` work out: an open type whole, a closed type with no
constructors, and nothing of a private type or alias.

A `DependencyInterface` is an interface in one of two forms: the whole
interface, or a _private_ one reduced to the types, with no values or
operators.

The rest of the module is the binary encoding of interfaces and dependency
interfaces, in the format `Utils.Bytes.Encode` describes.


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
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)



-- ====== INTERFACE ======


{-| The contents of a module's interface.

`home` is the package of the module, not the module itself; the interface does
not record the module's name. `values` and `binops` hold only what the module
exposes, while `unions` and `aliases` hold every custom type and type alias it
declares, each tagged with its visibility. `binops` is keyed by the operator.

-}
type alias InterfaceData =
    { home : Pkg.Name
    , values : Dict Name.Name (Can.Annotation Name)
    , unions : Dict Name.Name Union
    , aliases : Dict Name.Name Alias
    , binops : Dict Name.Name Binop
    }


{-| One module's interface: what it exposes, and every type it declares.
-}
type Interface
    = Interface InterfaceData


{-| A custom type as an interface records it: a declaration, tagged with how
the module's `exposing` list exposes it.

`OpenUnion` is exposed with its constructors, as `Type(..)`, and `ClosedUnion`
without them. `PrivateUnion` is not exposed. As `fromModule` builds them, all
three hold the declaration with its constructors; a closed type loses them only
in what `toPublicUnion` returns.

-}
type Union
    = OpenUnion Can.Union
    | ClosedUnion Can.Union
    | PrivateUnion Can.Union


{-| A type alias as an interface records it: its complete declaration, tagged
with whether the module's `exposing` list exposes it.

`PublicAlias` is exposed and `PrivateAlias` is not. Both hold the whole
declaration.

-}
type Alias
    = PublicAlias Can.Alias
    | PrivateAlias Can.Alias


{-| An infix operator a module exposes: the function it stands for, that
function's type annotation, and the operator's associativity and precedence.

`name` is the name of the function, not of the operator. The operator is the
key the record is stored under in `binops`.

-}
type alias BinopData =
    { name : Name.Name
    , annotation : Can.Annotation Name
    , associativity : Binop.Associativity
    , precedence : Binop.Precedence
    }


{-| An infix operator a module exposes, as `BinopData` describes it.
-}
type Binop
    = Binop BinopData



-- ====== FROM MODULE ======


{-| Builds the interface of a canonical module in package `home`, given the
annotations of its top-level values.

A value or operator is kept only if the module's `exposing` list names it, and
every one is kept under `exposing (..)`. Every custom type and type alias is
kept, with the visibility the list gives it.

Crashes if `annotations` has no annotation for the function an operator stands
for, whether or not the operator is exposed, or if the `exposing` list names a
custom type as some other kind of thing.

-}
fromModule : Pkg.Name -> Can.Module -> Dict Name.Name (Can.Annotation Name) -> Interface
fromModule home (Can.Module canData) annotations =
    Interface
        { home = home
        , values = restrict canData.exports annotations
        , unions = restrictUnions canData.exports canData.unions
        , aliases = restrictAliases canData.exports canData.aliases
        , binops = restrict canData.exports (Dict.map (\_ -> toOp annotations) canData.binops)
        }


{-| Returns the entries of `dict` whose names `exports` exposes: all of them
for `exposing (..)`, otherwise those whose names the list contains, whatever
kind of thing the list says each name is.
-}
restrict : Can.Exports -> Dict Name.Name a -> Dict Name.Name a
restrict exports dict =
    case exports of
        Can.ExportEverything _ ->
            dict

        Can.Export explicitExports ->
            Dict.filter (\k _ -> Dict.member k explicitExports) dict


{-| Returns the interface's record of an operator declaration, with the
annotation of the function it stands for taken from `types`. Crashes if
`types` has no annotation for that function.
-}
toOp : Dict Name.Name (Can.Annotation Name) -> Can.Binop -> Binop
toOp types (Can.Binop_ associativity precedence name) =
    Binop
        { name = name
        , annotation =
            case Dict.get name types of
                Just ann ->
                    ann

                Nothing ->
                    crash "Map.!: given key is not an element in the map"
        , associativity = associativity
        , precedence = precedence
        }


{-| Tags each custom type in `unions` with its visibility under `exports`.
Under `exposing (..)` every type is open. Otherwise a type is open or closed as
the list names it, and private if the list does not name it. Crashes if the
list names a type as anything other than an open or closed custom type.
-}
restrictUnions : Can.Exports -> Dict Name.Name Can.Union -> Dict Name.Name Union
restrictUnions exports unions =
    case exports of
        Can.ExportEverything _ ->
            Dict.map (\_ -> OpenUnion) unions

        Can.Export explicitExports ->
            Dict.merge
                (\_ _ result -> result)
                (\k (A.At _ export) union result ->
                    case export of
                        Can.ExportUnionOpen ->
                            Dict.insert k (OpenUnion union) result

                        Can.ExportUnionClosed ->
                            Dict.insert k (ClosedUnion union) result

                        _ ->
                            crash "impossible exports discovered in restrictUnions"
                )
                (\k union result -> Dict.insert k (PrivateUnion union) result)
                explicitExports
                unions
                Dict.empty


{-| Tags each type alias in `aliases` as public if `exports` exposes it,
under `exposing (..)` or by name, and as private otherwise. The kind of thing
the list says the name is goes unchecked.
-}
restrictAliases : Can.Exports -> Dict Name.Name Can.Alias -> Dict Name.Name Alias
restrictAliases exports aliases =
    case exports of
        Can.ExportEverything _ ->
            Dict.map (\_ alias -> PublicAlias alias) aliases

        Can.Export explicitExports ->
            Dict.merge
                (\_ _ result -> result)
                (\k _ alias result -> Dict.insert k (PublicAlias alias) result)
                (\k alias result -> Dict.insert k (PrivateAlias alias) result)
                explicitExports
                aliases
                Dict.empty



-- ====== TO PUBLIC ======


{-| Returns what a module importing this interface may see of a custom type:
the whole declaration if it is open, the declaration without its constructors
if it is closed, and `Nothing` if it is private.

A closed type keeps its type variables and its `opts` unchanged, but has an
empty `alts` and a `numAlts` of 0.

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


{-| Returns the declaration of a public type alias, or `Nothing` for a private
one.
-}
toPublicAlias : Alias -> Maybe Can.Alias
toPublicAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            Just alias

        PrivateAlias _ ->
            Nothing



-- ====== DEPENDENCY INTERFACE ======


{-| A module's interface in one of two forms: whole, or reduced to its types.

`Public` holds the whole interface. `Private` holds the module's package and
the declaration of every custom type and type alias the module declares, by
name, with no values and no operators. As `private` builds it, its
declarations are the interface's own without their visibility, so a closed or
private custom type keeps the constructors the interface records.

-}
type DependencyInterface
    = Public Interface
    | Private Pkg.Name (Dict Name.Name Can.Union) (Dict Name.Name Can.Alias)


{-| Returns the whole interface as a `Public` dependency interface.
-}
public : Interface -> DependencyInterface
public =
    Public


{-| Reduces an interface to a `Private` dependency interface: its package and
the declaration the interface holds for every custom type and type alias,
exposed or not, without its visibility.
-}
private : Interface -> DependencyInterface
private (Interface i) =
    Private i.home (Dict.map (\_ -> extractUnion) i.unions) (Dict.map (\_ -> extractAlias) i.aliases)


{-| Returns the declaration a custom type holds, whatever its visibility.
Unlike `toPublicUnion`, it does not remove a closed type's constructors.
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


{-| Returns the declaration of a type alias, whatever its visibility.
-}
extractAlias : Alias -> Can.Alias
extractAlias iAlias =
    case iAlias of
        PublicAlias alias ->
            alias

        PrivateAlias alias ->
            alias


{-| Reduces a dependency interface to its `Private` form, as `private` does,
and returns one that is already `Private` unchanged.
-}
privatize : DependencyInterface -> DependencyInterface
privatize di =
    case di of
        Public i ->
            private i

        Private _ _ _ ->
            di



-- ====== ENCODERS and DECODERS ======


{-| Encodes an interface as its package, then its values, custom types, type
aliases and operators, each as a dictionary keyed by name.
-}
interfaceEncoder : Interface -> Bytes.Encode.Encoder
interfaceEncoder (Interface i) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder i.home
        , BE.stdDict BE.string Can.annotationEncoder i.values
        , BE.stdDict BE.string unionEncoder i.unions
        , BE.stdDict BE.string aliasEncoder i.aliases
        , BE.stdDict BE.string binopEncoder i.binops
        ]


{-| A decoder for an interface as `interfaceEncoder` writes it. It fails on a
visibility tag `interfaceEncoder` does not write.
-}
interfaceDecoder : Bytes.Decode.Decoder Interface
interfaceDecoder =
    Bytes.Decode.map5 (\home_ values_ unions_ aliases_ binops_ -> Interface { home = home_, values = values_, unions = unions_, aliases = aliases_, binops = binops_ })
        Pkg.nameDecoder
        (BD.stdDict BD.string Can.annotationDecoder)
        (BD.stdDict BD.string unionDecoder)
        (BD.stdDict BD.string aliasDecoder)
        (BD.stdDict BD.string binopDecoder)


{-| Encodes a custom type as a one-byte visibility tag, 0 for open, 1 for
closed and 2 for private, followed by the declaration it holds.
-}
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


{-| A decoder for a custom type as `unionEncoder` writes it, failing on a tag
other than 0, 1 or 2.
-}
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


{-| Encodes a type alias as a one-byte visibility tag, 0 for public and 1 for
private, followed by its declaration.
-}
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


{-| A decoder for a type alias as `aliasEncoder` writes it, failing on a tag
other than 0 or 1.
-}
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


{-| Encodes an operator record as the name of its function, its annotation,
its associativity and its precedence, in that order.
-}
binopEncoder : Binop -> Bytes.Encode.Encoder
binopEncoder (Binop data) =
    Bytes.Encode.sequence
        [ BE.string data.name
        , Can.annotationEncoder data.annotation
        , Binop.associativityEncoder data.associativity
        , Binop.precedenceEncoder data.precedence
        ]


{-| A decoder for an operator record as `binopEncoder` writes it.
-}
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


{-| Encodes a dependency interface as a one-byte tag followed by its contents.
A `Public` one is tag 0 and the interface as `interfaceEncoder` writes it. A
`Private` one is tag 1, the package, and the custom type and type alias
declarations, each as a dictionary keyed by name.
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
                , BE.stdDict BE.string Can.unionEncoder unions
                , BE.stdDict BE.string Can.aliasEncoder aliases
                ]


{-| A decoder for a dependency interface as `dependencyInterfaceEncoder` writes
it, failing on a tag other than 0 or 1.
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
                            (BD.stdDict BD.string Can.unionDecoder)
                            (BD.stdDict BD.string Can.aliasDecoder)

                    _ ->
                        Bytes.Decode.fail
            )
