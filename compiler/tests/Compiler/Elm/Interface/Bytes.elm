module Compiler.Elm.Interface.Bytes exposing
    ( bytesDecodeInterface
    , bytesEncodeInterface
    , bytesInterface
    )

{-| Hand-built interfaces for the three modules of the elm/bytes package, so
that a test program can import `Bytes`, `Bytes.Encode` and `Bytes.Decode`
without that package being compiled. `Compiler.Elm.Interface.Basic` adds all
three to the interfaces that test programs are canonicalized against.

An interface is what a compiled module offers the modules that import it: an
annotation for each exported value, and its exported types, as
`Compiler.Elm.Interface` describes. Each interface here is assembled directly
from canonical types, with elm/bytes as its home package. A type whose
constructors elm/bytes keeps hidden (`Bytes`, `Encoder`, `Decoder`) is a closed
union with no constructors. `Endianness` and `Step` are open unions, so a test
program can use their constructors.

Only part of elm/bytes is present, and a test program can use nothing else from
it:

  - `Bytes`: the types `Bytes` and `Endianness`, and no values.
  - `Bytes.Encode`: the type `Encoder`, `encode`, the signed and unsigned 8-,
    16- and 32-bit integer encoders, `float32`, `float64`, `bytes`, `string`
    and `sequence`.
  - `Bytes.Decode`: the types `Decoder` and `Step`, `decode`, the integer and
    float decoders matching those encoders, `bytes`, `string`, `succeed`,
    `fail`, `map` to `map4`, `andThen` and `loop`.

Three things differ from elm/bytes itself. `loop` takes the step function first
and the initial state second, where elm/bytes takes the state first.
`Endianness` declares `BE` before `LE`, the reverse of elm/bytes, so the two
constructor indices are swapped. And `Endianness` is given the `Normal`
constructor representation, where canonicalizing a declaration whose
constructors are all nullary chooses `Enum`.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Returns the names of the type variables that occur anywhere in `tipe`,
including a record's extension variable. For an alias it collects from the
argument types and from the alias body, whether `Holey` or `Filled`.
-}
collectFreeVars : Can.Type Name -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda _ a b ->
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


{-| Builds the annotation of `tipe`, quantified over every type variable in it.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


{-| The canonical name of the `Bytes` module of elm/bytes.
-}
bytesHome : ModuleName.Canonical
bytesHome =
    ModuleName.Canonical Pkg.bytes "Bytes"


{-| The canonical name of the `Bytes.Encode` module of elm/bytes.
-}
bytesEncodeHome : ModuleName.Canonical
bytesEncodeHome =
    ModuleName.Canonical Pkg.bytes "Bytes.Encode"


{-| The canonical name of the `Bytes.Decode` module of elm/bytes.
-}
bytesDecodeHome : ModuleName.Canonical
bytesDecodeHome =
    ModuleName.Canonical Pkg.bytes "Bytes.Decode"



-- ============================================================================
-- COMMON TYPES
-- ============================================================================


{-| The type `Bytes`, from the `Bytes` module.
-}
bytesType : Can.Type Name
bytesType =
    Can.TType bytesHome "Bytes" []


{-| The type `Encoder`, from the `Bytes.Encode` module.
-}
encoderType : Can.Type Name
encoderType =
    Can.TType bytesEncodeHome "Encoder" []


{-| Returns the type `Decoder a` of the `Bytes.Decode` module, for the result
type `a`.
-}
decoderType : Can.Type Name -> Can.Type Name
decoderType a =
    Can.TType bytesDecodeHome "Decoder" [ a ]


{-| The type `Endianness`, from the `Bytes` module.
-}
endiannessType : Can.Type Name
endiannessType =
    Can.TType bytesHome "Endianness" []


{-| The type `Int`, from `Basics`.
-}
intType : Can.Type Name
intType =
    Can.TType ModuleName.basics "Int" []


{-| The type `Float`, from `Basics`.
-}
floatType : Can.Type Name
floatType =
    Can.TType ModuleName.basics "Float" []


{-| The type `String`, from the `String` module.
-}
stringType : Can.Type Name
stringType =
    Can.TType ModuleName.string "String" []



-- ============================================================================
-- BYTES MODULE (Bytes type + Endianness)
-- ============================================================================


{-| The interface of the `Bytes` module: the closed type `Bytes`, the open type
`Endianness` with constructors `BE` and `LE`, and no values.
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


{-| The union types of the `Bytes` module, keyed by name. `Bytes` is closed and
has no constructors. `Endianness` is open, with `BE` at index 0 and `LE` at
index 1.
-}
bytesUnions : Dict Name I.Union
bytesUnions =
    let
        bytesUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

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


{-| The interface of the `Bytes.Encode` module: the closed type `Encoder`, and
annotations for `encode`, `signedInt8`, `unsignedInt8`, the signed and unsigned
16- and 32-bit encoders, `float32`, `float64`, `bytes`, `string` and
`sequence`. Every annotation has the same type as in elm/bytes.
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


{-| The union types of the `Bytes.Encode` module: `Encoder` alone, closed and
without constructors.
-}
bytesEncodeUnions : Dict Name I.Union
bytesEncodeUnions =
    let
        encoderUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    Dict.singleton "Encoder" (I.ClosedUnion encoderUnion)


{-| The annotations of the `Bytes.Encode` values, keyed by name. Each has the
same type as in elm/bytes.
-}
bytesEncodeValues : Dict Name (Can.Annotation Name)
bytesEncodeValues =
    let
        encodeType =
            Can.tLambda encoderType bytesType

        u8Type =
            Can.tLambda intType encoderType

        i8Type =
            Can.tLambda intType encoderType

        u16Type =
            Can.tLambda endiannessType (Can.tLambda intType encoderType)

        i16Type =
            Can.tLambda endiannessType (Can.tLambda intType encoderType)

        u32Type =
            Can.tLambda endiannessType (Can.tLambda intType encoderType)

        i32Type =
            Can.tLambda endiannessType (Can.tLambda intType encoderType)

        f32Type =
            Can.tLambda endiannessType (Can.tLambda floatType encoderType)

        f64Type =
            Can.tLambda endiannessType (Can.tLambda floatType encoderType)

        bytesEncType =
            Can.tLambda bytesType encoderType

        stringEncType =
            Can.tLambda stringType encoderType

        listEncoder =
            Can.TType ModuleName.list "List" [ encoderType ]

        sequenceType =
            Can.tLambda listEncoder encoderType
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


{-| The interface of the `Bytes.Decode` module: the closed type `Decoder a`, the
open type `Step state a` with constructors `Loop` and `Done`, and annotations
for `decode`, the integer and float decoders matching those of `Bytes.Encode`,
`bytes`, `string`, `succeed`, `fail`, `map` to `map4`, `andThen` and `loop`.

Every annotation has the same type as in elm/bytes except `loop`, whose two
arguments are the other way round:
`(state -> Decoder (Step state a)) -> state -> Decoder a`.

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


{-| The union types of the `Bytes.Decode` module, keyed by name. `Decoder a` is
closed and has no constructors. `Step state a` is open: `Loop`, at index 0,
carries a state, and `Done`, at index 1, carries the result.
-}
bytesDecodeUnions : Dict Name I.Union
bytesDecodeUnions =
    let
        aVar =
            Can.TVar "a"

        decoderUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

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


{-| The annotations of the `Bytes.Decode` values, keyed by name. Each has the
same type as in elm/bytes except `loop`, which takes the step function before
the initial state.
-}
bytesDecodeValues : Dict Name (Can.Annotation Name)
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

        maybeA =
            Can.TType ModuleName.maybe "Maybe" [ aVar ]

        decodeType =
            Can.tLambda decoderA (Can.tLambda bytesType maybeA)

        decoderInt =
            decoderType intType

        decoderFloat =
            decoderType floatType

        decoderBytes =
            decoderType bytesType

        decoderString =
            decoderType stringType

        endianDecoderInt =
            Can.tLambda endiannessType decoderInt

        endianDecoderFloat =
            Can.tLambda endiannessType decoderFloat

        intToDecoderBytes =
            Can.tLambda intType decoderBytes

        intToDecoderString =
            Can.tLambda intType decoderString

        succeedType =
            Can.tLambda aVar decoderA

        failType =
            decoderA

        mapType =
            Can.tLambda (Can.tLambda aVar bVar) (Can.tLambda decoderA decoderB)

        map2Type =
            Can.tLambda (Can.tLambda aVar (Can.tLambda bVar cVar))
                (Can.tLambda decoderA (Can.tLambda decoderB decoderC))

        decoderD =
            decoderType dVar

        map3Type =
            Can.tLambda (Can.tLambda aVar (Can.tLambda bVar (Can.tLambda cVar dVar)))
                (Can.tLambda decoderA (Can.tLambda decoderB (Can.tLambda decoderC decoderD)))

        decoderE =
            decoderType eVar

        map4Type =
            Can.tLambda (Can.tLambda aVar (Can.tLambda bVar (Can.tLambda cVar (Can.tLambda dVar eVar))))
                (Can.tLambda decoderA (Can.tLambda decoderB (Can.tLambda decoderC (Can.tLambda decoderD decoderE))))

        andThenType =
            Can.tLambda (Can.tLambda aVar decoderB) (Can.tLambda decoderA decoderB)

        stateVar_ =
            Can.TVar "state"

        stepType =
            Can.TType bytesDecodeHome "Step" [ stateVar_, aVar ]

        loopType =
            Can.tLambda (Can.tLambda stateVar_ (decoderType stepType))
                (Can.tLambda stateVar_ decoderA)
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
