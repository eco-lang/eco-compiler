module Compiler.Optimize.Typed.Port exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| Generates typed JSON encoders and decoders for port types.

This is the typed version of Compiler.Optimize.Erased.Port. It produces
(TOpt.Expr IT.IncompleteType) values with IncompleteType annotations instead of Opt.Expr.

Port types are always fully known (not polymorphic), so all type annotations
use `IT.Complete` to wrap the canonical types.

@docs toEncoder
@docs toDecoder, toFlagsDecoder

-}

import Basics.Extra exposing (flip)
import Compiler.AST.Canonical as Can
import Compiler.AST.IncompleteType as IT
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
toEncoder : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                        TOpt.Function [ ( Name.dollar, IT.Complete Can.TUnit ) ] null (IT.Complete funcType)
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
                        Names.registerGlobal A.zero ModuleName.basics Name.identity_ (IT.Complete (Can.TLambda tipe tipe))

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

                encodeField : ( Name, Can.FieldType ) -> Names.Tracker (TOpt.Expr IT.IncompleteType)
                encodeField ( name, Can.FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.map
                            (\encoder ->
                                let
                                    tupleType =
                                        Can.TTuple (Can.TType ModuleName.basics "String" []) valueType []

                                    value =
                                        TOpt.Call A.zero encoder [ TOpt.Access (TOpt.VarLocal Name.dollar (IT.Complete tipe)) A.zero name (IT.Complete fieldType) ] (IT.Complete valueType)
                                in
                                TOpt.Tuple A.zero (TOpt.Str A.zero (Name.toElmString name) (IT.Complete (Can.TType ModuleName.basics "String" []))) value [] (IT.Complete tupleType)
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
                                        (TOpt.Function [ ( Name.dollar, IT.Complete tipe ) ]
                                            (TOpt.Call A.zero object [ TOpt.List A.zero keyValuePairs (IT.Complete listType) ] (IT.Complete valueType))
                                            (IT.Complete funcType)
                                        )
                                )
                    )



-- ====== ENCODE HELPERS ======


encodeMaybe : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                            Names.registerGlobal A.zero ModuleName.maybe "destruct" (IT.Complete (Can.TVar "destruct"))
                                |> Names.map
                                    (\destruct ->
                                        let
                                            funcType =
                                                Can.TLambda maybeType valueType
                                        in
                                        TOpt.Function [ ( Name.dollar, IT.Complete maybeType ) ]
                                            (TOpt.Call A.zero
                                                destruct
                                                [ null
                                                , encoder
                                                , TOpt.VarLocal Name.dollar (IT.Complete maybeType)
                                                ]
                                                (IT.Complete valueType)
                                            )
                                            (IT.Complete funcType)
                                    )
                        )
            )


encodeList : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                            TOpt.Call A.zero list [ encoder ] (IT.Complete (Can.TLambda (Can.TType ModuleName.list "List" [ tipe ]) valueType))
                        )
            )


encodeArray : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                            TOpt.Call A.zero array [ encoder ] (IT.Complete (Can.TLambda (Can.TType ModuleName.array "Array" [ tipe ]) valueType))
                        )
            )


encodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
encodeTuple a b cs =
    let
        tupleType =
            Can.TTuple a b cs

        valueType =
            Can.TType ModuleName.jsonEncode "Value" []

        listValueType =
            Can.TType ModuleName.list "List" [ valueType ]

        let_ : Name -> Can.Type -> Index.ZeroBased -> (TOpt.Expr IT.IncompleteType) -> (TOpt.Expr IT.IncompleteType)
        let_ arg argType index body =
            TOpt.Destruct (TOpt.Destructor arg (TOpt.Index index TOpt.HintUnknown (TOpt.Root Name.dollar)) (IT.Complete argType)) body (TOpt.typeOf body)

        letCs_ : Name -> Can.Type -> Int -> (TOpt.Expr IT.IncompleteType) -> (TOpt.Expr IT.IncompleteType)
        letCs_ arg argType index body =
            TOpt.Destruct (TOpt.Destructor arg (TOpt.ArrayIndex index (TOpt.Field "cs" (TOpt.Root Name.dollar))) (IT.Complete argType)) body (TOpt.typeOf body)

        encodeArg : Name -> Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
        encodeArg arg argType =
            toEncoder argType
                |> Names.map (\encoder -> TOpt.Call A.zero encoder [ TOpt.VarLocal arg (IT.Complete argType) ] (IT.Complete valueType))
    in
    encode "list"
        |> Names.andThen
            (\list ->
                Names.registerGlobal A.zero ModuleName.basics Name.identity_ (IT.Complete (Can.TLambda listValueType listValueType))
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
                                                                TOpt.Function [ ( Name.dollar, IT.Complete tupleType ) ]
                                                                    (let_ "a"
                                                                        a
                                                                        Index.first
                                                                        (let_ "b"
                                                                            b
                                                                            Index.second
                                                                            (List.foldr (\( i, index, argType ) -> letCs_ (JsName.fromIndex index) argType i)
                                                                                (TOpt.Call A.zero list [ identity, TOpt.List A.zero args (IT.Complete listValueType) ] (IT.Complete valueType))
                                                                                indexedCs
                                                                            )
                                                                        )
                                                                    )
                                                                    (IT.Complete funcType)
                                                            )
                                                )
                                    )
                        )
            )



-- ====== FLAGS DECODER ======


{-| Generate a typed JSON decoder for program flags.
-}
toFlagsDecoder : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            decode "succeed"
                |> Names.map
                    (\succeed ->
                        TOpt.Call A.zero succeed [ TOpt.Unit (IT.Complete Can.TUnit) ] (IT.Complete (Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ]))
                    )

        _ ->
            toDecoder tipe



-- ====== DECODE ======


{-| Generate a typed JSON decoder for the given Elm type.
-}
toDecoder : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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


decodeMaybe : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
decodeMaybe tipe =
    let
        maybeType =
            Can.TType ModuleName.maybe "Maybe" [ tipe ]

        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ maybeType ]
    in
    Names.registerGlobal A.zero ModuleName.maybe "Nothing" (IT.Complete maybeType)
        |> Names.andThen
            (\nothing ->
                Names.registerGlobal A.zero ModuleName.maybe "Just" (IT.Complete (Can.TLambda tipe maybeType))
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
                                                                                    [ TOpt.Call A.zero null [ nothing ] (IT.Complete decoderType)
                                                                                    , TOpt.Call A.zero map_ [ just, subDecoder ] (IT.Complete decoderType)
                                                                                    ]
                                                                                    (IT.Complete listType)
                                                                                ]
                                                                                (IT.Complete decoderType)
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


decodeList : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                            TOpt.Call A.zero list [ subDecoder ] (IT.Complete decoderType)
                        )
            )


decodeArray : Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                            TOpt.Call A.zero array [ subDecoder ] (IT.Complete decoderType)
                        )
            )


decodeTuple0 : Names.Tracker (TOpt.Expr IT.IncompleteType)
decodeTuple0 =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ Can.TUnit ]
    in
    decode "null"
        |> Names.map
            (\null ->
                TOpt.Call A.zero null [ TOpt.Unit (IT.Complete Can.TUnit) ] (IT.Complete decoderType)
            )


decodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                        TOpt.Tuple A.zero (toLocal 0 a) (toLocal 1 b) (List.indexedMap (\i c -> toLocal (i + 2) c) cs) (IT.Complete tupleType)
                in
                List.foldr (\( i, c ) -> Names.andThen (indexAndThen i c))
                    (indexAndThen (List.length cs + 1) lastElem (TOpt.Call A.zero succeed [ tuple ] (IT.Complete decoderType)))
                    (List.indexedMap Tuple.pair allElems)
            )


toLocal : Int -> Can.Type -> (TOpt.Expr IT.IncompleteType)
toLocal index tipe =
    TOpt.VarLocal (Name.fromVarIndex index) (IT.Complete tipe)


indexAndThen : Int -> Can.Type -> (TOpt.Expr IT.IncompleteType) -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                                                IT.buildFunctionType [ IT.Complete tipe ] decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( Name.fromVarIndex i, IT.Complete tipe ) ] decoder funcType
                                            , TOpt.Call A.zero index [ TOpt.Int A.zero i (IT.Complete (Can.TType ModuleName.basics "Int" [])), typeDecoder ] (IT.Complete subDecoderType)
                                            ]
                                            decoderResultType
                                    )
                        )
            )


decodeRecord : Dict String Name.Name Can.FieldType -> Can.Type -> Names.Tracker (TOpt.Expr IT.IncompleteType)
decodeRecord fields recordType =
    let
        decoderType =
            Can.TType ModuleName.jsonDecode "Decoder" [ recordType ]

        toFieldExpr : Name -> Can.FieldType -> (TOpt.Expr IT.IncompleteType)
        toFieldExpr name (Can.FieldType _ fieldType) =
            TOpt.VarLocal name (IT.Complete fieldType)

        record =
            TOpt.Record (Dict.map toFieldExpr fields) (IT.Complete recordType)
    in
    decode "succeed"
        |> Names.andThen
            (\succeed ->
                Names.registerFieldDict fields (Dict.toList compare fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen optCall fieldDecoder))
                                (Names.pure (TOpt.Call A.zero succeed [ record ] (IT.Complete decoderType)))
                                fieldDecoders
                        )
            )


fieldAndThen : (TOpt.Expr IT.IncompleteType) -> ( Name.Name, Can.FieldType ) -> Names.Tracker (TOpt.Expr IT.IncompleteType)
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
                                                IT.buildFunctionType [ IT.Complete tipe ] decoderResultType

                                            subDecoderType =
                                                Can.TType ModuleName.jsonDecode "Decoder" [ tipe ]
                                        in
                                        TOpt.Call A.zero
                                            andThen
                                            [ TOpt.Function [ ( key, IT.Complete tipe ) ] decoder funcType
                                            , TOpt.Call A.zero field [ TOpt.Str A.zero (Name.toElmString key) (IT.Complete (Can.TType ModuleName.basics "String" [])), typeDecoder ] (IT.Complete subDecoderType)
                                            ]
                                            decoderResultType
                                    )
                        )
            )



-- ====== GLOBALS HELPERS ======


encode : Name -> Names.Tracker (TOpt.Expr IT.IncompleteType)
encode name =
    Names.registerGlobal A.zero ModuleName.jsonEncode name (IT.Complete (Can.TVar name))


decode : Name -> Names.Tracker (TOpt.Expr IT.IncompleteType)
decode name =
    Names.registerGlobal A.zero ModuleName.jsonDecode name (IT.Complete (Can.TVar name))



-- ====== BYTES HELPERS ======


encodeBytes : Names.Tracker (TOpt.Expr IT.IncompleteType)
encodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero Name.json "encodeBytes" (IT.Complete (Can.TVar "encodeBytes")))


decodeBytes : Names.Tracker (TOpt.Expr IT.IncompleteType)
decodeBytes =
    Names.registerKernel Name.json (TOpt.VarKernel A.zero Name.json "decodeBytes" (IT.Complete (Can.TVar "decodeBytes")))
