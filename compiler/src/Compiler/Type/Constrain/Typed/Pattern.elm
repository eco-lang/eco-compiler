module Compiler.Type.Constrain.Typed.Pattern exposing (addWithIds)

{-| Type constraint generation for pattern matching (Typed pathway).

This module generates type constraints for patterns while also tracking node IDs
to solver variables, enabling later retrieval of pattern types from the solver.

Uses an internal PatternProg DSL for stack-safe constraint generation,
preventing stack overflow on deeply nested patterns.


# Constraint Generation with ID Tracking

@docs addWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.Common as Common exposing (State(..), extractVarFromType, getType, patternNeedsConstraint, patternToCategory)
import Compiler.Type.Constrain.Typed.NodeIds as NodeIds
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Type)
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



-- ===== PatternProg DSL =====
--
-- Internal DSL for stack-safe pattern constraint generation with ID tracking.


{-| Program representing pattern constraint generation steps.
-}
type PatternProg a
    = PDone a
    | PMkFlexVar (IO.Variable -> PatternProg a)
    | PFromSrcType (Dict String Name.Name Type) Can.Type (Type -> PatternProg a)
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


{-| Run a pattern program to produce an IO (State, NodeIdState).
-}
runPatternProgWithIds : PatternProg ( State, NodeIds.NodeIdState ) -> IO ( State, NodeIds.NodeIdState )
runPatternProgWithIds prog =
    IO.loop stepProgWithIds prog


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

        PAddPatternWithIds pat exp st ns k ->
            -- Recursive call - build new program and continue
            IO.pure (IO.Loop (addWithIdsProg pat exp st ns |> pAndThen k))

        PTraverseList names k ->
            IO.traverseList (\name -> IO.map (Tuple.pair name) (Type.nameToFlex name)) names
                |> IO.map (\pairs -> IO.Loop (k pairs))



-- ===== PUBLIC API =====


{-| Generate type constraints for a pattern, tracking node IDs.

Like the erased `add` but also tracks pattern node IDs to solver variables in the
NodeIdState, enabling later retrieval of pattern types from the solver.

IMPORTANT: This function matches `add` in constraint generation behavior.
For patterns that don't need constraints (PAnything, PVar, PAlias), we do NOT
add extra CPattern constraints or flex variables to the state. We only record
the pattern's type variable in NodeIds for later type retrieval.

Uses the stack-safe PatternProg DSL internally.

-}
addWithIds : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> IO ( State, NodeIds.NodeIdState )
addWithIds (A.At region patternInfo) expectation state nodeState0 =
    if patternNeedsConstraint patternInfo.node then
        -- CONSTRAINED path: create patVar, add CPattern constraint, add to state
        -- This matches the behavior of `add` for patterns like PUnit, PTuple, etc.
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

    else
        -- UNCONSTRAINED path: just record in NodeIds, no extra constraint or var in state
        -- This matches the behavior of `add` for PAnything, PVar, PAlias
        let
            -- Try to extract the variable directly from the expectation type
            -- For function args, expectation is typically PNoExpectation (VarN argVar)
            -- so we can record argVar directly - it will have the correct type after solving
            expectedType : Type
            expectedType =
                getType expectation
        in
        case extractVarFromType expectedType of
            Just existingVar ->
                -- Record the existing variable from expectation
                let
                    nodeState1 : NodeIds.NodeIdState
                    nodeState1 =
                        NodeIds.recordNodeVar patternInfo.id existingVar nodeState0
                in
                addHelpWithIdsProg region patternInfo.node expectation state nodeState1
                    |> runPatternProgWithIds

            Nothing ->
                -- Fallback: create a var just for NodeIds tracking (unconstrained)
                -- PostSolve will need to compute the type from context
                Type.mkFlexVar
                    |> IO.andThen
                        (\patVar ->
                            let
                                nodeState1 : NodeIds.NodeIdState
                                nodeState1 =
                                    NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                            in
                            -- Note: we do NOT add patVar to state.vars or add a constraint
                            addHelpWithIdsProg region patternInfo.node expectation state nodeState1
                                |> runPatternProgWithIds
                        )



-- ===== DSL version of addWithIds =====


{-| DSL version of addWithIds for recursive pattern processing.

Like addWithIds, this conditionally adds constraints only for patterns that
need them, matching the behavior of `add`/`addProg`.

-}
addWithIdsProg : Can.Pattern -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addWithIdsProg (A.At region patternInfo) expectation state nodeState0 =
    if patternNeedsConstraint patternInfo.node then
        -- CONSTRAINED path: create patVar, add CPattern constraint, add to state
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

    else
        -- UNCONSTRAINED path: just record in NodeIds, no extra constraint or var in state
        let
            expectedType : Type
            expectedType =
                getType expectation
        in
        case extractVarFromType expectedType of
            Just existingVar ->
                -- Record the existing variable from expectation
                let
                    nodeState1 : NodeIds.NodeIdState
                    nodeState1 =
                        NodeIds.recordNodeVar patternInfo.id existingVar nodeState0
                in
                addHelpWithIdsProg region patternInfo.node expectation state nodeState1

            Nothing ->
                -- Fallback: create a var just for NodeIds tracking (unconstrained)
                pMkFlexVar
                    |> pAndThen
                        (\patVar ->
                            let
                                nodeState1 : NodeIds.NodeIdState
                                nodeState1 =
                                    NodeIds.recordNodeVar patternInfo.id patVar nodeState0
                            in
                            -- Note: we do NOT add patVar to state.vars or add a constraint
                            addHelpWithIdsProg region patternInfo.node expectation state nodeState1
                        )


addHelpWithIdsProg : A.Region -> Can.Pattern_ -> E.PExpected Type -> State -> NodeIds.NodeIdState -> PatternProg ( State, NodeIds.NodeIdState )
addHelpWithIdsProg region patternNode expectation state nodeState =
    case patternNode of
        Can.PAnything ->
            pPure ( state, nodeState )

        Can.PVar name ->
            pPure ( Common.addToHeaders region name expectation state, nodeState )

        Can.PAlias realPattern name ->
            let
                state1 : State
                state1 =
                    Common.addToHeaders region name expectation state
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
