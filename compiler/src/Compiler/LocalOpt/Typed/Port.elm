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
type. `toFlagsDecoder` is `toDecoder` except for flags whose type is written as
`()` (not an alias of it), which are accepted whatever the JSON is. The code is built from the `Json.Encode` and
`Json.Decode` library functions, by recursion on the type: aliases are seen
through, `Maybe`, `List` and `Array` wrap the codec of their element, a tuple
is a JSON array, a closed record is a JSON object keyed by field name, unit is
JSON `null`, and `Bytes` uses the `Json` kernel's bytes functions. This is the
typed counterpart of `Compiler.LocalOpt.Erased.Port`.

Types are recognised by name alone, not by home module. A type that cannot
cross a port (a function, a type variable, an extensible record, any other
named type) crashes the compiler; `Compiler.Canonicalize.Effects` is expected
to have rejected such a payload already.

The synthesized calls, functions, literals and locals carry concrete types, as
do the references to `Basics.identity`, `Maybe.Nothing` and `Maybe.Just`; but
each `Json.Encode` or `Json.Decode` function, `Maybe.destruct` and the bytes
kernels is given the placeholder type `Can.TVar` of its own name. No node carries a solver
variable. Building a codec registers its dependencies and record field uses in
the `Names.Tracker` it runs in.

@docs toEncoder
@docs toDecoder, toFlagsDecoder

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.IndexName as IndexName
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== ENCODE ======


{-| Returns a one-argument function expression that encodes a value of type
`tipe` as a `Json.Encode.Value`, or, for `List` and `Array`, the
`Json.Encode.list` or `Json.Encode.array` call that does the same.

A record becomes an object whose keys are its field names, in name order, and
`Json.Encode.Value` is encoded by `Basics.identity`. A type that cannot cross a
port crashes, as the module docstring describes.

-}
toEncoder : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
toEncoder tipe =
    case tipe of
        Can.TAlias _ _ args alias ->
            toEncoder (Type.dealias args alias)

        Can.TLambda _ _ _ ->
            crash "toEncoder: function"

        Can.TVar _ ->
            crash "toEncoder: type variable"

        Can.TUnit ->
            encode "null"
                |> Names.map
                    (\null ->
                        let
                            funcType =
                                Can.tLambda Can.TUnit (Can.TType ModuleName.jsonEncode "Value" [])
                        in
                        TOpt.Function Nothing [ ( Name.dollar, Can.TUnit ) ] null { tipe = funcType, tvar = Nothing }
                    )

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
                        Names.registerGlobal A.zero ModuleName.basics Name.identity_ (Can.tLambda tipe tipe) Nothing

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
                valueType =
                    Can.TType ModuleName.jsonEncode "Value" []

                encodeField : ( Name, Can.FieldType Name ) -> Names.Tracker (TOpt.Expr Name)
                encodeField ( name, Can.FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    tupleType =
                                        Can.TTuple (Can.TType ModuleName.string "String" []) valueType []

                                    value =
                                        TOpt.Call A.zero encoder [ TOpt.Access (TOpt.VarLocal Name.dollar { tipe = tipe, tvar = Nothing }) A.zero name { tipe = fieldType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing }
                                in
                                TOpt.Tuple A.zero (TOpt.Str A.zero (Name.toElmString name) { tipe = Can.TType ModuleName.string "String" [], tvar = Nothing }) value [] { tipe = tupleType, tvar = Nothing }
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
                                            Can.TType ModuleName.list "List" [ Can.TTuple (Can.TType ModuleName.string "String" []) valueType [] ]

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
encodeMaybe : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
encodeMaybe tipe =
    let
        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ tipe ]

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "null"
        |> Names.andThen
            (\null ->
                toEncoder tipe
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
encodeList : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
encodeList tipe =
    let
        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "list"
        |> Names.andThen
            (\list ->
                toEncoder tipe
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero list [ encoder ] { tipe = Can.tLambda (Can.TType ModuleName.list "List" [ tipe ]) valueType, tvar = Nothing }
                        )
            )


{-| Returns `Json.Encode.array` applied to the encoder for `tipe`: an encoder of
an `Array tipe` as a JSON array.
-}
encodeArray : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
encodeArray tipe =
    let
        valueType =
            Can.TType ModuleName.jsonEncode "Value" []
    in
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder tipe
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero array [ encoder ] { tipe = Can.tLambda (Can.TType ModuleName.array "Array" [ tipe ]) valueType, tvar = Nothing }
                        )
            )


{-| Returns a function that encodes a tuple with element types `a`, `b` and then
`cs` as a JSON array of the encoded elements, in order.

The function destructures its argument by position, with a tuple index whose
hint is `HintTuple2` for a pair and `HintTuple3` otherwise; the elements after
the second are projected the same way, never as a record field.

-}
encodeTuple : Can.Type Name -> Can.Type Name -> List (Can.Type Name) -> Names.Tracker (TOpt.Expr Name)
encodeTuple a b cs =
    let
        tupleType =
            Can.TTuple a b cs

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []

        listValueType =
            Can.TType ModuleName.list "List" [ valueType ]

        let_ : Name -> Can.Type Name -> Index.ZeroBased -> TOpt.Expr Name -> TOpt.Expr Name
        let_ arg argType index body =
            let
                hint =
                    if List.isEmpty cs then
                        TOpt.HintTuple2

                    else
                        TOpt.HintTuple3
            in
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index hint (TOpt.Root Name.dollar)) { tipe = argType, tvar = Nothing }) body { tipe = TOpt.typeOf body, tvar = Nothing }

        letCs_ : Name -> Can.Type Name -> Index.ZeroBased -> TOpt.Expr Name -> TOpt.Expr Name
        letCs_ arg argType index body =
            -- letCs_ only binds elements of cs, so cs is non-empty and the hint is HintTuple3.
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index TOpt.HintTuple3 (TOpt.Root Name.dollar)) { tipe = argType, tvar = Nothing }) body { tipe = TOpt.typeOf body, tvar = Nothing }

        encodeArg : Name -> Can.Type Name -> Names.Tracker (TOpt.Expr Name)
        encodeArg arg argType =
            toEncoder argType
                |> Names.map (\encoder -> TOpt.Call A.zero encoder [ TOpt.VarLocal arg { tipe = argType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing })
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
                                                    let
                                                        ( _, indexedCs ) =
                                                            List.foldl (\( i, c ) ( index, acc ) -> ( Index.next index, ( i, index, c ) :: acc ))
                                                                ( Index.third, [] )
                                                                (List.indexedMap Tuple.pair cs)
                                                                |> Tuple.mapSecond List.reverse
                                                    in
                                                    List.foldl
                                                        (\( _, i, argType ) acc ->
                                                            encodeArg (IndexName.fromIndex i) argType
                                                                |> Names.andThen (\encodedArg -> Names.map (flip (++) [ encodedArg ]) acc)
                                                        )
                                                        (Names.pure [ arg1, arg2 ])
                                                        indexedCs
                                                        |> Names.map
                                                            (\args ->
                                                                let
                                                                    funcType =
                                                                        Can.tLambda tupleType valueType
                                                                in
                                                                TOpt.Function Nothing
                                                                    [ ( Name.dollar, tupleType ) ]
                                                                    (let_ "a"
                                                                        a
                                                                        Index.first
                                                                        (let_ "b"
                                                                            b
                                                                            Index.second
                                                                            (List.foldr (\( _, index, argType ) -> letCs_ (IndexName.fromIndex index) argType index)
                                                                                (TOpt.Call A.zero list [ identity, TOpt.List A.zero args { tipe = listValueType, tvar = Nothing } ] { tipe = valueType, tvar = Nothing })
                                                                                indexedCs
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


{-| Returns a decoder for program flags of type `tipe`.

Flags whose type is literally `()` decode as `Json.Decode.succeed ()`, which
ignores the JSON; any other type gets `toDecoder tipe`, so an alias of unit, or
unit inside another type, expects `null`.

-}
toFlagsDecoder : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            decode "succeed"
                |> Names.map
                    (\succeed ->
                        TOpt.Call A.zero succeed [ TOpt.Unit { tipe = Can.TUnit, tvar = Nothing } ] { tipe = Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ], tvar = Nothing }
                    )

        _ ->
            toDecoder tipe



-- ====== DECODE ======


{-| Returns a `Json.Decode.Decoder` expression for values of type `tipe`.

Unit decodes from JSON `null`, a tuple from a JSON array by index, and a record
from a JSON object, one field at a time by name. A `Maybe` is `null` for
`Nothing` or else the decoded contents. A type that cannot cross a port
crashes, as the module docstring describes.

-}
toDecoder : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
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
            decodeRecord fields tipe



-- ====== DECODE HELPERS ======


{-| Returns a decoder of `Maybe tipe`: `Json.Decode.oneOf` that tries `null` as
`Nothing` first and then the decoder for `tipe` mapped through `Just`.
-}
decodeMaybe : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
decodeMaybe tipe =
    let
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
                                                                toDecoder tipe
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
decodeList : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
decodeList tipe =
    let
        listType =
            Can.TType ModuleName.list "List" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ listType ]
    in
    decode "list"
        |> Names.andThen
            (\list ->
                toDecoder tipe
                    |> Names.map
                        (\subDecoder ->
                            TOpt.Call A.zero list [ subDecoder ] { tipe = decoderType, tvar = Nothing }
                        )
            )


{-| Returns `Json.Decode.array` applied to the decoder for `tipe`.
-}
decodeArray : Can.Type Name -> Names.Tracker (TOpt.Expr Name)
decodeArray tipe =
    let
        arrayType =
            Can.TType ModuleName.array "Array" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ arrayType ]
    in
    decode "array"
        |> Names.andThen
            (\array ->
                toDecoder tipe
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


{-| Returns a decoder of a tuple with element types `a`, `b` and then `cs`, read
from a JSON array.

Element `i` is decoded with `Json.Decode.index i` and bound to `Name.fromVarIndex i`
by a chain of `Json.Decode.andThen`, element 0 outermost, and the innermost
step is `Json.Decode.succeed` of the tuple of those locals.

-}
decodeTuple : Can.Type Name -> Can.Type Name -> List (Can.Type Name) -> Names.Tracker (TOpt.Expr Name)
decodeTuple a b cs =
    let
        tupleType =
            Can.TTuple a b cs

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ tupleType ]
    in
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

                    tuple =
                        TOpt.Tuple A.zero (toLocal 0 a) (toLocal 1 b) (List.indexedMap (\i c -> toLocal (i + 2) c) cs) { tipe = tupleType, tvar = Nothing }
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length cs + 1) lastElem (TOpt.Call A.zero succeed [ tuple ] { tipe = decoderType, tvar = Nothing }))
                    (List.indexedMap Tuple.pair allElems)
            )


{-| Returns a reference, of type `tipe`, to the local that `decodeTuple` binds
for element `index`.
-}
toLocal : Int -> Can.Type Name -> TOpt.Expr Name
toLocal index tipe =
    TOpt.VarLocal (Name.fromVarIndex index) { tipe = tipe, tvar = Nothing }


{-| Returns `Json.Decode.andThen (\v -> decoder) (Json.Decode.index i d)`, where
`d` decodes `tipe` and `v` is `Name.fromVarIndex i`: the step that decodes
array element `i` and makes it visible to `decoder` under that name.
-}
indexAndThen : Int -> Can.Type Name -> TOpt.Expr Name -> Names.Tracker (TOpt.Expr Name)
indexAndThen i tipe decoder =
    let
        decoderResultType =
            TOpt.typeOf decoder
    in
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "index"
                    |> Names.andThen
                        (\index ->
                            toDecoder tipe
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
decodeRecord : Dict Name.Name (Can.FieldType Name) -> Can.Type Name -> Names.Tracker (TOpt.Expr Name)
decodeRecord fields recordType =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ recordType ]

        toFieldExpr : Name -> Can.FieldType Name -> TOpt.Expr Name
        toFieldExpr name (Can.FieldType _ fieldType) =
            TOpt.VarLocal name { tipe = fieldType, tvar = Nothing }

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
fieldAndThen : TOpt.Expr Name -> ( Name.Name, Can.FieldType Name ) -> Names.Tracker (TOpt.Expr Name)
fieldAndThen decoder ( key, Can.FieldType _ tipe ) =
    let
        decoderResultType =
            TOpt.typeOf decoder
    in
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "field"
                    |> Names.andThen
                        (\field ->
                            toDecoder tipe
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
