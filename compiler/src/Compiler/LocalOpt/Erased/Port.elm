module Compiler.LocalOpt.Erased.Port exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| A port and a program's flags carry values between Elm and the host as JSON,
so each needs a codec built from its type, and this module builds those codecs
as expressions in the erased optimized AST.

An outgoing port needs an _encoder_: a function from the Elm value to a
`Json.Encode.Value`. An incoming port and the flags need a _decoder_: a
`Json.Decode.Decoder` for the Elm value. Each is assembled by walking the
payload type and combining the library functions of `Json.Encode` and
`Json.Decode`, so the result is ordinary code that calls those modules.

The payload types handled are `Int`, `Float`, `Bool`, `String`,
`Json.Encode.Value`, `Bytes`, unit, `Maybe`, `List` and `Array` of a payload
type, tuples and closed records. Aliases are expanded first. This is the set
`Compiler.Canonicalize.Effects.checkPayload` accepts, and any other type
(`Char`, a function, a type variable, an extensible record, another custom
type) would crash the compiler here; `checkPayload` reports such types to the
user before this module runs. A type is recognised by its name alone; its home
module is not looked at.

The JSON shapes are: a tuple is an array of its elements, a record is an
object keyed by its field names, unit is `null`, and `Maybe` is `null` for
`Nothing` and the value itself for `Just`. `Bytes` goes through the
`encodeBytes` and `decodeBytes` functions of the `Json` kernel module.

Everything here runs in a `Names.Tracker`, which records each global and
kernel module a codec refers to, and the record fields it uses, as
`Compiler.LocalOpt.Erased.Names` describes.


# Encoders

@docs toEncoder


# Decoders

@docs toDecoder, toFlagsDecoder

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.IndexName as IndexName
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Erased.Names as Names
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== ENCODE ======


{-| Builds a function expression that encodes a value of type `tipe` as JSON.

Crashes on a type outside the payload set given in the module docstring.

-}
toEncoder : Can.Type Name -> Names.Tracker Opt.Expr
toEncoder tipe =
    case tipe of
        Can.TAlias _ _ args alias ->
            toEncoder (Type.dealias args alias)

        Can.TLambda _ _ _ ->
            crash "toEncoder: function"

        Can.TVar _ ->
            crash "toEncoder: type variable"

        Can.TUnit ->
            Names.map (Opt.Function [ Name.dollar ]) (encode "null")

        Can.TTuple a b cs ->
            encodeTuple a b cs

        Can.TType _ name args ->
            case args of
                [] ->
                    if name == Name.float then
                        encode "float"

                    else if name == Name.int then
                        encode "int"

                    else if name == Name.bool then
                        encode "bool"

                    else if name == Name.string then
                        encode "string"

                    else if name == Name.value then
                        Names.registerGlobal A.zero ModuleName.basics Name.identity_

                    else if name == Name.bytes then
                        encodeBytes

                    else
                        crash "toEncoder: bad custom type"

                [ arg ] ->
                    if name == Name.maybe then
                        encodeMaybe arg

                    else if name == Name.list then
                        encodeList arg

                    else if name == Name.array then
                        encodeArray arg

                    else
                        crash "toEncoder: bad custom type"

                _ ->
                    crash "toEncoder: bad custom type"

        Can.TRecord _ (Just _) ->
            crash "toEncoder: bad record"

        Can.TRecord fields Nothing ->
            let
                encodeField : ( Name, Can.FieldType Name ) -> Names.Tracker Opt.Expr
                encodeField ( name, Can.FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    value : Opt.Expr
                                    value =
                                        Opt.Call A.zero encoder [ Opt.Access (Opt.VarLocal Name.dollar) A.zero name ]
                                in
                                Opt.Tuple A.zero (Opt.Str A.zero (Name.toElmString name)) value []
                            )
            in
            encode "object"
                |> Names.andThen
                    (\object ->
                        Names.traverse encodeField (Dict.toList fields)
                            |> Names.andThen
                                (\keyValuePairs ->
                                    Names.registerFieldList (Dict.keys fields)
                                        (Opt.Function [ Name.dollar ] (Opt.Call A.zero object [ Opt.List A.zero keyValuePairs ]))
                                )
                    )



-- ====== ENCODE HELPERS ======


{-| Builds an encoder for `Maybe tipe`: `Json.Encode.null` for `Nothing`, and
the encoding of the contained value for `Just`.
-}
encodeMaybe : Can.Type Name -> Names.Tracker Opt.Expr
encodeMaybe tipe =
    encode "null"
        |> Names.andThen
            (\null ->
                toEncoder tipe
                    |> Names.andThen
                        (\encoder ->
                            Names.registerGlobal A.zero ModuleName.maybe "destruct"
                                |> Names.map
                                    (\destruct ->
                                        Opt.Function [ Name.dollar ]
                                            (Opt.Call A.zero
                                                destruct
                                                [ null
                                                , encoder
                                                , Opt.VarLocal Name.dollar
                                                ]
                                            )
                                    )
                        )
            )


{-| Builds an encoder for `List tipe`, which encodes each element with the
encoder for `tipe`.
-}
encodeList : Can.Type Name -> Names.Tracker Opt.Expr
encodeList tipe =
    encode "list"
        |> Names.andThen
            (\list ->
                toEncoder tipe
                    |> Names.map (Opt.Call A.zero list << List.singleton)
            )


{-| Builds an encoder for `Array tipe`, which encodes each element with the
encoder for `tipe`.
-}
encodeArray : Can.Type Name -> Names.Tracker Opt.Expr
encodeArray tipe =
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder tipe
                    |> Names.map (Opt.Call A.zero array << List.singleton)
            )


{-| Builds an encoder for a tuple with elements of types `a`, `b` and then
`cs`, which encodes it as a JSON array of the encoded elements in order.

The function binds the first two elements as `a` and `b`, and each later one,
taken from the tuple's `cs` field, under the `IndexName` name for its position
(`c`, `d` and so on).

-}
encodeTuple : Can.Type Name -> Can.Type Name -> List (Can.Type Name) -> Names.Tracker Opt.Expr
encodeTuple a b cs =
    let
        let_ : Name -> Index.ZeroBased -> Opt.Expr -> Opt.Expr
        let_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.Index index (Opt.Root Name.dollar))) body

        letCs_ : Name -> Int -> Opt.Expr -> Opt.Expr
        letCs_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.ArrayIndex index (Opt.Field "cs" (Opt.Root Name.dollar)))) body

        encodeArg : Name -> Can.Type Name -> Names.Tracker Opt.Expr
        encodeArg arg tipe =
            toEncoder tipe
                |> Names.map (\encoder -> Opt.Call A.zero encoder [ Opt.VarLocal arg ])
    in
    encode "list"
        |> Names.andThen
            (\list ->
                Names.registerGlobal A.zero ModuleName.basics Name.identity_
                    |> Names.andThen
                        (\identity ->
                            encodeArg "a" a
                                |> Names.andThen
                                    (\arg1 ->
                                        encodeArg "b" b
                                            |> Names.andThen
                                                (\arg2 ->
                                                    let
                                                        ( _, indexedCs ) =
                                                            List.foldl (\( i, c ) ( index, acc ) -> ( Index.next index, ( i, index, c ) :: acc ))
                                                                ( Index.third, [] )
                                                                (List.indexedMap Tuple.pair cs)
                                                                |> Tuple.mapSecond List.reverse
                                                    in
                                                    List.foldl
                                                        (\( _, i, tipe ) acc ->
                                                            encodeArg (IndexName.fromIndex i) tipe |> Names.andThen (\encodedArg -> Names.map (flip (++) [ encodedArg ]) acc)
                                                        )
                                                        (Names.pure [ arg1, arg2 ])
                                                        indexedCs
                                                        |> Names.map
                                                            (\args ->
                                                                Opt.Function [ Name.dollar ]
                                                                    (let_ "a"
                                                                        Index.first
                                                                        (let_ "b"
                                                                            Index.second
                                                                            (List.foldr (\( i, index, _ ) -> letCs_ (IndexName.fromIndex index) i)
                                                                                (Opt.Call A.zero list [ identity, Opt.List A.zero args ])
                                                                                indexedCs
                                                                            )
                                                                        )
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )



-- ====== FLAGS DECODER ======


{-| Builds a decoder expression for program flags of type `tipe`.

When `tipe` is unit itself (not an alias of it), the decoder is
`Json.Decode.succeed ()`, which accepts any JSON value; otherwise it is
`toDecoder`.

-}
toFlagsDecoder : Can.Type Name -> Names.Tracker Opt.Expr
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            Names.map (\succeed -> Opt.Call A.zero succeed [ Opt.Unit ])
                (decode "succeed")

        _ ->
            toDecoder tipe



-- ====== DECODE ======


{-| Builds a decoder expression for values of type `tipe`.

Crashes on a type outside the payload set given in the module docstring.

-}
toDecoder : Can.Type Name -> Names.Tracker Opt.Expr
toDecoder tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            crash "functions should not be allowed through input ports"

        Can.TVar _ ->
            crash "type variables should not be allowed through input ports"

        Can.TAlias _ _ args alias ->
            toDecoder (Type.dealias args alias)

        Can.TUnit ->
            decodeTuple0

        Can.TTuple a b cs ->
            decodeTuple a b cs

        Can.TType _ name args ->
            case ( name, args ) of
                ( "Float", [] ) ->
                    decode "float"

                ( "Int", [] ) ->
                    decode "int"

                ( "Bool", [] ) ->
                    decode "bool"

                ( "String", [] ) ->
                    decode "string"

                ( "Value", [] ) ->
                    decode "value"

                ( "Bytes", [] ) ->
                    decodeBytes

                ( "Maybe", [ arg ] ) ->
                    decodeMaybe arg

                ( "List", [ arg ] ) ->
                    decodeList arg

                ( "Array", [ arg ] ) ->
                    decodeArray arg

                _ ->
                    crash "toDecoder: bad type"

        Can.TRecord _ (Just _) ->
            crash "toDecoder: bad record"

        Can.TRecord fields Nothing ->
            decodeRecord fields



-- ====== DECODE MAYBE ======


{-| Builds a decoder for `Maybe tipe` that gives `Nothing` for JSON `null`
and otherwise `Just` the value decoded as `tipe`.

`null` is tried first, so where `tipe` can itself decode `null`, such as a
nested `Maybe`, a `null` still gives the outer `Nothing`.

-}
decodeMaybe : Can.Type Name -> Names.Tracker Opt.Expr
decodeMaybe tipe =
    Names.registerGlobal A.zero ModuleName.maybe "Nothing"
        |> Names.andThen
            (\nothing ->
                Names.registerGlobal A.zero ModuleName.maybe "Just"
                    |> Names.andThen
                        (\just ->
                            decode "oneOf"
                                |> Names.andThen
                                    (\oneOf ->
                                        decode "null"
                                            |> Names.andThen
                                                (\null ->
                                                    decode "map"
                                                        |> Names.andThen
                                                            (\map_ ->
                                                                Names.map
                                                                    (\subDecoder ->
                                                                        Opt.Call A.zero
                                                                            oneOf
                                                                            [ Opt.List A.zero
                                                                                [ Opt.Call A.zero null [ nothing ]
                                                                                , Opt.Call A.zero map_ [ just, subDecoder ]
                                                                                ]
                                                                            ]
                                                                    )
                                                                    (toDecoder tipe)
                                                            )
                                                )
                                    )
                        )
            )



-- ====== DECODE LIST ======


{-| Builds a decoder for a JSON array as `List tipe`.
-}
decodeList : Can.Type Name -> Names.Tracker Opt.Expr
decodeList tipe =
    decode "list"
        |> Names.andThen
            (\list ->
                Names.map (Opt.Call A.zero list << List.singleton)
                    (toDecoder tipe)
            )



-- ====== DECODE ARRAY ======


{-| Builds a decoder for a JSON array as `Array tipe`.
-}
decodeArray : Can.Type Name -> Names.Tracker Opt.Expr
decodeArray tipe =
    decode "array"
        |> Names.andThen
            (\array ->
                Names.map (Opt.Call A.zero array << List.singleton)
                    (toDecoder tipe)
            )



-- ====== DECODE TUPLES ======


{-| A decoder for unit, which accepts only JSON `null`.
-}
decodeTuple0 : Names.Tracker Opt.Expr
decodeTuple0 =
    Names.map (\null -> Opt.Call A.zero null [ Opt.Unit ])
        (decode "null")


{-| Builds a decoder for a tuple with elements of types `a`, `b` and then `cs`,
read from a JSON array by position.

Each element is decoded with `Json.Decode.index` and bound by
`Json.Decode.andThen` to the name `Name.fromVarIndex` gives its position
(`_v0`, `_v1` and so on). The innermost step builds the tuple from those
names and passes it to `Json.Decode.succeed`.

-}
decodeTuple : Can.Type Name -> Can.Type Name -> List (Can.Type Name) -> Names.Tracker Opt.Expr
decodeTuple a b cs =
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                let
                    ( allElems, lastElem ) =
                        case List.reverse cs of
                            c :: rest ->
                                ( a :: b :: List.reverse rest, c )

                            _ ->
                                ( [ a ], b )

                    tuple : Opt.Expr
                    tuple =
                        Opt.Tuple A.zero (toLocal 0) (toLocal 1) (List.indexedMap (\i _ -> toLocal (i + 2)) cs)
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length cs + 1) lastElem (Opt.Call A.zero succeed [ tuple ]))
                    (List.indexedMap Tuple.pair allElems)
            )


{-| Returns a reference to the local variable for tuple position `index`, as
bound by `indexAndThen`.
-}
toLocal : Int -> Opt.Expr
toLocal index =
    Opt.VarLocal (Name.fromVarIndex index)


{-| Wraps `decoder` so that it runs after the element at array index `i` has
been decoded as `tipe` and bound to the name `Name.fromVarIndex i`.
-}
indexAndThen : Int -> Can.Type Name -> Opt.Expr -> Names.Tracker Opt.Expr
indexAndThen i tipe decoder =
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "index"
                    |> Names.andThen
                        (\index ->
                            Names.map
                                (\typeDecoder ->
                                    Opt.Call A.zero
                                        andThen
                                        [ Opt.Function [ Name.fromVarIndex i ] decoder
                                        , Opt.Call A.zero index [ Opt.Int A.zero i, typeDecoder ]
                                        ]
                                )
                                (toDecoder tipe)
                        )
            )



-- ====== DECODE RECORDS ======


{-| Builds a decoder for a closed record with `fields`, read from a JSON object
by field name.

Each field is decoded with `Json.Decode.field` and bound by
`Json.Decode.andThen` to a local of the field's own name, and the record is
built from those locals and passed to `Json.Decode.succeed`. The fields are
nested in reverse alphabetical order, so the last field alphabetically is
decoded first. Every field name is registered once in the field counts.

-}
decodeRecord : Dict Name.Name (Can.FieldType Name) -> Names.Tracker Opt.Expr
decodeRecord fields =
    let
        toFieldExpr : Name -> b -> Opt.Expr
        toFieldExpr name _ =
            Opt.VarLocal name

        record : Opt.Expr
        record =
            Opt.Record (Dict.map toFieldExpr fields)
    in
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                Names.registerFieldList (Dict.keys fields) (Dict.toList fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen optCall fieldDecoder))
                                (Names.pure (Opt.Call A.zero succeed [ record ]))
                                fieldDecoders
                        )
            )


{-| Wraps `decoder` so that it runs after field `key` has been decoded as its
type and bound to a local named `key`.
-}
fieldAndThen : Opt.Expr -> ( Name.Name, Can.FieldType Name ) -> Names.Tracker Opt.Expr
fieldAndThen decoder ( key, Can.FieldType _ tipe ) =
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "field"
                    |> Names.andThen
                        (\field ->
                            Names.map
                                (\typeDecoder ->
                                    Opt.Call A.zero
                                        andThen
                                        [ Opt.Function [ key ] decoder
                                        , Opt.Call A.zero field [ Opt.Str A.zero (Name.toElmString key), typeDecoder ]
                                        ]
                                )
                                (toDecoder tipe)
                        )
            )



-- ====== GLOBALS HELPERS ======


{-| Returns a reference to the `Json.Encode` value `name`, registering it as a
dependency.
-}
encode : Name -> Names.Tracker Opt.Expr
encode name =
    Names.registerGlobal A.zero ModuleName.jsonEncode name


{-| Returns a reference to the `Json.Decode` value `name`, registering it as a
dependency.
-}
decode : Name -> Names.Tracker Opt.Expr
decode name =
    Names.registerGlobal A.zero ModuleName.jsonDecode name



-- ====== BYTES HELPERS ======


{-| A reference to the `Json` kernel's `encodeBytes`, the encoder used for
`Bytes`, with the kernel module registered as a dependency.
-}
encodeBytes : Names.Tracker Opt.Expr
encodeBytes =
    Names.registerKernel "Elm" Name.json (Opt.VarKernel A.zero "Elm" Name.json "encodeBytes")


{-| A reference to the `Json` kernel's `decodeBytes`, the decoder used for
`Bytes`, with the kernel module registered as a dependency.
-}
decodeBytes : Names.Tracker Opt.Expr
decodeBytes =
    Names.registerKernel "Elm" Name.json (Opt.VarKernel A.zero "Elm" Name.json "decodeBytes")
