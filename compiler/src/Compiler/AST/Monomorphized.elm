module Compiler.AST.Monomorphized exposing
    ( ClosureInfo
    , CtorLayout
    , CustomLayout
    , Decider(..)
    , FieldInfo
    , Global(..)
    , LambdaId(..)
    , Literal(..)
    , MonoChoice(..)
    , MonoDef(..)
    , MonoDestructor(..)
    , MonoExpr(..)
    , MonoGraph(..)
    , MonoNode(..)
    , MonoPath(..)
    , MonoType(..)
    , RecordLayout
    , SpecId
    , SpecKey(..)
    , SpecializationRegistry
    , TupleLayout
    , canUnbox
    , compareGlobal
    , compareLambdaId
    , compareMonoType
    , compareSpecKey
    , computeCustomLayout
    , computeRecordLayout
    , computeTupleLayout
    , emptyRegistry
    , getOrCreateSpecId
    , lookupSpecKey
    , toComparableGlobal
    , toComparableLambdaId
    , toComparableMonoType
    , toComparableSpecKey
    , typeOf
    )

{-| Monomorphized AST - fully specialized with no type variables.

This IR is produced by the monomorphization pass and consumed by the MLIR backend.
All polymorphism has been resolved to concrete types, and all higher-order functions
have been specialized for their specific lambda arguments (lambda sets).

Key characteristics:

  - MonoType has no type variables
  - Every function specialization has a unique SpecId
  - Record/Custom/Tuple types carry their runtime layout
  - Closures are explicit with captured variables

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.DecisionTree as DT
import Compiler.Reporting.Annotation as A exposing (Region)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO



-- ============================================================================
-- MONOMORPHIC TYPES (No type variables)
-- ============================================================================


type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple TupleLayout
    | MRecord RecordLayout
    | MCustom IO.Canonical Name (List MonoType) CustomLayout
    | MFunction (List MonoType) MonoType



-- ============================================================================
-- LAYOUTS (Runtime representation info)
-- ============================================================================


type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int
    , fields : List FieldInfo
    }


type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : MonoType
    , isUnboxed : Bool
    }


type alias CustomLayout =
    { constructors : List CtorLayout
    }


type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }


type alias TupleLayout =
    { arity : Int
    , unboxedBitmap : Int
    , elements : List ( MonoType, Bool ) -- (type, isUnboxed)
    }



-- ============================================================================
-- LAMBDA SETS
-- ============================================================================


type LambdaId
    = NamedFunction Global
    | AnonymousLambda IO.Canonical Int (List ( Name, MonoType )) -- module, unique id, captures



-- ============================================================================
-- SPECIALIZATION KEYS AND IDS
-- ============================================================================


type Global
    = Global IO.Canonical Name


type SpecKey
    = SpecKey Global MonoType (Maybe LambdaId)


type alias SpecId =
    Int


type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict (List String) (List String) SpecId
    , reverseMapping : Dict Int Int ( Global, MonoType, Maybe LambdaId )
    }


emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Dict.empty
    , reverseMapping = Dict.empty
    }


getOrCreateSpecId : Global -> MonoType -> Maybe LambdaId -> SpecializationRegistry -> ( SpecId, SpecializationRegistry )
getOrCreateSpecId global monoType maybeLambda registry =
    let
        key =
            toComparableSpecKey (SpecKey global monoType maybeLambda)
    in
    case Dict.get identity key registry.mapping of
        Just specId ->
            ( specId, registry )

        Nothing ->
            let
                specId =
                    registry.nextId
            in
            ( specId
            , { nextId = specId + 1
              , mapping = Dict.insert identity key specId registry.mapping
              , reverseMapping = Dict.insert identity specId ( global, monoType, maybeLambda ) registry.reverseMapping
              }
            )


lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType, Maybe LambdaId )
lookupSpecKey specId registry =
    Dict.get identity specId registry.reverseMapping



-- ============================================================================
-- MONO GRAPH
-- ============================================================================


type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe SpecId
        , registry : SpecializationRegistry
        }



-- ============================================================================
-- MONO NODES
-- ============================================================================


type MonoNode
    = MonoDefine MonoExpr (EverySet Int Int) MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr (EverySet Int Int) MonoType
    | MonoCtor CtorLayout MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoPortIncoming MonoExpr (EverySet Int Int) MonoType
    | MonoPortOutgoing MonoExpr (EverySet Int Int) MonoType



-- ============================================================================
-- MONO EXPRESSIONS
-- ============================================================================


type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType
    | MonoCall Region MonoExpr (List MonoExpr) MonoType
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List MonoExpr) RecordLayout MonoType
    | MonoRecordAccess MonoExpr Name Int Bool MonoType
    | MonoRecordUpdate MonoExpr (List ( Int, MonoExpr )) RecordLayout MonoType
    | MonoTupleCreate Region (List MonoExpr) TupleLayout MonoType
    | MonoTupleAccess MonoExpr Int Bool MonoType
    | MonoCustomCreate Name Int (List MonoExpr) CtorLayout MonoType
    | MonoUnit
    | MonoAccessor Region Name MonoType


type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String


type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    }


type MonoDef
    = MonoDef Region Name MonoExpr MonoType
    | MonoTailDef Region Name (List ( Name, MonoType )) MonoExpr MonoType


type MonoDestructor
    = MonoDestructor Name MonoPath MonoType


type MonoPath
    = MonoIndex Int MonoPath
    | MonoField Name Int MonoPath
    | MonoUnbox MonoPath
    | MonoRoot Name


type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


type MonoChoice
    = Inline MonoExpr
    | Jump Int



-- ============================================================================
-- TYPE UTILITIES
-- ============================================================================


typeOf : MonoExpr -> MonoType
typeOf expr =
    case expr of
        MonoLiteral _ t ->
            t

        MonoVarLocal _ t ->
            t

        MonoVarGlobal _ _ t ->
            t

        MonoVarKernel _ _ _ t ->
            t

        MonoList _ _ t ->
            t

        MonoClosure _ _ t ->
            t

        MonoCall _ _ _ t ->
            t

        MonoTailCall _ _ t ->
            t

        MonoIf _ _ t ->
            t

        MonoLet _ _ t ->
            t

        MonoDestruct _ _ t ->
            t

        MonoCase _ _ _ _ t ->
            t

        MonoRecordCreate _ _ t ->
            t

        MonoRecordAccess _ _ _ _ t ->
            t

        MonoRecordUpdate _ _ _ t ->
            t

        MonoTupleCreate _ _ _ t ->
            t

        MonoTupleAccess _ _ _ t ->
            t

        MonoCustomCreate _ _ _ _ t ->
            t

        MonoUnit ->
            MUnit

        MonoAccessor _ _ t ->
            t


canUnbox : MonoType -> Bool
canUnbox monoType =
    case monoType of
        MInt ->
            True

        MFloat ->
            True

        MBool ->
            True

        MChar ->
            True

        _ ->
            False



-- ============================================================================
-- LAYOUT COMPUTATION
-- ============================================================================


computeRecordLayout : Dict String Name MonoType -> RecordLayout
computeRecordLayout fields =
    let
        allFields =
            Dict.toList compare fields

        ( unboxedFields, boxedFields ) =
            List.partition (\( _, ty ) -> canUnbox ty) allFields

        sortedUnboxed =
            List.sortBy Tuple.first unboxedFields

        sortedBoxed =
            List.sortBy Tuple.first boxedFields

        orderedFields =
            sortedUnboxed ++ sortedBoxed

        indexedFields =
            List.indexedMap
                (\idx ( name, ty ) ->
                    { name = name
                    , index = idx
                    , monoType = ty
                    , isUnboxed = canUnbox ty
                    }
                )
                orderedFields

        unboxedCount =
            List.length sortedUnboxed

        unboxedBitmap =
            if unboxedCount == 0 then
                0

            else
                (2 ^ unboxedCount) - 1
    in
    { fieldCount = List.length orderedFields
    , unboxedCount = unboxedCount
    , unboxedBitmap = unboxedBitmap
    , fields = indexedFields
    }


computeTupleLayout : List MonoType -> TupleLayout
computeTupleLayout types =
    let
        elements =
            List.map (\t -> ( t, canUnbox t )) types

        unboxedBitmap =
            List.indexedMap
                (\i ( _, isUnboxed ) ->
                    if isUnboxed then
                        2 ^ i

                    else
                        0
                )
                elements
                |> List.foldl (+) 0
    in
    { arity = List.length types
    , unboxedBitmap = unboxedBitmap
    , elements = elements
    }


computeCustomLayout : List ( Name, List MonoType ) -> CustomLayout
computeCustomLayout constructors =
    { constructors =
        List.indexedMap
            (\tag ( name, fieldTypes ) ->
                let
                    fields =
                        List.indexedMap
                            (\idx ty ->
                                { name = "field" ++ String.fromInt idx
                                , index = idx
                                , monoType = ty
                                , isUnboxed = canUnbox ty
                                }
                            )
                            fieldTypes

                    unboxedCount =
                        List.length (List.filter .isUnboxed fields)

                    unboxedBitmap =
                        if unboxedCount == 0 then
                            0

                        else
                            (2 ^ unboxedCount) - 1
                in
                { name = name
                , tag = tag
                , fields = fields
                , unboxedCount = unboxedCount
                , unboxedBitmap = unboxedBitmap
                }
            )
            constructors
    }



-- ============================================================================
-- COMPARISON FUNCTIONS
-- ============================================================================


compareGlobal : Global -> Global -> Order
compareGlobal (Global home1 name1) (Global home2 name2) =
    case compare name1 name2 of
        EQ ->
            ModuleName.compareCanonical home1 home2

        other ->
            other


toComparableGlobal : Global -> List String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ [ name ]


compareMonoType : MonoType -> MonoType -> Order
compareMonoType t1 t2 =
    compare (toComparableMonoType t1) (toComparableMonoType t2)


toComparableMonoType : MonoType -> List String
toComparableMonoType monoType =
    case monoType of
        MInt ->
            [ "Int" ]

        MFloat ->
            [ "Float" ]

        MBool ->
            [ "Bool" ]

        MChar ->
            [ "Char" ]

        MString ->
            [ "String" ]

        MUnit ->
            [ "Unit" ]

        MList inner ->
            "List" :: toComparableMonoType inner

        MTuple layout ->
            "Tuple" :: String.fromInt layout.arity :: List.concatMap (Tuple.first >> toComparableMonoType) layout.elements

        MRecord layout ->
            "Record" :: List.concatMap (\f -> f.name :: toComparableMonoType f.monoType) layout.fields

        MCustom canonical name args _ ->
            "Custom" :: ModuleName.toComparableCanonical canonical ++ [ name ] ++ List.concatMap toComparableMonoType args

        MFunction args ret ->
            "Function" :: List.concatMap toComparableMonoType args ++ [ "->" ] ++ toComparableMonoType ret


compareLambdaId : LambdaId -> LambdaId -> Order
compareLambdaId l1 l2 =
    compare (toComparableLambdaId l1) (toComparableLambdaId l2)


toComparableLambdaId : LambdaId -> List String
toComparableLambdaId lambdaId =
    case lambdaId of
        NamedFunction global ->
            "Named" :: toComparableGlobal global

        AnonymousLambda canonical uid _ ->
            "Anon" :: ModuleName.toComparableCanonical canonical ++ [ String.fromInt uid ]


compareSpecKey : SpecKey -> SpecKey -> Order
compareSpecKey k1 k2 =
    compare (toComparableSpecKey k1) (toComparableSpecKey k2)


toComparableSpecKey : SpecKey -> List String
toComparableSpecKey (SpecKey global monoType maybeLambda) =
    toComparableGlobal global
        ++ toComparableMonoType monoType
        ++ (case maybeLambda of
                Nothing ->
                    [ "NoLambda" ]

                Just lambdaId ->
                    "Lambda" :: toComparableLambdaId lambdaId
           )
