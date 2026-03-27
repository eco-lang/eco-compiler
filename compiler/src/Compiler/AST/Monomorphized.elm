module Compiler.AST.Monomorphized exposing
    ( MonoType(..), Literal(..), Constraint(..)
    , LambdaId(..)
    , Global(..), SpecKey(..), SpecId, SpecializationRegistry
    , MonoGraph(..), MainInfo(..), MonoNode(..), CtorShape, nodeType
    , MonoExpr(..), ClosureInfo, MonoDef(..), MonoDestructor(..), MonoPath(..)
    , MonoDtPath(..), dtPathType
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
    , CallModel(..), CallKind(..), CallInfo, defaultCallInfo
    , ClosureKindId(..), ClosureKind(..), MaybeClosureKind
    , CaptureABI
    , containsAnyMVar, containsCEcoMVar, resultTypeOf
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


# Decision Tree Paths

@docs MonoDtPath, dtPathType


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

@docs CallModel, CallKind, CallInfo, defaultCallInfo


# Typed Closure Calling (ABI Cloning)

@docs ClosureKindId, ClosureKind, MaybeClosureKind
@docs CaptureABI


# Misc Helpers

@docs containsAnyMVar, containsCEcoMVar, resultTypeOf

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as DT
import Compiler.Data.BitSet exposing (BitSet)
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
    if containsAnyMVar monoType then
        forceCNumberToIntHelp monoType

    else
        monoType


forceCNumberToIntHelp : MonoType -> MonoType
forceCNumberToIntHelp monoType =
    case monoType of
        MVar _ CNumber ->
            MInt

        MVar _ CEcoValue ->
            monoType

        MList elemType ->
            MList (forceCNumberToIntHelp elemType)

        MFunction args result ->
            MFunction
                (List.map forceCNumberToIntHelp args)
                (forceCNumberToIntHelp result)

        MTuple elems ->
            MTuple (List.map forceCNumberToIntHelp elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> forceCNumberToIntHelp t) fields)

        MCustom can name args ->
            MCustom can name (List.map forceCNumberToIntHelp args)

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


{-| Check whether a MonoType contains any `MVar _ CEcoValue`.
-}
containsCEcoMVar : MonoType -> Bool
containsCEcoMVar monoType =
    case monoType of
        MVar _ CEcoValue ->
            True

        MVar _ _ ->
            False

        MList t ->
            containsCEcoMVar t

        MFunction args result ->
            containsCEcoMVarList args || containsCEcoMVar result

        MTuple elems ->
            containsCEcoMVarList elems

        MRecord fields ->
            Dict.foldl (\_ t acc -> acc || containsCEcoMVar t) False fields

        MCustom _ _ args ->
            containsCEcoMVarList args

        _ ->
            False


containsCEcoMVarList : List MonoType -> Bool
containsCEcoMVarList types =
    case types of
        [] ->
            False

        t :: rest ->
            containsCEcoMVar t || containsCEcoMVarList rest


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
    , mapping : Dict String SpecId
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
        , ctorShapes : Dict String (List CtorShape)
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
            "G" ++ author ++ "\u{0000}" ++ project ++ "\u{0000}" ++ modName ++ "\u{0000}" ++ name

        Accessor fieldName ->
            "A" ++ fieldName


{-| Convert a monomorphic type to a comparable String key for use in dictionaries.
Builds the String directly to avoid intermediate List allocation and GC pressure.
-}
toComparableMonoType : MonoType -> String
toComparableMonoType monoType =
    toComparableMonoTypeHelper [ WorkType monoType ] ""


{-| Work item for the tail-recursive type comparison helper.
-}
type WorkItem
    = WorkType MonoType
    | WorkMarker String


{-| Tail-recursive helper using explicit work stack, accumulating a String directly.

The work list contains either MonoTypes to process or string markers.
We process each item, appending to the string accumulator and pushing
any nested types onto the work stack for later processing.

-}
toComparableMonoTypeHelper : List WorkItem -> String -> String
toComparableMonoTypeHelper work acc =
    case work of
        [] ->
            acc

        (WorkMarker s) :: rest ->
            toComparableMonoTypeHelper rest (acc ++ s)

        (WorkType mt) :: rest ->
            case mt of
                MInt ->
                    toComparableMonoTypeHelper rest (acc ++ "I")

                MFloat ->
                    toComparableMonoTypeHelper rest (acc ++ "F")

                MBool ->
                    toComparableMonoTypeHelper rest (acc ++ "B")

                MChar ->
                    toComparableMonoTypeHelper rest (acc ++ "C")

                MString ->
                    toComparableMonoTypeHelper rest (acc ++ "S")

                MUnit ->
                    toComparableMonoTypeHelper rest (acc ++ "U")

                MVar name constraint ->
                    toComparableMonoTypeHelper rest (acc ++ "V" ++ name ++ "\u{0000}" ++ constraintToString constraint)

                MList inner ->
                    toComparableMonoTypeHelper
                        (WorkType inner :: WorkMarker ")" :: rest)
                        (acc ++ "L(")

                MTuple elementTypes ->
                    let
                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) elementTypes
                    in
                    toComparableMonoTypeHelper newWork (acc ++ "T" ++ String.fromInt (List.length elementTypes) ++ "(")

                MRecord fields ->
                    let
                        newWork =
                            List.foldl
                                (\( name, ty ) w -> WorkMarker name :: WorkType ty :: w)
                                (WorkMarker ")" :: rest)
                                (Dict.toList fields)
                    in
                    toComparableMonoTypeHelper newWork (acc ++ "R(")

                MCustom canonical name args ->
                    let
                        (IO.Canonical ( author, project ) modName) =
                            canonical

                        newWork =
                            List.foldl (\t w -> WorkType t :: w) (WorkMarker ")" :: rest) args
                    in
                    toComparableMonoTypeHelper newWork (acc ++ "X" ++ author ++ "\u{0000}" ++ project ++ "\u{0000}" ++ modName ++ "\u{0000}" ++ name ++ "(")

                MFunction args ret ->
                    let
                        newWork =
                            List.foldl (\t w -> WorkType t :: w)
                                (WorkMarker "->" :: WorkType ret :: WorkMarker ")" :: rest)
                                args
                    in
                    toComparableMonoTypeHelper newWork (acc ++ "A(")


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
toComparableLambdaId : LambdaId -> String
toComparableLambdaId lambdaId =
    case lambdaId of
        AnonymousLambda canonical uid ->
            let
                (IO.Canonical ( author, project ) modName) =
                    canonical
            in
            author ++ "\u{0000}" ++ project ++ "\u{0000}" ++ modName ++ "\u{0000}" ++ String.fromInt uid


{-| Convert a specialization key to a single comparable String for use in dictionaries.

Uses compact encoding to avoid intermediate List allocation.
Parts are separated by \\u{0001}.

-}
toComparableSpecKey : SpecKey -> String
toComparableSpecKey (SpecKey global monoType maybeLambda) =
    toComparableGlobal global
        ++ "\u{0001}"
        ++ toComparableMonoType monoType
        ++ "\u{0001}"
        ++ (case maybeLambda of
                Nothing ->
                    "N"

                Just lambdaId ->
                    "L" ++ toComparableLambdaId lambdaId
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
    , callKind : CallKind
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
