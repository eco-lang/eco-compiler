module Compiler.Monomorphize.State exposing
    ( MonoState, WorkItem(..), Substitution, VarTypes
    , initState
    , LocalInstanceInfo, LocalMultiState
    )

{-| State types and utilities for monomorphization.

This module contains the core state threading types used throughout
the monomorphization process.


# Types

@docs MonoState, WorkItem, Substitution, VarTypes


# Initialization

@docs initState


# Local Specialization

@docs LocalInstanceInfo, LocalMultiState

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO


{-| State maintained during monomorphization, tracking work to be done and completed specializations.
-}
type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict Int Int Mono.MonoNode
    , inProgress : EverySet Int Int
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varTypes : VarTypes -- Mapping of variable names to their MonoTypes
    , localMulti : List LocalMultiState
    }


{-| Work item representing a function specialization to be processed.
-}
type WorkItem
    = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)


{-| Substitution mapping type variable names to their concrete monomorphic types.
-}
type alias Substitution =
    Dict String Name Mono.MonoType


{-| Mapping of variable names to their MonoTypes, used during specialization.
-}
type alias VarTypes =
    Dict String Name Mono.MonoType


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
    , instances : Dict (List String) (List String) LocalInstanceInfo
    }


{-| Initialize the monomorphization state with empty worklist and registry.
-}
initState : IO.Canonical -> Dict (List String) TOpt.Global TOpt.Node -> TypeEnv.GlobalTypeEnv -> MonoState
initState currentModule toptNodes globalTypeEnv =
    { worklist = []
    , nodes = Dict.empty
    , inProgress = EverySet.empty
    , registry = Registry.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    , globalTypeEnv = globalTypeEnv
    , varTypes = Dict.empty
    , localMulti = []
    }
