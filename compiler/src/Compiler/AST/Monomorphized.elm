module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry
    , MonoGraph(..), MainInfo(..), MonoNode(..), CtorShape, nodeType
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , Decider(..), MonoChoice(..)
    , ContainerKind(..)
    , typeOf
    , toComparableSpecKey, toComparableMonoType
    , getMonoPathType
    , monoTypeToDebugString
    , forceCNumberToInt
    , Segmentation, segmentLengths, stageParamTypes, stageReturnType
    , chooseCanonicalSegmentation, buildSegmentedFunctionType
    , decomposeFunctionType, isFunctionType, countTotalArity
    , CallModel(..), CallInfo, defaultCallInfo
    , ClosureKindId(..), ClosureKind(..), MaybeClosureKind
    , CaptureABI
    , containsAnyMVar, containsCEcoMVar, eraseCEcoVarsToErased, eraseCEcoVarsToErasedHelp, eraseTypeVarsToErased, eraseTypeVarsToErasedHelp
    , listMapChanged, resultTypeOf
    -- Typed closure calling (ABI cloning)
    -- Call staging metadata
    -- Staging/Segmentation helpers
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


# Lambda Sets

@docs LambdaId


# Globals and Specialization

@docs Global, SpecKey, SpecId, SpecializationRegistry


# Program Graph

@docs MonoGraph, MainInfo, MonoNode, CtorShape, nodeType


# Expressions

@docs MonoExpr, ClosureInfo, MonoDef, MonoDestructor, MonoPath


# Pattern Matching

@docs Decider, MonoChoice


# Container Classification

@docs ContainerKind


# Type Utilities

@docs typeOf


# Comparison and Ordering

@docs toComparableSpecKey, toComparableMonoType


# Path Utilities

@docs getMonoPathType


# Debug

@docs monoTypeToDebugString


# Comparable Conversions


# Constraint Utilities

@docs forceCNumberToInt


# Staging and Segmentation

@docs Segmentation, segmentLengths, stageParamTypes, stageReturnType
@docs chooseCanonicalSegmentation, buildSegmentedFunctionType
@docs decomposeFunctionType, isFunctionType, countTotalArity


# Call Staging Metadata

@docs CallModel, CallInfo, defaultCallInfo


# Typed Closure Calling (ABI Cloning)

@docs ClosureKindId, ClosureKind, MaybeClosureKind
@docs CaptureABI


# Type Variable Erasure

@docs containsAnyMVar, containsCEcoMVar, eraseCEcoVarsToErased, eraseCEcoVarsToErasedHelp, eraseTypeVarsToErased, eraseTypeVarsToErasedHelp


# Misc Helpers

@docs listMapChanged, resultTypeOf

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.Data.BitSet exposing (BitSet)
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation exposing (Region)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== MONOMORPHIC TYPES ======
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

`MErased` is an internal monomorphization-only type that replaces `MVar` in
two cases: (1) dead-value specializations whose value is never used (all MVars
erased), and (2) value-used specializations whose key type is still polymorphic
(only CEcoValue MVars erased — these are phantom type variables never constrained
by any call site). MErased is always treated as boxed `!eco.value` for layout
and ABI purposes and must not influence unboxing or staging decisions. In codegen,
MErased is mapped to `!eco.value` at all boundaries (ABI, SSA operand, type table).

-}
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple (List MonoType) -- Element types (layout computed at codegen)
    | MRecord (Dict Name MonoType) -- Field name -> type (layout computed at codegen)
    | MCustom IO.Canonical Name (List MonoType)
    | MFunction (List MonoType) MonoType
    | MVar Name Constraint
    | MErased -- Erased type for dead-value specs and phantom type vars in polymorphic-key specs; always boxed !eco.value


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
-- ====== LAMBDA SETS ======
-- ============================================================================


{-| Force all numeric-constrained type variables (MVar \_ CNumber)
to concrete Int (MInt) inside a MonoType.

Backend policy: when we have an ambiguous `number` that has not
been resolved to Float by constraints, we default it to Int.
This is sound for ECO because Elm `number` is morally "Int or Float",
and we only commit to Int where no Float-specific behaviour is required.

IMPORTANT: This does NOT affect MFloat or Float-typed code. Only
unresolved MVar \_ CNumber is converted. Float-specific operations
(Basics./, trig functions, etc.) have canonical Float types and
resolve to MFloat directly without going through CNumber.

-}
forceCNumberToInt : MonoType -> MonoType
forceCNumberToInt monoType =
    case monoType of
        MVar _ CNumber ->
            MInt

        MVar _ CEcoValue ->
            monoType

        MList elemType ->
            MList (forceCNumberToInt elemType)

        MFunction args result ->
            MFunction
                (List.map forceCNumberToInt args)
                (forceCNumberToInt result)

        MTuple elems ->
            MTuple (List.map forceCNumberToInt elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> forceCNumberToInt t) fields)

        MCustom can name args ->
            MCustom can name (List.map forceCNumberToInt args)

        _ ->
            monoType


{-| Extract the final result type from a (possibly curried) function type.
E.g., MFunction [MInt] (MFunction [MInt] MInt) -> MInt
For non-function types, returns the type itself.
-}
resultTypeOf : MonoType -> MonoType
resultTypeOf monoType =
    case monoType of
        MFunction _ result ->
            resultTypeOf result

        _ ->
            monoType


{-| Recursively replace all type variables (`MVar`) with `MErased`.

Used to normalize the types of specializations whose value is never used,
so that remaining polymorphic type variables don't trigger MONO\_021 violations
for dead-value nodes.

Uses a changed-flag pattern to avoid rebuilding the type tree when no MVars
are present (the common case for fully-specialized types).

-}
eraseTypeVarsToErased : MonoType -> MonoType
eraseTypeVarsToErased monoType =
    Tuple.second (eraseTypeVarsToErasedHelp monoType)


{-| Changed-flag variant: returns (True, newType) if any MVar was erased,
or (False, originalType) if the type was unchanged.
-}
eraseTypeVarsToErasedHelp : MonoType -> ( Bool, MonoType )
eraseTypeVarsToErasedHelp monoType =
    case monoType of
        MVar _ _ ->
            ( True, MErased )

        MList t ->
            let
                ( changed, newT ) =
                    eraseTypeVarsToErasedHelp t
            in
            if changed then
                ( True, MList newT )

            else
                ( False, monoType )

        MFunction args result ->
            let
                ( argsChanged, newArgs ) =
                    listMapChanged eraseTypeVarsToErasedHelp args

                ( resultChanged, newResult ) =
                    eraseTypeVarsToErasedHelp result
            in
            if argsChanged || resultChanged then
                ( True, MFunction newArgs newResult )

            else
                ( False, monoType )

        MTuple elems ->
            let
                ( changed, newElems ) =
                    listMapChanged eraseTypeVarsToErasedHelp elems
            in
            if changed then
                ( True, MTuple newElems )

            else
                ( False, monoType )

        MRecord fields ->
            let
                ( changed, newFields ) =
                    dictMapChanged eraseTypeVarsToErasedHelp fields
            in
            if changed then
                ( True, MRecord newFields )

            else
                ( False, monoType )

        MCustom can name args ->
            let
                ( changed, newArgs ) =
                    listMapChanged eraseTypeVarsToErasedHelp args
            in
            if changed then
                ( True, MCustom can name newArgs )

            else
                ( False, monoType )

        _ ->
            ( False, monoType )


{-| Check whether a MonoType contains any `MVar` (any constraint).
-}
containsAnyMVar : MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        MVar _ _ ->
            True

        MList t ->
            containsAnyMVar t

        MFunction args result ->
            List.any containsAnyMVar args || containsAnyMVar result

        MTuple elems ->
            List.any containsAnyMVar elems

        MRecord fields ->
            Dict.foldl (\_ t acc -> acc || containsAnyMVar t) False fields

        MCustom _ _ args ->
            List.any containsAnyMVar args

        _ ->
            False


{-| Check whether a MonoType contains any `MVar _ CEcoValue`.

Used to determine if a specialization's key type is still polymorphic
(has unconstrained type variables). CNumber MVars are ignored since they
are resolved separately via `forceCNumberToInt`.

-}
containsCEcoMVar : MonoType -> Bool
containsCEcoMVar monoType =
    case monoType of
        MVar _ CEcoValue ->
            True

        MVar _ CNumber ->
            False

        MList t ->
            containsCEcoMVar t

        MFunction args result ->
            List.any containsCEcoMVar args || containsCEcoMVar result

        MTuple elems ->
            List.any containsCEcoMVar elems

        MRecord fields ->
            Dict.foldl (\_ t acc -> acc || containsCEcoMVar t) False fields

        MCustom _ _ args ->
            List.any containsCEcoMVar args

        _ ->
            False


{-| Erase only `MVar _ CEcoValue` to `MErased`, leaving `MVar _ CNumber` intact.

Used for value-used specializations whose key type is still polymorphic.
These CEcoValue MVars are phantom type variables that were never constrained
by any call site. CNumber MVars are preserved to avoid hiding numeric
specialization bugs.

Uses a changed-flag pattern to avoid rebuilding the type tree when no
CEcoValue MVars are present.

-}
eraseCEcoVarsToErased : MonoType -> MonoType
eraseCEcoVarsToErased monoType =
    Tuple.second (eraseCEcoVarsToErasedHelp monoType)


{-| Changed-flag variant: returns (True, newType) if any CEcoValue MVar was erased,
or (False, originalType) if the type was unchanged.
-}
eraseCEcoVarsToErasedHelp : MonoType -> ( Bool, MonoType )
eraseCEcoVarsToErasedHelp monoType =
    case monoType of
        MVar _ CEcoValue ->
            ( True, MErased )

        MVar _ CNumber ->
            ( False, monoType )

        MList t ->
            let
                ( changed, newT ) =
                    eraseCEcoVarsToErasedHelp t
            in
            if changed then
                ( True, MList newT )

            else
                ( False, monoType )

        MFunction args result ->
            let
                ( argsChanged, newArgs ) =
                    listMapChanged eraseCEcoVarsToErasedHelp args

                ( resultChanged, newResult ) =
                    eraseCEcoVarsToErasedHelp result
            in
            if argsChanged || resultChanged then
                ( True, MFunction newArgs newResult )

            else
                ( False, monoType )

        MTuple elems ->
            let
                ( changed, newElems ) =
                    listMapChanged eraseCEcoVarsToErasedHelp elems
            in
            if changed then
                ( True, MTuple newElems )

            else
                ( False, monoType )

        MRecord fields ->
            let
                ( changed, newFields ) =
                    dictMapChanged eraseCEcoVarsToErasedHelp fields
            in
            if changed then
                ( True, MRecord newFields )

            else
                ( False, monoType )

        MCustom can name args ->
            let
                ( changed, newArgs ) =
                    listMapChanged eraseCEcoVarsToErasedHelp args
            in
            if changed then
                ( True, MCustom can name newArgs )

            else
                ( False, monoType )

        _ ->
            ( False, monoType )


{-| Map a changed-flag function over a list. Returns (True, newList) if any element
changed, or (False, originalList) if no element changed.
-}
listMapChanged : (a -> ( Bool, a )) -> List a -> ( Bool, List a )
listMapChanged f list =
    listMapChangedHelp f list list False []


listMapChangedHelp : (a -> ( Bool, a )) -> List a -> List a -> Bool -> List a -> ( Bool, List a )
listMapChangedHelp f remaining original anyChanged acc =
    case remaining of
        [] ->
            if anyChanged then
                ( True, List.reverse acc )

            else
                ( False, original )

        x :: xs ->
            let
                ( changed, newX ) =
                    f x
            in
            listMapChangedHelp f xs original (anyChanged || changed) (newX :: acc)


{-| Map a changed-flag function over Dict values. Returns (True, newDict) if any
value changed, or (False, originalDict) if no value changed.
-}
dictMapChanged : (v -> ( Bool, v )) -> Dict comparable v -> ( Bool, Dict comparable v )
dictMapChanged f dict =
    let
        ( changed, newDict ) =
            Dict.foldl
                (\key val ( ch, acc ) ->
                    let
                        ( valChanged, newVal ) =
                            f val
                    in
                    ( ch || valChanged, Dict.insert key newVal acc )
                )
                ( False, Dict.empty )
                dict
    in
    if changed then
        ( True, newDict )

    else
        ( False, dict )


{-| Identifier for lambda functions in lambda sets, distinguishing named functions from closures.
-}
type LambdaId
    = AnonymousLambda IO.Canonical Int



-- ============================================================================
-- ====== SPECIALIZATION KEYS AND IDS ======
-- ============================================================================


{-| A reference to a top-level definition in a module, or a virtual
global for record field accessors (.field).
-}
type Global
    = Global IO.Canonical Name
    | Accessor Name


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
    , mapping : Dict (List String) SpecId
    , reverseMapping : Array (Maybe ( Global, MonoType, Maybe LambdaId ))
    }



-- ============================================================================
-- ====== CONSTRUCTOR SHAPES ======
-- ============================================================================


{-| Backend-agnostic constructor shape: name, tag, field types.

This captures the semantic structure without layout-specific details like
field indices and unboxing bitmaps. The CtorLayout is computed from this
shape during code generation.

-}
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List MonoType
    }



-- ============================================================================
-- ====== MONO GRAPH ======
-- ============================================================================


{-| The complete monomorphized program graph containing all specialized definitions.
-}
type MonoGraph
    = MonoGraph
        { nodes : Array (Maybe MonoNode)
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List CtorShape)
        , nextLambdaIndex : Int
        , callEdges : Array (Maybe (List Int)) -- Collected during monomorphization. Reuse in downstream passes instead of re-traversing MonoExpr trees.
        , specHasEffects : BitSet -- SpecIds whose node body references Debug.* kernels
        , specValueUsed : BitSet -- SpecIds whose value is referenced via MonoVarGlobal
        }


{-| Information about the main entry point.

  - Static: A simple main value (Html, Svg, etc.)
  - Dynamic: An application with flags decoder (Browser.element, etc.)

-}
type MainInfo
    = StaticMain SpecId -- main specId, flags decoder expression



-- ============================================================================
-- ====== MONO NODES ======
-- ============================================================================


{-| A node in the monomorphized dependency graph representing a specialized definition.
-}
type MonoNode
    = MonoDefine MonoExpr MonoType
    | MonoTailFunc (List ( Name, MonoType )) MonoExpr MonoType
    | MonoCtor CtorShape MonoType -- Layout computed from shape at codegen
    | MonoEnum Int MonoType
    | MonoExtern MonoType
    | MonoManagerLeaf String MonoType -- Effect manager leaf: home module name, type
    | MonoPortIncoming MonoExpr MonoType
    | MonoPortOutgoing MonoExpr MonoType
    | MonoCycle (List ( Name, MonoExpr )) MonoType



-- ============================================================================
-- ====== MONO EXPRESSIONS ======
-- ============================================================================


{-| Extract the MonoType from any MonoNode variant.
-}
nodeType : MonoNode -> MonoType
nodeType node =
    case node of
        MonoDefine _ t ->
            t

        MonoTailFunc _ _ t ->
            t

        MonoCtor _ t ->
            t

        MonoEnum _ t ->
            t

        MonoExtern t ->
            t

        MonoManagerLeaf _ t ->
            t

        MonoPortIncoming _ t ->
            t

        MonoPortOutgoing _ t ->
            t

        MonoCycle _ t ->
            t


{-| A monomorphized expression with concrete types and explicit closures.
-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name MonoType -- Mutually recursive variable reference
    | MonoList Region (List MonoExpr) MonoType
    | MonoClosure ClosureInfo MonoExpr MonoType
    | MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo
    | MonoTailCall Name (List ( Name, MonoExpr )) MonoType
    | MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
    | MonoLet MonoDef MonoExpr MonoType
    | MonoDestruct MonoDestructor MonoExpr MonoType
    | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
    | MonoRecordCreate (List ( Name, MonoExpr )) MonoType -- Fields with names, codegen reorders by layout
    | MonoRecordAccess MonoExpr Name MonoType -- Field name only, codegen computes index/isUnboxed
    | MonoRecordUpdate MonoExpr (List ( Name, MonoExpr )) MonoType -- Field names, codegen computes indices
    | MonoTupleCreate Region (List MonoExpr) MonoType -- Layout computed at codegen
    | MonoUnit


{-| Literal values in monomorphized expressions.
-}
type Literal
    = LBool Bool
    | LInt Int
    | LFloat Float
    | LChar String
    | LStr String


{-| Information about a closure including its lambda ID, captured variables, and parameters.

Extended for typed closure calling:

  - closureKind: Three-way lattice state for ABI cloning
  - captureAbi: Explicit capture ABI (for closures with captures)

-}
type alias ClosureInfo =
    { lambdaId : LambdaId
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    }


{-| A local definition in monomorphized code.
-}
type MonoDef
    = MonoDef Name MonoExpr
    | MonoTailDef Name (List ( Name, MonoType )) MonoExpr


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
    | CustomContainer Name -- Constructor name for layout lookup


{-| Path for navigating into a data structure during destructuring.

MonoIndex now carries ContainerKind and MonoType to enable type-specific projection ops.
The MonoType is the RESULT type of evaluating that path segment.
In generateMonoPath, the container type for a MonoIndex is obtained via getMonoPathType subPath.

-}
type MonoPath
    = MonoIndex Int ContainerKind MonoType MonoPath -- MonoType = result type after projection
    | MonoField Name MonoType MonoPath -- MonoType = result type after field access (record field by name)
    | MonoUnbox MonoType MonoPath -- MonoType = result type after unwrapping (the field type)
    | MonoRoot Name MonoType -- MonoType = variable's type


{-| Get the result type of evaluating a MonoPath.
-}
getMonoPathType : MonoPath -> MonoType
getMonoPathType path =
    case path of
        MonoRoot _ ty ->
            ty

        MonoIndex _ _ ty _ ->
            ty

        MonoField _ ty _ ->
            ty

        MonoUnbox ty _ ->
            ty


{-| Convert a MonoType to a simple debug string for error messages.
-}
monoTypeToDebugString : MonoType -> String
monoTypeToDebugString monoType =
    case monoType of
        MInt ->
            "MInt"

        MFloat ->
            "MFloat"

        MBool ->
            "MBool"

        MChar ->
            "MChar"

        MString ->
            "MString"

        MUnit ->
            "MUnit"

        MList _ ->
            "MList ..."

        MTuple _ ->
            "MTuple ..."

        MRecord _ ->
            "MRecord ..."

        MCustom _ name _ ->
            "MCustom " ++ name ++ " ..."

        MFunction _ _ ->
            "MFunction ..."

        MVar name _ ->
            "MVar " ++ name

        MErased ->
            "MErased"


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
-- ====== TYPE UTILITIES ======
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

        MonoCall _ _ _ t _ ->
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

        MonoRecordCreate _ t ->
            t

        MonoRecordAccess _ _ t ->
            t

        MonoRecordUpdate _ _ t ->
            t

        MonoTupleCreate _ _ t ->
            t

        MonoUnit ->
            MUnit



-- ============================================================================
-- ====== COMPARISON FUNCTIONS ======
-- ============================================================================


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> List String
toComparableGlobal global =
    case global of
        Global home name ->
            "Global" :: ModuleName.toComparableCanonical home ++ [ name ]

        Accessor fieldName ->
            [ "Accessor", fieldName ]


{-| Convert a monomorphic type to a comparable key for use in dictionaries.
-}
toComparableMonoType : MonoType -> List String
toComparableMonoType monoType =
    -- Use explicit work stack to avoid deep recursion
    toComparableMonoTypeHelper [ WorkType monoType ] []


{-| Work item for the tail-recursive type comparison helper.
-}
type WorkItem
    = WorkType MonoType
    | WorkMarker String


{-| Tail-recursive helper using explicit work stack.

The work list contains either MonoTypes to process or string markers.
We process each item, adding strings to the accumulator and pushing
any nested types onto the work stack for later processing.

-}
toComparableMonoTypeHelper : List WorkItem -> List String -> List String
toComparableMonoTypeHelper work acc =
    -- Direct tail-recursive implementation using only TCO-safe operations
    -- Avoid: List.map, List.concatMap, (++) - they use foldr which isn't TCO
    case work of
        [] ->
            List.reverse acc

        (WorkMarker s) :: rest ->
            toComparableMonoTypeHelper rest (s :: acc)

        (WorkType monoType) :: rest ->
            case monoType of
                MInt ->
                    toComparableMonoTypeHelper rest ("Int" :: acc)

                MFloat ->
                    toComparableMonoTypeHelper rest ("Float" :: acc)

                MBool ->
                    toComparableMonoTypeHelper rest ("Bool" :: acc)

                MChar ->
                    toComparableMonoTypeHelper rest ("Char" :: acc)

                MString ->
                    toComparableMonoTypeHelper rest ("String" :: acc)

                MUnit ->
                    toComparableMonoTypeHelper rest ("Unit" :: acc)

                MVar name constraint ->
                    toComparableMonoTypeHelper rest (constraintToString constraint :: name :: "Var" :: acc)

                MList inner ->
                    toComparableMonoTypeHelper
                        (WorkType inner :: WorkMarker "}" :: rest)
                        ("List{" :: acc)

                MTuple elementTypes ->
                    -- Use foldl to cons items onto rest (builds work in reverse, which is fine)
                    let
                        workWithMarker =
                            WorkMarker "}" :: rest

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) workWithMarker elementTypes
                    in
                    toComparableMonoTypeHelper
                        newWork
                        ("{" :: String.fromInt (List.length elementTypes) :: "Tuple" :: acc)

                MRecord fields ->
                    let
                        fieldList =
                            Dict.toList fields

                        workWithMarker =
                            WorkMarker "}" :: rest

                        -- Add fields in reverse using foldl (name then type for each)
                        newWork =
                            List.foldl
                                (\( name, ty ) w -> WorkMarker name :: WorkType ty :: w)
                                workWithMarker
                                fieldList
                    in
                    toComparableMonoTypeHelper newWork ("Record{" :: acc)

                MCustom canonical name args ->
                    let
                        workWithMarker =
                            WorkMarker "}" :: rest

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) workWithMarker args

                        header =
                            "{" :: name :: ModuleName.toComparableCanonical canonical ++ [ "Custom" ]

                        newAcc =
                            List.foldl (::) acc header
                    in
                    toComparableMonoTypeHelper newWork newAcc

                MFunction args ret ->
                    let
                        workWithRetAndMarker =
                            WorkMarker "->" :: WorkType ret :: WorkMarker "}" :: rest

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) workWithRetAndMarker args
                    in
                    toComparableMonoTypeHelper newWork ("Function{" :: acc)

                MErased ->
                    toComparableMonoTypeHelper rest ("Erased" :: acc)


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


{-| Convert a specialization key to a single comparable String for use in dictionaries.

Uses a compact single-String encoding to avoid List String allocation and concatenation
overhead. Parts are separated by \\u{0001}, elements within parts by \\u{0000}.

-}
toComparableSpecKey : SpecKey -> List String
toComparableSpecKey (SpecKey global monoType maybeLambda) =
    toComparableGlobal global
        ++ [ "\u{0001}" ]
        ++ toComparableMonoType monoType
        ++ [ "\u{0001}" ]
        ++ (case maybeLambda of
                Nothing ->
                    [ "N" ]

                Just lambdaId ->
                    "L" :: toComparableLambdaId lambdaId
           )



-- ============================================================================
-- ====== FUNCTION SHAPE HELPERS ======
-- ============================================================================


{-| Check if a MonoType is a function type.
-}
isFunctionType : MonoType -> Bool
isFunctionType monoType =
    case monoType of
        MFunction _ _ ->
            True

        _ ->
            False


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Stage parameter types: outermost MFunction argument list.
-}
stageParamTypes : MonoType -> List MonoType
stageParamTypes monoType =
    case monoType of
        MFunction argTypes _ ->
            argTypes

        _ ->
            []


{-| Stage return type: the result type after applying the current stage's arguments.

For `MFunction [a, b] (MFunction [c] d)`, this returns `MFunction [c] d`.
For non-function types, returns the type itself.

-}
stageReturnType : MonoType -> MonoType
stageReturnType monoType =
    case monoType of
        MFunction _ result ->
            result

        other ->
            other


{-| Decompose a function type into its flattened arguments and final result.
-}
decomposeFunctionType : MonoType -> ( List MonoType, MonoType )
decomposeFunctionType monoType =
    case monoType of
        MFunction argTypes result ->
            let
                ( nestedArgs, finalResult ) =
                    decomposeFunctionType result
            in
            ( argTypes ++ nestedArgs, finalResult )

        other ->
            ( [], other )


{-| A Segmentation is a list of stage arities: [m1, m2, ...] means
stage 1 takes m1 args, stage 2 takes m2 args, etc.
-}
type alias Segmentation =
    List Int


{-| Call model of a function, independent of backend.
This is the AST-side version; MLIR Context.CallModel can be removed.
-}
type CallModel
    = FlattenedExternal
    | StageCurried


{-| Staging / call-site metadata for MonoCall.

  - callModel: FlattenedExternal vs StageCurried
  - stageArities: Full list of stage arities [a1, a2, ...] for the callee.
  - isSingleStageSaturated: True if this call consumes all arguments and
    fits entirely in the first stage.
  - initialRemaining: Stage arity of the current closure value at this call site
    (used as sourceRemaining in applyByStages).
  - remainingStageArities: Stage arities for subsequent stages after saturating
    the current closure (used in applyByStages).

Extended for typed closure calling:

  - closureKind: Three-way lattice for callee value's closure kind
  - captureAbi: For typed closure calls with known ABI

-}
type alias CallInfo =
    { callModel : CallModel
    , stageArities : List Int
    , isSingleStageSaturated : Bool
    , initialRemaining : Int
    , remainingStageArities : List Int
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    }


{-| Default/placeholder CallInfo for newly constructed calls.
Will be overwritten by annotateCallStaging pass in GlobalOpt.
-}
defaultCallInfo : CallInfo
defaultCallInfo =
    { callModel = StageCurried
    , stageArities = []
    , isSingleStageSaturated = False
    , initialRemaining = 0
    , remainingStageArities = []
    , closureKind = Nothing
    , captureAbi = Nothing
    }


{-| Extract the staging pattern (segment lengths) from a function type.
For `MFunction [A,B] (MFunction [C,D] R)` returns `[2, 2]`.
For `MFunction [A,B,C,D] R` returns `[4]`.
For non-function types returns `[]`.
-}
segmentLengths : MonoType -> Segmentation
segmentLengths monoType =
    let
        go t acc =
            case t of
                MFunction stageArgs stageRet ->
                    go stageRet (List.length stageArgs :: acc)

                _ ->
                    List.reverse acc
    in
    go monoType []


{-| Choose the canonical ABI segmentation for a join point.
Given leaf function types from case branches:

1.  Pick the segmentation that appears most often (minimize wrappers)
2.  Among ties, pick the one with fewest stages (prefer flatter)

Returns (canonicalSegmentation, flatArgs, flatRet).

-}
chooseCanonicalSegmentation : List MonoType -> ( Segmentation, List MonoType, MonoType )
chooseCanonicalSegmentation leafTypes =
    case leafTypes of
        [] ->
            -- Should not happen for well-formed MonoCase
            ( [], [], MUnit )

        firstType :: _ ->
            let
                -- Shared flattened signature (all branches must agree)
                ( flatArgs, flatRet ) =
                    decomposeFunctionType firstType

                -- Count how often each segmentation occurs
                countSegmentations : List MonoType -> Dict (List Int) Int
                countSegmentations types =
                    List.foldl
                        (\t accDict ->
                            let
                                seg =
                                    segmentLengths t

                                current =
                                    Dict.get seg accDict |> Maybe.withDefault 0
                            in
                            Dict.insert seg (current + 1) accDict
                        )
                        Dict.empty
                        types

                freqDict =
                    countSegmentations leafTypes

                -- Find maximum count
                maxCount =
                    Dict.foldl (\_ count acc -> max count acc) 0 freqDict

                -- All segmentations that hit maxCount
                bestSegs =
                    Dict.foldl
                        (\seg count acc ->
                            if count == maxCount then
                                seg :: acc

                            else
                                acc
                        )
                        []
                        freqDict

                -- Among them, prefer fewest stages (most flat)
                canonicalSeg =
                    case List.sortBy List.length bestSegs of
                        shortest :: _ ->
                            shortest

                        [] ->
                            -- Fallback: use first type's segmentation
                            segmentLengths firstType
            in
            ( canonicalSeg, flatArgs, flatRet )


{-| Rebuild a nested MFunction from flat args and a segmentation.
buildSegmentedFunctionType [A,B,C,D] R [2,2] = MFunction [A,B] (MFunction [C,D] R)
buildSegmentedFunctionType [A,B,C,D] R [4] = MFunction [A,B,C,D] R
-}
buildSegmentedFunctionType : List MonoType -> MonoType -> Segmentation -> MonoType
buildSegmentedFunctionType flatArgs finalRet seg =
    let
        -- Split flatArgs according to seg = [m1, m2, ...]
        splitBySegments : List MonoType -> Segmentation -> List (List MonoType)
        splitBySegments remaining segLengths =
            case segLengths of
                [] ->
                    []

                m :: rest ->
                    let
                        ( now, later ) =
                            ( List.take m remaining, List.drop m remaining )
                    in
                    now :: splitBySegments later rest

        stageArgsLists =
            splitBySegments flatArgs seg
    in
    -- Build nested MFunction from inside out
    List.foldr
        (\stageArgs acc -> MFunction stageArgs acc)
        finalRet
        stageArgsLists



-- ============================================================================
-- ====== TYPED CLOSURE CALLING (ABI CLONING) ======
-- ============================================================================


{-| Unique identifier for a closure kind (lambda + capture ABI combination).
Each distinct closure creation site with a unique capture ABI gets its own ID.
-}
type ClosureKindId
    = ClosureKindId Int


{-| Three-way lattice for closure kind tracking.

  - Known id: definitely this specific closure kind (homogeneous)
  - Heterogeneous: definitely one of several closure kinds (analysis proved it)

This is wrapped in Maybe to provide the third state (Nothing = unknown/untracked).

-}
type ClosureKind
    = Known ClosureKindId


{-| Maybe ClosureKind provides the third state:

  - Just (Known id): homogeneous - SSA value is definitely closure kind `id`
  - Just Heterogeneous: known heterogeneous - SSA value is one of multiple closure kinds
  - Nothing: unknown - no closure-kind info (non-closure, legacy path, or analysis bug)

-}
type alias MaybeClosureKind =
    Maybe ClosureKind


{-| The ABI signature for a closure's captures + params + return.
Used to determine if two closures have compatible calling conventions.
-}
type alias CaptureABI =
    { captureTypes : List MonoType
    , paramTypes : List MonoType
    , returnType : MonoType
    }
