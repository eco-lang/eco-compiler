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
    , toComparableGlobal, toComparableLambdaId
      -- Staging/Segmentation helpers
    , Segmentation
    , segmentLengths
    , stageParamTypes
    , stageReturnType
    , stageArity
    , chooseCanonicalSegmentation
    , buildSegmentedFunctionType
    , decomposeFunctionType
      -- Call staging metadata
    , CallModel(..), CallInfo, defaultCallInfo
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

@docs toComparableGlobal, toComparableLambdaId

-}

import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DT
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation exposing (Region)
import Data.Map as Dict exposing (Dict)
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
    | MRecord (Dict String Name MonoType) -- Field name -> type (layout computed at codegen)
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


{-| Update the MonoType stored in reverseMapping for a given SpecId.

This is called after specializeNode to ensure the registry stores the actual
node type rather than the requested type. This is necessary because the actual
type may differ (e.g., flattened MFunction vs nested MFunction) due to
closure transformations.

-}
updateRegistryType : SpecId -> MonoType -> SpecializationRegistry -> SpecializationRegistry
updateRegistryType specId actualType registry =
    case Dict.get identity specId registry.reverseMapping of
        Nothing ->
            registry

        Just ( global, _, maybeLambda ) ->
            { registry
                | reverseMapping =
                    Dict.insert identity specId ( global, actualType, maybeLambda ) registry.reverseMapping
            }


{-| Look up the specialization information for a given SpecId.
-}
lookupSpecKey : SpecId -> SpecializationRegistry -> Maybe ( Global, MonoType, Maybe LambdaId )
lookupSpecKey specId registry =
    Dict.get identity specId registry.reverseMapping



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
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , ctorShapes : Dict (List String) (List String) (List CtorShape)
        , returnedClosureParamCounts : Dict Int SpecId (Maybe Int)
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
                            Dict.toList compare fields

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


{-| Count the arity of a function type (number of arrow levels).
-}
functionArity : MonoType -> Int
functionArity monoType =
    case monoType of
        MFunction _ result ->
            1 + functionArity result

        _ ->
            0


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


{-| Stage arity: number of arguments expected in the current stage.
-}
stageArity : MonoType -> Int
stageArity monoType =
    List.length (stageParamTypes monoType)


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

-}
type alias CallInfo =
    { callModel : CallModel
    , stageArities : List Int
    , isSingleStageSaturated : Bool
    , initialRemaining : Int
    , remainingStageArities : List Int
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
                countSegmentations : List MonoType -> Dict (List Int) (List Int) Int
                countSegmentations types =
                    List.foldl
                        (\t accDict ->
                            let
                                seg =
                                    segmentLengths t

                                current =
                                    Dict.get identity seg accDict |> Maybe.withDefault 0
                            in
                            Dict.insert identity seg (current + 1) accDict
                        )
                        Dict.empty
                        types

                freqDict =
                    countSegmentations leafTypes

                -- Find maximum count
                maxCount =
                    Dict.foldl compare (\_ count acc -> max count acc) 0 freqDict

                -- All segmentations that hit maxCount
                bestSegs =
                    Dict.foldl compare
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
