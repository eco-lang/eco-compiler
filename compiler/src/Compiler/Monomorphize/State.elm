module Compiler.Monomorphize.State exposing
    ( MonoState, WorkItem(..), Substitution
    , initState
    , LocalInstanceInfo, LocalMultiState
    , VarEnv(..), emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame
    )

{-| State types and utilities for monomorphization.

This module contains the core state threading types used throughout
the monomorphization process.


# Types

@docs MonoState, WorkItem, Substitution


# Initialization

@docs initState


# Local Specialization

@docs LocalInstanceInfo, LocalMultiState


# Variable Environment

@docs VarEnv, emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Data.Map as DataMap
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : DataMap.Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varEnv : VarEnv -- Layered mapping of variable names to their MonoTypes
    , localMulti : List LocalMultiState
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet -- SpecIds whose node body references Debug.* kernels
    , specValueUsed : BitSet -- SpecIds whose value is referenced via MonoVarGlobal
    , renameEpoch : Int -- Monotonically increasing counter for unique __callee names
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


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> DataMap.Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState currentModule toptNodes globalTypeEnv =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = BitSet.empty
    , scheduled = BitSet.empty
    , registry = Registry.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    , globalTypeEnv = globalTypeEnv
    , varEnv = emptyVarEnv
    , localMulti = []
    , callEdges = Dict.empty
    , specHasEffects = BitSet.empty
    , specValueUsed = BitSet.empty
    , renameEpoch = 0
    }
