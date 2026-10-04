module Compiler.Monomorphize.Closure exposing
    ( freshParams, extractRegion
    , computeClosureCaptures, findFreeLocals
    , flattenFunctionType
    )

{-| A closure has to carry the values of the local variables its body uses but
does not bind, and this module works out what those are.

A _free local_ of an expression is a local variable it reads without binding
it. A _capture_ is one entry of `ClosureInfo.captures` in
`Compiler.AST.Monomorphized`: a name, the expression whose value is stored in the
closure under that name, and a flag that code generation reads as whether the
value is stored unboxed. `computeClosureCaptures` turns the free locals of a
closure body into captures, each a `MonoVarLocal` of the free name, with the flag
always `False`.

A name counts as a reference wherever the Mono AST reads a local variable: a
`MonoVarLocal`, the root variable of a `MonoCase`, and the variable at the start
of a destructuring path or a decision-tree path. A variable that a closure uses
only as a `case` scrutinee therefore still counts as free.

A capture needs a `MonoType`, and most of this file is the search for one. A
`MonoCase` names its root variable without a type, so a variable that occurs only
as a case root has no type of its own to give.

The module also has three small helpers for code that builds closures: naming
fresh parameters, reading an expression's source region, and flattening a curried
function type. None of them changes how a function type is curried.


# Parameters and Regions

@docs freshParams, extractRegion


# Free Variable Analysis

@docs computeClosureCaptures, findFreeLocals


# Type Utilities

@docs flattenFunctionType

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Set exposing (Set)
import Utils.Crash



-- ========== TYPE UTILITIES ==========


{-| Returns every argument type of a chain of nested function types, in order,
together with the result type at the end of the chain.

A type that is not a function gives no arguments and itself as the result.

-}
flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ args ret ->
            let
                ( moreArgs, finalRet ) =
                    flattenFunctionType ret
            in
            ( args ++ moreArgs, finalRet )

        _ ->
            ( [], monoType )



-- ========== PARAMETERS AND REGIONS ==========


{-| Pairs each of `argTypes` with a parameter name, `arg0`, `arg1` and so on by
position.

The names are fresh only in the sense that nothing else in this module produces
them: nothing checks that the expression they are used in does not already bind
`arg0`.

-}
freshParams : List Mono.MonoType -> List ( Name, Mono.MonoType )
freshParams argTypes =
    List.indexedMap
        (\i ty -> ( "arg" ++ String.fromInt i, ty ))
        argTypes


{-| Returns the source region of an expression.

Only a global or kernel variable, a list, a call, a tuple and an accessor carry a
region. A record access or update takes the region of the record expression.
Every other kind of expression gives `A.zero`, the region that stands for no
location in the source.

-}
extractRegion : Mono.MonoExpr -> A.Region
extractRegion expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            A.zero

        Mono.MonoVarLocal _ _ ->
            A.zero

        Mono.MonoVarGlobal region _ _ ->
            region

        Mono.MonoVarKernel region _ _ _ _ ->
            region

        Mono.MonoList region _ _ ->
            region

        Mono.MonoClosure _ _ _ ->
            A.zero

        Mono.MonoCall region _ _ _ _ ->
            region

        Mono.MonoTailCall _ _ _ ->
            A.zero

        Mono.MonoIf _ _ _ ->
            A.zero

        Mono.MonoLet _ _ _ ->
            A.zero

        Mono.MonoDestruct _ _ _ ->
            A.zero

        Mono.MonoCase _ _ _ _ _ ->
            A.zero

        Mono.MonoRecordCreate _ _ ->
            A.zero

        Mono.MonoRecordAccess record _ _ ->
            extractRegion record

        Mono.MonoRecordUpdate record _ _ ->
            extractRegion record

        Mono.MonoTupleCreate region _ _ ->
            region

        Mono.MonoUnit ->
            A.zero

        Mono.MonoAccessorValue region _ _ ->
            region



-- ========== CLOSURE CAPTURE ANALYSIS ==========


{-| Returns the captures for a closure with parameters `params` and body `body`:
one per distinct free local of `body`, each a `MonoVarLocal` of the name with the
unboxed flag `False`. The order is deterministic but is not guaranteed to be
source order.

A free local is what `findFreeLocals` finds, with every name in `params` bound.

The type of a capture is looked up by name, not by scope. It is the type of the
first `MonoVarLocal` of that name, or destructuring or decision-tree path
starting at it, found anywhere in `body`, nested closures included. Failing
that, for a name that is the root of a `MonoCase` outside any nested closure, it
is `MUnit`. A free name with none of these crashes.

-}
computeClosureCaptures :
    List ( Name, Mono.MonoType )
    -> Mono.MonoExpr
    -> List ( Name, Mono.MonoExpr, Bool )
computeClosureCaptures params body =
    let
        boundInitial : Set String
        boundInitial =
            List.foldl
                (\( name, _ ) acc -> Set.insert name acc)
                Set.empty
                params

        freeNames : List Name
        freeNames =
            findFreeLocals boundInitial body
                |> dedupeNames

        varTypeMap : Dict String Mono.MonoType
        varTypeMap =
            collectVarTypes body

        caseRootTypeMap : Dict String Mono.MonoType
        caseRootTypeMap =
            collectCaseRootTypes body

        captureFor name =
            case Dict.get name varTypeMap of
                Just actualType ->
                    ( name, Mono.MonoVarLocal name actualType, False )

                Nothing ->
                    case Dict.get name caseRootTypeMap of
                        Just rootType ->
                            ( name, Mono.MonoVarLocal name rootType, False )

                        Nothing ->
                            Utils.Crash.crash
                                ("computeClosureCaptures: missing type for captured var `"
                                    ++ name
                                    ++ "`; this violates Mono typing invariants"
                                )
    in
    List.map captureFor freeNames


{-| Returns the names `expr` reads as local variables that are neither in
`bound` nor bound inside `expr`. A name read more than once can appear more than
once, and the order is not the order of occurrence.

A reference is a `MonoVarLocal`, a `MonoCase` root, or the variable at the start
of a destructuring path or a decision-tree path. The names bound inside `expr`
are a nested closure's parameters, a `MonoDestruct`'s name, a local tail
function's parameters, and every name defined by a chain of directly nested
`MonoLet`s. A name defined anywhere in such a chain is bound throughout it, in
every definition and in the final body, so definitions that refer to each other
are not free. A nested closure's free locals are free here too, unless bound.

-}
findFreeLocals :
    Set String
    -> Mono.MonoExpr
    -> List Name
findFreeLocals bound expr =
    findFreeLocalsAcc bound expr []


{-| Returns `acc` with the free locals of `expr` added in front, as `findFreeLocals`
describes them.
-}
findFreeLocalsAcc :
    Set String
    -> Mono.MonoExpr
    -> List Name
    -> List Name
findFreeLocalsAcc bound expr acc =
    case expr of
        Mono.MonoVarLocal name _ ->
            if Set.member name bound then
                acc

            else
                name :: acc

        Mono.MonoClosure closureInfo body _ ->
            -- Not stopped at the closure: what an inner closure captures, the outer one must too.
            let
                closureParams =
                    List.map Tuple.first closureInfo.params

                newBound =
                    List.foldl (\name a -> Set.insert name a) bound closureParams
            in
            findFreeLocalsAcc newBound body acc

        Mono.MonoLet _ _ _ ->
            let
                ( allDefs, finalBody ) =
                    collectLetChain expr

                defName def =
                    case def of
                        Mono.MonoDef n _ ->
                            n

                        Mono.MonoTailDef n _ _ ->
                            n

                -- Every name of the chain is bound before any definition is read.
                allNames =
                    List.map defName allDefs

                boundWithAllNames =
                    List.foldl (\name a -> Set.insert name a) bound allNames

                analyzeDefAcc def a =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            findFreeLocalsAcc boundWithAllNames defExpr a

                        Mono.MonoTailDef _ params defExpr ->
                            let
                                paramNames =
                                    List.map Tuple.first params

                                boundWithParams =
                                    List.foldl (\name a2 -> Set.insert name a2) boundWithAllNames paramNames
                            in
                            findFreeLocalsAcc boundWithParams defExpr a

                accWithBody =
                    findFreeLocalsAcc boundWithAllNames finalBody acc
            in
            List.foldl (\def a -> analyzeDefAcc def a) accWithBody allDefs

        Mono.MonoIf branches final _ ->
            let
                accWithFinal =
                    findFreeLocalsAcc bound final acc
            in
            List.foldl
                (\( cond, thenExpr ) a ->
                    findFreeLocalsAcc bound thenExpr (findFreeLocalsAcc bound cond a)
                )
                accWithFinal
                branches

        Mono.MonoCase _ root decider jumps _ ->
            let
                -- The second Name is the variable matched; the first is only a label.
                accWithRoot =
                    if Set.member root bound then
                        acc

                    else
                        root :: acc

                accWithDecider =
                    collectDeciderFreeLocalsAcc bound decider accWithRoot
            in
            List.foldl (\( _, e ) a -> findFreeLocalsAcc bound e a) accWithDecider jumps

        Mono.MonoList _ exprs _ ->
            List.foldl (\e a -> findFreeLocalsAcc bound e a) acc exprs

        Mono.MonoCall _ func args _ _ ->
            let
                accWithFunc =
                    findFreeLocalsAcc bound func acc
            in
            List.foldl (\e a -> findFreeLocalsAcc bound e a) accWithFunc args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) a -> findFreeLocalsAcc bound e a) acc namedExprs

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> findFreeLocalsAcc bound e a) acc fields

        Mono.MonoRecordAccess record _ _ ->
            findFreeLocalsAcc bound record acc

        Mono.MonoRecordUpdate record updates _ ->
            let
                accWithRecord =
                    findFreeLocalsAcc bound record acc
            in
            List.foldl (\( _, e ) a -> findFreeLocalsAcc bound e a) accWithRecord updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl (\e a -> findFreeLocalsAcc bound e a) acc exprs

        Mono.MonoDestruct (Mono.MonoDestructor name path _) body _ ->
            let
                accWithPath =
                    findPathFreeLocalsAcc bound path acc

                newBound =
                    Set.insert name bound
            in
            findFreeLocalsAcc newBound body accWithPath

        _ ->
            acc


{-| Returns `acc` with the variable a destructuring path starts from added in
front, unless it is in `bound`.
-}
findPathFreeLocalsAcc : Set String -> Mono.MonoPath -> List Name -> List Name
findPathFreeLocalsAcc bound path acc =
    case path of
        Mono.MonoRoot name _ ->
            if Set.member name bound then
                acc

            else
                name :: acc

        Mono.MonoIndex _ _ _ inner ->
            findPathFreeLocalsAcc bound inner acc

        Mono.MonoField _ _ inner ->
            findPathFreeLocalsAcc bound inner acc

        Mono.MonoUnbox _ inner ->
            findPathFreeLocalsAcc bound inner acc


{-| Returns the definitions of a chain of directly nested `MonoLet`s, outermost
first, and the first expression in the chain that is not a `MonoLet`.

For `MonoLet def1 (MonoLet def2 body)` that is `( [ def1, def2 ], body )`. An
expression that is not a `MonoLet` gives no definitions and itself.

-}
collectLetChain : Mono.MonoExpr -> ( List Mono.MonoDef, Mono.MonoExpr )
collectLetChain expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                ( restDefs, finalBody ) =
                    collectLetChain body
            in
            ( def :: restDefs, finalBody )

        _ ->
            ( [], expr )


{-| Returns `acc` with the free locals of a `case`'s decision tree added in front:
those of the path roots its tests read, and those of the branch bodies held
inline at its leaves. A leaf that jumps to a numbered branch adds nothing.
-}
collectDeciderFreeLocalsAcc :
    Set String
    -> Mono.Decider Mono.MonoChoice
    -> List Name
    -> List Name
collectDeciderFreeLocalsAcc bound decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    findFreeLocalsAcc bound expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithPaths =
                    List.foldl (\( dtPath, _ ) a -> findDtPathFreeLocalsAcc bound dtPath a) acc tests

                accWithSuccess =
                    collectDeciderFreeLocalsAcc bound success accWithPaths
            in
            collectDeciderFreeLocalsAcc bound failure accWithSuccess

        Mono.FanOut dtPath edges fallback ->
            let
                accWithRoot =
                    findDtPathFreeLocalsAcc bound dtPath acc

                accWithEdges =
                    List.foldl (\( _, d ) a -> collectDeciderFreeLocalsAcc bound d a) accWithRoot edges
            in
            collectDeciderFreeLocalsAcc bound fallback accWithEdges


{-| Returns `acc` with the variable a decision-tree path starts from added in
front, unless it is in `bound`.
-}
findDtPathFreeLocalsAcc : Set String -> Mono.MonoDtPath -> List Name -> List Name
findDtPathFreeLocalsAcc bound dtPath acc =
    case dtPath of
        Mono.DtRoot name _ ->
            if Set.member name bound then
                acc

            else
                name :: acc

        Mono.DtIndex _ _ _ inner ->
            findDtPathFreeLocalsAcc bound inner acc

        Mono.DtUnbox _ inner ->
            findDtPathFreeLocalsAcc bound inner acc


{-| Returns `names` with every repeat of a name removed, keeping each name's
first position.
-}
dedupeNames : List Name -> List Name
dedupeNames names =
    let
        step name ( seen, acc ) =
            if Set.member name seen then
                ( seen, acc )

            else
                ( Set.insert name seen, name :: acc )
    in
    names
        |> List.foldl step ( Set.empty, [] )
        |> Tuple.second
        |> List.reverse


{-| Returns the type of each local variable name read in `expr`, as given by
the first `MonoVarLocal` of it or destructuring or decision-tree path starting
at it, found anywhere in `expr`, nested closures included.

Names are not scoped: where two variables share a name, the first occurrence
found gives the type for both.

-}
collectVarTypes : Mono.MonoExpr -> Dict String Mono.MonoType
collectVarTypes expr =
    collectVarTypesHelper expr Dict.empty


{-| Returns `acc` with the types `collectVarTypes` describes for `expr` added,
keeping any name already in `acc`.
-}
collectVarTypesHelper : Mono.MonoExpr -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectVarTypesHelper expr acc =
    case expr of
        Mono.MonoVarLocal name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.MonoClosure _ body _ ->
            collectVarTypesHelper body acc

        Mono.MonoLet def body _ ->
            let
                accAfterDef =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            collectVarTypesHelper defExpr acc

                        Mono.MonoTailDef _ _ defExpr ->
                            collectVarTypesHelper defExpr acc
            in
            collectVarTypesHelper body accAfterDef

        Mono.MonoIf branches final _ ->
            let
                accAfterBranches =
                    List.foldl
                        (\( cond, thenExpr ) a ->
                            collectVarTypesHelper thenExpr (collectVarTypesHelper cond a)
                        )
                        acc
                        branches
            in
            collectVarTypesHelper final accAfterBranches

        Mono.MonoCase _ _ decider jumps _ ->
            let
                accAfterDecider =
                    collectDeciderVarTypes decider acc
            in
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) accAfterDecider jumps

        Mono.MonoList _ exprs _ ->
            List.foldl collectVarTypesHelper acc exprs

        Mono.MonoCall _ func args _ _ ->
            List.foldl collectVarTypesHelper (collectVarTypesHelper func acc) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) acc namedExprs

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) acc fields

        Mono.MonoRecordAccess record _ _ ->
            collectVarTypesHelper record acc

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectVarTypesHelper e a) (collectVarTypesHelper record acc) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl collectVarTypesHelper acc exprs

        Mono.MonoDestruct (Mono.MonoDestructor _ path _) body _ ->
            let
                accAfterPath =
                    collectPathVarTypes path acc
            in
            collectVarTypesHelper body accAfterPath

        _ ->
            acc


{-| Returns `acc` with the variable a destructuring path starts from and its
type added, unless the name is already in `acc`.
-}
collectPathVarTypes : Mono.MonoPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectPathVarTypes path acc =
    case path of
        Mono.MonoRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.MonoIndex _ _ _ inner ->
            collectPathVarTypes inner acc

        Mono.MonoField _ _ inner ->
            collectPathVarTypes inner acc

        Mono.MonoUnbox _ inner ->
            collectPathVarTypes inner acc


{-| Returns `acc` with the types `collectVarTypes` describes for a decision
tree added: from the paths its tests read and the bodies held inline at its
leaves.
-}
collectDeciderVarTypes : Mono.Decider Mono.MonoChoice -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDeciderVarTypes decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectVarTypesHelper expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithTests =
                    List.foldl (\( dtPath, _ ) a -> collectDtPathVarTypes dtPath a) acc tests
            in
            collectDeciderVarTypes failure (collectDeciderVarTypes success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectDtPathVarTypes dtPath acc

                accAfterEdges =
                    List.foldl (\( _, d ) a -> collectDeciderVarTypes d a) accWithPath edges
            in
            collectDeciderVarTypes fallback accAfterEdges


{-| Returns `acc` with the variable a decision-tree path starts from and its type
added, unless the name is already in `acc`.
-}
collectDtPathVarTypes : Mono.MonoDtPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDtPathVarTypes dtPath acc =
    case dtPath of
        Mono.DtRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.DtIndex _ _ _ inner ->
            collectDtPathVarTypes inner acc

        Mono.DtUnbox _ inner ->
            collectDtPathVarTypes inner acc


{-| Returns a type for each variable that is the root of a `MonoCase` in `expr`,
for the case roots `collectVarTypes` may not see.

A `MonoCase` names its root without a type. The type given is the one on the
first decision-tree path found that starts at a variable of that name, and
`MUnit` when there is none, as in a case whose decision tree makes no test.
The variables at the start of the decision-tree paths of each case are included
too, whether roots or not.

Nested closures are not searched.

-}
collectCaseRootTypes : Mono.MonoExpr -> Dict String Mono.MonoType
collectCaseRootTypes expr =
    collectCaseRootTypesHelper expr Dict.empty


{-| Returns `acc` with the types `collectCaseRootTypes` describes for `expr`
added, keeping any name already in `acc`.
-}
collectCaseRootTypesHelper : Mono.MonoExpr -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectCaseRootTypesHelper expr acc =
    case expr of
        Mono.MonoCase _ root decider jumps _ ->
            let
                -- The decider's typed path roots go in first, so MUnit is only a fallback.
                accAfterDecider =
                    collectCaseRootTypesFromDecider decider acc

                accWithRoot =
                    if Dict.member root accAfterDecider then
                        accAfterDecider

                    else
                        Dict.insert root Mono.MUnit accAfterDecider
            in
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) accWithRoot jumps

        Mono.MonoClosure _ _ _ ->
            acc

        Mono.MonoLet def body _ ->
            let
                accAfterDef =
                    case def of
                        Mono.MonoDef _ defExpr ->
                            collectCaseRootTypesHelper defExpr acc

                        Mono.MonoTailDef _ _ defExpr ->
                            collectCaseRootTypesHelper defExpr acc
            in
            collectCaseRootTypesHelper body accAfterDef

        Mono.MonoIf branches final _ ->
            let
                accAfterBranches =
                    List.foldl
                        (\( cond, thenExpr ) a ->
                            collectCaseRootTypesHelper thenExpr (collectCaseRootTypesHelper cond a)
                        )
                        acc
                        branches
            in
            collectCaseRootTypesHelper final accAfterBranches

        Mono.MonoCall _ func args _ _ ->
            List.foldl collectCaseRootTypesHelper (collectCaseRootTypesHelper func acc) args

        Mono.MonoList _ exprs _ ->
            List.foldl collectCaseRootTypesHelper acc exprs

        Mono.MonoDestruct _ inner _ ->
            collectCaseRootTypesHelper inner acc

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectCaseRootTypesHelper inner acc

        Mono.MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) (collectCaseRootTypesHelper inner acc) updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl collectCaseRootTypesHelper acc exprs

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectCaseRootTypesHelper e a) acc args

        _ ->
            acc


{-| Returns `acc` with the variables at the start of a decision tree's paths and
their types added, then the case-root types `collectCaseRootTypes` describes for
the bodies held inline at its leaves.
-}
collectCaseRootTypesFromDecider : Mono.Decider Mono.MonoChoice -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectCaseRootTypesFromDecider decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCaseRootTypesHelper expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithTests =
                    List.foldl (\( dtPath, _ ) a -> collectDtPathCaseRootTypes dtPath a) acc tests
            in
            collectCaseRootTypesFromDecider failure (collectCaseRootTypesFromDecider success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectDtPathCaseRootTypes dtPath acc

                accAfterEdges =
                    List.foldl (\( _, d ) a -> collectCaseRootTypesFromDecider d a) accWithPath edges
            in
            collectCaseRootTypesFromDecider fallback accAfterEdges


{-| Returns `acc` with the variable a decision-tree path starts from and its type
added, unless the name is already in `acc`.
-}
collectDtPathCaseRootTypes : Mono.MonoDtPath -> Dict String Mono.MonoType -> Dict String Mono.MonoType
collectDtPathCaseRootTypes dtPath acc =
    case dtPath of
        Mono.DtRoot name monoType ->
            if Dict.member name acc then
                acc

            else
                Dict.insert name monoType acc

        Mono.DtIndex _ _ _ inner ->
            collectDtPathCaseRootTypes inner acc

        Mono.DtUnbox _ inner ->
            collectDtPathCaseRootTypes inner acc
