module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..)
    , RecordLayout, FieldInfo, CustomLayout, CtorLayout, TupleLayout
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry, emptyRegistry, getOrCreateSpecId, lookupSpecKey
    , MonoGraph(..), MainInfo(..), MonoNode(..), ManagerInfo
    , MonoExpr(..), ShaderInfo, ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , Decider(..), MonoChoice(..)
    , typeOf, canUnbox
    , computeRecordLayout, computeTupleLayout, computeCustomLayout
    , compareGlobal, compareMonoType, compareLambdaId, compareSpecKey, toComparableGlobal, toComparableMonoType, toComparableLambdaId, toComparableSpecKey
    , Constraint(..), canTypeToMonoType, constraintToString, containsMVar
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


# Types

@docs MonoType, Literal


# Runtime Layouts

@docs RecordLayout, FieldInfo, CustomLayout, CtorLayout, TupleLayout


# Lambda Sets

@docs LambdaId


# Globals and Specialization

@docs Global, SpecKey, SpecId, SpecializationRegistry, emptyRegistry, getOrCreateSpecId, lookupSpecKey


# Program Graph

@docs MonoGraph, MainInfo, MonoNode, ManagerInfo


# Expressions

@docs MonoExpr, ShaderInfo, ClosureInfo, MonoDef, MonoDestructor, MonoPath


# Pattern Matching

@docs Decider, MonoChoice


# Type Utilities

@docs typeOf, canUnbox


# Layout Computation

@docs computeRecordLayout, computeTupleLayout, computeCustomLayout


# Comparison and Ordering

@docs compareGlobal, compareMonoType, compareLambdaId, compareSpecKey, toComparableGlobal, toComparableMonoType, toComparableLambdaId, toComparableSpecKey

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Optimize.DecisionTree as DT
import Compiler.Reporting.Annotation exposing (Region)
import Data.Map as Dict exposing (Dict)
import Data.Set exposing (EverySet)
import System.TypeCheck.IO as IO



-- ============================================================================
-- MONOMORPHIC TYPES (No type variables)
-- ============================================================================


{-| A fully monomorphized type with no type variables remaining.
-}
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
    | MVar Name Constraint -- Unspecialized type var


type Constraint
    = CAny -- Unconstrained phantom
    | CNumber
    | CComparable
    | CAppendable
    | CCompAppend



-- ============================================================================
-- LAYOUTS (Runtime representation info)
-- ============================================================================


{-| Runtime layout information for records, including field order and unboxing.
-}
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int
    , fields : List FieldInfo
    }


{-| Information about a single field in a record or constructor.
-}
type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : MonoType
    , isUnboxed : Bool
    }


{-| Runtime layout information for custom types.
-}
type alias CustomLayout =
    { constructors : List CtorLayout
    }


{-| Runtime layout information for a single constructor variant.
-}
type alias CtorLayout =
    { name : Name
    , tag : Int
    , fields : List FieldInfo
    , unboxedCount : Int
    , unboxedBitmap : Int
    }


{-| Runtime layout information for tuples.
-}
type alias TupleLayout =
    { arity : Int
    , unboxedBitmap : Int
    , elements : List ( MonoType, Bool ) -- (type, isUnboxed)
    }



-- ============================================================================
-- LAMBDA SETS
-- ============================================================================


{-| Identifier for lambda functions in lambda sets, distinguishing named functions from closures.
-}
type LambdaId
    = NamedFunction Global
    | AnonymousLambda IO.Canonical Int (List ( Name, MonoType )) -- module, unique id, captures



-- ============================================================================
-- SPECIALIZATION KEYS AND IDS
-- ============================================================================


{-| A reference to a top-level definition in a module.
-}
type Global
    = Global IO.Canonical Name


{-| Key identifying a unique specialization of a polymorphic function.
-}
type SpecKey
    = SpecKey Global MonoType (Maybe LambdaId)


{-| Unique integer identifier for a function specialization.
-}
type alias SpecId =
    Int


{-| Registry tracking all function specializations in the program.
-}
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict (List String) (List String) SpecId
    , reverseMapping : Dict Int Int ( Global, MonoType, Maybe LambdaId )
    }


{-| Create an empty specialization registry.
-}
emptyRegistry : SpecializationRegistry
emptyRegistry =
    { nextId = 0
    , mapping = Dict.empty
    , reverseMapping = Dict.empty
    }


{-| Get or create a SpecId for a function specialization, updating the registry if needed.
-}
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


{-| Look up the specialization information for a given SpecId.
-}
lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType, Maybe LambdaId )
lookupSpecKey specId registry =
    Dict.get identity specId registry.reverseMapping



-- ============================================================================
-- MONO GRAPH
-- ============================================================================


{-| The complete monomorphized program graph containing all specialized definitions.
-}
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        }


{-| Information about the main entry point.

  - Static: A simple main value (Html, Svg, etc.)
  - Dynamic: An application with flags decoder (Browser.element, etc.)

-}
type MainInfo
    = StaticMain SpecId
    | DynamicMain SpecId MonoExpr -- main specId, flags decoder expression



-- ============================================================================
-- MONO NODES
-- ============================================================================


{-| A node in the monomorphized dependency graph representing a specialized definition.
-}
type MonoNode
    = MonoDefine MonoExpr (EverySet Int Int) MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr (EverySet Int Int) MonoType
    | MonoCtor CtorLayout MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoPortIncoming MonoExpr (EverySet Int Int) MonoType
    | MonoPortOutgoing MonoExpr (EverySet Int Int) MonoType
    | MonoManager ManagerInfo MonoType
    | MonoCycle (List ( Name, MonoExpr )) (EverySet Int Int) MonoType


{-| Effects manager information
-}
type alias ManagerInfo =
    { init : MonoExpr
    , onEffects : MonoExpr
    , onSelfMsg : MonoExpr
    , cmdMap : Maybe MonoExpr
    , subMap : Maybe MonoExpr
    }



-- ============================================================================
-- MONO EXPRESSIONS
-- ============================================================================


{-| A monomorphized expression with concrete types and explicit closures.
-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType
    | MonoVarDebug Region Name IO.Canonical (Maybe Name) MonoType -- Debug.log, Debug.todo, etc.
    | MonoVarCycle Region IO.Canonical Name MonoType -- Mutually recursive variable reference
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
    | MonoShader Region ShaderInfo MonoType -- WebGL shader
    | MonoPolyGlobal Region TOpt.Global Can.Type -- Polymorphic global, to be resolved at call site


{-| WebGL shader information
-}
type alias ShaderInfo =
    { src : String
    , types : { attribute : Dict String Name String, uniform : Dict String Name String, varying : Dict String Name String }
    }


{-| Literal values in monomorphized expressions.
-}
type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String


{-| Information about a closure including its lambda ID, captured variables, and parameters.
-}
type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    }


{-| A local definition in monomorphized code.
-}
type MonoDef
    = MonoDef Region Name MonoExpr MonoType
    | MonoTailDef Region Name (List ( Name, MonoType )) MonoExpr MonoType


{-| Destructuring pattern for extracting values from data structures.
-}
type MonoDestructor
    = MonoDestructor Name MonoPath MonoType


{-| Path for navigating into a data structure during destructuring.
-}
type MonoPath
    = MonoIndex Int MonoPath
    | MonoField Name Int MonoPath
    | MonoUnbox MonoPath
    | MonoRoot Name
    | MonoArrayIndex Int MonoPath -- Array index access


{-| Decision tree for pattern matching.
-}
type Decider a
    = Leaf a
    | Chain (List ( DT.Path, DT.Test )) (Decider a) (Decider a)
    | FanOut DT.Path (List ( DT.Test, Decider a )) (Decider a)


{-| Action to take when a pattern match succeeds.
-}
type MonoChoice
    = Inline MonoExpr
    | Jump Int



-- ============================================================================
-- TYPE UTILITIES
-- ============================================================================


{-| Extract the monomorphic type from any expression.
-}
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

        MonoVarDebug _ _ _ _ t ->
            t

        MonoVarCycle _ _ _ t ->
            t

        MonoShader _ _ t ->
            t

        MonoPolyGlobal _ _ canType ->
            canTypeToMonoType canType


{-| Convert a canonical type to a monomorphic type.
Unresolved type variables become MVar with appropriate constraints.
-}
canTypeToMonoType : Can.Type -> MonoType
canTypeToMonoType canType =
    case canType of
        Can.TVar name ->
            -- Determine constraint from name prefix
            if String.startsWith "number" name then
                MVar name CNumber

            else if String.startsWith "comparable" name then
                MVar name CComparable

            else if String.startsWith "appendable" name then
                MVar name CAppendable

            else if String.startsWith "compappend" name then
                MVar name CCompAppend

            else
                MVar name CAny

        Can.TLambda from to ->
            MFunction [ canTypeToMonoType from ] (canTypeToMonoType to)

        Can.TType ((IO.Canonical pkg _) as canonical) name args ->
            if pkg == Pkg.core then
                case ( name, args ) of
                    ( "Int", [] ) ->
                        MInt

                    ( "Float", [] ) ->
                        MFloat

                    ( "Bool", [] ) ->
                        MBool

                    ( "Char", [] ) ->
                        MChar

                    ( "String", [] ) ->
                        MString

                    ( "List", [ inner ] ) ->
                        MList (canTypeToMonoType inner)

                    _ ->
                        MCustom canonical name (List.map canTypeToMonoType args) (computeCustomLayout [])

            else
                MCustom canonical name (List.map canTypeToMonoType args) (computeCustomLayout [])

        Can.TRecord fields _ ->
            let
                monoFields =
                    Dict.map (\_ (Can.FieldType _ t) -> canTypeToMonoType t) fields
            in
            MRecord (computeRecordLayout monoFields)

        Can.TTuple a b rest ->
            let
                monoTypes =
                    List.map canTypeToMonoType (a :: b :: rest)
            in
            MTuple (computeTupleLayout monoTypes)

        Can.TUnit ->
            MUnit

        Can.TAlias _ _ _ (Can.Filled inner) ->
            canTypeToMonoType inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            -- For holey aliases, we'd need the args substituted - just recurse for now
            canTypeToMonoType inner


{-| Determine whether a type can be unboxed (stored inline without heap allocation).
-}
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


{-| Check if a monomorphic type contains any unresolved type variables (MVar).
-}
containsMVar : MonoType -> Bool
containsMVar monoType =
    case monoType of
        MVar _ _ ->
            True

        MFunction args ret ->
            List.any containsMVar args || containsMVar ret

        MList inner ->
            containsMVar inner

        MTuple layout ->
            List.any (Tuple.first >> containsMVar) layout.elements

        MRecord layout ->
            List.any (.monoType >> containsMVar) layout.fields

        MCustom _ _ args _ ->
            List.any containsMVar args

        _ ->
            False



-- ============================================================================
-- LAYOUT COMPUTATION
-- ============================================================================


{-| Compute runtime layout for a record type, ordering fields to place unboxed values first.
-}
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


{-| Compute runtime layout for a tuple type.
-}
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
                |> List.sum
    in
    { arity = List.length types
    , unboxedBitmap = unboxedBitmap
    , elements = elements
    }


{-| Compute runtime layout for a custom type with its constructors.
-}
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


{-| Compare two global references for ordering.
-}
compareGlobal : Global -> Global -> Order
compareGlobal (Global home1 name1) (Global home2 name2) =
    case compare name1 name2 of
        EQ ->
            ModuleName.compareCanonical home1 home2

        other ->
            other


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> List String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ [ name ]


{-| Compare two monomorphic types for ordering.
-}
compareMonoType : MonoType -> MonoType -> Order
compareMonoType t1 t2 =
    compare (toComparableMonoType t1) (toComparableMonoType t2)


{-| Convert a monomorphic type to a comparable key for use in dictionaries.
-}
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

        MVar name constraint ->
            [ "Var", name, constraintToString constraint ]


{-| Convert a constraint to a string for comparison purposes.
-}
constraintToString : Constraint -> String
constraintToString constraint =
    case constraint of
        CAny ->
            "any"

        CNumber ->
            "number"

        CComparable ->
            "comparable"

        CAppendable ->
            "appendable"

        CCompAppend ->
            "compappend"


{-| Compare two lambda IDs for ordering.
-}
compareLambdaId : LambdaId -> LambdaId -> Order
compareLambdaId l1 l2 =
    compare (toComparableLambdaId l1) (toComparableLambdaId l2)


{-| Convert a lambda ID to a comparable key for use in dictionaries.
-}
toComparableLambdaId : LambdaId -> List String
toComparableLambdaId lambdaId =
    case lambdaId of
        NamedFunction global ->
            "Named" :: toComparableGlobal global

        AnonymousLambda canonical uid _ ->
            "Anon" :: ModuleName.toComparableCanonical canonical ++ [ String.fromInt uid ]


{-| Compare two specialization keys for ordering.
-}
compareSpecKey : SpecKey -> SpecKey -> Order
compareSpecKey k1 k2 =
    compare (toComparableSpecKey k1) (toComparableSpecKey k2)


{-| Convert a specialization key to a comparable key for use in dictionaries.
-}
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
