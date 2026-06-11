module Compiler.Monomorphize.State exposing
    ( MonoState, SpecAccum, SpecContext, WorkItem(..), Substitution, SchemeInfo, SchemeInfoCache
    , initState
    , LocalInstanceInfo, LocalMultiState
    , ValueInstanceInfo, ValueMultiState
    , VarEnv(..), emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame, varEnvKeys
    , MVarEnv, initMVarEnv, freshMVar, isNumberVar
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

@docs VarEnv, emptyVarEnv, insertVar, lookupVar, popFrame, pushFrame, varEnvKeys


# Monomorphization Variable Environment

@docs MVarEnv, initMVarEnv, freshMVar, isNumberVar

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds exposing (MVarId)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Data.Map as DataMap
import Dict exposing (Dict)
import Set
import System.TypeCheck.IO as IO


{-| Precomputed metadata about a polymorphic function's type scheme.
Cached per top-level callee to avoid repeated TLambda traversal and
var collection at every call site.
-}
type alias SchemeInfo =
    { varIds : List MVarId
    , numberVarKeys : Set.Set Int
    , argTypes : List (Can.Type MVarId)
    , resultType : Can.Type MVarId
    , argCount : Int
    , schemeType : Can.Type MVarId
    }


{-| Cache of SchemeInfo per top-level global, keyed by TOpt.toComparableGlobal.
-}
type alias SchemeInfoCache =
    DataMap.Dict String TOpt.Global SchemeInfo


{-| Environment for tracking MVarIds during monomorphization.
Uses a sequential allocator with a sparse set of CNumber-constrained vars.
All MVarIds are globally unique sequential Ints from a single supplier.
-}
type alias MVarEnv =
    { nextId : MVarId
    , numberVars : Set.Set Int -- MVarIds with CNumber constraint
    }


{-| Create an MVarEnv from an initial state (produced by AssignMVarIds).
-}
initMVarEnv : MVarId -> Set.Set Int -> MVarEnv
initMVarEnv nextId numberVars =
    { nextId = nextId
    , numberVars = numberVars
    }


{-| Allocate a fresh MVarId with the given constraint.
Returns the new id and updated environment.
-}
freshMVar : Mono.Constraint -> MVarEnv -> ( MVarId, MVarEnv )
freshMVar constraint env =
    let
        currentId =
            env.nextId

        newNumberVars =
            case constraint of
                Mono.CNumber ->
                    Set.insert (Id.toComparable currentId) env.numberVars

                Mono.CEcoValue ->
                    env.numberVars
    in
    ( currentId
    , { nextId = Id.succ currentId
      , numberVars = newNumberVars
      }
    )


{-| Check whether an MVarId has the CNumber constraint.
-}
isNumberVar : MVarId -> MVarEnv -> Bool
isNumberVar mvarId env =
    Set.member (Id.toComparable mvarId) env.numberVars


{-| Global accumulator fields that grow monotonically during monomorphization.
Updated by enqueueSpec, processWorklist completion, and scheme cache lookups.
-}
type alias SpecAccum =
    { worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , schemeCache : SchemeInfoCache -- Cached type scheme metadata per global
    , ports : List Mono.PortRegistration -- Ports reached during specialization (PORT_003)
    }


{-| Traversal context fields that change on scope entry/exit during tree traversal.
Updated by varEnv push/pop, localMulti push/pop, currentGlobal set.
-}
type alias SpecContext =
    { currentModule : IO.Canonical
    , toptNodes : DataMap.Dict String TOpt.Global (TOpt.Node MVarId)
    , currentGlobal : Maybe Mono.Global
    , currentFreeVars : Can.FreeVars
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , annotations : TOpt.AnnotationsByGlobal MVarId
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    , valueMulti : List ValueMultiState
    , lambdaCounter : Int
    , mvarEnv : MVarEnv
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


{-| Substitution mapping MVarIds (as Int keys) to their concrete monomorphic types.
-}
type alias Substitution =
    Dict Int Mono.MonoType


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


{-| Get all variable names in the environment (for debugging).
-}
varEnvKeys : VarEnv -> List Name
varEnvKeys (VarEnv frames) =
    List.concatMap Dict.keys frames


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
    , instances : Dict String LocalInstanceInfo
    }


{-| Information about a single value-multi instance discovered during
specialization of a let-bound value whose type contains lambdas.

    - freshName              : the generated name for the specialized def
    - monoType               : the root container MonoType used as the instance key
    - subst                  : accumulated substitution; refined by destructor
                               call-site unification so emit-time specialization
                               sees concrete field/lambda types
    - derivedDestructorNames : set of local names introduced by destructors
                               over this instance (e.g. `getter`/`setter`).
                               Used at call sites to thread call-site
                               refinements back into `subst`.

-}
type alias ValueInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    , derivedDestructorNames : Set.Set Name
    }


{-| Per-let state for value-level multi-specialization.

    - defName    : the let-bound value we're multi-specializing
    - defCanType : the canonical type of the value
    - def        : the original TOpt.Def MVarId
    - instances  : all discovered (typeKey -> instance) mappings,
                   keyed by Mono.toComparableMonoType of the instance type.

-}
type alias ValueMultiState =
    { defName : Name
    , defCanType : Can.Type MVarId
    , def : TOpt.Def MVarId
    , instances : Dict String ValueInstanceInfo
    }


{-| Initialize the monomorphization state.
-}
initState : IO.Canonical -> DataMap.Dict String TOpt.Global (TOpt.Node MVarId) -> TOpt.AnnotationsByGlobal MVarId -> TypeEnv.GlobalTypeEnv -> MVarEnv -> MonoState
initState currentModule toptNodes annotations globalTypeEnv mvarEnv =
    { accum =
        { worklist = []
        , nodes = Array.empty
        , inProgress = BitSet.empty
        , scheduled = BitSet.empty
        , registry = Registry.emptyRegistry
        , schemeCache = DataMap.empty
        , ports = []
        }
    , ctx =
        { currentModule = currentModule
        , toptNodes = toptNodes
        , currentGlobal = Nothing
        , currentFreeVars = Dict.empty
        , globalTypeEnv = globalTypeEnv
        , annotations = annotations
        , varEnv = emptyVarEnv
        , localMulti = []
        , valueMulti = []
        , lambdaCounter = 0
        , mvarEnv = mvarEnv
        }
    }
