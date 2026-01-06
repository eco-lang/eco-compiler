module Compiler.Type.Constrain.Erased.Pattern exposing (add)

{-| Type constraint generation for pattern matching (Erased pathway).

This module generates type constraints for patterns used in case expressions, function
arguments, let bindings, and destructuring assignments. Patterns introduce new variables
into scope and constrain their types based on the pattern structure (e.g., a list pattern
constrains the matched value to be a list).

Uses an internal PatternProg DSL for stack-safe constraint generation,
preventing stack overflow on deeply nested patterns.


# Constraint Generation

@docs add

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.Common as Common exposing (State(..))
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Type)
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)



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

        PTraverseList names k ->
            IO.traverseList (\name -> IO.map (Tuple.pair name) (Type.nameToFlex name)) names
                |> IO.map (\pairs -> IO.Loop (k pairs))



-- ===== PUBLIC API =====


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



-- ===== Pattern Constraint Generation using PatternProg DSL =====


{-| Build a pattern program for the given pattern.
-}
addProg : Can.Pattern -> E.PExpected Type -> State -> PatternProg State
addProg (A.At region patternInfo) expectation state =
    case patternInfo.node of
        Can.PAnything ->
            pPure state

        Can.PVar name ->
            pPure (Common.addToHeaders region name expectation state)

        Can.PAlias realPattern name ->
            pAddPattern realPattern expectation (Common.addToHeaders region name expectation state)

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
