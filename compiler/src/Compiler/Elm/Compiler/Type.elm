module Compiler.Elm.Compiler.Type exposing
    ( Type(..), Alias(..), Union(..), DebugMetadata(..)
    , toDoc
    , encode, encodeMetadata, decoder
    , bytesEncoder, bytesDecoder
    )

{-| Package documentation (`docs.json`) and the Elm debugger both describe
types to readers outside the compiler, and this module is the type they use: a
plain tree of names, with none of the compiler's internal annotations.

A `Type` names a type constructor by a string and nothing more. Which string
that is depends on whoever built the value; this module neither qualifies nor
resolves a name. When a type leaves the compiler as JSON it is written as Elm
type syntax, the text a programmer would write, and `decoder` reads that text
back with the compiler's own type parser. The binary encoding keeps the tree
as it is.

_Debug metadata_ is what the debugger needs to decode and show a program's
messages: the message type, together with the type aliases and custom types it
refers to.


# Types

@docs Type, Alias, Union, DebugMetadata


# Conversion

@docs toDoc


# JSON Encoding

@docs encode, encodeMetadata, decoder


# Binary Encoding

@docs bytesEncoder, bytesDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Json.Decode as D exposing (Decoder)
import Compiler.Json.Encode as E exposing (Value)
import Compiler.Json.String as Json
import Compiler.Parse.Primitives as P
import Compiler.Parse.Type as Type
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)



-- ====== TYPES ======


{-| An Elm type, as written in a type annotation.

`Lambda` is a function type from its first type to its second; a function of
several arguments is a chain of them, grouping to the right.

`Var` is a type variable.

`Type` is a named type applied to its arguments. The name is stored as given,
qualified or not.

`Record` carries its fields in order and, for an extensible record, the name
of the variable it extends.

`Unit` is `()`.

`Tuple` carries its first two elements and then any further ones.

-}
type Type
    = Lambda Type Type
    | Var Name.Name
    | Type Name.Name (List Type)
    | Record (List ( Name.Name, Type )) (Maybe Name.Name)
    | Unit
    | Tuple Type Type (List Type)


{-| The debug metadata of a program: its message type, and the type aliases and
custom types that are listed alongside it for the debugger.

Nothing here checks that the lists hold exactly the types the message type
refers to; that is up to whoever builds the value.

-}
type DebugMetadata
    = DebugMetadata Type (List Alias) (List Union)


{-| A type alias definition: its name, its type variables in order, and the type
it stands for.
-}
type Alias
    = Alias Name.Name (List Name.Name) Type


{-| A custom type definition: its name, its type variables in order, and each
constructor's name with the types of its arguments.
-}
type Union
    = Union Name.Name (List Name.Name) (List ( Name.Name, List Type ))



-- ====== TO DOC ======


{-| Returns a document showing `tipe` in Elm type syntax, parenthesised as
`context` requires.

Names are printed exactly as they are stored. `localizer` is passed down to
every part of the type but is not used to shorten any name.

-}
toDoc : L.Localizer -> RT.Context -> Type -> D.Doc
toDoc localizer context tipe =
    case tipe of
        Lambda _ _ ->
            case List.map (toDoc localizer RT.Func) (collectLambdas tipe) of
                a :: b :: cs ->
                    RT.lambda context a b cs

                _ ->
                    crash "toDoc Lambda"

        Var name ->
            D.fromName name

        Unit ->
            D.fromChars "()"

        Tuple a b cs ->
            RT.tuple
                (toDoc localizer RT.None a)
                (toDoc localizer RT.None b)
                (List.map (toDoc localizer RT.None) cs)

        Type name args ->
            RT.apply
                context
                (D.fromName name)
                (List.map (toDoc localizer RT.App) args)

        Record fields ext ->
            RT.record
                (List.map (entryToDoc localizer) fields)
                (Maybe.map D.fromName ext)


{-| Returns the documents for one record field's name and its type.
-}
entryToDoc : L.Localizer -> ( Name.Name, Type ) -> ( D.Doc, D.Doc )
entryToDoc localizer ( field, fieldType ) =
    ( D.fromName field, toDoc localizer RT.None fieldType )


{-| Returns the argument types of a chain of `Lambda`s followed by its final
result, or a one-element list for a type that is not a function.
-}
collectLambdas : Type -> List Type
collectLambdas tipe =
    case tipe of
        Lambda arg body ->
            arg :: collectLambdas body

        _ ->
            [ tipe ]



-- ====== JSON for TYPE ======


{-| Encodes a type as a JSON string holding the type in Elm syntax, with names
as stored and every group laid out on one line.
-}
encode : Type -> Value
encode tipe =
    E.string (D.toLine (toDoc L.empty RT.None tipe))


{-| A decoder for a type written as Elm type syntax in a JSON string, which must
be read in full.

A qualified name such as `Maybe.Maybe` is read as its last part only, so
`decoder` does not give back the names `encode` was given when they were
qualified.

-}
decoder : Decoder () Type
decoder =
    D.customString parser (\_ _ -> ())


{-| A parser for one Elm type expression, converted to a `Type`, with every
parse error reduced to `()`.
-}
parser : P.Parser () Type
parser =
    P.specialize (\_ _ _ -> ()) (P.map fromRawType (P.map (Tuple.first >> Tuple.second) (Type.expression [])))


{-| Converts a parsed type to a `Type`, dropping positions, comments,
parentheses and the module part of a qualified name.
-}
fromRawType : Src.Type -> Type
fromRawType (A.At _ astType) =
    case astType of
        Src.TLambda ( _, t1 ) ( _, t2 ) ->
            Lambda (fromRawType t1) (fromRawType t2)

        Src.TVar x ->
            Var x

        Src.TUnit ->
            Unit

        Src.TTuple ( _, a ) ( _, b ) cs ->
            Tuple
                (fromRawType a)
                (fromRawType b)
                (List.map (Src.c2EolValue >> fromRawType) cs)

        Src.TType _ name args ->
            Type name (List.map fromRawType (List.map Tuple.second args))

        Src.TTypeQual _ _ name args ->
            Type name (List.map fromRawType (List.map Tuple.second args))

        Src.TRecord fields maybeExt _ ->
            let
                fromField : Src.C2 ( Src.C1 (A.Located a), Src.C1 Src.Type ) -> ( a, Type )
                fromField ( _, ( ( _, A.At _ field ), ( _, tipe ) ) ) =
                    ( field, fromRawType tipe )
            in
            Record
                (List.map fromField fields)
                (Maybe.map (\( _, A.At _ ext ) -> ext) maybeExt)

        Src.TParens ( _, astType_ ) ->
            fromRawType astType_



-- ====== JSON for PROGRAM ======


{-| Encodes debug metadata as a JSON object with three fields: `message`, the
message type as `encode` writes it, and `aliases` and `unions`, objects keyed
by each definition's name.
-}
encodeMetadata : DebugMetadata -> Value
encodeMetadata (DebugMetadata msg aliases unions) =
    E.object
        [ ( "message", encode msg )
        , ( "aliases", E.object (List.map toTypeAliasField aliases) )
        , ( "unions", E.object (List.map toCustomTypeField unions) )
        ]


{-| Returns the key and value for a type alias in the `aliases` object: its type
variables as `args` and the aliased type as `type`.
-}
toTypeAliasField : Alias -> ( String, Value )
toTypeAliasField (Alias name args tipe) =
    ( Json.fromName name
    , E.object
        [ ( "args", E.list E.string args )
        , ( "type", encode tipe )
        ]
    )


{-| Returns the key and value for a custom type in the `unions` object: its type
variables as `args` and, as `tags`, an object from each constructor to its
argument types.
-}
toCustomTypeField : Union -> ( String, Value )
toCustomTypeField (Union name args constructors) =
    ( Json.fromName name
    , E.object
        [ ( "args", E.list E.string args )
        , ( "tags", E.object (List.map toVariantObject constructors) )
        ]
    )


{-| Returns the entry for one constructor in a `tags` object.
-}
toVariantObject : ( Name.Name, List Type ) -> ( String, Value )
toVariantObject ( name, args ) =
    ( Json.fromName name, E.list encode args )



-- ====== BINARY ENCODERS and DECODERS ======


{-| Encodes a type in the binary format that `bytesDecoder` reads: a tag byte
for the constructor, then its contents.
-}
bytesEncoder : Type -> Bytes.Encode.Encoder
bytesEncoder type_ =
    case type_ of
        Lambda arg body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , bytesEncoder arg
                , bytesEncoder body
                ]

        Var name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        Type name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.string name
                , BE.list bytesEncoder args
                ]

        Record fields ext ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.list (BE.jsonPair BE.string bytesEncoder) fields
                , BE.maybe BE.string ext
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 4

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , bytesEncoder a
                , bytesEncoder b
                , BE.list bytesEncoder cs
                ]


{-| A decoder for a type written by `bytesEncoder`. An unknown tag byte fails.
-}
bytesDecoder : Bytes.Decode.Decoder Type
bytesDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Lambda
                            bytesDecoder
                            bytesDecoder

                    1 ->
                        Bytes.Decode.map Var BD.string

                    2 ->
                        Bytes.Decode.map2 Type
                            BD.string
                            (BD.list bytesDecoder)

                    3 ->
                        Bytes.Decode.map2 Record
                            (BD.list (BD.jsonPair BD.string bytesDecoder))
                            (BD.maybe BD.string)

                    4 ->
                        Bytes.Decode.succeed Unit

                    5 ->
                        Bytes.Decode.map3 Tuple
                            bytesDecoder
                            bytesDecoder
                            (BD.list bytesDecoder)

                    _ ->
                        Bytes.Decode.fail
            )
