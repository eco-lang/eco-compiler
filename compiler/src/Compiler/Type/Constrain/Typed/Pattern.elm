module Compiler.Type.Constrain.Typed.Pattern exposing (addWithIds)

{-| Type inference must know what a pattern says about the value it matches
and which names it binds, and later stages must be able to read back the type
the solver found for each pattern node. This module produces both.

`addWithIds` walks a canonical pattern against an _expectation_, the type the
matched value is expected to have together with the context it came from, used
in error messages. It adds to a `Common.State`: the pattern's _header_ (the
names it binds, each with its type and region), the flexible type variables it
creates, and the `CPattern` constraints it emits. `Compiler.Type.Constrain.Common`
owns `State`; the constraints are held newest first. Alongside, it records in
`NodeIds` one solver variable for each pattern node id, which is how a pattern
node's type is found after solving. Whether anything is recorded is decided by
`NodeIds`.

Most patterns are walked by direct recursion, which is safe because their
nesting depth is bounded by what was written in the source: constructor, tuple,
list and record patterns have a written number of children, and an alias chain
such as `((p as a) as b)` needs parentheses at every level. A `::` chain is the
exception. `a :: b :: c :: t` nests one `PCons` per element down its tail, so
a pattern can nest as deeply as it has elements. That tail chain, the _cons
spine_, is walked by a self-tail-recursive function that builds a list of
_frames_ on the way down, one deferred level each, and the heads are
constrained as the frames are folded back up.


# Constraint Generation with ID Tracking

@docs addWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
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


{-| Returns `state` extended with what `pattern` binds, the variables it
creates and the constraints it imposes when matched against `expectation`, and
records a solver variable for the pattern's node id and for each node inside
it.

A pattern other than `_`, a variable or an alias gets a fresh variable, recorded
for its node, and a `CPattern` constraint tying that variable to `expectation`.
A `_`, variable or alias pattern adds no constraint of its own when the
expectation's type is a bare type variable: that variable is recorded for the
node instead. When the expectation's type is anything else, such a pattern too
gets a fresh variable and a `CPattern` constraint, reported under the `PRecord`
category that `Common.patternToCategory` gives it.

-}
addWithIds : Can.Pattern -> E.PExpected Type -> State -> IO State
addWithIds (A.At region patternInfo) expectation state =
    if patternNeedsConstraint patternInfo.node then
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

                        (State headers vars revCons) =
                            state

                        stateWithPatVar : State
                        stateWithPatVar =
                            State headers (patVar :: vars) (eqCon :: revCons)
                    in
                    NodeIds.recordNodeVar patternInfo.id patVar
                        |> IO.andThen
                            (\() -> addHelpWithIds region patternInfo.node expectation stateWithPatVar)
                )

    else
        let
            expectedType : Type
            expectedType =
                getType expectation
        in
        case extractVarFromType expectedType of
            Just existingVar ->
                NodeIds.recordNodeVar patternInfo.id existingVar
                    |> IO.andThen
                        (\() -> addHelpWithIds region patternInfo.node expectation state)

            Nothing ->
                -- No variable to record: make one and tie it to the expected type.
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


{-| Returns `state` extended with what the pattern node `patternNode`, found at
`region`, binds and imposes when matched against `expectation`, recursing into
its children.

This covers the node's own kind only; the variable and `CPattern` that
`addWithIds` adds for the node as a whole are added there. A variable or alias
binds its name to the expectation's type. A literal or `()` is constrained to
its built-in type. A list pattern gets one fresh entry variable that every
element is checked against. A record pattern binds each field name to a fresh
variable, located at the whole record pattern, and has a fresh extension
variable, so it matches any record with at least those fields.

-}
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


{-| One deferred level of a cons spine: what is needed to constrain the
level's head pattern and add its list constraint once the deeper tail is done.

`expectation` is the one the level itself was matched against.

-}
type alias ConsFrame =
    { entryVar : Vars.Variable
    , entryType : Type
    , listType : Type
    , region : A.Region
    , headPattern : Can.Pattern
    , expectation : E.PExpected Type
    }


{-| Returns `state` extended with what the cons pattern `headPattern :: tailPattern`
at `region` binds and imposes when matched against `expectation`, using
constant stack depth however long the `::` chain is.

Each level gets a fresh element variable and is constrained to be a list of it,
with the head expected to have the element type and the tail, under a `PTail`
context, the list type. On the way down, every tail that is itself a cons gets
the fresh variable, `CPattern` and node recording that `addWithIds` gives a
constrained pattern. The first tail that is not a cons is walked by
`addWithIds`. The heads are then walked innermost first, each level adding its
element variable and list constraint after its head.

-}
addConsWithIds : A.Region -> Can.Pattern -> Can.Pattern -> E.PExpected Type -> State -> IO State
addConsWithIds region headPattern tailPattern expectation state s0 =
    let
        ( s1, ( finalState, frames ) ) =
            consSpineGo region headPattern tailPattern expectation state [] s0
    in
    IO.foldM applyConsFrame finalState frames s1


{-| Returns, threading the `IO.State` by hand, the pattern state after the
descent of a cons spine together with the frames still to be applied, innermost
first.

`frames` holds the levels already passed. The function calls itself only in
tail position, so Elm compiles it to a loop.

-}
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
            -- What addWithIds would add for this constrained tail node, done here
            -- so the descent stays a tail call.
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
            let
                ( s2, newState ) =
                    addWithIds tailPattern tailExpectation state s1
            in
            ( s2, ( newState, newFrames ) )


{-| Returns `state` extended with the head pattern of `frame`, expected to have
the element type, then with the frame's element variable and the constraint
that the level is a list matching the frame's expectation.
-}
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


{-| Returns `state` extended with each of `patterns`, every one expected to have
`entryType` under a `PListEntry` context numbered from `index`.
-}
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


{-| Returns `state` extended with the tuple pattern of `a`, `b` and the further
elements `cs`, each element checked against its own fresh variable, and with the
constraint that the tuple of those variables matches `expectation`.
-}
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


{-| Returns the fresh variables made for the tuple elements `cs`, in element
order after any in `accVars`, with `state` extended by those elements.

`accVars` holds the variables already made, newest first.

-}
addTupleRestWithIds : List Can.Pattern -> List Vars.Variable -> State -> IO ( List Vars.Variable, State )
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


{-| Returns `state` extended with `pattern` expected to have `patternType`, with
no context for error messages.
-}
simpleAddWithIds : Can.Pattern -> Type -> State -> IO State
simpleAddWithIds pattern patternType state =
    addWithIds pattern (E.PNoExpectation patternType) state


{-| Returns `state` extended with a constructor pattern: its arguments `args`,
and the constraint that the union type `typeName` from module `home`, applied
to fresh variables for its parameters `typeVarNames`, matches `expectation`.

The same parameter variables are used for every argument's declared type, so
two arguments that share a type parameter get the same type.

-}
addCtorWithIds : A.Region -> ModuleName.Canonical -> Name.Name -> List Name.Name -> Name.Name -> List Can.PatternCtorArg -> E.PExpected Type -> State -> IO State
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


{-| Returns `state` extended with each constructor argument pattern, expected to
have its declared type with the union's parameters replaced from `freeVarDict`,
under a `PCtorArg` context naming `ctorName` and the argument's index.
-}
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
