module Compiler.PreMono.AssignMVarIdsHelpers exposing (assignIdsToType, varSupersOfType)

{-| Fixture builders for tests that need one canonical type with ids assigned
the way `Compiler.PreMono.AssignMVarIds` assigns them, without building a
program.

`assignIdsToType` runs `AssignMVarIds.assignIds` on a graph that holds only one
annotation, with no declared variables and no solver roots. The type is then the
first thing the walk meets, so its variables take the first `MVarId`s in the
order the walk meets them, and every arrow gets a fresh `ArrowId`. Each
variable's super-type comes from its name, by `varSupersOfType`.

@docs assignIdsToType, varSupersOfType

-}

import Compiler.Core.Name as Name exposing (Name)
import Compiler.Core.StringTable as StringTable
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.IR.Typed.TypeVars as Vars
import Compiler.PreMono.AssignMVarIds as AssignMVarIds
import Data.Map as DMap
import Dict exposing (Dict)
import Set


{-| Returns `canType` with ids assigned as for one annotation, and the state
the supplies ended in.
-}
assignIdsToType : Can.Type Name -> ( Can.Type TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
assignIdsToType canType =
    let
        global =
            TOpt.Global ModuleName.basics "fixture"

        graph =
            TOpt.GlobalGraph DMap.empty
                Dict.empty
                (DMap.insert TOpt.toComparableGlobal global (Can.Forall Dict.empty canType) DMap.empty)
                DMap.empty
                (varSupersOfType canType)

        ( TOpt.GlobalGraph _ _ annotations _ _, state ) =
            AssignMVarIds.assignIds False False graph
    in
    case DMap.get TOpt.toComparableGlobal global annotations of
        Just (Can.Forall _ assigned) ->
            ( assigned, state )

        Nothing ->
            Debug.todo "AssignMVarIdsHelpers.assignIdsToType: assignIds dropped the annotation"


{-| Returns a varSupers map for one canonical type: each string the type writes
that has a super-constraint prefix, mapped to that constraint. It takes alias
argument and record field names as well as type variables, as
`TOpt.computeVarSupers` does for a whole graph.
-}
varSupersOfType : Can.Type Name -> Dict Name Vars.SuperType
varSupersOfType tipe =
    Set.foldl
        (\name acc ->
            case superOfName name of
                Just s ->
                    Dict.insert name s acc

                Nothing ->
                    acc
        )
        Dict.empty
        (StringTable.collected (Can.collectStringsFromType tipe StringTable.collectSupers))


{-| Returns the super constraint a name's prefix implies, as the private
`superOfName` of `Compiler.IR.Typed.Optimized` does.
-}
superOfName : Name -> Maybe Vars.SuperType
superOfName name =
    if Name.isNumberType name then
        Just Vars.Number

    else if Name.isComparableType name then
        Just Vars.Comparable

    else if Name.isAppendableType name then
        Just Vars.Appendable

    else if Name.isCompappendType name then
        Just Vars.CompAppend

    else
        Nothing
