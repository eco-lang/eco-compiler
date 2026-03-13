module Compiler.Monomorphize.State exposing
    ( MonoState, SpecAccum, SpecContext, WorkItem(..), Substitution, SchemeInfo, SchemeInfoCache
    , initState
    , LocalInstanceInfo, LocalMultiState
    , ValueInstanceInfo, ValueMultiState
    , VarEnv(..), emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame
    )

{-| State types and utilities for monomorphization.

This module contains the core state threading types used throughout
the monomorphization process.


# Types

@docs MonoState, SpecAccum, SpecContext, WorkItem, Substitution, SchemeInfo, SchemeInfoCache


# Initialization

@docs initState


# Local Specialization

@docs LocalInstanceInfo, LocalMultiState


# Value Specialization

@docs ValueInstanceInfo, ValueMultiState


# Variable Environment

@docs VarEnv, emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Data.Map as DataMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| Precomputed metadata about a polymorphic function's type scheme.
Cached per top-level callee to avoid repeated TLambda traversal and
var collection at every call site.

The pre-renamed variants have all type variables renamed to definition-scoped
names (e.g., `a__def_Module_func_0`) to avoid per-call-site rename work.
-}
type alias SchemeInfo =
    { varNames : List Name
    , constraints : Dict Name Mono.Constraint
    , argTypes : List Can.Type
    , resultType : Can.Type
    , argCount : Int
    , renamedFuncType : Can.Type
    , renamedArgTypes : List Can.Type
    , renamedResultType : Can.Type
    , renamedVarNames : List Name
    , preRenameMap : DataMap.Dict String Name Name
    }


{-| Cache of SchemeInfo per top-level global, keyed by TOpt.toComparableGlobal.
-}
type alias SchemeInfoCache =
    DataMap.Dict (List String) TOpt.Global SchemeInfo


{-| Global accumulator fields that grow monotonically during monomorphization.
Updated by enqueueSpec, processWorklist completion, and scheme cache lookups.
-}
type alias SpecAccum =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet -- SpecIds whose node body references Debug.* kernels
    , specValueUsed : BitSet -- SpecIds whose value is referenced via MonoVarGlobal
    , schemeCache : SchemeInfoCache -- Cached type scheme metadata per global
    }


{-| Traversal context fields that change on scope entry/exit during tree traversal.
Updated by varEnv push/pop, localMulti push/pop, renameEpoch bump, currentGlobal set.
-}
type alias SpecContext =
    { currentModule : IO.Canonical
    , toptNodes : DataMap.Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varEnv : VarEnv -- Layered mapping of variable names to their MonoTypes
    , localMulti : List LocalMultiState
    , valueMulti : List ValueMultiState
    , lambdaCounter : Int
    , renameEpoch : Int -- Monotonically increasing counter for unique __callee names
    }


{-| State maintained during monomorphization, split into accumulator and context
to reduce _Utils_update overhead (each update copies ~9 fields instead of 17).
-}
type alias MonoState =
    { accum : SpecAccum
    , ctx : SpecContext
    }


{-| Work item representing a function specialization to be processed.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    Dict Name Mono.MonoType


{-| Layered environment for variable type lookups. Uses a stack of frames
so that inner scopes (let, lambda, case) can be cheaply pushed/popped
without copying the entire environment.
-}
type VarEnv
    = VarEnv (List (Dict Name Mono.MonoType))


{-| An empty variable environment with a single empty frame.
-}
emptyVarEnv : VarEnv
emptyVarEnv =
    VarEnv [ Dict.empty ]


{-| Look up a variable's type in the environment, searching from innermost to outermost frame.
-}
lookupVar : Name -> VarEnv -> Maybe Mono.MonoType
lookupVar name (VarEnv frames) =
    lookupVarHelp name frames


lookupVarHelp : Name -> List (Dict Name Mono.MonoType) -> Maybe Mono.MonoType
lookupVarHelp name frames =
    case frames of
        [] ->
            Nothing

        frame :: rest ->
            case Dict.get name frame of
                Just t ->
                    Just t

                Nothing ->
                    lookupVarHelp name rest


{-| Insert a variable binding into the current (innermost) frame.
-}
insertVar : Name -> Mono.MonoType -> VarEnv -> VarEnv
insertVar name t (VarEnv frames) =
    case frames of
        [] ->
            VarEnv [ Dict.singleton name t ]

        frame :: rest ->
            VarEnv (Dict.insert name t frame :: rest)


{-| Push a new empty frame onto the environment stack for a nested scope.
-}
pushFrame : VarEnv -> VarEnv
pushFrame (VarEnv frames) =
    VarEnv (Dict.empty :: frames)


{-| Pop the innermost frame from the environment stack.
-}
popFrame : VarEnv -> VarEnv
popFrame (VarEnv frames) =
    case frames of
        [] ->
            VarEnv []

        _ :: rest ->
            VarEnv rest


{-| Information about a single local function instance discovered during
specialization of a particular let-bound function.
-}
type alias LocalInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    }


{-| Per-let state for local multi-specialization.

    - defName  : the let-bound function we're currently multi-specializing
    - instances: all discovered (typeKey -> instance) mappings for this let,
                 keyed by Mono.toComparableMonoType of the instance type.

-}
type alias LocalMultiState =
    { defName : Name
    , instances : Dict (List String) LocalInstanceInfo
    }


{-| Information about a single value-multi instance discovered during
specialization of a let-bound value whose type contains lambdas.
-}
type alias ValueInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    }


{-| Per-let state for value-level multi-specialization.

    - defName    : the let-bound value we're multi-specializing
    - defCanType : the canonical type of the value
    - def        : the original TOpt.Def
    - instances  : all discovered (typeKey -> instance) mappings,
                   keyed by Mono.toComparableMonoType of the instance type.

-}
type alias ValueMultiState =
    { defName : Name
    , defCanType : Can.Type
    , def : TOpt.Def
    , instances : Dict (List String) ValueInstanceInfo
    }


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> DataMap.Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState currentModule toptNodes globalTypeEnv =
    { accum =
        { worklist = []
        , nodes = Dict.empty
        , inProgress = BitSet.empty
        , scheduled = BitSet.empty
        , registry = Registry.emptyRegistry
        , callEdges = Dict.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , schemeCache = DataMap.empty
        }
    , ctx =
        { currentModule = currentModule
        , toptNodes = toptNodes
        , currentGlobal = Nothing
        , globalTypeEnv = globalTypeEnv
        , varEnv = emptyVarEnv
        , localMulti = []
        , valueMulti = []
        , lambdaCounter = 0
        , renameEpoch = 0
        }
    }
