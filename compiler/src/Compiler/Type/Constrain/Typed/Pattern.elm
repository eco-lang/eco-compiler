module Compiler.Type.Constrain.Typed.Pattern exposing (addWithIds)

{-| Type constraint generation for pattern matching (Typed pathway).

This module generates type constraints for patterns while also tracking node IDs
to solver variables (via `NodeIds`, whose state lives in `IO.State`), enabling
later retrieval of pattern types from the solver.

The generator is written as ordinary recursive `IO` functions (Design B).
Stack safety relies on the axis classification below: the only pattern axis
whose nesting depth is unbounded in practice is walked with an explicit
`IO.loop` spine; everything else recurses directly on the JS stack.


## Pattern axis classification (the stack-safety argument)

Linear-unbounded (spine loop required):

  - `PCons` tail chains — `a :: b :: c :: ... :: t` nests `PCons` down the
    tail one level per element, so machine-generated patterns can nest
    arbitrarily deep. Walked by `addConsWithIds` (explicit `IO.loop` descent
    over the tail spine, heads constrained on the fold-up).

Bounded (direct recursion OK):

  - `PCtor` / `PTuple` / `PList` / `PRecord` — children are width-bounded
    argument/element/field lists; each child's own depth is again one of the
    classified axes.
  - `PAlias` — alias chains (`(p as a) as b`) require explicit parentheses
    per level, so their depth is bounded by written source, not data size.
  - `PAnything`, `PVar`, `PUnit`, `PInt`, `PStr`, `PChr`, `PBool` — leaves.


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
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



-- ===== PUBLIC API =====


{-| Generate type constraints for a pattern, tracking node IDs.

Like the erased `add` but also tracks pattern node IDs to solver variables
(in `IO.State`), enabling later retrieval of pattern types from the solver.

IMPORTANT: This function matches `add` in constraint generation behavior.
For patterns that don't need constraints (PAnything, PVar, PAlias), we do NOT
add extra CPattern constraints or flex variables to the state. We only record
the pattern's type variable in NodeIds for later type retrieval.

-}
addWithIds : Can.Pattern -> E.PExpected Type -> State -> IO State
addWithIds (A.At region patternInfo) expectation state =
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
                    in
                    -- record ID → variable mapping, then generate the pattern constraints
                    NodeIds.recordNodeVar patternInfo.id patVar
                        |> IO.andThen
                            (\() -> addHelpWithIds region patternInfo.node expectation stateWithPatVar)
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
                NodeIds.recordNodeVar patternInfo.id existingVar
                    |> IO.andThen
                        (\() -> addHelpWithIds region patternInfo.node expectation state)

            Nothing ->
                -- Concrete type path: expectedType is a concrete type (e.g., AppN "Int")
                -- rather than a VarN that we could directly record.
                -- Create a fresh variable and constrain it to equal the expected type.
                Type.mkFlexVar
                    |> IO.andThen
                        (\patVar ->
                            let
                                patType : Type
                                patType =
                                    Type.VarN patVar

                                -- Constrain patVar to equal the expected type
                                eqCon : Type.Constraint
                                eqCon =
                                    Type.CPattern region (patternToCategory patternInfo.node) patType expectation

                                -- Add the variable and constraint to state
                                (State headers vars revCons) =
                                    state

                                stateWithConstraint : State
                                stateWithConstraint =
                                    State headers (patVar :: vars) (eqCon :: revCons)
                            in
                            NodeIds.recordNodeVar patternInfo.id patVar
                                |> IO.andThen
                                    (\() -> addHelpWithIds region patternInfo.node expectation stateWithConstraint)
                        )


addHelpWithIds : A.Region -> Can.Pattern_ -> E.PExpected Type -> State -> IO State
addHelpWithIds region patternNode expectation state =
    case patternNode of
        Can.PAnything ->
            IO.pure state

        Can.PVar name ->
            IO.pure (Common.addToHeaders region name expectation state)

        Can.PAlias realPattern name ->
            addWithIds realPattern expectation (Common.addToHeaders region name expectation state)

        Can.PUnit ->
            let
                (State headers vars revCons) =
                    state

                unitCon : Type.Constraint
                unitCon =
                    Type.CPattern region E.PUnit Type.UnitN expectation
            in
            IO.pure (State headers vars (unitCon :: revCons))

        Can.PTuple a b cs ->
            addTupleWithIds region a b cs expectation state

        Can.PCtor { home, type_, union, name, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            addCtorWithIds region home type_ unionData.vars name args expectation state

        Can.PList patterns ->
            Type.mkFlexVar
                |> IO.andThen
                    (\entryVar ->
                        let
                            entryType : Type
                            entryType =
                                Type.VarN entryVar

                            listType : Type
                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]
                        in
                        addListEntriesWithIds region entryType Index.first patterns state
                            |> IO.map
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
            addConsWithIds region headPattern tailPattern expectation state

        Can.PRecord fields ->
            Type.mkFlexVar
                |> IO.andThen
                    (\extVar ->
                        let
                            extType : Type
                            extType =
                                Type.VarN extVar
                        in
                        IO.traverseList (\field -> IO.map (Tuple.pair field) Type.mkFlexVar) fields
                            |> IO.map
                                (\fieldVars ->
                                    let
                                        fieldTypes : Dict Name.Name Type
                                        fieldTypes =
                                            Dict.fromList (List.map (Tuple.mapSecond Type.VarN) fieldVars)

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
            IO.pure (State headers vars (intCon :: revCons))

        Can.PStr _ _ ->
            let
                (State headers vars revCons) =
                    state

                strCon : Type.Constraint
                strCon =
                    Type.CPattern region E.PStr Type.string expectation
            in
            IO.pure (State headers vars (strCon :: revCons))

        Can.PChr _ ->
            let
                (State headers vars revCons) =
                    state

                chrCon : Type.Constraint
                chrCon =
                    Type.CPattern region E.PChr Type.char expectation
            in
            IO.pure (State headers vars (chrCon :: revCons))

        Can.PBool _ _ ->
            let
                (State headers vars revCons) =
                    state

                boolCon : Type.Constraint
                boolCon =
                    Type.CPattern region E.PBool Type.bool expectation
            in
            IO.pure (State headers vars (boolCon :: revCons))



-- ===== CONS SPINE LOOP =====


{-| One deferred level of a `::`-chain: everything needed to constrain the
head pattern and close the level once the deeper tail is done.
-}
type alias ConsFrame =
    { entryVar : IO.Variable
    , entryType : Type
    , listType : Type
    , region : A.Region
    , headPattern : Can.Pattern
    , expectation : E.PExpected Type
    }


{-| Walk a `PCons` tail chain iteratively (constant JS stack).

Descend: at each cons level allocate the entry var, push a frame with the
head pattern, and — when the tail is itself a cons — inline the constrained
wrapper prefix (`patVar` + `CPattern` + record) that `addWithIds` would have
applied to it, then continue down the tail. The first non-cons tail is
constrained via the ordinary re-entrant `addWithIds`.

Fold up: constrain each level's head pattern (innermost first) and extend the
state with that level's entry var and list constraint — exactly the wrap the
recursive arm performed.

The IO operation order (var allocations, recordings) is identical to the
recursive formulation's.

-}
addConsWithIds : A.Region -> Can.Pattern -> Can.Pattern -> E.PExpected Type -> State -> IO State
addConsWithIds region headPattern tailPattern expectation state s0 =
    -- A5: direct self-tail-recursive spine (TCO → while-loop; stack-safe) replacing
    -- the `IO.loop`/`Step` trampoline. The PCons arm ends in a DIRECT self-tail-call
    -- of `consSpineGo`. Byte-identical var-alloc/recording order sans trampoline.
    let
        ( s1, ( finalState, frames ) ) =
            consSpineGo region headPattern tailPattern expectation state [] s0
    in
    IO.foldM applyConsFrame finalState frames s1


consSpineGo : A.Region -> Can.Pattern -> Can.Pattern -> E.PExpected Type -> State -> List ConsFrame -> IO.State -> ( IO.State, ( State, List ConsFrame ) )
consSpineGo region headPattern tailPattern expectation state frames s0 =
    let
        ( s1, entryVar ) =
            Type.mkFlexVar s0

        entryType : Type
        entryType =
            Type.VarN entryVar

        listType : Type
        listType =
            Type.AppN ModuleName.list Name.list [ entryType ]

        tailExpectation : E.PExpected Type
        tailExpectation =
            E.PFromContext region E.PTail listType

        newFrames : List ConsFrame
        newFrames =
            { entryVar = entryVar
            , entryType = entryType
            , listType = listType
            , region = region
            , headPattern = headPattern
            , expectation = expectation
            }
                :: frames

        (A.At tailRegion tailInfo) =
            tailPattern
    in
    case tailInfo.node of
        Can.PCons nextHead nextTail ->
            -- The tail is another cons level: inline the constrained wrapper prefix
            -- addWithIds would apply (PCons always takes the constrained path), then
            -- keep descending via a self-tail-call.
            let
                ( s2, patVar ) =
                    Type.mkFlexVar s1

                eqCon : Type.Constraint
                eqCon =
                    Type.CPattern tailRegion (patternToCategory tailInfo.node) (Type.VarN patVar) tailExpectation

                (State headers vars revCons) =
                    state

                stateWithPatVar : State
                stateWithPatVar =
                    State headers (patVar :: vars) (eqCon :: revCons)

                ( s3, () ) =
                    NodeIds.recordNodeVar tailInfo.id patVar s2
            in
            consSpineGo tailRegion nextHead nextTail tailExpectation stateWithPatVar newFrames s3

        _ ->
            -- Non-cons tail: the spine ends here; constrain it normally.
            let
                ( s2, newState ) =
                    addWithIds tailPattern tailExpectation state s1
            in
            ( s2, ( newState, newFrames ) )


applyConsFrame : State -> ConsFrame -> IO State
applyConsFrame state frame =
    addWithIds frame.headPattern (E.PNoExpectation frame.entryType) state
        |> IO.map
            (\(State headers vars revCons) ->
                let
                    listCon : Type.Constraint
                    listCon =
                        Type.CPattern frame.region E.PList frame.listType frame.expectation
                in
                State headers (frame.entryVar :: vars) (listCon :: revCons)
            )



-- ===== BOUNDED HELPERS (direct recursion; width-bounded) =====


addListEntriesWithIds : A.Region -> Type -> Index.ZeroBased -> List Can.Pattern -> State -> IO State
addListEntriesWithIds region entryType index patterns state =
    case patterns of
        [] ->
            IO.pure state

        pattern :: rest ->
            let
                expectation : E.PExpected Type
                expectation =
                    E.PFromContext region (E.PListEntry index) entryType
            in
            addWithIds pattern expectation state
                |> IO.andThen (addListEntriesWithIds region entryType (Index.next index) rest)


addTupleWithIds : A.Region -> Can.Pattern -> Can.Pattern -> List Can.Pattern -> E.PExpected Type -> State -> IO State
addTupleWithIds region a b cs expectation state =
    Type.mkFlexVar
        |> IO.andThen
            (\aVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    Type.VarN aVar

                                bType : Type
                                bType =
                                    Type.VarN bVar
                            in
                            simpleAddWithIds a aType state
                                |> IO.andThen (\s1 -> simpleAddWithIds b bType s1)
                                |> IO.andThen
                                    (\s2 ->
                                        addTupleRestWithIds cs [] s2
                                            |> IO.map
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


addTupleRestWithIds : List Can.Pattern -> List IO.Variable -> State -> IO ( List IO.Variable, State )
addTupleRestWithIds cs accVars state =
    case cs of
        [] ->
            IO.pure ( List.reverse accVars, state )

        c :: rest ->
            Type.mkFlexVar
                |> IO.andThen
                    (\cVar ->
                        simpleAddWithIds c (Type.VarN cVar) state
                            |> IO.andThen (addTupleRestWithIds rest (cVar :: accVars))
                    )


simpleAddWithIds : Can.Pattern -> Type -> State -> IO State
simpleAddWithIds pattern patternType state =
    addWithIds pattern (E.PNoExpectation patternType) state


addCtorWithIds : A.Region -> IO.Canonical -> Name.Name -> List Name.Name -> Name.Name -> List Can.PatternCtorArg -> E.PExpected Type -> State -> IO State
addCtorWithIds region home typeName typeVarNames ctorName args expectation state =
    IO.traverseList (\name -> IO.map (Tuple.pair name) (Type.nameToFlex name)) typeVarNames
        |> IO.andThen
            (\varPairs ->
                let
                    typePairs : List ( Name.Name, Type )
                    typePairs =
                        List.map (Tuple.mapSecond Type.VarN) varPairs

                    freeVarDict : Dict Name.Name Type
                    freeVarDict =
                        Dict.fromList typePairs
                in
                addCtorArgsWithIds region ctorName freeVarDict args state
                    |> IO.map
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


addCtorArgsWithIds : A.Region -> Name.Name -> Dict Name.Name Type -> List Can.PatternCtorArg -> State -> IO State
addCtorArgsWithIds region ctorName freeVarDict args state =
    case args of
        [] ->
            IO.pure state

        (Can.PatternCtorArg index srcType pattern) :: rest ->
            Instantiate.fromSrcType freeVarDict srcType
                |> IO.andThen
                    (\tipe ->
                        let
                            expectation : E.PExpected Type
                            expectation =
                                E.PFromContext region (E.PCtorArg ctorName index) tipe
                        in
                        addWithIds pattern expectation state
                            |> IO.andThen (addCtorArgsWithIds region ctorName freeVarDict rest)
                    )
