module Compiler.Elm.Compiler.Type.Extract exposing
    ( Types(..), Types_
    , fromType, fromMsg, fromInterface, fromDependencyInterface
    , merge, mergeMany
    , typesEncoder, typesDecoder
    )

{-| A type shown outside the compiler, in documentation or to the debugger,
has to be readable without the compiler's own data structures, and a type that
names other types is only understood together with their definitions. This
module turns canonical types into the plain types of `Compiler.Elm.Compiler.Type`
and, for a message type, gathers the definitions of every type alias and custom
type it reaches.

Converting a type is a walk that also records, as it goes, every named type it
meets: each alias and each custom type, identified by home module and name.
That walk runs in an _extractor_, a small state carrying the two sets of names
recorded so far. `fromType` keeps only the converted type. `fromMsg` uses the
recorded names: it looks each one up in a `Types`, converts its definition,
and repeats on whatever the definitions name in turn, until no new name turns
up.

A named type is printed as its module's name and its own name joined by a dot,
such as `Maybe.Maybe`, without the package. An alias is printed by name with
its arguments, not expanded; its expansion is walked only to record the types
it mentions.

`Types` is where definitions are looked up, one entry per module, built from
module interfaces and combined with `merge`.


# Types

@docs Types, Types_


# Extraction

@docs fromType, fromMsg, fromInterface, fromDependencyInterface


# Operations

@docs merge, mergeMany


# Binary Encoding

@docs typesEncoder, typesDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Compiler.Type as T
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== EXTRACTION ======


{-| Returns `astType` converted to a `T.Type`, discarding the record of the
named types it mentions.
-}
fromType : Can.Type Name -> T.Type
fromType astType =
    Tuple.second (run (extract astType))


{-| Produces an extractor that converts `astType` and records every alias and
custom type it names, including those named inside an alias's expansion. The
arrow slot of a function type is dropped.
-}
extract : Can.Type Name -> Extractor T.Type
extract astType =
    case astType of
        Can.TLambda _ arg result ->
            pure T.Lambda
                |> apply (extract arg)
                |> apply (extract result)

        Can.TVar x ->
            pure (T.Var x)

        Can.TType home name args ->
            addUnion (Opt.Global home name) (T.Type (toPublicName home name))
                |> apply (traverse extract args)

        Can.TRecord fields ext ->
            traverse (tupleTraverse extract) (Can.fieldsToList fields)
                |> map (\efields -> T.Record efields ext)

        Can.TUnit ->
            pure T.Unit

        Can.TTuple a b cs ->
            pure T.Tuple
                |> apply (extract a)
                |> apply (extract b)
                |> apply (traverse extract cs)

        Can.TAlias home name args aliasType ->
            addAlias (Opt.Global home name) ()
                |> andThen
                    (\_ ->
                        extract (Type.dealias args aliasType)
                            |> andThen
                                (\_ ->
                                    map (T.Type (toPublicName home name))
                                        (traverse (extract << Tuple.second) args)
                                )
                    )


{-| Returns the printed name of a named type: its module's name, a dot, and
`name`. The package is left out.
-}
toPublicName : ModuleName.Canonical -> Name.Name -> Name.Name
toPublicName (ModuleName.Canonical _ home) name =
    Name.sepBy '.' home name



-- ====== TRANSITIVELY AVAILABLE TYPES ======


{-| The custom type and type alias definitions of a set of modules, by module,
that `fromMsg` looks named types up in.
-}
type Types
    = Types (Data.Map.Dict String ModuleName.Canonical Types_)


{-| One module's custom type and type alias definitions, each by name,
whatever their visibility.
-}
type Types_
    = Types_ (Dict Name.Name Can.Union) (Dict Name.Name Can.Alias)


{-| Returns one collection holding every module of every element of
`listOfTypes`, and an empty one for an empty list.

Where a module occurs in more than one element, the entry kept is that of the
earliest element after the first, and the first element's entry is kept only
when no later element has the module.

-}
mergeMany : List Types -> Types
mergeMany listOfTypes =
    case listOfTypes of
        [] ->
            Types Data.Map.empty

        t :: ts ->
            List.foldr merge t ts


{-| Returns every module of both collections. Where both hold the same module,
the first collection's entry is kept.
-}
merge : Types -> Types -> Types
merge (Types types1) (Types types2) =
    Types (Data.Map.union types1 types2)


{-| Returns a collection of the one module that `I.Interface` describes, filed
under the interface's package and the module name `name`. Every custom type and
alias is included, whatever its visibility.
-}
fromInterface : ModuleName.Raw -> I.Interface -> Types
fromInterface name (I.Interface iface) =
    Types_ (Dict.map (\_ -> I.extractUnion) iface.unions) (Dict.map (\_ -> I.extractAlias) iface.aliases) |> Data.Map.singleton ModuleName.toComparableCanonical (ModuleName.Canonical iface.home name) |> Types


{-| Returns a collection of the one module `home`, holding the custom type and
alias definitions of its dependency interface, whatever their visibility.
-}
fromDependencyInterface : ModuleName.Canonical -> I.DependencyInterface -> Types
fromDependencyInterface home di =
    Types
        (Data.Map.singleton ModuleName.toComparableCanonical home <|
            case di of
                I.Public (I.Interface iface) ->
                    Types_ (Dict.map (\_ -> I.extractUnion) iface.unions) (Dict.map (\_ -> I.extractAlias) iface.aliases)

                I.Private _ unions aliases ->
                    Types_ unions aliases
        )



-- ====== EXTRACT MODEL AND MSG ======


{-| Returns the debug metadata for the message type `message`: the converted
type, and the definition of every alias and custom type it reaches, directly or
through other definitions.

Every module the message type can reach must be in `types`, with each reached
definition in it; a missing module or definition crashes the compiler. `List`
from `elm/core` is the exception: it needs no entry and is listed as a custom
type with the variable `a` and no constructors.

-}
fromMsg : Types -> Can.Type Name -> T.DebugMetadata
fromMsg types message =
    let
        ( msgDeps, msgType ) =
            run (extract message)

        ( aliases, unions ) =
            extractTransitive types noDeps msgDeps
    in
    T.DebugMetadata msgType aliases unions


{-| Returns the definitions of the aliases and custom types in `next` that are
not in `seen`, followed by those of every name they reach in turn, until no new
name appears. A name is listed at most once.
-}
extractTransitive : Types -> Deps -> Deps -> ( List T.Alias, List T.Union )
extractTransitive types (Deps seenAliases seenUnions) (Deps nextAliases nextUnions) =
    let
        aliases : EverySet String Opt.Global
        aliases =
            EverySet.diff nextAliases seenAliases

        unions : EverySet String Opt.Global
        unions =
            EverySet.diff nextUnions seenUnions
    in
    if EverySet.isEmpty aliases && EverySet.isEmpty unions then
        ( [], [] )

    else
        let
            ( newDeps, ( resultAlias, resultUnion ) ) =
                run
                    (pure Tuple.pair
                        |> apply (traverse (extractAlias types) (EverySet.toList aliases))
                        |> apply (traverse (extractUnion types) (EverySet.toList unions))
                    )

            oldDeps : Deps
            oldDeps =
                Deps (EverySet.union seenAliases nextAliases) (EverySet.union seenUnions nextUnions)

            ( remainingResultAlias, remainingResultUnion ) =
                extractTransitive types oldDeps newDeps
        in
        ( resultAlias ++ remainingResultAlias, resultUnion ++ remainingResultUnion )


{-| Produces an extractor that converts the definition of an alias, looked up
in `Types` and crashing if it is not there.
-}
extractAlias : Types -> Opt.Global -> Extractor T.Alias
extractAlias (Types dict) (Opt.Global home name) =
    let
        (Can.Alias args aliasType) =
            Utils.find ModuleName.toComparableCanonical home dict
                |> (\(Types_ _ aliasInfo) -> aliasInfo)
                |> stdFind name
    in
    map (T.Alias (toPublicName home name) args) (extract aliasType)


{-| Produces an extractor that converts the definition of a custom type, looked
up in `Types` and crashing if it is not there. `List` is described without a
lookup, with the variable `a` and no constructors.
-}
extractUnion : Types -> Opt.Global -> Extractor T.Union
extractUnion (Types dict) (Opt.Global home name) =
    if name == Name.list && home == ModuleName.list then
        T.Union (toPublicName home name) [ "a" ] [] |> pure

    else
        let
            pname : Name.Name
            pname =
                toPublicName home name

            (Can.Union unionData) =
                Utils.find ModuleName.toComparableCanonical home dict
                    |> (\(Types_ unionInfo _) -> unionInfo)
                    |> stdFind name
        in
        map (T.Union pname unionData.vars) (traverse extractCtor unionData.alts)


{-| Returns the value under `key` in a standard `Dict`, and crashes the compiler
if there is none.
-}
stdFind : comparable -> Dict comparable a -> a
stdFind key dict =
    case Dict.get key dict of
        Just value ->
            value

        Nothing ->
            crash "stdFind: key not found"


{-| Produces an extractor that converts one constructor to its name and the
converted types of its arguments.
-}
extractCtor : Can.Ctor -> Extractor ( Name.Name, List T.Type )
extractCtor (Can.Ctor c) =
    map (Tuple.pair c.name) (traverse extract c.args)



-- ====== DEPS ======


{-| The named types one walk recorded: the aliases, then the custom types.
-}
type Deps
    = Deps (EverySet String Opt.Global) (EverySet String Opt.Global)


{-| The record of a walk that has met no named type.
-}
noDeps : Deps
noDeps =
    Deps EverySet.empty EverySet.empty



-- ====== EXTRACTOR ======


{-| A computation producing an `a` that may record aliases and custom types as
it goes. It takes the aliases and custom types recorded so far and returns them
extended, with its result.
-}
type Extractor a
    = Extractor (EverySet String Opt.Global -> EverySet String Opt.Global -> EResult a)


{-| What an extractor returns: the recorded aliases, the recorded custom types,
and its result.
-}
type EResult a
    = EResult (EverySet String Opt.Global) (EverySet String Opt.Global) a


{-| Returns what an extractor records, starting from nothing, and its result.
-}
run : Extractor a -> ( Deps, a )
run (Extractor k) =
    case k EverySet.empty EverySet.empty of
        EResult aliases unions value ->
            ( Deps aliases unions, value )


{-| Produces an extractor that records the alias `alias` and returns `value`.
-}
addAlias : Opt.Global -> a -> Extractor a
addAlias alias value =
    Extractor <|
        \aliases unions ->
            EResult (EverySet.insert Opt.toComparableGlobal alias aliases) unions value


{-| Produces an extractor that records the custom type `union` and returns
`value`.
-}
addUnion : Opt.Global -> a -> Extractor a
addUnion union value =
    Extractor <|
        \aliases unions ->
            EResult aliases (EverySet.insert Opt.toComparableGlobal union unions) value


{-| Produces an extractor that applies `func` to the result of another.
-}
map : (a -> b) -> Extractor a -> Extractor b
map func (Extractor k) =
    Extractor <|
        \aliases unions ->
            case k aliases unions of
                EResult a1 u1 value ->
                    EResult a1 u1 (func value)


{-| Produces an extractor that records nothing and returns `value`.
-}
pure : a -> Extractor a
pure value =
    Extractor (\aliases unions -> EResult aliases unions value)


{-| Produces an extractor that runs the function extractor, then the value
extractor, and applies the one result to the other.
-}
apply : Extractor a -> Extractor (a -> b) -> Extractor b
apply (Extractor kv) (Extractor kf) =
    Extractor <|
        \aliases unions ->
            case kf aliases unions of
                EResult a1 u1 func ->
                    case kv a1 u1 of
                        EResult a2 u2 value ->
                            EResult a2 u2 (func value)


{-| Produces an extractor that runs another, then the extractor `callback`
returns for its result.
-}
andThen : (a -> Extractor b) -> Extractor a -> Extractor b
andThen callback (Extractor ka) =
    Extractor <|
        \aliases unions ->
            case ka aliases unions of
                EResult a1 u1 value ->
                    case callback value of
                        Extractor kb ->
                            kb a1 u1


{-| Produces an extractor that applies `f` to every element and collects the
results in order. The extractors run from the last element to the first.
-}
traverse : (a -> Extractor b) -> List a -> Extractor (List b)
traverse f =
    List.foldr (\a -> andThen (\c -> map (\va -> va :: c) (f a)))
        (pure [])


{-| Produces an extractor that applies `f` to the second element of a pair,
keeping the first.
-}
tupleTraverse : (b -> Extractor c) -> ( a, b ) -> Extractor ( a, c )
tupleTraverse f ( a, b ) =
    map (Tuple.pair a) (f b)



-- ====== ENCODERS and DECODERS ======


{-| Produces the binary encoder for a `Types`, which `typesDecoder` reads back.
-}
typesEncoder : Types -> Bytes.Encode.Encoder
typesEncoder (Types types) =
    BE.assocListDict ModuleName.canonicalEncoder types_Encoder types


{-| The binary decoder for a `Types` as `typesEncoder` writes it.
-}
typesDecoder : Bytes.Decode.Decoder Types
typesDecoder =
    Bytes.Decode.map Types (BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder types_Decoder)


{-| Produces the binary encoder for one module's definitions: custom types,
then aliases.
-}
types_Encoder : Types_ -> Bytes.Encode.Encoder
types_Encoder (Types_ unionInfo aliasInfo) =
    Bytes.Encode.sequence
        [ BE.stdDict BE.string Can.unionEncoder unionInfo
        , BE.stdDict BE.string Can.aliasEncoder aliasInfo
        ]


{-| The binary decoder for one module's definitions as `types_Encoder` writes
them.
-}
types_Decoder : Bytes.Decode.Decoder Types_
types_Decoder =
    Bytes.Decode.map2 Types_
        (BD.stdDict BD.string Can.unionDecoder)
        (BD.stdDict BD.string Can.aliasDecoder)
