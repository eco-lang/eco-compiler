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

The payload types handled are those of `Can.Payload`: `Int`, `Float`, `Bool`,
`String`, `Json.Encode.Value`, `Bytes`, unit, `Maybe`, `List` and `Array` of a
payload type, tuples and closed records, as
`Compiler.Canonicalize.Effects.checkPayload` validates them.

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

import Compiler.Core.Annotation as A
import Compiler.Core.Index as Index
import Compiler.Core.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Optimized as Opt
import Compiler.LocalOpt.Erased.Names as Names
import Dict exposing (Dict)
import Maybe.Extra as Maybe



-- ====== ENCODE ======


{-| Builds a function expression that encodes a value of the payload type
`payload` as JSON.
-}
toEncoder : Can.Payload -> Names.Tracker Opt.Expr
toEncoder payload =
    case payload of
        Can.PayloadUnit ->
            Names.map (Opt.Function [ Name.dollar ]) (encode "null")

        Can.PayloadTuple a b cs ->
            encodeTuple a b cs

        Can.PayloadFloat ->
            encode "float"

        Can.PayloadInt ->
            encode "int"

        Can.PayloadBool ->
            encode "bool"

        Can.PayloadString ->
            encode "string"

        Can.PayloadValue ->
            Names.registerGlobal A.zero ModuleName.basics Name.identity_

        Can.PayloadBytes ->
            encodeBytes

        Can.PayloadMaybe arg ->
            encodeMaybe arg

        Can.PayloadList arg ->
            encodeList arg

        Can.PayloadArray arg ->
            encodeArray arg

        Can.PayloadRecord fields ->
            let
                encodeField : ( Name, ( Int, Can.Payload ) ) -> Names.Tracker Opt.Expr
                encodeField ( name, ( _, fieldType ) ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    value : Opt.Expr
                                    value =
                                        Opt.Call A.zero encoder [ Opt.Access (Opt.VarLocal Name.dollar) A.zero name ]
                                in
                                Opt.Tuple A.zero (Opt.Str A.zero (Name.toElmString name)) value Nothing
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
encodeMaybe : Can.Payload -> Names.Tracker Opt.Expr
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
encodeList : Can.Payload -> Names.Tracker Opt.Expr
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
encodeArray : Can.Payload -> Names.Tracker Opt.Expr
encodeArray tipe =
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder tipe
                    |> Names.map (Opt.Call A.zero array << List.singleton)
            )


{-| Builds an encoder for a tuple with elements of types `a`, `b` and, for a
three-element tuple, `maybeC`, which encodes it as a JSON array of the encoded
elements in order.

The function binds the elements as `a`, `b` and, for a three-element tuple,
`c`.

-}
encodeTuple : Can.Payload -> Can.Payload -> Maybe Can.Payload -> Names.Tracker Opt.Expr
encodeTuple a b maybeC =
    let
        let_ : Name -> Index.ZeroBased -> Opt.Expr -> Opt.Expr
        let_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.Index index (Opt.Root Name.dollar))) body

        encodeArg : Name -> Can.Payload -> Names.Tracker Opt.Expr
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
                                                    Names.traverseMaybe (encodeArg "c") maybeC
                                                        |> Names.map
                                                            (\maybeArg3 ->
                                                                let
                                                                    listCall : Opt.Expr
                                                                    listCall =
                                                                        Opt.Call A.zero list [ identity, Opt.List A.zero (arg1 :: arg2 :: Maybe.toList maybeArg3) ]
                                                                in
                                                                Opt.Function [ Name.dollar ]
                                                                    (let_ "a"
                                                                        Index.first
                                                                        (let_ "b"
                                                                            Index.second
                                                                            (case maybeArg3 of
                                                                                Just _ ->
                                                                                    let_ "c" Index.third listCall

                                                                                Nothing ->
                                                                                    listCall
                                                                            )
                                                                        )
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )



-- ====== FLAGS DECODER ======


{-| Builds a decoder expression for program flags of the payload type
`payload`.

When `payload` is unit, the decoder is `Json.Decode.succeed ()`, which accepts
any JSON value; otherwise it is `toDecoder`.

-}
toFlagsDecoder : Can.Payload -> Names.Tracker Opt.Expr
toFlagsDecoder payload =
    case payload of
        Can.PayloadUnit ->
            Names.map (\succeed -> Opt.Call A.zero succeed [ Opt.Unit ])
                (decode "succeed")

        _ ->
            toDecoder payload



-- ====== DECODE ======


{-| Builds a decoder expression for values of the payload type `payload`.
-}
toDecoder : Can.Payload -> Names.Tracker Opt.Expr
toDecoder payload =
    case payload of
        Can.PayloadUnit ->
            decodeTuple0

        Can.PayloadTuple a b cs ->
            decodeTuple a b cs

        Can.PayloadFloat ->
            decode "float"

        Can.PayloadInt ->
            decode "int"

        Can.PayloadBool ->
            decode "bool"

        Can.PayloadString ->
            decode "string"

        Can.PayloadValue ->
            decode "value"

        Can.PayloadBytes ->
            decodeBytes

        Can.PayloadMaybe arg ->
            decodeMaybe arg

        Can.PayloadList arg ->
            decodeList arg

        Can.PayloadArray arg ->
            decodeArray arg

        Can.PayloadRecord fields ->
            decodeRecord fields



-- ====== DECODE MAYBE ======


{-| Builds a decoder for `Maybe tipe` that gives `Nothing` for JSON `null`
and otherwise `Just` the value decoded as `tipe`.

`null` is tried first, so where `tipe` can itself decode `null`, such as a
nested `Maybe`, a `null` still gives the outer `Nothing`.

-}
decodeMaybe : Can.Payload -> Names.Tracker Opt.Expr
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
decodeList : Can.Payload -> Names.Tracker Opt.Expr
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
decodeArray : Can.Payload -> Names.Tracker Opt.Expr
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


{-| Builds a decoder for a tuple with elements of types `a`, `b` and, for a
three-element tuple, `maybeC`, read from a JSON array by position.

Each element is decoded with `Json.Decode.index` and bound by
`Json.Decode.andThen` to the name `Name.fromVarIndex` gives its position
(`_v0`, `_v1` and so on). The innermost step builds the tuple from those
names and passes it to `Json.Decode.succeed`.

-}
decodeTuple : Can.Payload -> Can.Payload -> Maybe Can.Payload -> Names.Tracker Opt.Expr
decodeTuple a b maybeC =
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                let
                    ( allElems, lastElem ) =
                        case maybeC of
                            Just c ->
                                ( [ a, b ], c )

                            Nothing ->
                                ( [ a ], b )

                    tuple : Opt.Expr
                    tuple =
                        Opt.Tuple A.zero (toLocal 0) (toLocal 1) (Maybe.map (\_ -> toLocal 2) maybeC)
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length allElems) lastElem (Opt.Call A.zero succeed [ tuple ]))
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
indexAndThen : Int -> Can.Payload -> Opt.Expr -> Names.Tracker Opt.Expr
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
decodeRecord : Dict Name.Name ( Int, Can.Payload ) -> Names.Tracker Opt.Expr
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
fieldAndThen : Opt.Expr -> ( Name.Name, ( Int, Can.Payload ) ) -> Names.Tracker Opt.Expr
fieldAndThen decoder ( key, ( _, tipe ) ) =
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
