module Compiler.MonoDirect.State exposing
    ( MonoDirectState
    , WorkItem(..)
    , VarEnv(..)
    , initState
    , emptyVarEnv
    , insertVar
    , lookupVar
    , pushFrame
    , popFrame
    , LocalMultiState
    , LocalInstanceInfo
    , isLocalMultiTarget
    , getOrCreateLocalInstance
    )

{-| State for solver-directed monomorphization.

Uses a flat record instead of the accum/ctx split of `Monomorphize.State.MonoState`.


# Types

@docs MonoDirectState, WorkItem


# Initialization

@docs initState


# Variable Environment

@docs VarEnv, emptyVarEnv, insertVar, lookupVar, pushFrame, popFrame


# Local Multi-Specialization

@docs LocalMultiState, LocalInstanceInfo

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Data.Map as DataMap
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverSnapshot)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| A unit of work for the monomorphization worklist.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| The full mutable state for solver-directed monomorphization.
-}
type alias MonoDirectState =
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
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    , renameEpoch : Int
    , snapshot : SolverSnapshot
    }


{-| Create an initial MonoDirectState from module info, nodes, type env, and solver snapshot.
-}
initState :
    IO.Canonical
    -> DataMap.Dict (List String) TOpt.Global TOpt.Node
    -> TypeEnv.GlobalTypeEnv
    -> SolverSnapshot
    -> MonoDirectState
initState currentModule toptNodes globalTypeEnv snapshot =
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
    , snapshot = snapshot
    }



-- ========== VARIABLE ENVIRONMENT ==========


{-| A stack of variable-to-MonoType frames for lexical scoping during specialization.
-}
type VarEnv
    = VarEnv (List (Dict Name Mono.MonoType))


{-| An empty variable environment with a single empty frame.
-}
emptyVarEnv : VarEnv
emptyVarEnv =
    VarEnv [ Dict.empty ]


{-| Push a new empty frame onto the variable environment.
-}
pushFrame : VarEnv -> VarEnv
pushFrame (VarEnv frames) =
    VarEnv (Dict.empty :: frames)


{-| Pop the top frame from the variable environment.
-}
popFrame : VarEnv -> VarEnv
popFrame (VarEnv frames) =
    case frames of
        _ :: rest ->
            VarEnv rest

        [] ->
            VarEnv []


{-| Insert a variable binding into the top frame of the environment.
-}
insertVar : Name -> Mono.MonoType -> VarEnv -> VarEnv
insertVar name monoType (VarEnv frames) =
    case frames of
        top :: rest ->
            VarEnv (Dict.insert name monoType top :: rest)

        [] ->
            VarEnv [ Dict.singleton name monoType ]


{-| Look up a variable in the environment, searching from top frame down.
-}
lookupVar : Name -> VarEnv -> Maybe Mono.MonoType
lookupVar name (VarEnv frames) =
    lookupVarHelp name frames


lookupVarHelp : Name -> List (Dict Name Mono.MonoType) -> Maybe Mono.MonoType
lookupVarHelp name frames =
    case frames of
        [] ->
            Nothing

        top :: rest ->
            case Dict.get name top of
                Just t ->
                    Just t

                Nothing ->
                    lookupVarHelp name rest



-- ========== LOCAL MULTI-SPECIALIZATION ==========


{-| State for tracking multi-specializations of a local let-binding.
-}
type alias LocalMultiState =
    { defName : Name
    , instances : Dict (List String) LocalInstanceInfo
    }


{-| Information about a single local instance: fresh name and mono type.
-}
type alias LocalInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    }


{-| Check if a name is a local multi-specialization target.
-}
isLocalMultiTarget : Name -> MonoDirectState -> Bool
isLocalMultiTarget name state =
    List.any (\ls -> ls.defName == name) state.localMulti


{-| Get or create a local instance for the given def name and mono type.
Returns the fresh name to use at the call site.
-}
getOrCreateLocalInstance :
    Name -> Mono.MonoType -> MonoDirectState -> ( Name, MonoDirectState )
getOrCreateLocalInstance defName funcMonoType state =
    let
        key =
            Mono.toComparableMonoType funcMonoType

        ( updatedStack, freshName ) =
            updateLocalMultiStack defName key funcMonoType state.localMulti
    in
    ( freshName, { state | localMulti = updatedStack } )


updateLocalMultiStack :
    Name -> List String -> Mono.MonoType -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName key funcMonoType stack =
    case stack of
        [] ->
            -- Not found: this shouldn't happen if isLocalMultiTarget was checked first
            ( stack, defName )

        entry :: rest ->
            if entry.defName == defName then
                case Dict.get key entry.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Dict.size entry.instances

                            freshName =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName, monoType = funcMonoType }

                            newEntry =
                                { entry | instances = Dict.insert key newInfo entry.instances }
                        in
                        ( newEntry :: rest, freshName )

            else
                let
                    ( updatedRest, freshName ) =
                        updateLocalMultiStack defName key funcMonoType rest
                in
                ( entry :: updatedRest, freshName )
