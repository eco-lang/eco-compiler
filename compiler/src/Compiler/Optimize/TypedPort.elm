module Compiler.Optimize.TypedPort exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| Typed port encoder/decoder generation.

Generates JSON encoders and decoders for port types with full type information
preserved. Like the regular Port generator but produces TypedOptimized expressions
with Can.Type annotations, enabling type-aware code generation for ports.

Handles all Elm types that can pass through ports: primitives, records, tuples,
Maybe, List, Array, and the Json.Decode.Value / Json.Encode.Value types.


# Encoders

@docs toEncoder


# Decoders

@docs toDecoder, toFlagsDecoder

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.JavaScript.Name as JsName
import Compiler.Optimize.TypedNames as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ENCODE


{-| Generate a JSON encoder function for the given Elm type.
Produces a typed expression that converts Elm values to JSON.
-}
toEncoder : Can.Type -> Names.Tracker TOpt.Expr
toEncoder tipe =
    case tipe of
        Can.TAlias _ _ args alias ->
            toEncoder (Type.dealias args alias)

        Can.TLambda _ _ ->
            crash "toEncoder: function"

        Can.TVar _ ->
            crash "toEncoder: type variable"

        Can.TUnit ->
            encode "null"
                |> Names.map
                    (\nullEncoder ->
                        let
                            funcType : Can.Type
                            funcType =
                                Can.TLambda Can.TUnit jsonValueType
                        in
                        TOpt.Function [ ( Name.dollar, Can.TUnit ) ] nullEncoder funcType
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
                        let
                            identityType : Can.Type
                            identityType =
                                Can.TLambda jsonValueType jsonValueType
                        in
                        Names.registerGlobal A.zero ModuleName.basics Name.identity_ identityType

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
                encodeField : ( Name, Can.FieldType ) -> Names.Tracker TOpt.Expr
                encodeField ( name, Can.FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    accessExpr : TOpt.Expr
                                    accessExpr =
                                        TOpt.Access (TOpt.VarLocal Name.dollar tipe) A.zero name fieldType

                                    value : TOpt.Expr
                                    value =
                                        TOpt.Call A.zero encoder [ accessExpr ] jsonValueType

                                    tupleType : Can.Type
                                    tupleType =
                                        Can.TTuple stringType jsonValueType []
                                in
                                TOpt.Tuple A.zero (TOpt.Str A.zero (Name.toElmString name) stringType) value [] tupleType
                            )
            in
            encode "object"
                |> Names.andThen
                    (\object ->
                        Names.traverse encodeField (Dict.toList compare fields)
                            |> Names.andThen
                                (\keyValuePairs ->
                                    let
                                        listType : Can.Type
                                        listType =
                                            Can.TType ModuleName.list "List" [ Can.TTuple stringType jsonValueType [] ]

                                        funcType : Can.Type
                                        funcType =
                                            Can.TLambda tipe jsonValueType
                                    in
                                    Names.registerFieldDict fields
                                        (TOpt.Function [ ( Name.dollar, tipe ) ]
                                            (TOpt.Call A.zero object [ TOpt.List A.zero keyValuePairs listType ] jsonValueType)
                                            funcType
                                        )
                                )
                    )



-- ENCODE HELPERS


encodeMaybe : Can.Type -> Names.Tracker TOpt.Expr
encodeMaybe argType =
    let
        maybeType : Can.Type
        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ argType ]
    in
    encode "null"
        |> Names.andThen
            (\null ->
                toEncoder argType
                    |> Names.andThen
                        (\encoder ->
                            let
                                destructType : Can.Type
                                destructType =
                                    Can.TLambda jsonValueType (Can.TLambda (Can.TLambda argType jsonValueType) (Can.TLambda maybeType jsonValueType))

                                funcType : Can.Type
                                funcType =
                                    Can.TLambda maybeType jsonValueType
                            in
                            Names.registerGlobal A.zero ModuleName.maybe "destruct" destructType
                                |> Names.map
                                    (\destruct ->
                                        TOpt.Function [ ( Name.dollar, maybeType ) ]
                                            (TOpt.Call A.zero
                                                destruct
                                                [ null
                                                , encoder
                                                , TOpt.VarLocal Name.dollar maybeType
                                                ]
                                                jsonValueType
                                            )
                                            funcType
                                    )
                        )
            )


encodeList : Can.Type -> Names.Tracker TOpt.Expr
encodeList argType =
    let
        listType : Can.Type
        listType =
            Can.TType ModuleName.list "List" [ argType ]
    in
    encode "list"
        |> Names.andThen
            (\list ->
                toEncoder argType
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero list [ encoder ] (Can.TLambda listType jsonValueType)
                        )
            )


encodeArray : Can.Type -> Names.Tracker TOpt.Expr
encodeArray argType =
    let
        arrayType : Can.Type
        arrayType =
            Can.TType ModuleName.array "Array" [ argType ]
    in
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder argType
                    |> Names.map
                        (\encoder ->
                            TOpt.Call A.zero array [ encoder ] (Can.TLambda arrayType jsonValueType)
                        )
            )


encodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker TOpt.Expr
encodeTuple a b cs =
    let
        tupleType : Can.Type
        tupleType =
            Can.TTuple a b cs

        let_ : Name -> Index.ZeroBased -> Can.Type -> TOpt.Expr -> TOpt.Expr
        let_ arg index elemType body =
            let
                bodyType : Can.Type
                bodyType =
                    TOpt.typeOf body
            in
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index (TOpt.Root Name.dollar)) elemType) body bodyType

        letCs_ : Name -> Int -> Can.Type -> TOpt.Expr -> TOpt.Expr
        letCs_ arg index elemType body =
            let
                bodyType : Can.Type
                bodyType =
                    TOpt.typeOf body
            in
            TOpt.Destruct (TOpt.Destructor arg (TOpt.ArrayIndex index (TOpt.Field "cs" (TOpt.Root Name.dollar))) elemType) body bodyType

        encodeArg : Name -> Can.Type -> Names.Tracker TOpt.Expr
        encodeArg arg elemType =
            toEncoder elemType
                |> Names.map (\encoder -> TOpt.Call A.zero encoder [ TOpt.VarLocal arg elemType ] jsonValueType)
    in
    encode "list"
        |> Names.andThen
            (\list ->
                let
                    identityType : Can.Type
                    identityType =
                        Can.TLambda jsonValueType jsonValueType
                in
                Names.registerGlobal A.zero ModuleName.basics Name.identity_ identityType
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
                                                            List.foldl (\( i, cType ) ( index, acc ) -> ( Index.next index, ( i, index, cType ) :: acc ))
                                                                ( Index.third, [] )
                                                                (List.indexedMap Tuple.pair cs)
                                                                |> Tuple.mapSecond List.reverse
                                                    in
                                                    List.foldl
                                                        (\( _, i, elemType ) acc ->
                                                            encodeArg (JsName.fromIndex i) elemType |> Names.andThen (\encodedArg -> Names.map (flip (++) [ encodedArg ]) acc)
                                                        )
                                                        (Names.pure [ arg1, arg2 ])
                                                        indexedCs
                                                        |> Names.map
                                                            (\args ->
                                                                let
                                                                    listType : Can.Type
                                                                    listType =
                                                                        Can.TType ModuleName.list "List" [ jsonValueType ]

                                                                    funcType : Can.Type
                                                                    funcType =
                                                                        Can.TLambda tupleType jsonValueType
                                                                in
                                                                TOpt.Function [ ( Name.dollar, tupleType ) ]
                                                                    (let_ "a"
                                                                        Index.first
                                                                        a
                                                                        (let_ "b"
                                                                            Index.second
                                                                            b
                                                                            (List.foldr (\( i, index, elemType ) -> letCs_ (JsName.fromIndex index) i elemType)
                                                                                (TOpt.Call A.zero list [ identity, TOpt.List A.zero args listType ] jsonValueType)
                                                                                indexedCs
                                                                            )
                                                                        )
                                                                    )
                                                                    funcType
                                                            )
                                                )
                                    )
                        )
            )



-- FLAGS DECODER


{-| Generate a JSON decoder for program flags.
Handles the special case where Unit flags decode to a successful Unit value.
-}
toFlagsDecoder : Can.Type -> Names.Tracker TOpt.Expr
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            decode "succeed"
                |> Names.map
                    (\succeed ->
                        TOpt.Call A.zero succeed [ TOpt.Unit Can.TUnit ] (decoderType Can.TUnit)
                    )

        _ ->
            toDecoder tipe



-- DECODE


{-| Generate a JSON decoder for the given Elm type.
Produces a typed expression that converts JSON to Elm values.
-}
toDecoder : Can.Type -> Names.Tracker TOpt.Expr
toDecoder tipe =
    case tipe of
        Can.TLambda _ _ ->
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
            decodeRecord tipe fields



-- DECODE MAYBE


decodeMaybe : Can.Type -> Names.Tracker TOpt.Expr
decodeMaybe argType =
    let
        maybeType : Can.Type
        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ argType ]

        nothingType : Can.Type
        nothingType =
            maybeType

        justType : Can.Type
        justType =
            Can.TLambda argType maybeType
    in
    Names.registerGlobal A.zero ModuleName.maybe "Nothing" nothingType
        |> Names.andThen
            (\nothing ->
                Names.registerGlobal A.zero ModuleName.maybe "Just" justType
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
                                                                toDecoder argType
                                                                    |> Names.map
                                                                        (\subDecoder ->
                                                                            let
                                                                                listType : Can.Type
                                                                                listType =
                                                                                    Can.TType ModuleName.list "List" [ decoderType maybeType ]
                                                                            in
                                                                            TOpt.Call A.zero
                                                                                oneOf
                                                                                [ TOpt.List A.zero
                                                                                    [ TOpt.Call A.zero null [ nothing ] (decoderType maybeType)
                                                                                    , TOpt.Call A.zero map_ [ just, subDecoder ] (decoderType maybeType)
                                                                                    ]
                                                                                    listType
                                                                                ]
                                                                                (decoderType maybeType)
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )



-- DECODE LIST


decodeList : Can.Type -> Names.Tracker TOpt.Expr
decodeList argType =
    let
        listType : Can.Type
        listType =
            Can.TType ModuleName.list "List" [ argType ]
    in
    decode "list"
        |> Names.andThen
            (\list ->
                toDecoder argType
                    |> Names.map
                        (\argDecoder ->
                            TOpt.Call A.zero list [ argDecoder ] (decoderType listType)
                        )
            )



-- DECODE ARRAY


decodeArray : Can.Type -> Names.Tracker TOpt.Expr
decodeArray argType =
    let
        arrayType : Can.Type
        arrayType =
            Can.TType ModuleName.array "Array" [ argType ]
    in
    decode "array"
        |> Names.andThen
            (\array ->
                toDecoder argType
                    |> Names.map
                        (\argDecoder ->
                            TOpt.Call A.zero array [ argDecoder ] (decoderType arrayType)
                        )
            )



-- DECODE TUPLES


decodeTuple0 : Names.Tracker TOpt.Expr
decodeTuple0 =
    decode "null"
        |> Names.map
            (\null ->
                TOpt.Call A.zero null [ TOpt.Unit Can.TUnit ] (decoderType Can.TUnit)
            )


decodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker TOpt.Expr
decodeTuple a b cs =
    let
        tupleType : Can.Type
        tupleType =
            Can.TTuple a b cs
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

                    tuple : TOpt.Expr
                    tuple =
                        TOpt.Tuple A.zero (toLocal 0 a) (toLocal 1 b) (List.indexedMap (\i cType -> toLocal (i + 2) cType) cs) tupleType
                in
                List.foldr (\( i, cType ) -> Names.andThen (indexAndThen i cType))
                    (indexAndThen (List.length cs + 1) lastElem (TOpt.Call A.zero succeed [ tuple ] (decoderType tupleType)))
                    (List.indexedMap Tuple.pair allElems)
            )


toLocal : Int -> Can.Type -> TOpt.Expr
toLocal index tipe =
    TOpt.VarLocal (Name.fromVarIndex index) tipe


indexAndThen : Int -> Can.Type -> TOpt.Expr -> Names.Tracker TOpt.Expr
indexAndThen i argType decoder =
    let
        decoderResultType : Can.Type
        decoderResultType =
            getDecoderResultType (TOpt.typeOf decoder)
    in
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "index"
                    |> Names.andThen
                        (\index ->
                            toDecoder argType
                                |> Names.map
                                    (\typeDecoder ->
                                        let
                                            funcType : Can.Type
                                            funcType =
                                                Can.TLambda argType (decoderType decoderResultType)
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( Name.fromVarIndex i, argType ) ] decoder funcType
                                            , TOpt.Call A.zero index [ TOpt.Int A.zero i intType, typeDecoder ] (decoderType argType)
                                            ]
                                            (decoderType decoderResultType)
                                    )
                        )
            )



-- DECODE RECORDS


decodeRecord : Can.Type -> Dict String Name.Name Can.FieldType -> Names.Tracker TOpt.Expr
decodeRecord recordType fields =
    let
        toFieldExpr : Name -> Can.FieldType -> TOpt.Expr
        toFieldExpr name (Can.FieldType _ fieldType) =
            TOpt.VarLocal name fieldType

        record : TOpt.Expr
        record =
            TOpt.Record (Dict.map toFieldExpr fields) recordType
    in
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                Names.registerFieldDict fields (Dict.toList compare fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen recordType optCall fieldDecoder))
                                (Names.pure (TOpt.Call A.zero succeed [ record ] (decoderType recordType)))
                                fieldDecoders
                        )
            )


fieldAndThen : Can.Type -> TOpt.Expr -> ( Name.Name, Can.FieldType ) -> Names.Tracker TOpt.Expr
fieldAndThen recordType decoder ( key, Can.FieldType _ fieldType ) =
    decode "andThen"
        |> Names.andThen
            (\andThen ->
                decode "field"
                    |> Names.andThen
                        (\field ->
                            toDecoder fieldType
                                |> Names.map
                                    (\typeDecoder ->
                                        let
                                            funcType : Can.Type
                                            funcType =
                                                Can.TLambda fieldType (decoderType recordType)
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( key, fieldType ) ] decoder funcType
                                            , TOpt.Call A.zero field [ TOpt.Str A.zero (Name.toElmString key) stringType, typeDecoder ] (decoderType fieldType)
                                            ]
                                            (decoderType recordType)
                                    )
                        )
            )



-- GLOBALS HELPERS


encode : Name -> Names.Tracker TOpt.Expr
encode name =
    let
        -- Encoder types are approximate
        encoderType : Can.Type
        encoderType =
            Can.TVar "_encoder"
    in
    Names.registerGlobal A.zero ModuleName.jsonEncode name encoderType


decode : Name -> Names.Tracker TOpt.Expr
decode name =
    let
        -- Decoder types are approximate
        decoderFuncType : Can.Type
        decoderFuncType =
            Can.TVar "_decoder"
    in
    Names.registerGlobal A.zero ModuleName.jsonDecode name decoderFuncType



-- TYPE HELPERS


jsonValueType : Can.Type
jsonValueType =
    Can.TType ModuleName.jsonEncode "Value" []


stringType : Can.Type
stringType =
    Can.TType ModuleName.string "String" []


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


decoderType : Can.Type -> Can.Type
decoderType a =
    Can.TType ModuleName.jsonDecode "Decoder" [ a ]


getDecoderResultType : Can.Type -> Can.Type
getDecoderResultType tipe =
    case tipe of
        Can.TType _ "Decoder" [ a ] ->
            a

        _ ->
            Can.TVar "_unknown"
