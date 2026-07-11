module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , LambdaSetAnno(..), widenSets, eqLayout, headAnno, unionAnno
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry
    , MonoGraph(..), MainInfo(..), MonoNode(..), CtorShape, nodeType
    , PortRegistration
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , MonoDtPath(..), dtPathType
    , Decider(..), MonoChoice(..)
    , ContainerKind(..)
    , typeOf
    , toComparableSpecKey, toComparableMonoType, toComparableGlobal
    , getMonoPathType
    , monoTypeToDebugString
    , resolveNumberType, typeHasResidualNumber
    , Segmentation, segmentLengths, stageParamTypes, stageReturnType
    , chooseCanonicalSegmentation, buildSegmentedFunctionType
    , decomposeFunctionType, isFunctionType, countTotalArity
    , CallModel(..), CallKind(..), CallInfo, defaultCallInfo
    , ClosureKindId(..), ClosureKind(..), MaybeClosureKind
    , CaptureABI
    , containsAnyMVar, resultTypeOf
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
@docs PortRegistration


# Expressions

@docs MonoExpr, ClosureInfo, MonoDef, MonoDestructor, MonoPath


# Decision Tree Paths

@docs MonoDtPath, dtPathType


# Pattern Matching

@docs Decider, MonoChoice


# Container Classification

@docs ContainerKind


# Type Utilities

@docs typeOf


# Comparison and Ordering

@docs toComparableSpecKey, toComparableMonoType, toComparableGlobal


# Path Utilities

@docs getMonoPathType


# Debug

@docs monoTypeToDebugString


# Comparable Conversions


# Constraint Utilities

@docs resolveNumberType, typeHasResidualNumber


# Staging and Segmentation

@docs Segmentation, segmentLengths, stageParamTypes, stageReturnType
@docs chooseCanonicalSegmentation, buildSegmentedFunctionType
@docs decomposeFunctionType, isFunctionType, countTotalArity


# Call Staging Metadata

@docs CallModel, CallKind, CallInfo, defaultCallInfo


# Typed Closure Calling (ABI Cloning)

@docs ClosureKindId, ClosureKind, MaybeClosureKind
@docs CaptureABI


# Misc Helpers

@docs containsAnyMVar, resultTypeOf

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.TypeIds as TypeIds exposing (MVarId)
import Compiler.Data.BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
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
    | MFunction LambdaSetAnno (List MonoType) MonoType
    | MVar MVarId Constraint


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


{-| The lambda-set fact on an arrow. `LTop` = statically unknown or
deliberately widened — exactly today's world; the whole existing pipeline
(boxed closures, papCreate/papExtend, CallGenericApply) is the correct
lowering of `LTop`. `LSet` is a non-empty, ascending-sorted list of member
ids (Phase-0 lambda ids + engine-interned globals/ctors/kernels/accessors);
an unconstrained residual zonks to `LTop`, never to an empty set, so
`LSet []` is unrepresentable by construction (LSS_001).
-}
type LambdaSetAnno
    = LTop
    | LSet (List Int)


{-| Widen every arrow annotation to `LTop`, recursively. Used for
annotation-insensitive keying/comparison (`eqLayout`, budget-widened
specialization keys).
-}
widenSets : MonoType -> MonoType
widenSets monoType =
    case monoType of
        MFunction _ args result ->
            MFunction LTop (List.map widenSets args) (widenSets result)

        MList inner ->
            MList (widenSets inner)

        MTuple elems ->
            MTuple (List.map widenSets elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> widenSets t) fields)

        MCustom home name args ->
            MCustom home name (List.map widenSets args)

        _ ->
            monoType


{-| Annotation-insensitive structural equality. Layout comparisons must not
become set-sensitive: two types with the same shape but different lambda
sets have identical representation (an arrow is a boxed closure value
regardless of its set — REP_* untouched by LSS).
-}
eqLayout : MonoType -> MonoType -> Bool
eqLayout a b =
    widenSets a == widenSets b


{-| The head arrow's annotation; `LTop` for non-function types.
-}
headAnno : MonoType -> LambdaSetAnno
headAnno monoType =
    case monoType of
        MFunction anno _ _ ->
            anno

        _ ->
            LTop


{-| Join two annotations: the least annotation covering both. `LTop`
absorbs; sets union (kept ascending-sorted for key canonicality).
-}
unionAnno : LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno
unionAnno a b =
    case ( a, b ) of
        ( LTop, _ ) ->
            LTop

        ( _, LTop ) ->
            LTop

        ( LSet xs, LSet ys ) ->
            LSet (unionSortedInts xs ys)


{-| Union of two ascending-sorted int lists, ascending and deduplicated.
-}
unionSortedInts : List Int -> List Int -> List Int
unionSortedInts xs ys =
    case ( xs, ys ) of
        ( [], _ ) ->
            ys

        ( _, [] ) ->
            xs

        ( x :: xRest, y :: yRest ) ->
            if x < y then
                x :: unionSortedInts xRest ys

            else if y < x then
                y :: unionSortedInts xs yRest

            else
                x :: unionSortedInts xRest yRest


{-| Closing operator for quiescence-before-defaulting: structurally resolve every
residual number var in a MonoType to `MInt`.

Table-consulting: a var closes to `MInt` if EITHER its stamped constraint is
`CNumber` (an original number var) OR the `isNumber` predicate reports its id as
number-tainted in the final `superVars` (a boxed var that Join-R merged into a
number class after this copy was stamped — the stale `CEcoValue` stamp is
healed). A genuine, never-tainted `CEcoValue` var is left untouched (boxed).
`applySubst` no longer defaults number vars during the fixpoint; this discharges
them once, at the end, from `resolveResidualNumbers`.

-}
resolveNumberType : (MVarId -> Bool) -> MonoType -> MonoType
resolveNumberType isNumber monoType =
    -- Identity-preserving (perf): a residual number var is rare, so short-circuit
    -- and return the input by reference when the type has none — no copy. Only
    -- rebuild the subtrees that actually contain a residual.
    if typeHasResidualNumber isNumber monoType then
        resolveNumberTypeRebuild isNumber monoType

    else
        monoType


{-| Does the type contain a residual number var — `MVar _ CNumber`, or an
`MVar id CEcoValue` that `isNumber` reports as Join-R-tainted? Allocation-free.
-}
typeHasResidualNumber : (MVarId -> Bool) -> MonoType -> Bool
typeHasResidualNumber isNumber monoType =
    case monoType of
        MVar mvarId constraint ->
            case constraint of
                CNumber ->
                    True

                CEcoValue ->
                    isNumber mvarId

        MList inner ->
            typeHasResidualNumber isNumber inner

        MTuple elems ->
            List.any (typeHasResidualNumber isNumber) elems

        MRecord fields ->
            Dict.foldl (\_ t acc -> acc || typeHasResidualNumber isNumber t) False fields

        MCustom _ _ args ->
            List.any (typeHasResidualNumber isNumber) args

        MFunction _ args result ->
            List.any (typeHasResidualNumber isNumber) args || typeHasResidualNumber isNumber result

        _ ->
            False


resolveNumberTypeRebuild : (MVarId -> Bool) -> MonoType -> MonoType
resolveNumberTypeRebuild isNumber monoType =
    case monoType of
        MVar mvarId constraint ->
            case constraint of
                CNumber ->
                    MInt

                CEcoValue ->
                    if isNumber mvarId then
                        MInt

                    else
                        monoType

        MList inner ->
            MList (resolveNumberType isNumber inner)

        MTuple elems ->
            MTuple (List.map (resolveNumberType isNumber) elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> resolveNumberType isNumber t) fields)

        MCustom home name args ->
            MCustom home name (List.map (resolveNumberType isNumber) args)

        MFunction anno args result ->
            -- Rebuilder: thread the annotation through (never stamp LTop here).
            MFunction anno (List.map (resolveNumberType isNumber) args) (resolveNumberType isNumber result)

        MInt ->
            monoType

        MFloat ->
            monoType

        MBool ->
            monoType

        MChar ->
            monoType

        MString ->
            monoType

        MUnit ->
            monoType


{-| Extract the final result type from a (possibly curried) function type.
E.g., MFunction [MInt] (MFunction [MInt] MInt) -> MInt
For non-function types, returns the type itself.
-}
resultTypeOf : MonoType -> MonoType
resultTypeOf monoType =
    case monoType of
        MFunction _ _ result ->
            resultTypeOf result

        _ ->
            monoType


{-| Check whether a MonoType contains any `MVar` (any constraint).
-}
containsAnyMVar : MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        MVar _ _ ->
            True

        MList t ->
            containsAnyMVar t

        MFunction _ args result ->
            containsAnyMVarList args || containsAnyMVar result

        MTuple elems ->
            containsAnyMVarList elems

        MRecord fields ->
            Dict.foldl (\_ t acc -> acc || containsAnyMVar t) False fields

        MCustom _ _ args ->
            containsAnyMVarList args

        _ ->
            False


containsAnyMVarList : List MonoType -> Bool
containsAnyMVarList types =
    case types of
        [] ->
            False

        t :: rest ->
            containsAnyMVar t || containsAnyMVarList rest


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
    = SpecKey Global MonoType


{-| Unique integer identifier for a function specialization.
-}
type alias SpecId =
    Int


{-| Registry tracking all function specializations in the program.
-}
type alias SpecializationRegistry =
    { nextId : Int
    , mapping : Dict String SpecId
    , reverseMapping : Array (Maybe ( Global, MonoType ))
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
        , ctorShapes : Dict String (List CtorShape)
        , nextLambdaIndex : Int
        , callEdges : Array (Maybe (List Int)) -- Collected during monomorphization. Reuse in downstream passes instead of re-traversing MonoExpr trees.
        , specHasEffects : BitSet -- SpecIds whose node body references Debug.* kernels
        , specValueUsed : BitSet -- SpecIds whose value is referenced via MonoVarGlobal
        , ports : List PortRegistration -- Ports reached during monomorphization; drives @__eco_register_ports emission (PORT_003)
        , flagsDecoder : Maybe SpecId -- The root program's flags decoder (Phase 5); registered at startup like port decoders
        }


{-| One port registration collected during monomorphization.

`name` is the bare port name — the effect-manager registry key, globally
unique per program (PORT\_001, JS `_Platform_checkPortName` parity). For
incoming ports `decoderSpecId` points at the synthetic `MonoDefine`
specialization holding the payload `Decoder` value; Prune keeps it
reachable and the MLIR backend's `@__eco_register_ports` preamble calls
its thunk to register the decoder with the runtime.

-}
type alias PortRegistration =
    { name : String
    , key : String -- comparable Global; dedup key (same port, many instantiations)
    , incoming : Bool
    , decoderSpecId : Maybe SpecId
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


{-| A monomorphized expression with concrete types and explicit closures.
-}
type MonoExpr
    = MonoLiteral Literal MonoType
    | MonoVarLocal Name MonoType
    | MonoVarGlobal Region SpecId MonoType
    | MonoVarKernel Region Name Name Name MonoType -- kernel prefix, home, name, type
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
    | MonoAccessorValue Region Name MonoType -- Deferred accessor .field value; eliminated by ResolveAccessorValues


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
    , srcLambda : Maybe TypeIds.SrcLambdaId -- source identity (LSS member); several instances MAY share one (inliner copies verbatim — unlike lambdaId, MONO_019)
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

        MFunction _ _ _ ->
            "MFunction ..."

        MVar mvarId _ ->
            "MVar#" ++ String.fromInt (Id.toComparable mvarId)


{-| A typed path for decision-tree navigation.

Mirrors `MonoPath` but only carries the constructors relevant to decision trees
(Index, Unbox, Root — no Field or ArrayIndex). The root embeds the scrutinee
variable name and its MonoType, so codegen does not need a separate `root` param.

-}
type MonoDtPath
    = DtRoot Name MonoType
    | DtIndex Int ContainerKind MonoType MonoDtPath
    | DtUnbox MonoType MonoDtPath


{-| Get the result type of evaluating a MonoDtPath.
-}
dtPathType : MonoDtPath -> MonoType
dtPathType path =
    case path of
        DtRoot _ ty ->
            ty

        DtIndex _ _ ty _ ->
            ty

        DtUnbox ty _ ->
            ty


{-| Decision tree for pattern matching.

This matches the structure of Opt.Decider from Compiler.AST.Optimized:

  - Chain carries a list of (MonoDtPath, Test) pairs for the condition
  - FanOut carries the MonoDtPath being tested

-}
type Decider a
    = Leaf a
    | Chain (List ( MonoDtPath, DT.Test )) (Decider a) (Decider a)
    | FanOut MonoDtPath (List ( DT.Test, Decider a )) (Decider a)


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

        MonoVarKernel _ _ _ _ t ->
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

        MonoAccessorValue _ _ t ->
            t



-- ============================================================================
-- ====== COMPARISON FUNCTIONS ======
-- ============================================================================


{-| Convert a global reference to a comparable key for use in dictionaries.
-}
toComparableGlobal : Global -> String
toComparableGlobal global =
    case global of
        Global home name ->
            let
                (IO.Canonical ( author, project ) modName) =
                    home
            in
            String.concat [ "G", author, "\u{0000}", project, "\u{0000}", modName, "\u{0000}", name ]

        Accessor fieldName ->
            String.concat [ "A", fieldName ]


{-| Convert a monomorphic type to a comparable String key for use in dictionaries.

This is used for:

  - Specialization keys in the monomorphization registry
  - Let-bound multi-specialization (localMulti / valueMulti)
  - Type table keys in MLIR codegen

IMPORTANT: `MVar _ CEcoValue` is layout-erased (MONO\_003). All such variables
are normalized to a canonical placeholder ID when building this comparable key,
so fresh MVarIds do not produce distinct keys. `MVar _ CNumber` retains its
numeric ID to preserve distinct numeric specializations.

Uses a List String accumulator joined at the end for O(n) instead of O(n²)
from repeated ++.

-}
toComparableMonoType : MonoType -> String
toComparableMonoType monoType =
    toComparableMonoTypeHelper [ WorkType monoType ] []
        |> List.reverse
        |> String.concat


{-| Work item for the tail-recursive type comparison helper.
-}
type WorkItem
    = WorkType MonoType
    | WorkMarker String


{-| Tail-recursive helper using explicit work stack, accumulating string fragments in reverse.

The work list contains either MonoTypes to process or string markers.
We process each item, prepending fragments to the accumulator list and pushing
any nested types onto the work stack for later processing. The caller reverses
and concatenates the list once at the end.

-}
toComparableMonoTypeHelper : List WorkItem -> List String -> List String
toComparableMonoTypeHelper work acc =
    case work of
        [] ->
            acc

        (WorkMarker s) :: rest ->
            toComparableMonoTypeHelper rest (s :: acc)

        (WorkType mt) :: rest ->
            case mt of
                MInt ->
                    toComparableMonoTypeHelper rest ("I" :: acc)

                MFloat ->
                    toComparableMonoTypeHelper rest ("F" :: acc)

                MBool ->
                    toComparableMonoTypeHelper rest ("B" :: acc)

                MChar ->
                    toComparableMonoTypeHelper rest ("C" :: acc)

                MString ->
                    toComparableMonoTypeHelper rest ("S" :: acc)

                MUnit ->
                    toComparableMonoTypeHelper rest ("U" :: acc)

                MVar _ constraint ->
                    case constraint of
                        CEcoValue ->
                            -- Layout-erased: ignore numeric ID (MONO_003). All CEcoValue MVars
                            -- produce the same key fragment so fresh IDs don't split specializations.
                            toComparableMonoTypeHelper
                                rest
                                ("ecovalue" :: "\u{0000}" :: "0" :: "V" :: acc)

                        CNumber ->
                            -- Quiescence-before-defaulting (D4): an OPEN number var is
                            -- a residual that closes to Int (Float always manifests as
                            -- bound MFloat, never open CNumber, at a locally-quiescent
                            -- key point). Key it IDENTICALLY to MInt ("I") so open-number
                            -- and explicit-Int instantiations of a global merge to one
                            -- specialization (they are the same after
                            -- the residual-number close in Prune), while Float ("F") stays distinct
                            -- and the boxed CEcoValue sentinel ("V") stays distinct from
                            -- i64. The MVarId is dropped so fresh ids never split specs.
                            -- Callers apply `refreshConstraints` before keying so a
                            -- number-tainted (Join-R) var reaches this arm.
                            toComparableMonoTypeHelper rest ("I" :: acc)

                MList inner ->
                    toComparableMonoTypeHelper
                        (WorkType inner :: WorkMarker ")" :: rest)
                        ("L(" :: acc)

                MTuple elementTypes ->
                    let
                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) elementTypes
                    in
                    toComparableMonoTypeHelper newWork ("(" :: String.fromInt (List.length elementTypes) :: "T" :: acc)

                MRecord fields ->
                    let
                        newWork =
                            List.foldl
                                (\( name, ty ) w -> WorkMarker name :: WorkType ty :: w)
                                (WorkMarker ")" :: rest)
                                (Dict.toList fields)
                    in
                    toComparableMonoTypeHelper newWork ("R(" :: acc)

                MCustom canonical name args ->
                    let
                        (IO.Canonical ( author, project ) modName) =
                            canonical

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) args
                    in
                    toComparableMonoTypeHelper newWork ("(" :: name :: "\u{0000}" :: modName :: "\u{0000}" :: project :: "\u{0000}" :: author :: "X" :: acc)

                MFunction anno args ret ->
                    let
                        -- LTop must keep today's exact "A(" fragment so that
                        -- all-LTop graphs key byte-identically (M1 gate).
                        annoKey =
                            case anno of
                                LTop ->
                                    "A("

                                LSet members ->
                                    "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

                        newWork =
                            List.foldl (\t w -> WorkType t :: w)
                                (WorkMarker "->" :: WorkType ret :: WorkMarker ")" :: rest)
                                args
                    in
                    toComparableMonoTypeHelper newWork (annoKey :: acc)


{-| Convert a specialization key to a single comparable String for use in dictionaries.

Uses compact encoding to avoid intermediate List allocation.
Parts are separated by \\u{0001}.

-}
toComparableSpecKey : SpecKey -> String
toComparableSpecKey (SpecKey global monoType) =
    String.concat
        [ toComparableGlobal global
        , "\u{0001}"
        , toComparableMonoType monoType
        ]



-- ============================================================================
-- ====== FUNCTION SHAPE HELPERS ======
-- ============================================================================


{-| Check if a MonoType is a function type.
-}
isFunctionType : MonoType -> Bool
isFunctionType monoType =
    case monoType of
        MFunction _ _ _ ->
            True

        _ ->
            False


{-| Count the total number of arguments in a curried function type.
-}
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction _ argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Stage parameter types: outermost MFunction argument list.
-}
stageParamTypes : MonoType -> List MonoType
stageParamTypes monoType =
    case monoType of
        MFunction _ argTypes _ ->
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
        MFunction _ _ result ->
            result

        other ->
            other


{-| Decompose a function type into its flattened arguments and final result.
-}
decomposeFunctionType : MonoType -> ( List MonoType, MonoType )
decomposeFunctionType monoType =
    case monoType of
        MFunction _ argTypes result ->
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


{-| Call lowering strategy, determined by GlobalOpt based on closure kind
analysis and staging solver results. Controls how MLIR codegen lowers the call.

  - CallDirectKnownSegmentation: staging is known, use typed papExtend with
    remaining\_arity and typed closure calling dispatch.
  - CallDirectFlat: flattened external/kernel call, no staged currying.
  - CallGenericApply: closure kind is heterogeneous or unknown, or staging
    slot is dynamic. Use generic-mode eco.papExtend (no remaining\_arity),
    which determines saturation at runtime from the closure header.

-}
type CallKind
    = CallDirectKnownSegmentation
    | CallDirectFlat
    | CallGenericApply
    | CallSegmentationUnknown


{-| Staging / call-site metadata for MonoCall.

  - callModel: FlattenedExternal vs StageCurried
  - stageArities: Full list of stage arities [a1, a2, ...] for the callee.
  - isSingleStageSaturated: True if this call consumes all arguments and
    fits entirely in the first stage.
  - initialRemaining: Stage arity of the current closure value at this call site
    (used as sourceRemaining in applyByStages).
  - remainingStageArities: Stage arities for subsequent stages after saturating
    the current closure (used in applyByStages).
  - evaluatorReturnType: Mono return type of the evaluator func.func invoked
    at this call site (one MFunction peel from the callee's type). Used by
    MLIR codegen to satisfy CGEN\_056: typed saturating papExtends must use
    the evaluator's func.func result type, NOT the caller's
    MonoCall.resultType, which differs from it on over-saturated calls.

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
    , callKind : CallKind
    , evaluatorReturnType : MonoType
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
    , callKind = CallGenericApply
    , evaluatorReturnType = MUnit
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
                MFunction _ stageArgs stageRet ->
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
buildSegmentedFunctionType anno [A,B,C,D] R [2,2] = MFunction anno [A,B] (MFunction anno [C,D] R)
buildSegmentedFunctionType anno [A,B,C,D] R [4] = MFunction anno [A,B,C,D] R

The annotation is stamped on EVERY stage arrow it builds: the stages of one
callable share provenance (PAP results keep the underlying callee's member),
so re-segmenting a type must not lose or invent set facts. Callers derive
`anno` from the original type's head arrow (`headAnno`), joining branch
annotations (`unionAnno`) where several types merge.
-}
buildSegmentedFunctionType : LambdaSetAnno -> List MonoType -> MonoType -> Segmentation -> MonoType
buildSegmentedFunctionType anno flatArgs finalRet seg =
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
        (\stageArgs acc -> MFunction anno stageArgs acc)
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
