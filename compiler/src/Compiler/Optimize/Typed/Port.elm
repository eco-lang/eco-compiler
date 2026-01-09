module Compiler.Optimize.Typed.Port exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| Generates typed JSON encoders and decoders for port types.

This is the typed version of Compiler.Optimize.Erased.Port. It produces
TOpt.Expr values with type annotations instead of Opt.Expr.

@docs toEncoder
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
import Compiler.Optimize.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== ENCODE ======


{-| Generate a typed JSON encoder function for the given Elm type.
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
                    (\null ->
                        let
                            funcType =
                                Can.TLambda Can.TUnit (Can.TType ModuleName.jsonEncode "Value" [])
                        in
                        TOpt.Function [ ( Name.dollar, Can.TUnit ) ] null funcType
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
                        Names.registerGlobal A.zero ModuleName.basics Name.identity_ (Can.TLambda tipe tipe)

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

                encodeField : ( Name, Can.FieldType ) -> Names.Tracker TOpt.Expr
                encodeField ( name, Can.FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    tupleType =
                                        Can.TTuple (Can.TType ModuleName.basics "String" []) valueType []

                                    value =
                                        TOpt.Call A.zero encoder [ TOpt.Access (TOpt.VarLocal Name.dollar tipe) A.zero name fieldType ] valueType
                                in
                                TOpt.Tuple A.zero (TOpt.Str A.zero (Name.toElmString name) (Can.TType ModuleName.basics "String" [])) value [] tupleType
                            )
            in
            encode "object"
                |> Names.andThen
                    (\object ->
                        Names.traverse encodeField (Dict.toList compare fields)
                            |> Names.andThen
                                (\keyValuePairs ->
                                    let
                                        listType =
                                            Can.TType ModuleName.list "List" [ Can.TTuple (Can.TType ModuleName.basics "String" []) valueType [] ]

                                        funcType =
                                            Can.TLambda tipe valueType
                                    in
                                    Names.registerFieldDict fields
                                        (TOpt.Function [ ( Name.dollar, tipe ) ]
                                            (TOpt.Call A.zero object [ TOpt.List A.zero keyValuePairs listType ] valueType)
                                            funcType
                                        )
                                )
                    )



-- ====== ENCODE HELPERS ======


encodeMaybe : Can.Type -> Names.Tracker TOpt.Expr
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
                            Names.registerGlobal A.zero ModuleName.maybe "destruct" (Can.TVar "destruct")
                                |> Names.map
                                    (\destruct ->
                                        let
                                            funcType =
                                                Can.TLambda maybeType valueType
                                        in
                                        TOpt.Function [ ( Name.dollar, maybeType ) ]
                                            (TOpt.Call A.zero
                                                destruct
                                                [ null
                                                , encoder
                                                , TOpt.VarLocal Name.dollar maybeType
                                                ]
                                                valueType
                                            )
                                            funcType
                                    )
                        )
            )


encodeList : Can.Type -> Names.Tracker TOpt.Expr
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
                            TOpt.Call A.zero list [ encoder ] (Can.TLambda (Can.TType ModuleName.list "List" [ tipe ]) valueType)
                        )
            )


encodeArray : Can.Type -> Names.Tracker TOpt.Expr
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
                            TOpt.Call A.zero array [ encoder ] (Can.TLambda (Can.TType ModuleName.array "Array" [ tipe ]) valueType)
                        )
            )


encodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker TOpt.Expr
encodeTuple a b cs =
    let
        tupleType =
            Can.TTuple a b cs

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []

        listValueType =
            Can.TType ModuleName.list "List" [ valueType ]

        let_ : Name -> Can.Type -> Index.ZeroBased -> TOpt.Expr -> TOpt.Expr
        let_ arg argType index body =
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index TOpt.HintUnknown (TOpt.Root Name.dollar)) argType) body (TOpt.typeOf body)

        letCs_ : Name -> Can.Type -> Int -> TOpt.Expr -> TOpt.Expr
        letCs_ arg argType index body =
            TOpt.Destruct (TOpt.Destructor arg (TOpt.ArrayIndex index (TOpt.Field "cs" (TOpt.Root Name.dollar))) argType) body (TOpt.typeOf body)

        encodeArg : Name -> Can.Type -> Names.Tracker TOpt.Expr
        encodeArg arg argType =
            toEncoder argType
                |> Names.map (\encoder -> TOpt.Call A.zero encoder [ TOpt.VarLocal arg argType ] valueType)
    in
    encode "list"
        |> Names.andThen
            (\list ->
                Names.registerGlobal A.zero ModuleName.basics Name.identity_ (Can.TLambda listValueType listValueType)
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
                                                            encodeArg (JsName.fromIndex i) argType
                                                                |> Names.andThen (\encodedArg -> Names.map (flip (++) [ encodedArg ]) acc)
                                                        )
                                                        (Names.pure [ arg1, arg2 ])
                                                        indexedCs
                                                        |> Names.map
                                                            (\args ->
                                                                let
                                                                    funcType =
                                                                        Can.TLambda tupleType valueType
                                                                in
                                                                TOpt.Function [ ( Name.dollar, tupleType ) ]
                                                                    (let_ "a"
                                                                        a
                                                                        Index.first
                                                                        (let_ "b"
                                                                            b
                                                                            Index.second
                                                                            (List.foldr (\( i, index, argType ) -> letCs_ (JsName.fromIndex index) argType i)
                                                                                (TOpt.Call A.zero list [ identity, TOpt.List A.zero args listValueType ] valueType)
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



-- ====== FLAGS DECODER ======


{-| Generate a typed JSON decoder for program flags.
-}
toFlagsDecoder : Can.Type -> Names.Tracker TOpt.Expr
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            decode "succeed"
                |> Names.map
                    (\succeed ->
                        TOpt.Call A.zero succeed [ TOpt.Unit Can.TUnit ] (Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ])
                    )

        _ ->
            toDecoder tipe



-- ====== DECODE ======


{-| Generate a typed JSON decoder for the given Elm type.
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


decodeMaybe : Can.Type -> Names.Tracker TOpt.Expr
decodeMaybe tipe =
    let
        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ maybeType ]
    in
    Names.registerGlobal A.zero ModuleName.maybe "Nothing" maybeType
        |> Names.andThen
            (\nothing ->
                Names.registerGlobal A.zero ModuleName.maybe "Just" (Can.TLambda tipe maybeType)
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
                                                                                    [ TOpt.Call A.zero null [ nothing ] decoderType
                                                                                    , TOpt.Call A.zero map_ [ just, subDecoder ] decoderType
                                                                                    ]
                                                                                    listType
                                                                                ]
                                                                                decoderType
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


decodeList : Can.Type -> Names.Tracker TOpt.Expr
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
                            TOpt.Call A.zero list [ subDecoder ] decoderType
                        )
            )


decodeArray : Can.Type -> Names.Tracker TOpt.Expr
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
                            TOpt.Call A.zero array [ subDecoder ] decoderType
                        )
            )


decodeTuple0 : Names.Tracker TOpt.Expr
decodeTuple0 =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ]
    in
    decode "null"
        |> Names.map
            (\null ->
                TOpt.Call A.zero null [ TOpt.Unit Can.TUnit ] decoderType
            )


decodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker TOpt.Expr
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
                        TOpt.Tuple A.zero (toLocal 0 a) (toLocal 1 b) (List.indexedMap (\i c -> toLocal (i + 2) c) cs) tupleType
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length cs + 1) lastElem (TOpt.Call A.zero succeed [ tuple ] decoderType))
                    (List.indexedMap Tuple.pair allElems)
            )


toLocal : Int -> Can.Type -> TOpt.Expr
toLocal index tipe =
    TOpt.VarLocal (Name.fromVarIndex index) tipe


indexAndThen : Int -> Can.Type -> TOpt.Expr -> Names.Tracker TOpt.Expr
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
                                                Can.TLambda tipe decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( Name.fromVarIndex i, tipe ) ] decoder funcType
                                            , TOpt.Call A.zero index [ TOpt.Int A.zero i (Can.TType ModuleName.basics "Int" []), typeDecoder ] subDecoderType
                                            ]
                                            decoderResultType
                                    )
                        )
            )


decodeRecord : Dict String Name.Name Can.FieldType -> Can.Type -> Names.Tracker TOpt.Expr
decodeRecord fields recordType =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ recordType ]

        toFieldExpr : Name -> Can.FieldType -> TOpt.Expr
        toFieldExpr name (Can.FieldType _ fieldType) =
            TOpt.VarLocal name fieldType

        record =
            TOpt.Record (Dict.map toFieldExpr fields) recordType
    in
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                Names.registerFieldDict fields (Dict.toList compare fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen optCall fieldDecoder))
                                (Names.pure (TOpt.Call A.zero succeed [ record ] decoderType))
                                fieldDecoders
                        )
            )


fieldAndThen : TOpt.Expr -> ( Name.Name, Can.FieldType ) -> Names.Tracker TOpt.Expr
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
                                                Can.TLambda tipe decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( key, tipe ) ] decoder funcType
                                            , TOpt.Call A.zero field [ TOpt.Str A.zero (Name.toElmString key) (Can.TType ModuleName.basics "String" []), typeDecoder ] subDecoderType
                                            ]
                                            decoderResultType
                                    )
                        )
            )



-- ====== GLOBALS HELPERS ======


encode : Name -> Names.Tracker TOpt.Expr
encode name =
    Names.registerGlobal A.zero ModuleName.jsonEncode name (Can.TVar name)


decode : Name -> Names.Tracker TOpt.Expr
decode name =
    Names.registerGlobal A.zero ModuleName.jsonDecode name (Can.TVar name)



-- ====== BYTES HELPERS ======


encodeBytes : Names.Tracker TOpt.Expr
encodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero Name.json "encodeBytes" (Can.TVar "encodeBytes"))


decodeBytes : Names.Tracker TOpt.Expr
decodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero Name.json "decodeBytes" (Can.TVar "decodeBytes"))
