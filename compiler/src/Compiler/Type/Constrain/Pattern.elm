module Compiler.Type.Constrain.Pattern exposing
    ( State(..), Header
    , add, emptyState
    , addWithIds
    )

{-| Type constraint generation for pattern matching.

This module generates type constraints for patterns used in case expressions, function
arguments, let bindings, and destructuring assignments. Patterns introduce new variables
into scope and constrain their types based on the pattern structure (e.g., a list pattern
constrains the matched value to be a list).

The State accumulates information about variables introduced by patterns, including their
names, types, and regions for error reporting. Constraints are stored in reverse order
for efficient appending and later reversed when complete.

This module uses an internal PatternProg DSL for stack-safe constraint generation,
preventing stack overflow on deeply nested patterns.


# Types

@docs State, Header


# Constraint Generation

@docs add, emptyState

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.NodeIds as NodeIds
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Type)
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



-- PATTERN CATEGORY HELPER


{-| Determine the appropriate PCategory for a pattern node.
This matches the categories used in the constraint generation.
-}
patternToCategory : Can.Pattern_ -> E.PCategory
patternToCategory node =
    case node of
        Can.PAnything ->
            -- PAnything doesn't generate a CPattern constraint, use PRecord as fallback
            E.PRecord

        Can.PVar _ ->
            -- PVar doesn't generate a CPattern constraint, use PRecord as fallback
            E.PRecord

        Can.PAlias _ _ ->
            -- PAlias delegates to inner pattern, use PRecord as fallback
            E.PRecord

        Can.PUnit ->
            E.PUnit

        Can.PTuple _ _ _ ->
            E.PTuple

        Can.PCtor { name } ->
            E.PCtor name

        Can.PList _ ->
            E.PList

        Can.PCons _ _ ->
            E.PList

        Can.PRecord _ ->
            E.PRecord

        Can.PInt _ ->
            E.PInt

        Can.PStr _ _ ->
            E.PStr

        Can.PChr _ ->
            E.PChr

        Can.PBool _ _ ->
            E.PBool



-- ACTUALLY ADD CONSTRAINTS
-- The constraints are stored in reverse order so that adding a new
-- constraint is O(1) and we can reverse it at some later time.


{-| State accumulated during pattern constraint generation.

Contains the header (variables introduced by the pattern with their types),
a list of flexible type variables created during constraint generation,
and constraints stored in reverse order for efficient appending.

-}
type State
    = State Header (List IO.Variable) (List Type.Constraint)


{-| Header maps variable names to their types with source locations.

Records all variables introduced by a pattern, associating each name
with its inferred type and the region where it was bound.

-}
type alias Header =
    Dict String Name.Name (A.Located Type)


{-| Generate type constraints for a pattern.

Takes a pattern, an expected type, and the current state, and returns
updated state with new constraints and variable bindings. Handles all
pattern forms including literals, variables, tuples, lists, records,
and custom type constructors.

Uses the stack-safe PatternProg DSL internally.

-}
add : Can.Pattern -> E.PExpected Type -> State -> IO State
add pattern expectation state =
    addProg pattern expectation state |> runPatternProg


{-| Generate type constraints for a pattern, tracking node IDs.

Like `add` but also tracks pattern node IDs to solver variables in the
NodeIdState, enabling later retrieval of pattern types from the solver.

Uses the stack-safe PatternProg DSL internally.

-}
addWithIds : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> IO ( State, NodeIds.NodeIdState )
addWithIds ((A.At region patternInfo) as pattern) expectation state nodeState0 =
    Type.mkFlexVar
        |> IO.andThen
            (\patVar ->
                let
                    patType : Type
                    patType =
                        Type.VarN patVar

                    eqCon : Type.Constraint
                    eqCon =
                        Type.CPattern region (patternToCategory patternInfo.node) patType expectation

                    -- extend the pattern state with this new variable + constraint
                    (State headers vars revCons) =
                        state

                    stateWithPatVar : State
                    stateWithPatVar =
                        State headers (patVar :: vars) (eqCon :: revCons)

                    -- record ID → variable mapping
                    nodeState1 : NodeIds.NodeIdState
                    nodeState1 =
                        NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                in
                -- Now generate all the usual pattern constraints using the DSL
                addHelpWithIdsProg region patternInfo.node expectation stateWithPatVar nodeState1
                    |> runPatternProgWithIds
            )



-- ===== PatternProg DSL =====
--
-- Internal DSL for stack-safe pattern constraint generation.
-- This ensures we don't overflow the stack on deeply nested patterns.


{-| Program representing pattern constraint generation steps.
-}
type PatternProg a
    = PDone a
    | PMkFlexVar (IO.Variable -> PatternProg a)
    | PFromSrcType (Dict String Name.Name Type) Can.Type (Type -> PatternProg a)
    | PAddPattern Can.Pattern (E.PExpected Type) State (State -> PatternProg a)
    | PAddPatternWithIds Can.Pattern (E.PExpected Type) State NodeIds.NodeIdState (( State, NodeIds.NodeIdState ) -> PatternProg a)
    | PTraverseList (List Name.Name) (List ( Name.Name, IO.Variable ) -> PatternProg a)


{-| Pure value in the DSL.
-}
pPure : a -> PatternProg a
pPure =
    PDone


{-| Map over a pattern program.
-}
pMap : (a -> b) -> PatternProg a -> PatternProg b
pMap f prog =
    case prog of
        PDone a ->
            PDone (f a)

        PMkFlexVar k ->
            PMkFlexVar (k >> pMap f)

        PFromSrcType dict srcType k ->
            PFromSrcType dict srcType (k >> pMap f)

        PAddPattern pat exp st k ->
            PAddPattern pat exp st (k >> pMap f)

        PAddPatternWithIds pat exp st ns k ->
            PAddPatternWithIds pat exp st ns (k >> pMap f)

        PTraverseList names k ->
            PTraverseList names (k >> pMap f)


{-| Sequence two pattern programs.
-}
pAndThen : (a -> PatternProg b) -> PatternProg a -> PatternProg b
pAndThen f prog =
    case prog of
        PDone a ->
            f a

        PMkFlexVar k ->
            PMkFlexVar (k >> pAndThen f)

        PFromSrcType dict srcType k ->
            PFromSrcType dict srcType (k >> pAndThen f)

        PAddPattern pat exp st k ->
            PAddPattern pat exp st (k >> pAndThen f)

        PAddPatternWithIds pat exp st ns k ->
            PAddPatternWithIds pat exp st ns (k >> pAndThen f)

        PTraverseList names k ->
            PTraverseList names (k >> pAndThen f)


{-| Create a fresh flex variable.
-}
pMkFlexVar : PatternProg IO.Variable
pMkFlexVar =
    PMkFlexVar PDone


{-| Instantiate a source type.
-}
pFromSrcType : Dict String Name.Name Type -> Can.Type -> PatternProg Type
pFromSrcType dict srcType =
    PFromSrcType dict srcType PDone


{-| Recursively add a pattern.
-}
pAddPattern : Can.Pattern -> E.PExpected Type -> State -> PatternProg State
pAddPattern pat exp st =
    PAddPattern pat exp st PDone


{-| Recursively add a pattern with ID tracking.
-}
pAddPatternWithIds : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
pAddPatternWithIds pat exp st ns =
    PAddPatternWithIds pat exp st ns PDone


{-| Traverse a list of names to create flex variables.
-}
pTraverseList : List Name.Name -> PatternProg (List ( Name.Name, IO.Variable ))
pTraverseList names =
    PTraverseList names PDone


{-| Run a pattern program to produce an IO State.
-}
runPatternProg : PatternProg State -> IO State
runPatternProg prog =
    IO.loop stepProg prog


{-| Run a pattern program to produce an IO (State, NodeIdState).
-}
runPatternProgWithIds : PatternProg ( State, NodeIds.NodeIdState ) -> IO ( State, NodeIds.NodeIdState )
runPatternProgWithIds prog =
    IO.loop stepProgWithIds prog


{-| Step function for the pattern program interpreter.
-}
stepProg : PatternProg State -> IO (IO.Step (PatternProg State) State)
stepProg prog =
    case prog of
        PDone state ->
            IO.pure (IO.Done state)

        PMkFlexVar k ->
            Type.mkFlexVar
                |> IO.map (\var -> IO.Loop (k var))

        PFromSrcType dict srcType k ->
            Instantiate.fromSrcType dict srcType
                |> IO.map (\tipe -> IO.Loop (k tipe))

        PAddPattern pat exp st k ->
            -- Recursive call - build new program and continue
            IO.pure (IO.Loop (addProg pat exp st |> pAndThen k))

        PAddPatternWithIds _ _ st ns k ->
            -- Not expected in non-WithIds version, but handle gracefully
            IO.pure (IO.Loop (PDone st |> pAndThen (\s -> k ( s, ns ))))

        PTraverseList names k ->
            IO.traverseList (\name -> IO.map (Tuple.pair name) (Type.nameToFlex name)) names
                |> IO.map (\pairs -> IO.Loop (k pairs))


{-| Step function for the pattern program interpreter with ID tracking.
-}
stepProgWithIds : PatternProg ( State, NodeIds.NodeIdState ) -> IO (IO.Step (PatternProg ( State, NodeIds.NodeIdState )) ( State, NodeIds.NodeIdState ))
stepProgWithIds prog =
    case prog of
        PDone result ->
            IO.pure (IO.Done result)

        PMkFlexVar k ->
            Type.mkFlexVar
                |> IO.map (\var -> IO.Loop (k var))

        PFromSrcType dict srcType k ->
            Instantiate.fromSrcType dict srcType
                |> IO.map (\tipe -> IO.Loop (k tipe))

        PAddPattern pat exp st k ->
            -- Run addProg, then continue with k
            IO.pure (IO.Loop (addProg pat exp st |> pAndThen k))

        PAddPatternWithIds pat exp st ns k ->
            -- Recursive call - build new program and continue
            IO.pure (IO.Loop (addWithIdsProg pat exp st ns |> pAndThen k))

        PTraverseList names k ->
            IO.traverseList (\name -> IO.map (Tuple.pair name) (Type.nameToFlex name)) names
                |> IO.map (\pairs -> IO.Loop (k pairs))



-- ===== Pattern Constraint Generation using PatternProg DSL =====


{-| Build a pattern program for the given pattern.
-}
addProg : Can.Pattern -> E.PExpected Type -> State -> PatternProg State
addProg (A.At region patternInfo) expectation state =
    case patternInfo.node of
        Can.PAnything ->
            pPure state

        Can.PVar name ->
            pPure (addToHeaders region name expectation state)

        Can.PAlias realPattern name ->
            pAddPattern realPattern expectation (addToHeaders region name expectation state)

        Can.PUnit ->
            let
                (State headers vars revCons) =
                    state

                unitCon : Type.Constraint
                unitCon =
                    Type.CPattern region E.PUnit Type.UnitN expectation
            in
            pPure (State headers vars (unitCon :: revCons))

        Can.PTuple a b cs ->
            addTupleProg region a b cs expectation state

        Can.PCtor { home, type_, union, name, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            addCtorProg region home type_ unionData.vars name args expectation state

        Can.PList patterns ->
            pMkFlexVar
                |> pAndThen
                    (\entryVar ->
                        let
                            entryType : Type
                            entryType =
                                Type.VarN entryVar

                            listType : Type
                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]
                        in
                        addListEntriesProg region entryType state Index.first patterns
                            |> pMap
                                (\(State headers vars revCons) ->
                                    let
                                        listCon : Type.Constraint
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    State headers (entryVar :: vars) (listCon :: revCons)
                                )
                    )

        Can.PCons headPattern tailPattern ->
            pMkFlexVar
                |> pAndThen
                    (\entryVar ->
                        let
                            entryType : Type
                            entryType =
                                Type.VarN entryVar

                            listType : Type
                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]

                            headExpectation : E.PExpected Type
                            headExpectation =
                                E.PNoExpectation entryType

                            tailExpectation : E.PExpected Type
                            tailExpectation =
                                E.PFromContext region E.PTail listType
                        in
                        pAddPattern tailPattern tailExpectation state
                            |> pAndThen (pAddPattern headPattern headExpectation)
                            |> pMap
                                (\(State headers vars revCons) ->
                                    let
                                        listCon : Type.Constraint
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    State headers (entryVar :: vars) (listCon :: revCons)
                                )
                    )

        Can.PRecord fields ->
            pMkFlexVar
                |> pAndThen
                    (\extVar ->
                        let
                            extType : Type
                            extType =
                                Type.VarN extVar
                        in
                        addRecordFieldsProg fields []
                            |> pMap
                                (\fieldVars ->
                                    let
                                        fieldTypes : Dict String Name.Name Type
                                        fieldTypes =
                                            Dict.fromList identity (List.map (Tuple.mapSecond Type.VarN) fieldVars)

                                        recordType : Type
                                        recordType =
                                            Type.RecordN fieldTypes extType

                                        (State headers vars revCons) =
                                            state

                                        recordCon : Type.Constraint
                                        recordCon =
                                            Type.CPattern region E.PRecord recordType expectation
                                    in
                                    State
                                        (Dict.union headers (Dict.map (\_ v -> A.At region v) fieldTypes))
                                        (List.map Tuple.second fieldVars ++ extVar :: vars)
                                        (recordCon :: revCons)
                                )
                    )

        Can.PInt _ ->
            let
                (State headers vars revCons) =
                    state

                intCon : Type.Constraint
                intCon =
                    Type.CPattern region E.PInt Type.int expectation
            in
            pPure (State headers vars (intCon :: revCons))

        Can.PStr _ _ ->
            let
                (State headers vars revCons) =
                    state

                strCon : Type.Constraint
                strCon =
                    Type.CPattern region E.PStr Type.string expectation
            in
            pPure (State headers vars (strCon :: revCons))

        Can.PChr _ ->
            let
                (State headers vars revCons) =
                    state

                chrCon : Type.Constraint
                chrCon =
                    Type.CPattern region E.PChr Type.char expectation
            in
            pPure (State headers vars (chrCon :: revCons))

        Can.PBool _ _ ->
            let
                (State headers vars revCons) =
                    state

                boolCon : Type.Constraint
                boolCon =
                    Type.CPattern region E.PBool Type.bool expectation
            in
            pPure (State headers vars (boolCon :: revCons))


{-| Add list entries using tail-recursive accumulator pattern.
-}
addListEntriesProg : A.Region -> Type -> State -> Index.ZeroBased -> List Can.Pattern -> PatternProg State
addListEntriesProg region entryType state index patterns =
    case patterns of
        [] ->
            pPure state

        pattern :: rest ->
            let
                expectation : E.PExpected Type
                expectation =
                    E.PFromContext region (E.PListEntry index) entryType
            in
            pAddPattern pattern expectation state
                |> pAndThen
                    (\newState ->
                        addListEntriesProg region entryType newState (Index.next index) rest
                    )


{-| Add record fields using tail-recursive accumulator pattern.
-}
addRecordFieldsProg : List Name.Name -> List ( Name.Name, IO.Variable ) -> PatternProg (List ( Name.Name, IO.Variable ))
addRecordFieldsProg fields acc =
    case fields of
        [] ->
            pPure (List.reverse acc)

        field :: rest ->
            pMkFlexVar
                |> pAndThen
                    (\fieldVar ->
                        addRecordFieldsProg rest (( field, fieldVar ) :: acc)
                    )


{-| Build a pattern program for tuple patterns.
-}
addTupleProg : A.Region -> Can.Pattern -> Can.Pattern -> List Can.Pattern -> E.PExpected Type -> State -> PatternProg State
addTupleProg region a b cs expectation state =
    pMkFlexVar
        |> pAndThen
            (\aVar ->
                pMkFlexVar
                    |> pAndThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    Type.VarN aVar

                                bType : Type
                                bType =
                                    Type.VarN bVar
                            in
                            simpleAddProg a aType state
                                |> pAndThen (simpleAddProg b bType)
                                |> pAndThen
                                    (\updatedState ->
                                        addTupleRestProg cs [] updatedState
                                            |> pMap
                                                (\( cVars, State headers vars revCons ) ->
                                                    let
                                                        tupleCon : Type.Constraint
                                                        tupleCon =
                                                            Type.CPattern region E.PTuple (Type.TupleN aType bType (List.map Type.VarN cVars)) expectation
                                                    in
                                                    State headers (aVar :: bVar :: cVars ++ vars) (tupleCon :: revCons)
                                                )
                                    )
                        )
            )


addTupleRestProg : List Can.Pattern -> List IO.Variable -> State -> PatternProg ( List IO.Variable, State )
addTupleRestProg cs accVars state =
    case cs of
        [] ->
            pPure ( List.reverse accVars, state )

        c :: rest ->
            pMkFlexVar
                |> pAndThen
                    (\cVar ->
                        simpleAddProg c (Type.VarN cVar) state
                            |> pAndThen
                                (\newState ->
                                    addTupleRestProg rest (cVar :: accVars) newState
                                )
                    )


simpleAddProg : Can.Pattern -> Type -> State -> PatternProg State
simpleAddProg pattern patternType state =
    pAddPattern pattern (E.PNoExpectation patternType) state


{-| Build a pattern program for constructor patterns.
-}
addCtorProg : A.Region -> IO.Canonical -> Name.Name -> List Name.Name -> Name.Name -> List Can.PatternCtorArg -> E.PExpected Type -> State -> PatternProg State
addCtorProg region home typeName typeVarNames ctorName args expectation state =
    pTraverseList typeVarNames
        |> pAndThen
            (\varPairs ->
                let
                    typePairs : List ( Name.Name, Type )
                    typePairs =
                        List.map (Tuple.mapSecond Type.VarN) varPairs

                    freeVarDict : Dict String Name.Name Type
                    freeVarDict =
                        Dict.fromList identity typePairs
                in
                addCtorArgsProg region ctorName freeVarDict state args
                    |> pMap
                        (\(State headers vars revCons) ->
                            let
                                ctorType : Type
                                ctorType =
                                    Type.AppN home typeName (List.map Tuple.second typePairs)

                                ctorCon : Type.Constraint
                                ctorCon =
                                    Type.CPattern region (E.PCtor ctorName) ctorType expectation
                            in
                            State headers
                                (List.map Tuple.second varPairs ++ vars)
                                (ctorCon :: revCons)
                        )
            )


addCtorArgsProg : A.Region -> Name.Name -> Dict String Name.Name Type -> State -> List Can.PatternCtorArg -> PatternProg State
addCtorArgsProg region ctorName freeVarDict state args =
    case args of
        [] ->
            pPure state

        (Can.PatternCtorArg index srcType pattern) :: rest ->
            pFromSrcType freeVarDict srcType
                |> pAndThen
                    (\tipe ->
                        let
                            expectation : E.PExpected Type
                            expectation =
                                E.PFromContext region (E.PCtorArg ctorName index) tipe
                        in
                        pAddPattern pattern expectation state
                            |> pAndThen
                                (\newState ->
                                    addCtorArgsProg region ctorName freeVarDict newState rest
                                )
                    )



-- ===== WithIds versions =====


addWithIdsProg : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addWithIdsProg ((A.At region patternInfo) as pattern) expectation state nodeState0 =
    pMkFlexVar
        |> pAndThen
            (\patVar ->
                let
                    patType : Type
                    patType =
                        Type.VarN patVar

                    eqCon : Type.Constraint
                    eqCon =
                        Type.CPattern region (patternToCategory patternInfo.node) patType expectation

                    (State headers vars revCons) =
                        state

                    stateWithPatVar : State
                    stateWithPatVar =
                        State headers (patVar :: vars) (eqCon :: revCons)

                    nodeState1 : NodeIds.NodeIdState
                    nodeState1 =
                        NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                in
                addHelpWithIdsProg region patternInfo.node expectation stateWithPatVar nodeState1
            )


addHelpWithIdsProg : A.Region -> Can.Pattern_ -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addHelpWithIdsProg region patternNode expectation state nodeState =
    case patternNode of
        Can.PAnything ->
            pPure ( state, nodeState )

        Can.PVar name ->
            pPure ( addToHeaders region name expectation state, nodeState )

        Can.PAlias realPattern name ->
            let
                state1 : State
                state1 =
                    addToHeaders region name expectation state
            in
            pAddPatternWithIds realPattern expectation state1 nodeState

        Can.PUnit ->
            let
                (State headers vars revCons) =
                    state

                unitCon : Type.Constraint
                unitCon =
                    Type.CPattern region E.PUnit Type.UnitN expectation
            in
            pPure ( State headers vars (unitCon :: revCons), nodeState )

        Can.PTuple a b cs ->
            addTupleWithIdsProg region a b cs expectation state nodeState

        Can.PCtor { home, type_, union, name, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            addCtorWithIdsProg region home type_ unionData.vars name args expectation state nodeState

        Can.PList patterns ->
            pMkFlexVar
                |> pAndThen
                    (\entryVar ->
                        let
                            entryType : Type
                            entryType =
                                Type.VarN entryVar

                            listType : Type
                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]
                        in
                        addListEntriesWithIdsProg region entryType state nodeState Index.first patterns
                            |> pMap
                                (\( State headers vars revCons, ns ) ->
                                    let
                                        listCon : Type.Constraint
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    ( State headers (entryVar :: vars) (listCon :: revCons), ns )
                                )
                    )

        Can.PCons headPattern tailPattern ->
            pMkFlexVar
                |> pAndThen
                    (\entryVar ->
                        let
                            entryType : Type
                            entryType =
                                Type.VarN entryVar

                            listType : Type
                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]

                            headExpectation : E.PExpected Type
                            headExpectation =
                                E.PNoExpectation entryType

                            tailExpectation : E.PExpected Type
                            tailExpectation =
                                E.PFromContext region E.PTail listType
                        in
                        pAddPatternWithIds tailPattern tailExpectation state nodeState
                            |> pAndThen
                                (\( s1, ns1 ) ->
                                    pAddPatternWithIds headPattern headExpectation s1 ns1
                                )
                            |> pMap
                                (\( State headers vars revCons, ns ) ->
                                    let
                                        listCon : Type.Constraint
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    ( State headers (entryVar :: vars) (listCon :: revCons), ns )
                                )
                    )

        Can.PRecord fields ->
            pMkFlexVar
                |> pAndThen
                    (\extVar ->
                        let
                            extType : Type
                            extType =
                                Type.VarN extVar
                        in
                        addRecordFieldsProg fields []
                            |> pMap
                                (\fieldVars ->
                                    let
                                        fieldTypes : Dict String Name.Name Type
                                        fieldTypes =
                                            Dict.fromList identity (List.map (Tuple.mapSecond Type.VarN) fieldVars)

                                        recordType : Type
                                        recordType =
                                            Type.RecordN fieldTypes extType

                                        (State headers vars revCons) =
                                            state

                                        recordCon : Type.Constraint
                                        recordCon =
                                            Type.CPattern region E.PRecord recordType expectation
                                    in
                                    ( State
                                        (Dict.union headers (Dict.map (\_ v -> A.At region v) fieldTypes))
                                        (List.map Tuple.second fieldVars ++ extVar :: vars)
                                        (recordCon :: revCons)
                                    , nodeState
                                    )
                                )
                    )

        Can.PInt _ ->
            let
                (State headers vars revCons) =
                    state

                intCon : Type.Constraint
                intCon =
                    Type.CPattern region E.PInt Type.int expectation
            in
            pPure ( State headers vars (intCon :: revCons), nodeState )

        Can.PStr _ _ ->
            let
                (State headers vars revCons) =
                    state

                strCon : Type.Constraint
                strCon =
                    Type.CPattern region E.PStr Type.string expectation
            in
            pPure ( State headers vars (strCon :: revCons), nodeState )

        Can.PChr _ ->
            let
                (State headers vars revCons) =
                    state

                chrCon : Type.Constraint
                chrCon =
                    Type.CPattern region E.PChr Type.char expectation
            in
            pPure ( State headers vars (chrCon :: revCons), nodeState )

        Can.PBool _ _ ->
            let
                (State headers vars revCons) =
                    state

                boolCon : Type.Constraint
                boolCon =
                    Type.CPattern region E.PBool Type.bool expectation
            in
            pPure ( State headers vars (boolCon :: revCons), nodeState )


addListEntriesWithIdsProg : A.Region -> Type -> State -> NodeIds.NodeIdState -> Index.ZeroBased -> List Can.Pattern -> PatternProg ( State, NodeIds.NodeIdState )
addListEntriesWithIdsProg region entryType state nodeState index patterns =
    case patterns of
        [] ->
            pPure ( state, nodeState )

        pattern :: rest ->
            let
                expectation : E.PExpected Type
                expectation =
                    E.PFromContext region (E.PListEntry index) entryType
            in
            pAddPatternWithIds pattern expectation state nodeState
                |> pAndThen
                    (\( newState, newNodeState ) ->
                        addListEntriesWithIdsProg region entryType newState newNodeState (Index.next index) rest
                    )


addTupleWithIdsProg : A.Region -> Can.Pattern -> Can.Pattern -> List Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addTupleWithIdsProg region a b cs expectation state nodeState0 =
    pMkFlexVar
        |> pAndThen
            (\aVar ->
                pMkFlexVar
                    |> pAndThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    Type.VarN aVar

                                bType : Type
                                bType =
                                    Type.VarN bVar
                            in
                            simpleAddWithIdsProg a aType state nodeState0
                                |> pAndThen
                                    (\( s1, ns1 ) ->
                                        simpleAddWithIdsProg b bType s1 ns1
                                    )
                                |> pAndThen
                                    (\( updatedState, ns2 ) ->
                                        addTupleRestWithIdsProg cs [] updatedState ns2
                                            |> pMap
                                                (\( cVars, State headers vars revCons, nsFinal ) ->
                                                    let
                                                        tupleCon : Type.Constraint
                                                        tupleCon =
                                                            Type.CPattern region E.PTuple (Type.TupleN aType bType (List.map Type.VarN cVars)) expectation
                                                    in
                                                    ( State headers (aVar :: bVar :: cVars ++ vars) (tupleCon :: revCons), nsFinal )
                                                )
                                    )
                        )
            )


addTupleRestWithIdsProg : List Can.Pattern -> List IO.Variable -> State -> NodeIds.NodeIdState -> PatternProg ( List IO.Variable, State, NodeIds.NodeIdState )
addTupleRestWithIdsProg cs accVars state nodeState =
    case cs of
        [] ->
            pPure ( List.reverse accVars, state, nodeState )

        c :: rest ->
            pMkFlexVar
                |> pAndThen
                    (\cVar ->
                        simpleAddWithIdsProg c (Type.VarN cVar) state nodeState
                            |> pAndThen
                                (\( newState, newNodeState ) ->
                                    addTupleRestWithIdsProg rest (cVar :: accVars) newState newNodeState
                                )
                    )


simpleAddWithIdsProg : Can.Pattern -> Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
simpleAddWithIdsProg pattern patternType state nodeState =
    pAddPatternWithIds pattern (E.PNoExpectation patternType) state nodeState


addCtorWithIdsProg : A.Region -> IO.Canonical -> Name.Name -> List Name.Name -> Name.Name -> List Can.PatternCtorArg -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addCtorWithIdsProg region home typeName typeVarNames ctorName args expectation state nodeState0 =
    pTraverseList typeVarNames
        |> pAndThen
            (\varPairs ->
                let
                    typePairs : List ( Name.Name, Type )
                    typePairs =
                        List.map (Tuple.mapSecond Type.VarN) varPairs

                    freeVarDict : Dict String Name.Name Type
                    freeVarDict =
                        Dict.fromList identity typePairs
                in
                addCtorArgsWithIdsProg region ctorName freeVarDict state nodeState0 args
                    |> pMap
                        (\( State headers vars revCons, nsFinal ) ->
                            let
                                ctorType : Type
                                ctorType =
                                    Type.AppN home typeName (List.map Tuple.second typePairs)

                                ctorCon : Type.Constraint
                                ctorCon =
                                    Type.CPattern region (E.PCtor ctorName) ctorType expectation
                            in
                            ( State headers
                                (List.map Tuple.second varPairs ++ vars)
                                (ctorCon :: revCons)
                            , nsFinal
                            )
                        )
            )


addCtorArgsWithIdsProg : A.Region -> Name.Name -> Dict String Name.Name Type -> State -> NodeIds.NodeIdState -> List Can.PatternCtorArg -> PatternProg ( State, NodeIds.NodeIdState )
addCtorArgsWithIdsProg region ctorName freeVarDict state nodeState args =
    case args of
        [] ->
            pPure ( state, nodeState )

        (Can.PatternCtorArg index srcType pattern) :: rest ->
            pFromSrcType freeVarDict srcType
                |> pAndThen
                    (\tipe ->
                        let
                            expectation : E.PExpected Type
                            expectation =
                                E.PFromContext region (E.PCtorArg ctorName index) tipe
                        in
                        pAddPatternWithIds pattern expectation state nodeState
                            |> pAndThen
                                (\( newState, newNodeState ) ->
                                    addCtorArgsWithIdsProg region ctorName freeVarDict newState newNodeState rest
                                )
                    )



-- STATE HELPERS


{-| Initial empty state for pattern constraint generation.

Contains no variable bindings, no type variables, and no constraints.

-}
emptyState : State
emptyState =
    State Dict.empty [] []


addToHeaders : A.Region -> Name.Name -> E.PExpected Type -> State -> State
addToHeaders region name expectation (State headers vars revCons) =
    let
        tipe : Type
        tipe =
            getType expectation

        newHeaders : Dict String Name.Name (A.Located Type)
        newHeaders =
            Dict.insert identity name (A.At region tipe) headers
    in
    State newHeaders vars revCons


getType : E.PExpected Type -> Type
getType expectation =
    case expectation of
        E.PNoExpectation tipe ->
            tipe

        E.PFromContext _ _ tipe ->
            tipe
