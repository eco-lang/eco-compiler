module Compiler.Type.SolverSnapshot exposing
    ( SolverSnapshot
    , SolverState
    , TypeVar
    , fromSolveResult
    , exprVarFromId
    , lookupDescriptor
    , resolveVariable
    , withLocalUnification
    , LocalView
    )

{-| Snapshot of solver union-find state for post-inference queries.

This module captures the HM solver's union-find state (descriptors, point info,
weights) after constraint solving completes, enabling type queries outside the
IO monad. It is used by the MonoDirect monomorphizer.

@docs SolverSnapshot, SolverState, TypeVar
@docs fromSolveResult, exprVarFromId, lookupDescriptor, resolveVariable
@docs withLocalUnification, LocalView

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Type.Type as Type
import Compiler.Type.Unify as Unify
import Dict
import System.TypeCheck.IO as IO exposing (Descriptor(..), PointInfo(..), Variable)


{-| A type variable from the solver's union-find.
-}
type alias TypeVar =
    IO.Variable


{-| Snapshot of the solver's mutable arrays at the time of capture.
-}
type alias SolverState =
    { descriptors : Array IO.Descriptor
    , pointInfo : Array IO.PointInfo
    , weights : Array Int
    }


{-| Complete snapshot: solver state + mapping from expression IDs to solver vars.
-}
type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    }


{-| Build a snapshot from the result of `Solve.runWithIds`.
-}
fromSolveResult : { a | nodeVars : Array (Maybe TypeVar), solverState : SolverState } -> SolverSnapshot
fromSolveResult result =
    { state = result.solverState
    , nodeVars = result.nodeVars
    }


{-| Look up the solver variable for a given expression ID.
Returns Nothing if the ID is out of range or no variable was assigned.
-}
exprVarFromId : SolverSnapshot -> Int -> Maybe TypeVar
exprVarFromId snap id =
    Array.get id snap.nodeVars |> Maybe.andThen identity


{-| Follow union-find parent links to find the root representative variable.
-}
resolveVariable : SolverSnapshot -> TypeVar -> TypeVar
resolveVariable snap var =
    resolveVariableHelp snap.state.pointInfo var


resolveVariableHelp : Array IO.PointInfo -> TypeVar -> TypeVar
resolveVariableHelp pointInfo var =
    case var of
        IO.Pt idx ->
            case Array.get idx pointInfo of
                Just (IO.Link parent) ->
                    resolveVariableHelp pointInfo parent

                _ ->
                    -- Info or out of bounds: this is the root
                    var


{-| Look up the descriptor for a variable (after resolving to root).
-}
lookupDescriptor : SolverSnapshot -> TypeVar -> Maybe IO.Descriptor
lookupDescriptor snap var =
    let
        (IO.Pt rootIdx) =
            resolveVariable snap var
    in
    Array.get rootIdx snap.state.descriptors


{-| View into solver state after local unification for type queries.
-}
type alias LocalView =
    { typeOf : TypeVar -> Can.Type
    , monoTypeOf : TypeVar -> Mono.MonoType
    }


{-| Perform local unification and provide a view for type queries.

1. Copies solver state arrays (O(1) structural sharing in Elm)
2. For each root var: if rigid, relaxes to flex
3. Runs unify on each (v1, v2) pair
4. Builds LocalView with typeOf and monoTypeOf
5. Calls callback with LocalView, discards local state

-}
withLocalUnification :
    SolverSnapshot
    -> List TypeVar
    -> List ( TypeVar, TypeVar )
    -> (LocalView -> a)
    -> a
withLocalUnification snap rootsToRelax equalities callback =
    let
        -- Build a local IO.State from the snapshot
        localState : IO.State
        localState =
            { ioRefsWeight = snap.state.weights
            , ioRefsPointInfo = snap.state.pointInfo
            , ioRefsDescriptor = snap.state.descriptors
            , ioRefsMVector = Array.empty
            }

        -- Step 1: Relax rigid vars to flex
        stateAfterRelax =
            List.foldl relaxRigidVar localState rootsToRelax

        -- Step 2: Unify each pair
        unifyPair ( v1, v2 ) st =
            let
                ( st2, _ ) =
                    Unify.unify v1 v2 st
            in
            st2

        stateAfterUnify =
            List.foldl unifyPair stateAfterRelax equalities

        -- Step 3: Build LocalView
        -- typeOf uses variableToCanType via the IO monad with our local state
        typeOfVar : TypeVar -> Can.Type
        typeOfVar var =
            let
                ( _, result ) =
                    Type.toCanTypeBatch (Array.fromList [ Just var ]) stateAfterUnify
            in
            case Array.get 0 result of
                Just (Just t) ->
                    t

                _ ->
                    -- Fallback: shouldn't happen for valid vars
                    Can.TUnit

        monoTypeOfVar : TypeVar -> Mono.MonoType
        monoTypeOfVar var =
            TypeSubst.canTypeToMonoType Dict.empty (typeOfVar var)

        view =
            { typeOf = typeOfVar
            , monoTypeOf = monoTypeOfVar
            }
    in
    callback view


{-| Relax a rigid variable to flex in the local state.
-}
relaxRigidVar : TypeVar -> IO.State -> IO.State
relaxRigidVar var st =
    let
        (IO.Pt rootIdx) =
            resolveVariableHelp st.ioRefsPointInfo var
    in
    case Array.get rootIdx st.ioRefsDescriptor of
        Just (IO.Descriptor props) ->
            let
                newContent =
                    case props.content of
                        IO.RigidVar name ->
                            IO.FlexVar (Just name)

                        IO.RigidSuper super name ->
                            IO.FlexSuper super (Just name)

                        other ->
                            other

                newDescriptor =
                    IO.Descriptor { props | content = newContent }
            in
            { st | ioRefsDescriptor = Array.set rootIdx newDescriptor st.ioRefsDescriptor }

        Nothing ->
            st
