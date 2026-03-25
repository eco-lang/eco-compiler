module Compiler.Elm.Interface.Bytes exposing
    ( bytesDecodeInterface
    , bytesEncodeInterface
    , bytesInterface
    )

{-| Interfaces for elm/bytes modules used in tests.

Provides Bytes, Bytes.Encode, and Bytes.Decode module interfaces
to enable testing of bytes fusion codegen paths.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- HELPERS
-- ============================================================================


collectFreeVars : Can.Type -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda a b ->
            Dict.union (collectFreeVars a) (collectFreeVars b)

        Can.TVar name ->
            Dict.singleton name ()

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Dict.union (collectFreeVars arg) acc) Dict.empty args

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl (\_ (Can.FieldType _ t) acc -> Dict.union (collectFreeVars t) acc) Dict.empty fields
            in
            case maybeExt of
                Just name ->
                    Dict.insert name () fieldVars

                Nothing ->
                    fieldVars

        Can.TUnit ->
            Dict.empty

        Can.TTuple a b cs ->
            List.foldl (\t acc -> Dict.union (collectFreeVars t) acc)
                (Dict.union (collectFreeVars a) (collectFreeVars b))
                cs

        Can.TAlias _ _ args aliasType ->
            let
                argVars =
                    List.foldl (\( _, t ) acc -> Dict.union (collectFreeVars t) acc) Dict.empty args
            in
            case aliasType of
                Can.Holey t ->
                    Dict.union argVars (collectFreeVars t)

                Can.Filled t ->
                    Dict.union argVars (collectFreeVars t)


mkAnnotation : Can.Type -> Can.Annotation
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


bytesHome : IO.Canonical
bytesHome =
    IO.Canonical Pkg.bytes "Bytes"


bytesEncodeHome : IO.Canonical
bytesEncodeHome =
    IO.Canonical Pkg.bytes "Bytes.Encode"


bytesDecodeHome : IO.Canonical
bytesDecodeHome =
    IO.Canonical Pkg.bytes "Bytes.Decode"



-- ============================================================================
-- COMMON TYPES
-- ============================================================================


bytesType : Can.Type
bytesType =
    Can.TType bytesHome "Bytes" []


encoderType : Can.Type
encoderType =
    Can.TType bytesEncodeHome "Encoder" []


decoderType : Can.Type -> Can.Type
decoderType a =
    Can.TType bytesDecodeHome "Decoder" [ a ]


endiannessType : Can.Type
endiannessType =
    Can.TType bytesHome "Endianness" []


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


floatType : Can.Type
floatType =
    Can.TType ModuleName.basics "Float" []


stringType : Can.Type
stringType =
    Can.TType ModuleName.string "String" []



-- ============================================================================
-- BYTES MODULE (Bytes type + Endianness)
-- ============================================================================


{-| The Bytes module interface: Bytes opaque type and Endianness union.
-}
bytesInterface : I.Interface
bytesInterface =
    I.Interface
        { home = Pkg.bytes
        , values = Dict.empty
        , unions = bytesUnions
        , aliases = Dict.empty
        , binops = Dict.empty
        }


bytesUnions : Dict Name I.Union
bytesUnions =
    let
        -- type Bytes (opaque)
        bytesUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

        -- type Endianness = BE | LE
        beC =
            Can.Ctor { name = "BE", index = Index.first, numArgs = 0, args = [] }

        leC =
            Can.Ctor { name = "LE", index = Index.second, numArgs = 0, args = [] }

        endiannessUnion =
            Can.Union
                { vars = []
                , alts = [ beC, leC ]
                , numAlts = 2
                , opts = Can.Normal
                }
    in
    Dict.fromList
        [ ( "Bytes", I.ClosedUnion bytesUnion )
        , ( "Endianness", I.OpenUnion endiannessUnion )
        ]



-- ============================================================================
-- BYTES.ENCODE MODULE
-- ============================================================================


{-| The Bytes.Encode module interface: Encoder type and encoder functions.
-}
bytesEncodeInterface : I.Interface
bytesEncodeInterface =
    I.Interface
        { home = Pkg.bytes
        , values = bytesEncodeValues
        , unions = bytesEncodeUnions
        , aliases = Dict.empty
        , binops = Dict.empty
        }


bytesEncodeUnions : Dict Name I.Union
bytesEncodeUnions =
    let
        -- type Encoder (opaque)
        encoderUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    Dict.singleton "Encoder" (I.ClosedUnion encoderUnion)


bytesEncodeValues : Dict Name Can.Annotation
bytesEncodeValues =
    let
        -- encode : Encoder -> Bytes
        encodeType =
            Can.TLambda encoderType bytesType

        -- unsignedInt8 : Int -> Encoder
        u8Type =
            Can.TLambda intType encoderType

        -- signedInt8 : Int -> Encoder
        i8Type =
            Can.TLambda intType encoderType

        -- unsignedInt16 : Endianness -> Int -> Encoder
        u16Type =
            Can.TLambda endiannessType (Can.TLambda intType encoderType)

        -- signedInt16 : Endianness -> Int -> Encoder
        i16Type =
            Can.TLambda endiannessType (Can.TLambda intType encoderType)

        -- unsignedInt32 : Endianness -> Int -> Encoder
        u32Type =
            Can.TLambda endiannessType (Can.TLambda intType encoderType)

        -- signedInt32 : Endianness -> Int -> Encoder
        i32Type =
            Can.TLambda endiannessType (Can.TLambda intType encoderType)

        -- float32 : Endianness -> Float -> Encoder
        f32Type =
            Can.TLambda endiannessType (Can.TLambda floatType encoderType)

        -- float64 : Endianness -> Float -> Encoder
        f64Type =
            Can.TLambda endiannessType (Can.TLambda floatType encoderType)

        -- bytes : Bytes -> Encoder
        bytesEncType =
            Can.TLambda bytesType encoderType

        -- string : String -> Encoder
        stringEncType =
            Can.TLambda stringType encoderType

        -- sequence : List Encoder -> Encoder
        listEncoder =
            Can.TType ModuleName.list "List" [ encoderType ]

        sequenceType =
            Can.TLambda listEncoder encoderType
    in
    Dict.fromList
        [ ( "encode", mkAnnotation encodeType )
        , ( "unsignedInt8", mkAnnotation u8Type )
        , ( "signedInt8", mkAnnotation i8Type )
        , ( "unsignedInt16", mkAnnotation u16Type )
        , ( "signedInt16", mkAnnotation i16Type )
        , ( "unsignedInt32", mkAnnotation u32Type )
        , ( "signedInt32", mkAnnotation i32Type )
        , ( "float32", mkAnnotation f32Type )
        , ( "float64", mkAnnotation f64Type )
        , ( "bytes", mkAnnotation bytesEncType )
        , ( "string", mkAnnotation stringEncType )
        , ( "sequence", mkAnnotation sequenceType )
        ]



-- ============================================================================
-- BYTES.DECODE MODULE
-- ============================================================================


{-| The Bytes.Decode module interface: Decoder type and decoder functions.
-}
bytesDecodeInterface : I.Interface
bytesDecodeInterface =
    I.Interface
        { home = Pkg.bytes
        , values = bytesDecodeValues
        , unions = bytesDecodeUnions
        , aliases = Dict.empty
        , binops = Dict.empty
        }


bytesDecodeUnions : Dict Name I.Union
bytesDecodeUnions =
    let
        aVar =
            Can.TVar "a"

        -- type Decoder a (opaque)
        decoderUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

        -- type Step state a = Loop state | Done a
        stateVar =
            Can.TVar "state"

        loopC =
            Can.Ctor { name = "Loop", index = Index.first, numArgs = 1, args = [ stateVar ] }

        doneC =
            Can.Ctor { name = "Done", index = Index.second, numArgs = 1, args = [ aVar ] }

        stepUnion =
            Can.Union
                { vars = [ "state", "a" ]
                , alts = [ loopC, doneC ]
                , numAlts = 2
                , opts = Can.Normal
                }
    in
    Dict.fromList
        [ ( "Decoder", I.ClosedUnion decoderUnion )
        , ( "Step", I.OpenUnion stepUnion )
        ]


bytesDecodeValues : Dict Name Can.Annotation
bytesDecodeValues =
    let
        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        cVar =
            Can.TVar "c"

        dVar =
            Can.TVar "d"

        eVar =
            Can.TVar "e"

        decoderA =
            decoderType aVar

        decoderB =
            decoderType bVar

        decoderC =
            decoderType cVar

        -- decode : Decoder a -> Bytes -> Maybe a
        maybeA =
            Can.TType ModuleName.maybe "Maybe" [ aVar ]

        decodeType =
            Can.TLambda decoderA (Can.TLambda bytesType maybeA)

        -- unsignedInt8 : Decoder Int
        -- (zero-arg decoder values)
        decoderInt =
            decoderType intType

        decoderFloat =
            decoderType floatType

        decoderBytes =
            decoderType bytesType

        decoderString =
            decoderType stringType

        -- unsignedInt16 : Endianness -> Decoder Int
        endianDecoderInt =
            Can.TLambda endiannessType decoderInt

        -- float32 : Endianness -> Decoder Float
        endianDecoderFloat =
            Can.TLambda endiannessType decoderFloat

        -- bytes : Int -> Decoder Bytes
        intToDecoderBytes =
            Can.TLambda intType decoderBytes

        -- string : Int -> Decoder String
        intToDecoderString =
            Can.TLambda intType decoderString

        -- succeed : a -> Decoder a
        succeedType =
            Can.TLambda aVar decoderA

        -- fail : Decoder a
        failType =
            decoderA

        -- map : (a -> b) -> Decoder a -> Decoder b
        mapType =
            Can.TLambda (Can.TLambda aVar bVar) (Can.TLambda decoderA decoderB)

        -- map2 : (a -> b -> c) -> Decoder a -> Decoder b -> Decoder c
        map2Type =
            Can.TLambda (Can.TLambda aVar (Can.TLambda bVar cVar))
                (Can.TLambda decoderA (Can.TLambda decoderB decoderC))

        -- map3 : (a -> b -> c -> d) -> Decoder a -> Decoder b -> Decoder c -> Decoder d
        decoderD =
            decoderType dVar

        map3Type =
            Can.TLambda (Can.TLambda aVar (Can.TLambda bVar (Can.TLambda cVar dVar)))
                (Can.TLambda decoderA (Can.TLambda decoderB (Can.TLambda decoderC decoderD)))

        -- map4 : (a -> b -> c -> d -> e) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e
        decoderE =
            decoderType eVar

        map4Type =
            Can.TLambda (Can.TLambda aVar (Can.TLambda bVar (Can.TLambda cVar (Can.TLambda dVar eVar))))
                (Can.TLambda decoderA (Can.TLambda decoderB (Can.TLambda decoderC (Can.TLambda decoderD decoderE))))

        -- andThen : (a -> Decoder b) -> Decoder a -> Decoder b
        andThenType =
            Can.TLambda (Can.TLambda aVar decoderB) (Can.TLambda decoderA decoderB)

        -- loop : (state -> Decoder (Step state a)) -> state -> Decoder a
        stateVar_ =
            Can.TVar "state"

        stepType =
            Can.TType bytesDecodeHome "Step" [ stateVar_, aVar ]

        loopType =
            Can.TLambda (Can.TLambda stateVar_ (decoderType stepType))
                (Can.TLambda stateVar_ decoderA)
    in
    Dict.fromList
        [ ( "decode", mkAnnotation decodeType )
        , ( "unsignedInt8", mkAnnotation decoderInt )
        , ( "signedInt8", mkAnnotation decoderInt )
        , ( "unsignedInt16", mkAnnotation endianDecoderInt )
        , ( "signedInt16", mkAnnotation endianDecoderInt )
        , ( "unsignedInt32", mkAnnotation endianDecoderInt )
        , ( "signedInt32", mkAnnotation endianDecoderInt )
        , ( "float32", mkAnnotation endianDecoderFloat )
        , ( "float64", mkAnnotation endianDecoderFloat )
        , ( "bytes", mkAnnotation intToDecoderBytes )
        , ( "string", mkAnnotation intToDecoderString )
        , ( "succeed", mkAnnotation succeedType )
        , ( "fail", mkAnnotation failType )
        , ( "map", mkAnnotation mapType )
        , ( "map2", mkAnnotation map2Type )
        , ( "map3", mkAnnotation map3Type )
        , ( "map4", mkAnnotation map4Type )
        , ( "andThen", mkAnnotation andThenType )
        , ( "loop", mkAnnotation loopType )
        ]
