module Compiler.LocalOpt.Typed.Port exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| A value crosses a port, or arrives as a program's flags, as JSON, so the
compiler has to write the code that converts between the Elm value and JSON.
This module writes that code for the typed optimized AST, where every node
carries a type.

`toEncoder` builds a function from a value of the port's type to a
`Json.Encode.Value`, and `toDecoder` builds a `Json.Decode.Decoder` for the
type. `toFlagsDecoder` is `toDecoder` except for flags of type `()`, which are
accepted whatever the JSON is. The code is built from the `Json.Encode` and
`Json.Decode` library functions, by recursion on the `Can.Payload` that
`Compiler.Canonicalize.Effects.checkPayload` validated: `Maybe`, `List` and
`Array` wrap the codec of their element, a tuple is a JSON array, a closed
record is a JSON object keyed by field name, unit is JSON `null`, and `Bytes`
uses the `Json` kernel's bytes functions. This is the typed counterpart of
`Compiler.LocalOpt.Erased.Port`. Each node's type is the payload's
`Can.payloadType`.

The synthesized calls, functions, literals and locals carry concrete types, as
do the references to `Basics.identity`, `Maybe.Nothing` and `Maybe.Just`; but
each `Json.Encode` or `Json.Decode` function, `Maybe.destruct` and the bytes
kernels is given the placeholder type `Can.TVar` of its own name. No node carries a solver
variable. Building a codec registers its dependencies and record field uses in
the `Names.Tracker` it runs in.

@docs toEncoder
@docs toDecoder, toFlagsDecoder

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Index as Index
import Compiler.Core.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.LocalOpt.Typed.Names as Names
import Dict exposing (Dict)
import Maybe.Extra as Maybe



-- ====== ENCODE ======


{-| Returns a one-argument function expression that encodes a value of the
payload type `payload` as a `Json.Encode.Value`, or, for `List` and `Array`,
the `Json.Encode.list` or `Json.Encode.array` call that does the same.

A record becomes an object whose keys are its field names, in name order, and
`Json.Encode.Value` is encoded by `Basics.identity`.

-}
toEncoder : Can.Payload -> Names.Tracker (TOpt.Expr Name)
toEncoder payload =
    let
        tipe : Can.Type Name
        tipe =
            Can.payloadType payload
    in
    case payload of
        Can.PayloadUnit ->
            let
                valueType =
                    Can.TType ModuleName.jsonEncode "Value" []
            in
            -- `null` is the function's body, not a callee, so it carries its
            -- real type, `Json.Encode.Value`, rather than the placeholder
            -- `encode` gives a reference: the function's type must be its
            -- parameter type arrowed into its body's type (TOPT_005).
            Names.registerGlobal A.zero ModuleName.jsonEncode "null" valueType Nothing
                |> Names.map
                    (\null ->
                        TOpt.Function Nothing [ ( Name.dollar, Can.TUnit ) ] null { tipe = Can.tLambda Can.TUnit valueType, tvar = Nothing }
                    )

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
            Names.registerGlobal A.zero ModuleName.basics Name.identity_ (Can.tLambda tipe tipe) Nothing

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
                valueType =
                    Can.TType ModuleName.jsonEncode "Value" []

                encodeField : ( Name, ( Int, Can.Payload ) ) -> Names.Tracker (TOpt.Expr Name)
                encodeField ( name, ( _, fieldPayload ) ) =
                    let
                        fieldType : Can.Type Name
                        fieldType =
                            Can.payloadType fieldPayload
                    in
                    toEncoder fieldPayload
                        |> Names.map
                            (\encoder ->
                                let
                                    tupleType =
                                        Can.TTuple (Can.TType ModuleName.string "String" []) valueType Nothing

                                    value =
                                        TOpt.Call A.zero encoder [ TOpt.Access (TOpt.VarLocal Name.dollar { tipe = tipe, tvar = Nothing }) A.zero name { tipe = fieldType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing }
                                in
                                TOpt.Tuple A.zero (TOpt.Str A.zero (Name.toElmString name) { tipe = Can.TType ModuleName.string "String" [], tvar = Nothing }) value Nothing { tipe = tupleType, tvar = Nothing }
                            )
            in
            encode "object"
                |> Names.andThen
                    (\object ->
                        Names.traverse encodeField (Dict.toList fields)
                            |> Names.andThen
                                (\keyValuePairs ->
                                    let
                                        listType =
                                            Can.TType ModuleName.list "List" [ Can.TTuple (Can.TType ModuleName.string "String" []) valueType Nothing ]

                                        funcType =
                                            Can.tLambda tipe valueType
                                    in
                                    Names.registerFieldList (Dict.keys fields)
                                        (TOpt.Function Nothing
                                            [ ( Name.dollar, tipe ) ]
                                            (TOpt.Call A.zero object [ TOpt.List A.zero keyValuePairs { tipe = listType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing })
                                            { tipe = funcType, tvar = Nothing }
                                        )
                                )
                    )



-- ====== ENCODE HELPERS ======


{-| Returns a function that encodes a `Maybe tipe`, through `Maybe.destruct`, as
JSON `null` for `Nothing` and as the encoded contents for `Just`.
-}
encodeMaybe : Can.Payload -> Names.Tracker (TOpt.Expr Name)
encodeMaybe payload =
    let
        tipe =
            Can.payloadType payload

        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ tipe ]

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "null"
        |> Names.andThen
            (\null ->
                toEncoder payload
                    |> Names.andThen
                        (\encoder ->
                            Names.registerGlobal A.zero ModuleName.maybe "destruct" (Can.TVar "destruct") Nothing
                                |> Names.map
                                    (\destruct ->
                                        let
                                            funcType =
                                                Can.tLambda maybeType valueType
                                        in
                                        TOpt.Function Nothing
                                            [ ( Name.dollar, maybeType ) ]
                                            (TOpt.Call A.zero
                                                destruct
                                                [ null
                                                , encoder
                                                , TOpt.VarLocal Name.dollar { tipe = maybeType, tvar = Nothing }
                                                ]
                                                { tipe = valueType, tvar = Nothing }
                                            )
                                            { tipe = funcType, tvar = Nothing }
                                    )
                        )
            )


{-| Returns `Json.Encode.list` applied to the encoder for `tipe`: an encoder of a
`List tipe` as a JSON array.
-}
encodeList : Can.Payload -> Names.Tracker (TOpt.Expr Name)
encodeList payload =
    let
        tipe =
            Can.payloadType payload

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "list"
        |> Names.andThen
            (\list ->
                toEncoder payload
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero list [ encoder ] { tipe = Can.tLambda (Can.TType ModuleName.list "List" [ tipe ]) valueType, tvar = Nothing }
                        )
            )


{-| Returns `Json.Encode.array` applied to the encoder for `tipe`: an encoder of
an `Array tipe` as a JSON array.
-}
encodeArray : Can.Payload -> Names.Tracker (TOpt.Expr Name)
encodeArray payload =
    let
        tipe =
            Can.payloadType payload

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder payload
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero array [ encoder ] { tipe = Can.tLambda (Can.TType ModuleName.array "Array" [ tipe ]) valueType, tvar = Nothing }
                        )
            )


{-| Returns a function that encodes a tuple with element types `a`, `b` and, for
a three-element tuple, `maybeC`, as a JSON array of the encoded elements, in
order.

The function destructures its argument by position, with a tuple index whose
hint is `HintTuple2` for a pair and `HintTuple3` for a triple; the third
element is projected the same way, never as a record field.

-}
encodeTuple : Can.Payload -> Can.Payload -> Maybe Can.Payload -> Names.Tracker (TOpt.Expr Name)
encodeTuple a b maybeC =
    let
        tupleType =
            Can.payloadType (Can.PayloadTuple a b maybeC)

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []

        listValueType =
            Can.TType ModuleName.list "List" [ valueType ]

        hint =
            case maybeC of
                Just _ ->
                    TOpt.HintTuple3

                Nothing ->
                    TOpt.HintTuple2

        let_ : Name -> Can.Type Name -> Index.ZeroBased -> TOpt.Expr Name -> TOpt.Expr Name
        let_ arg argType index body =
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index hint (TOpt.Root Name.dollar)) { tipe = argType, tvar = Nothing }) body { tipe = TOpt.typeOf body, tvar = Nothing }

        encodeArg : Name -> Can.Payload -> Names.Tracker (TOpt.Expr Name)
        encodeArg arg argPayload =
            toEncoder argPayload
                |> Names.map (\encoder -> TOpt.Call A.zero encoder [ TOpt.VarLocal arg { tipe = Can.payloadType argPayload, tvar = Nothing } ] { tipe = valueType, tvar = Nothing })
    in
    encode "list"
        |> Names.andThen
            (\list ->
                Names.registerGlobal A.zero ModuleName.basics Name.identity_ (Can.tLambda listValueType listValueType) Nothing
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
                                                                    funcType =
                                                                        Can.tLambda tupleType valueType

                                                                    listCall =
                                                                        TOpt.Call A.zero list [ identity, TOpt.List A.zero (arg1 :: arg2 :: Maybe.toList maybeArg3) { tipe = listValueType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing }
                                                                in
                                                                TOpt.Function Nothing
                                                                    [ ( Name.dollar, tupleType ) ]
                                                                    (let_ "a"
                                                                        (Can.payloadType a)
                                                                        Index.first
                                                                        (let_ "b"
                                                                            (Can.payloadType b)
                                                                            Index.second
                                                                            (case maybeC of
                                                                                Just c ->
                                                                                    let_ "c" (Can.payloadType c) Index.third listCall

                                                                                Nothing ->
                                                                                    listCall
                                                                            )
                                                                        )
                                                                    )
                                                                    { tipe = funcType, tvar = Nothing }
                                                            )
                                                )
                                    )
                        )
            )



-- ====== FLAGS DECODER ======


{-| Returns a decoder for program flags of the payload type `payload`.

Flags of type `()` decode as `Json.Decode.succeed ()`, which ignores the JSON;
any other type gets `toDecoder payload`, so unit inside another type expects
`null`.

-}
toFlagsDecoder : Can.Payload -> Names.Tracker (TOpt.Expr Name)
toFlagsDecoder payload =
    case payload of
        Can.PayloadUnit ->
            decode "succeed"
                |> Names.map
                    (\succeed ->
                        TOpt.Call A.zero succeed [ TOpt.Unit { tipe = Can.TUnit, tvar = Nothing } ] { tipe = Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ], tvar = Nothing }
                    )

        _ ->
            toDecoder payload



-- ====== DECODE ======


{-| Returns a `Json.Decode.Decoder` expression for values of the payload type
`payload`.

Unit decodes from JSON `null`, a tuple from a JSON array by index, and a record
from a JSON object, one field at a time by name. A `Maybe` is `null` for
`Nothing` or else the decoded contents.

-}
toDecoder : Can.Payload -> Names.Tracker (TOpt.Expr Name)
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
            decodeRecord fields (Can.payloadType payload)



-- ====== DECODE HELPERS ======


{-| Returns a decoder of `Maybe tipe`: `Json.Decode.oneOf` that tries `null` as
`Nothing` first and then the decoder for `tipe` mapped through `Just`.
-}
decodeMaybe : Can.Payload -> Names.Tracker (TOpt.Expr Name)
decodeMaybe payload =
    let
        tipe =
            Can.payloadType payload

        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ maybeType ]
    in
    Names.registerGlobal A.zero ModuleName.maybe "Nothing" maybeType Nothing
        |> Names.andThen
            (\nothing ->
                Names.registerGlobal A.zero ModuleName.maybe "Just" (Can.tLambda tipe maybeType) Nothing
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
                                                                toDecoder payload
                                                                    |> Names.map
                                                                        (\subDecoder ->
                                                                            let
                                                                                listType =
                                                                                    Can.TType ModuleName.list "List" [ decoderType ]
                                                                            in
                                                                            TOpt.Call A.zero
                                                                                oneOf
                                                                                [ TOpt.List A.zero
                                                                                    [ TOpt.Call A.zero null [ nothing ] { tipe = decoderType, tvar = Nothing }
                                                                                    , TOpt.Call A.zero map_ [ just, subDecoder ] { tipe = decoderType, tvar = Nothing }
                                                                                    ]
                                                                                    { tipe = listType, tvar = Nothing }
                                                                                ]
                                                                                { tipe = decoderType, tvar = Nothing }
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| Returns `Json.Decode.list` applied to the decoder for `tipe`.
-}
decodeList : Can.Payload -> Names.Tracker (TOpt.Expr Name)
decodeList payload =
    let
        tipe =
            Can.payloadType payload

        listType =
            Can.TType ModuleName.list "List" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ listType ]
    in
    decode "list"
        |> Names.andThen
            (\list ->
                toDecoder payload
                    |> Names.map
                        (\subDecoder ->
                            TOpt.Call A.zero list [ subDecoder ] { tipe = decoderType, tvar = Nothing }
                        )
            )


{-| Returns `Json.Decode.array` applied to the decoder for `tipe`.
-}
decodeArray : Can.Payload -> Names.Tracker (TOpt.Expr Name)
decodeArray payload =
    let
        tipe =
            Can.payloadType payload

        arrayType =
            Can.TType ModuleName.array "Array" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ arrayType ]
    in
    decode "array"
        |> Names.andThen
            (\array ->
                toDecoder payload
                    |> Names.map
                        (\subDecoder ->
                            TOpt.Call A.zero array [ subDecoder ] { tipe = decoderType, tvar = Nothing }
                        )
            )


{-| The decoder of unit: `Json.Decode.null ()`, which succeeds only on JSON
`null`.
-}
decodeTuple0 : Names.Tracker (TOpt.Expr Name)
decodeTuple0 =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ]
    in
    decode "null"
        |> Names.map
            (\null ->
                TOpt.Call A.zero null [ TOpt.Unit { tipe = Can.TUnit, tvar = Nothing } ] { tipe = decoderType, tvar = Nothing }
            )


{-| Returns a decoder of a tuple with element types `a`, `b` and, for a
three-element tuple, `maybeC`, read from a JSON array.

Element `i` is decoded with `Json.Decode.index i` and bound to `Name.fromVarIndex i`
by a chain of `Json.Decode.andThen`, element 0 outermost, and the innermost
step is `Json.Decode.succeed` of the tuple of those locals.

-}
decodeTuple : Can.Payload -> Can.Payload -> Maybe Can.Payload -> Names.Tracker (TOpt.Expr Name)
decodeTuple a b maybeC =
    let
        tupleType =
            Can.payloadType (Can.PayloadTuple a b maybeC)

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ tupleType ]
    in
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

                    tuple =
                        TOpt.Tuple A.zero (toLocal 0 a) (toLocal 1 b) (Maybe.map (toLocal 2) maybeC) { tipe = tupleType, tvar = Nothing }
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length allElems) lastElem (TOpt.Call A.zero succeed [ tuple ] { tipe = decoderType, tvar = Nothing }))
                    (List.indexedMap Tuple.pair allElems)
            )


{-| Returns a reference, of the type of `payload`, to the local that
`decodeTuple` binds for element `index`.
-}
toLocal : Int -> Can.Payload -> TOpt.Expr Name
toLocal index payload =
    TOpt.VarLocal (Name.fromVarIndex index) { tipe = Can.payloadType payload, tvar = Nothing }


{-| Returns `Json.Decode.andThen (\v -> decoder) (Json.Decode.index i d)`, where
`d` decodes `payload` and `v` is `Name.fromVarIndex i`: the step that decodes
array element `i` and makes it visible to `decoder` under that name.
-}
indexAndThen : Int -> Can.Payload -> TOpt.Expr Name -> Names.Tracker (TOpt.Expr Name)
indexAndThen i payload decoder =
    let
        tipe =
            Can.payloadType payload

        decoderResultType =
            TOpt.typeOf decoder
    in
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "index"
                    |> Names.andThen
                        (\index ->
                            toDecoder payload
                                |> Names.map
                                    (\typeDecoder ->
                                        let
                                            funcType =
                                                Can.tLambda tipe decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function Nothing [ ( Name.fromVarIndex i, tipe ) ] decoder { tipe = funcType, tvar = Nothing }
                                            , TOpt.Call A.zero index [ TOpt.Int A.zero i { tipe = Can.TType ModuleName.basics "Int" [], tvar = Nothing }, typeDecoder ] { tipe = subDecoderType, tvar = Nothing }
                                            ]
                                            { tipe = decoderResultType, tvar = Nothing }
                                    )
                        )
            )


{-| Returns a decoder of the closed record `recordType` with fields `fields`,
read from a JSON object.

Each field is decoded with `Json.Decode.field` and bound to a local of the
field's own name by a chain of `Json.Decode.andThen`, and the innermost step is
`Json.Decode.succeed` of the record built from those locals. The field with the
last name in name order is the outermost step, so it is decoded first.

-}
decodeRecord : Dict Name.Name ( Int, Can.Payload ) -> Can.Type Name -> Names.Tracker (TOpt.Expr Name)
decodeRecord fields recordType =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ recordType ]

        toFieldExpr : Name -> ( Int, Can.Payload ) -> TOpt.Expr Name
        toFieldExpr name ( _, fieldPayload ) =
            TOpt.VarLocal name { tipe = Can.payloadType fieldPayload, tvar = Nothing }

        record =
            TOpt.Record (Dict.map toFieldExpr fields) { tipe = recordType, tvar = Nothing }
    in
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                Names.registerFieldList (Dict.keys fields) (Dict.toList fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen optCall fieldDecoder))
                                (Names.pure (TOpt.Call A.zero succeed [ record ] { tipe = decoderType, tvar = Nothing }))
                                fieldDecoders
                        )
            )


{-| Returns the step that decodes field `key` of type `tipe` with
`Json.Decode.field` and passes it, bound to the name `key`, to `decoder`
through `Json.Decode.andThen`.
-}
fieldAndThen : TOpt.Expr Name -> ( Name.Name, ( Int, Can.Payload ) ) -> Names.Tracker (TOpt.Expr Name)
fieldAndThen decoder ( key, ( _, payload ) ) =
    let
        tipe =
            Can.payloadType payload

        decoderResultType =
            TOpt.typeOf decoder
    in
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "field"
                    |> Names.andThen
                        (\field ->
                            toDecoder payload
                                |> Names.map
                                    (\typeDecoder ->
                                        let
                                            funcType =
                                                Can.tLambda tipe decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function Nothing [ ( key, tipe ) ] decoder { tipe = funcType, tvar = Nothing }
                                            , TOpt.Call A.zero field [ TOpt.Str A.zero (Name.toElmString key) { tipe = Can.TType ModuleName.string "String" [], tvar = Nothing }, typeDecoder ] { tipe = subDecoderType, tvar = Nothing }
                                            ]
                                            { tipe = decoderResultType, tvar = Nothing }
                                    )
                        )
            )



-- ====== GLOBALS HELPERS ======


{-| Returns a reference to the `Json.Encode` function `name`, typed with the
placeholder `Can.TVar name`, after registering it as a dependency.
-}
encode : Name -> Names.Tracker (TOpt.Expr Name)
encode name =
    Names.registerGlobal A.zero ModuleName.jsonEncode name (Can.TVar name) Nothing


{-| Returns a reference to the `Json.Decode` function `name`, typed with the
placeholder `Can.TVar name`, after registering it as a dependency.
-}
decode : Name -> Names.Tracker (TOpt.Expr Name)
decode name =
    Names.registerGlobal A.zero ModuleName.jsonDecode name (Can.TVar name) Nothing



-- ====== BYTES HELPERS ======


{-| A reference to the `Json` kernel's `encodeBytes`, the encoder used for
`Bytes`, typed with a placeholder type variable; using it registers a dependency
on the `Json` kernel module.
-}
encodeBytes : Names.Tracker (TOpt.Expr Name)
encodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero "Elm" Name.json "encodeBytes" { tipe = Can.TVar "encodeBytes", tvar = Nothing })


{-| A reference to the `Json` kernel's `decodeBytes`, the decoder used for
`Bytes`, typed with a placeholder type variable; using it registers a dependency
on the `Json` kernel module.
-}
decodeBytes : Names.Tracker (TOpt.Expr Name)
decodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero "Elm" Name.json "decodeBytes" { tipe = Can.TVar "decodeBytes", tvar = Nothing })
