module Compiler.Optimize.Erased.Port exposing
    ( toEncoder
    , toDecoder, toFlagsDecoder
    )

{-| Generates JSON encoders and decoders for port types.

This module analyzes Elm types used in port definitions and automatically
generates the necessary encoder and decoder expressions for converting between
Elm values and JavaScript JSON values. It handles:

  - Primitives (Int, Float, Bool, String)
  - Collections (List, Array, Maybe)
  - Tuples
  - Records
  - Special types (Bytes, Json.Encode.Value)

The generated code ensures type-safe communication across the Elm/JavaScript
boundary without requiring manual encoder/decoder implementations.


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
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.JavaScript.Name as JsName
import Compiler.Optimize.Erased.Names as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== ENCODE ======


{-| Generate a JSON encoder function for the given Elm type.
Produces an optimized expression that converts Elm values to JSON for outgoing ports.
-}
toEncoder : Can.Type -> Names.Tracker Opt.Expr
toEncoder tipe =
    case tipe of
        Can.TAlias _ _ args alias ->
            toEncoder (Type.dealias args alias)

        Can.TLambda _ _ ->
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
                encodeField : ( Name, Can.FieldType ) -> Names.Tracker Opt.Expr
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
                        Names.traverse encodeField (Dict.toList compare fields)
                            |> Names.andThen
                                (\keyValuePairs ->
                                    Names.registerFieldDict fields
                                        (Opt.Function [ Name.dollar ] (Opt.Call A.zero object [ Opt.List A.zero keyValuePairs ]))
                                )
                    )



-- ====== ENCODE HELPERS ======


encodeMaybe : Can.Type -> Names.Tracker Opt.Expr
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


encodeList : Can.Type -> Names.Tracker Opt.Expr
encodeList tipe =
    encode "list"
        |> Names.andThen
            (\list ->
                toEncoder tipe
                    |> Names.map (Opt.Call A.zero list << List.singleton)
            )


encodeArray : Can.Type -> Names.Tracker Opt.Expr
encodeArray tipe =
    encode "array"
        |> Names.andThen
            (\array ->
                toEncoder tipe
                    |> Names.map (Opt.Call A.zero array << List.singleton)
            )


encodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker Opt.Expr
encodeTuple a b cs =
    let
        let_ : Name -> Index.ZeroBased -> Opt.Expr -> Opt.Expr
        let_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.Index index (Opt.Root Name.dollar))) body

        letCs_ : Name -> Int -> Opt.Expr -> Opt.Expr
        letCs_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.ArrayIndex index (Opt.Field "cs" (Opt.Root Name.dollar)))) body

        encodeArg : Name -> Can.Type -> Names.Tracker Opt.Expr
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
                                                            encodeArg (JsName.fromIndex i) tipe |> Names.andThen (\encodedArg -> Names.map (flip (++) [ encodedArg ]) acc)
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
                                                                            (List.foldr (\( i, index, _ ) -> letCs_ (JsName.fromIndex index) i)
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


{-| Generate a JSON decoder for program flags.
Handles the special case where Unit flags decode to a successful Unit value.
-}
toFlagsDecoder : Can.Type -> Names.Tracker Opt.Expr
toFlagsDecoder tipe =
    case tipe of
        Can.TUnit ->
            Names.map (\succeed -> Opt.Call A.zero succeed [ Opt.Unit ])
                (decode "succeed")

        _ ->
            toDecoder tipe



-- ====== DECODE ======


{-| Generate a JSON decoder for the given Elm type.
Produces an optimized expression that converts JSON to Elm values for incoming ports.
-}
toDecoder : Can.Type -> Names.Tracker Opt.Expr
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
            decodeRecord fields



-- ====== DECODE MAYBE ======


decodeMaybe : Can.Type -> Names.Tracker Opt.Expr
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


decodeList : Can.Type -> Names.Tracker Opt.Expr
decodeList tipe =
    decode "list"
        |> Names.andThen
            (\list ->
                Names.map (Opt.Call A.zero list << List.singleton)
                    (toDecoder tipe)
            )



-- ====== DECODE ARRAY ======


decodeArray : Can.Type -> Names.Tracker Opt.Expr
decodeArray tipe =
    decode "array"
        |> Names.andThen
            (\array ->
                Names.map (Opt.Call A.zero array << List.singleton)
                    (toDecoder tipe)
            )



-- ====== DECODE TUPLES ======


decodeTuple0 : Names.Tracker Opt.Expr
decodeTuple0 =
    Names.map (\null -> Opt.Call A.zero null [ Opt.Unit ])
        (decode "null")


decodeTuple : Can.Type -> Can.Type -> List Can.Type -> Names.Tracker Opt.Expr
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


toLocal : Int -> Opt.Expr
toLocal index =
    Opt.VarLocal (Name.fromVarIndex index)


indexAndThen : Int -> Can.Type -> Opt.Expr -> Names.Tracker Opt.Expr
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


decodeRecord : Dict String Name.Name Can.FieldType -> Names.Tracker Opt.Expr
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
                Names.registerFieldDict fields (Dict.toList compare fields)
                    |> Names.andThen
                        (\fieldDecoders ->
                            List.foldl (\fieldDecoder -> Names.andThen (\optCall -> fieldAndThen optCall fieldDecoder))
                                (Names.pure (Opt.Call A.zero succeed [ record ]))
                                fieldDecoders
                        )
            )


fieldAndThen : Opt.Expr -> ( Name.Name, Can.FieldType ) -> Names.Tracker Opt.Expr
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


encode : Name -> Names.Tracker Opt.Expr
encode name =
    Names.registerGlobal A.zero ModuleName.jsonEncode name


decode : Name -> Names.Tracker Opt.Expr
decode name =
    Names.registerGlobal A.zero ModuleName.jsonDecode name



-- ====== BYTES HELPERS ======


encodeBytes : Names.Tracker Opt.Expr
encodeBytes =
    Names.registerKernel Name.json (Opt.VarKernel A.zero Name.json "encodeBytes")


decodeBytes : Names.Tracker Opt.Expr
decodeBytes =
    Names.registerKernel Name.json (Opt.VarKernel A.zero Name.json "decodeBytes")
