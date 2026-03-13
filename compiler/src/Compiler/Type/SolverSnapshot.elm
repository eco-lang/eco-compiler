module Compiler.Type.SolverSnapshot exposing
    ( SolverSnapshot
    , SolverState
    , TypeVar
    , fromSolveResult
    , exprVarFromId
    , lookupDescriptor
    , resolveVariable
    , withLocalUnification
    , specializeFunction
    , LocalView
    )

{-| Snapshot of solver union-find state for post-inference queries.

This module captures the HM solver's union-find state (descriptors, point info,
weights) after constraint solving completes, enabling type queries outside the
IO monad. It is used by the MonoDirect monomorphizer.

@docs SolverSnapshot, SolverState, TypeVar
@docs fromSolveResult, exprVarFromId, lookupDescriptor, resolveVariable
@docs withLocalUnification, specializeFunction, LocalView

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Type.Type as Type
import Compiler.Type.Unify as Unify
import Data.Map as DMap
import Dict exposing (Dict)
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
    , annotationVars : DMap.Dict String Name.Name TypeVar
    }


{-| Build a snapshot from the result of `Solve.runWithIds`.
-}
fromSolveResult : { a | nodeVars : Array (Maybe TypeVar), solverState : SolverState, annotationVars : DMap.Dict String Name.Name TypeVar } -> SolverSnapshot
fromSolveResult result =
    { state = result.solverState
    , nodeVars = result.nodeVars
    , annotationVars = result.annotationVars
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


{-| Resolve a variable in a local IO.State (using its pointInfo array).
-}
resolveInState : IO.State -> TypeVar -> TypeVar
resolveInState st var =
    resolveVariableHelp st.ioRefsPointInfo var


{-| Look up the descriptor for a variable (after resolving to root).
-}
lookupDescriptor : SolverSnapshot -> TypeVar -> Maybe IO.Descriptor
lookupDescriptor snap var =
    let
        (IO.Pt rootIdx) =
            resolveVariable snap var
    in
    Array.get rootIdx snap.state.descriptors


{-| Look up the descriptor for a variable in a local IO.State.
-}
lookupDescriptorInState : IO.State -> TypeVar -> Maybe IO.Descriptor
lookupDescriptorInState st var =
    let
        (IO.Pt rootIdx) =
            resolveInState st var
    in
    Array.get rootIdx st.ioRefsDescriptor


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
        localState =
            snapshotToIoState snap.state

        stateAfterRelax =
            List.foldl relaxRigidVar localState rootsToRelax

        unifyPair ( v1, v2 ) st =
            let
                ( st2, _ ) =
                    Unify.unify v1 v2 st
            in
            st2

        stateAfterUnify =
            List.foldl unifyPair stateAfterRelax equalities

        stateAfterDefault =
            defaultNumericVarsToInt stateAfterUnify

        view =
            buildLocalView stateAfterDefault
    in
    callback view


{-| Specialize a function by walking its type structure against a requested
MonoType. Creates a local solver state copy, walks + unifies, defaults
numerics, and provides a LocalView for type queries on the body.
-}
specializeFunction :
    SolverSnapshot
    -> TypeVar
    -> Mono.MonoType
    -> (LocalView -> a)
    -> a
specializeFunction snap funcTvar requestedMonoType callback =
    let
        localState =
            snapshotToIoState snap.state

        stateAfterWalk =
            walkAndUnify localState funcTvar requestedMonoType

        stateAfterDefault =
            defaultNumericVarsToInt stateAfterWalk

        view =
            buildLocalView stateAfterDefault
    in
    callback view



-- ====== INTERNAL HELPERS ======


snapshotToIoState : SolverState -> IO.State
snapshotToIoState ss =
    { ioRefsWeight = ss.weights
    , ioRefsPointInfo = ss.pointInfo
    , ioRefsDescriptor = ss.descriptors
    , ioRefsMVector = Array.empty
    }


buildLocalView : IO.State -> LocalView
buildLocalView st =
    let
        typeOfVar : TypeVar -> Can.Type
        typeOfVar var =
            let
                ( _, result ) =
                    Type.toCanTypeBatch (Array.fromList [ Just var ]) st
            in
            case Array.get 0 result of
                Just (Just t) ->
                    t

                _ ->
                    Can.TUnit

        monoTypeOfVar : TypeVar -> Mono.MonoType
        monoTypeOfVar var =
            TypeSubst.canTypeToMonoType Dict.empty (typeOfVar var)
    in
    { typeOf = typeOfVar
    , monoTypeOf = monoTypeOfVar
    }


{-| Default unconstrained FlexSuper Number vars to Int in a local IO.State.
Must run AFTER walkAndUnify but BEFORE building LocalView.
-}
defaultNumericVarsToInt : IO.State -> IO.State
defaultNumericVarsToInt st =
    { st
        | ioRefsDescriptor =
            Array.map
                (\desc ->
                    case desc of
                        IO.Descriptor props ->
                            case props.content of
                                IO.FlexSuper IO.Number _ ->
                                    IO.Descriptor
                                        { props
                                            | content =
                                                IO.Structure
                                                    (IO.App1 elmCoreBasics "Int" [])
                                        }

                                _ ->
                                    desc
                )
                st.ioRefsDescriptor
    }


elmCoreBasics : IO.Canonical
elmCoreBasics =
    IO.Canonical ( "elm", "core" ) "Basics"


elmCoreChar : IO.Canonical
elmCoreChar =
    IO.Canonical ( "elm", "core" ) "Char"


elmCoreString : IO.Canonical
elmCoreString =
    IO.Canonical ( "elm", "core" ) "String"


elmCoreList : IO.Canonical
elmCoreList =
    IO.Canonical ( "elm", "core" ) "List"



-- ====== WALK AND UNIFY ======


{-| Walk a solver variable's type structure in parallel with a MonoType,
unifying rigid/flex vars with concrete types created from the MonoType.
Returns the updated local IO.State.
-}
walkAndUnify : IO.State -> TypeVar -> Mono.MonoType -> IO.State
walkAndUnify st var monoType =
    let
        root =
            resolveInState st var
    in
    case lookupDescriptorInState st root of
        Just (IO.Descriptor props) ->
            case props.content of
                IO.RigidVar _ ->
                    unifyVarWithMono (relaxRigidVar root st) root monoType

                IO.RigidSuper _ _ ->
                    unifyVarWithMono (relaxRigidVar root st) root monoType

                IO.FlexVar _ ->
                    unifyVarWithMono st root monoType

                IO.FlexSuper _ _ ->
                    unifyVarWithMono st root monoType

                IO.Structure flatType ->
                    walkStructure st root flatType monoType

                IO.Alias _ _ _ innerVar ->
                    walkAndUnify st innerVar monoType

                IO.Error ->
                    st

        Nothing ->
            st


{-| Unify a solver variable with a fresh variable created from a MonoType.
-}
unifyVarWithMono : IO.State -> TypeVar -> Mono.MonoType -> IO.State
unifyVarWithMono st var monoType =
    let
        ( concreteVar, st1 ) =
            monoTypeToVar monoType st

        ( st2, _ ) =
            Unify.unify var concreteVar st1
    in
    st2


{-| Walk a structural type in parallel with a MonoType.
-}
walkStructure : IO.State -> TypeVar -> IO.FlatType -> Mono.MonoType -> IO.State
walkStructure st root flatType monoType =
    case ( flatType, monoType ) of
        ( IO.Fun1 argVar resVar, Mono.MFunction argMonos resMono ) ->
            case argMonos of
                [ argMono ] ->
                    st
                        |> (\s -> walkAndUnify s argVar argMono)
                        |> (\s -> walkAndUnify s resVar resMono)

                a :: rest ->
                    st
                        |> (\s -> walkAndUnify s argVar a)
                        |> (\s -> walkAndUnify s resVar (Mono.MFunction rest resMono))

                [] ->
                    walkAndUnify st resVar resMono

        ( IO.App1 _ _ childVars, Mono.MList elemMono ) ->
            case childVars of
                [ elemVar ] ->
                    walkAndUnify st elemVar elemMono

                _ ->
                    st

        ( IO.App1 _ _ childVars, Mono.MCustom _ _ childMonos ) ->
            walkPairs st childVars childMonos

        ( IO.App1 _ _ _, Mono.MBool ) ->
            -- Bool is App1 Basics "Bool" [] — already matches
            st

        ( IO.App1 _ _ _, Mono.MInt ) ->
            st

        ( IO.App1 _ _ _, Mono.MFloat ) ->
            st

        ( IO.App1 _ _ _, Mono.MChar ) ->
            st

        ( IO.App1 _ _ _, Mono.MString ) ->
            st

        ( IO.Tuple1 a b rest, Mono.MTuple monos ) ->
            case monos of
                ma :: mb :: mrest ->
                    st
                        |> (\s -> walkAndUnify s a ma)
                        |> (\s -> walkAndUnify s b mb)
                        |> (\s -> walkPairs s rest mrest)

                _ ->
                    st

        ( IO.Record1 fields _, Mono.MRecord monoFields ) ->
            DMap.foldl compare
                (\name fieldVar s ->
                    case Dict.get name monoFields of
                        Just fieldMono ->
                            walkAndUnify s fieldVar fieldMono

                        Nothing ->
                            s
                )
                st
                fields

        ( IO.EmptyRecord1, _ ) ->
            st

        ( IO.Unit1, _ ) ->
            st

        _ ->
            -- Structure mismatch: force-unify the whole thing
            unifyVarWithMono st root monoType


walkPairs : IO.State -> List TypeVar -> List Mono.MonoType -> IO.State
walkPairs st vars monos =
    case ( vars, monos ) of
        ( v :: vs, m :: ms ) ->
            walkPairs (walkAndUnify st v m) vs ms

        _ ->
            st



-- ====== MONO TYPE TO SOLVER VAR ======


{-| Create a fresh solver variable with a Structure descriptor.
-}
freshStructureVar : IO.FlatType -> IO.State -> ( TypeVar, IO.State )
freshStructureVar flatType st =
    let
        pIdx =
            Array.length st.ioRefsPointInfo

        wIdx =
            Array.length st.ioRefsWeight

        dIdx =
            Array.length st.ioRefsDescriptor

        descriptor =
            IO.Descriptor
                { content = IO.Structure flatType
                , rank = 0
                , mark = IO.Mark 2
                , copy = Nothing
                }
    in
    ( IO.Pt pIdx
    , { st
        | ioRefsWeight = Array.push 1 st.ioRefsWeight
        , ioRefsDescriptor = Array.push descriptor st.ioRefsDescriptor
        , ioRefsPointInfo = Array.push (IO.Info wIdx dIdx) st.ioRefsPointInfo
      }
    )


{-| Create a fresh unconstrained flex variable.
-}
freshFlexVar : IO.State -> ( TypeVar, IO.State )
freshFlexVar st =
    let
        pIdx =
            Array.length st.ioRefsPointInfo

        wIdx =
            Array.length st.ioRefsWeight

        dIdx =
            Array.length st.ioRefsDescriptor

        descriptor =
            IO.Descriptor
                { content = IO.FlexVar Nothing
                , rank = 0
                , mark = IO.Mark 2
                , copy = Nothing
                }
    in
    ( IO.Pt pIdx
    , { st
        | ioRefsWeight = Array.push 1 st.ioRefsWeight
        , ioRefsDescriptor = Array.push descriptor st.ioRefsDescriptor
        , ioRefsPointInfo = Array.push (IO.Info wIdx dIdx) st.ioRefsPointInfo
      }
    )


{-| Recursively create solver variables encoding a MonoType.
-}
monoTypeToVar : Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoTypeToVar monoType st =
    case monoType of
        Mono.MInt ->
            freshStructureVar (IO.App1 elmCoreBasics "Int" []) st

        Mono.MFloat ->
            freshStructureVar (IO.App1 elmCoreBasics "Float" []) st

        Mono.MBool ->
            freshStructureVar (IO.App1 elmCoreBasics "Bool" []) st

        Mono.MChar ->
            freshStructureVar (IO.App1 elmCoreChar "Char" []) st

        Mono.MString ->
            freshStructureVar (IO.App1 elmCoreString "String" []) st

        Mono.MUnit ->
            freshStructureVar IO.Unit1 st

        Mono.MList elemType ->
            let
                ( elemVar, st1 ) =
                    monoTypeToVar elemType st
            in
            freshStructureVar (IO.App1 elmCoreList "List" [ elemVar ]) st1

        Mono.MFunction args resultType ->
            monoFunctionToVar args resultType st

        Mono.MRecord fields ->
            monoRecordToVar fields st

        Mono.MTuple parts ->
            monoTupleToVar parts st

        Mono.MCustom canonical name args ->
            let
                ( argVars, stN ) =
                    monoTypesToVars args st
            in
            freshStructureVar (IO.App1 canonical name argVars) stN

        Mono.MErased ->
            freshFlexVar st

        Mono.MVar _ _ ->
            freshFlexVar st


monoFunctionToVar : List Mono.MonoType -> Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoFunctionToVar args resultType st =
    case args of
        [ argType ] ->
            let
                ( argVar, st1 ) =
                    monoTypeToVar argType st

                ( resVar, st2 ) =
                    monoTypeToVar resultType st1
            in
            freshStructureVar (IO.Fun1 argVar resVar) st2

        a :: rest ->
            let
                ( argVar, st1 ) =
                    monoTypeToVar a st

                ( resVar, st2 ) =
                    monoFunctionToVar rest resultType st1
            in
            freshStructureVar (IO.Fun1 argVar resVar) st2

        [] ->
            monoTypeToVar resultType st


monoRecordToVar : Dict String Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoRecordToVar fields st =
    let
        ( fieldVars, stN ) =
            Dict.foldl
                (\name fieldType ( acc, s ) ->
                    let
                        ( fVar, s1 ) =
                            monoTypeToVar fieldType s
                    in
                    ( DMap.insert identity name fVar acc, s1 )
                )
                ( DMap.empty, st )
                fields

        ( extVar, stFinal ) =
            freshStructureVar IO.EmptyRecord1 stN
    in
    freshStructureVar (IO.Record1 fieldVars extVar) stFinal


monoTupleToVar : List Mono.MonoType -> IO.State -> ( TypeVar, IO.State )
monoTupleToVar parts st =
    case parts of
        a :: b :: rest ->
            let
                ( aVar, st1 ) =
                    monoTypeToVar a st

                ( bVar, st2 ) =
                    monoTypeToVar b st1

                ( restVars, st3 ) =
                    monoTypesToVars rest st2
            in
            freshStructureVar (IO.Tuple1 aVar bVar restVars) st3

        [ single ] ->
            monoTypeToVar single st

        [] ->
            freshStructureVar IO.Unit1 st


monoTypesToVars : List Mono.MonoType -> IO.State -> ( List TypeVar, IO.State )
monoTypesToVars types st =
    List.foldl
        (\t ( acc, s ) ->
            let
                ( v, s1 ) =
                    monoTypeToVar t s
            in
            ( acc ++ [ v ], s1 )
        )
        ( [], st )
        types


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
