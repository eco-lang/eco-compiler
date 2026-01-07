module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , RecordLayout, FieldInfo, CtorLayout, TupleLayout
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry, emptyRegistry, getOrCreateSpecId, lookupSpecKey
    , MonoGraph(..), MainInfo(..), MonoNode(..)
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..), ContainerKind(..)
    , Decider(..), MonoChoice(..)
    , typeOf, canUnbox
    , computeRecordLayout, computeTupleLayout
    , toComparableSpecKey
    )

{-| Monomorphized AST for backends that can optimize using concrete types.

This IR makes all specialized definitions, layouts, and closure structures
explicit so that later stages can generate low-level code without needing
type inference or layout computation.

High‑level properties:

  - Each polymorphic Elm definition that is actually used at one or more
    type instantiations appears as one or more specialized nodes in
    `MonoGraph`, identified by a concrete `SpecId`.

  - Record, tuple, and custom types carry their computed runtime layouts
    (`RecordLayout`, `TupleLayout`, `CustomLayout`), so consumers of this
    IR can rely on fixed shapes and unboxing decisions.

  - Higher‑order functions are either represented as explicit closures
    (`MonoClosure` with captured variables and parameter types) or as
    specialized top‑level function nodes (`MonoDefine`, `MonoTailFunc`).

  - Remaining type variables in `MonoType` are limited to a small,
    backend‑aware set of constrained variables (`MVar` with `Constraint`)
    that do not require further inference. In particular, any unresolved
    numeric variables are intended to be rejected before final code
    generation. See `MonoType` and `Constraint` for the precise invariants.

This module defines the data structures for the monomorphized program
(`MonoGraph`, `MonoNode`, `MonoExpr`, etc.) along with utilities such as
`typeOf` and the layout computation functions.


# Types

@docs MonoType, Literal, Constraint


# Runtime Layouts

@docs RecordLayout, FieldInfo, CtorLayout, TupleLayout


# Lambda Sets

@docs LambdaId


# Globals and Specialization

@docs Global, SpecKey, SpecId, SpecializationRegistry, emptyRegistry, getOrCreateSpecId, lookupSpecKey


# Program Graph

@docs MonoGraph, MainInfo, MonoNode


# Expressions

@docs MonoExpr, ClosureInfo, MonoDef, MonoDestructor, MonoPath


# Pattern Matching

@docs Decider, MonoChoice


# Type Utilities

@docs typeOf, canUnbox


# Layout Computation

@docs computeRecordLayout, computeTupleLayout


# Comparison and Ordering

@docs toComparableSpecKey

-}

import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.DecisionTree as DT
import Compiler.Reporting.Annotation exposing (Region)
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- MONOMORPHIC TYPES (No type variables)
-- ============================================================================


{-| Monomorphized type used by the MLIR backend.

This type represents the fully elaborated runtime shape of values after
monomorphization. All concrete instantiations of source types (including
primitives, functions, lists, tuples, records, and custom types) must appear
here as `MInt`, `MFloat`, `MList`, `MTuple`, etc.

Type variables only remain in the form of `MVar` with an attached `Constraint`
when their exact runtime type is either:

  - Guaranteed to be represented as a boxed `eco.value` (`CEcoValue`), or
  - A numeric type (`CNumber`) that is waiting to be resolved to `MInt` or
    `MFloat` during specialization.

INVARIANTS BY PHASE:

  - Before codegen:
      - `MVar _ CNumber` is allowed as an intermediate result of
        monomorphization and must be resolved to either `MInt` or `MFloat`
        for any reachable code path that performs numeric operations.
      - `MVar _ CEcoValue` is allowed for positions whose concrete type does
        not affect layout (always boxed) and may remain until codegen.

  - At codegen time:
      - No `MVar _ CNumber` may remain in any reachable `MonoType`. Such
        a case indicates a failed specialization and is a compiler bug.
      - Any remaining `MVar _ CEcoValue` is treated as a boxed `eco.value`
        in the target representation.

The actual specialization to `MInt` or `MFloat` is expected tp be done at call
sites during code generation.

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
    | MCustom IO.Canonical Name (List MonoType)
    | MFunction (List MonoType) MonoType
    | MVar Name Constraint


{-| Constraint on an unspecialized type variable in `MonoType`.

These constraints record how much is known about a type variable after
monomorphization and determine what obligations remain before codegen.

  - `CEcoValue`:
    The variable's concrete Elm type is erased in the backend and is
    always represented as a boxed `eco.value`. Its precise source type
    does not influence layout or calling convention; it is only tracked
    for comparison/debugging purposes. It is safe (and expected) for
    `MVar _ CEcoValue` to survive to MLIR codegen, where it is lowered
    uniformly to `eco.value`.

  - `CNumber`:
    The variable is known to be a numeric type (`Int` or `Float` in Elm).
    This variable MUST be resolved to either `MInt` or `MFloat` by the
    monomorphization/specialization phase for all reachable code paths
    that perform numeric operations. Any occurrence of `MVar _ CNumber`
    in a `MonoType` that reaches MLIR codegen is a compiler bug.

In other words, `CEcoValue` marks "erased / always boxed" variables that can
remain polymorphic at the backend, while `CNumber` marks numeric variables
that must be fully specialized before code generation.

-}
type Constraint
    = CEcoValue
    | CNumber



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
    = AnonymousLambda IO.Canonical Int



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
    = StaticMain SpecId -- main specId, flags decoder expression



-- ============================================================================
-- MONO NODES
-- ============================================================================


{-| A node in the monomorphized dependency graph representing a specialized definition.
-}
type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr MonoType
    | MonoCtor CtorLayout MonoType
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoPortIncoming MonoExpr MonoType
    | MonoPortOutgoing MonoExpr MonoType
    | MonoCycle (List ( Name, MonoExpr )) MonoType



-- ============================================================================
-- MONO EXPRESSIONS
-- ============================================================================


{-| A monomorphized expression with concrete types and explicit closures.
-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType -- Mutually recursive variable reference
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
    | MonoUnit
    | MonoAccessor Region Name MonoType -- Polymorphic global, to be resolved at call site


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
    = MonoDef Name MonoExpr
    | MonoTailDef Name MonoExpr


{-| Destructuring pattern for extracting values from data structures.
Contains the variable name, path to navigate to the value, and the type of the destructured value.
-}
type MonoDestructor
    = MonoDestructor Name MonoPath MonoType


{-| The kind of container being navigated during destructuring.

This is used to select the correct runtime projection operation:
  - ListContainer: eco.project.list.head / eco.project.list.tail
  - Tuple2Container: eco.project.tuple2
  - Tuple3Container: eco.project.tuple3
  - CustomContainer: eco.project (generic custom type)
  - RecordContainer: eco.project (record field access)
-}
type ContainerKind
    = ListContainer
    | Tuple2Container
    | Tuple3Container
    | CustomContainer
    | RecordContainer


{-| Path for navigating into a data structure during destructuring.

MonoIndex now carries ContainerKind to enable type-specific projection ops.
-}
type MonoPath
    = MonoIndex Int ContainerKind MonoPath
    | MonoField Int MonoPath
    | MonoUnbox MonoPath
    | MonoRoot Name


{-| Decision tree for pattern matching.

This matches the structure of Opt.Decider from Compiler.AST.Optimized:

  - Chain carries a list of (Path, Test) pairs for the condition
  - FanOut carries the Path being tested

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

        MonoUnit ->
            MUnit

        MonoAccessor _ _ t ->
            t


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



-- ============================================================================
-- COMPARISON FUNCTIONS
-- ============================================================================


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> List String
toComparableGlobal (Global home name) =
    ModuleName.toComparableCanonical home ++ [ name ]


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

        MCustom canonical name args ->
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
        CEcoValue ->
            "ecovalue"

        CNumber ->
            "number"


{-| Convert a lambda ID to a comparable key for use in dictionaries.
-}
toComparableLambdaId : LambdaId -> List String
toComparableLambdaId lambdaId =
    case lambdaId of
        AnonymousLambda canonical uid ->
            "Anon" :: ModuleName.toComparableCanonical canonical ++ [ String.fromInt uid ]


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
