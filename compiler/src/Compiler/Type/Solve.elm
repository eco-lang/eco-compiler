module Compiler.Type.Solve exposing (run, runWithIds)

{-| Type checking a module produces a tree of constraints, and this module
solves that tree: it decides whether all of them can hold at once and, if they
can, what type each top-level name has.

The constraints and the types they mention are described in
`Compiler.Type.Type`; a type variable is a point of the union-find store, and
two variables are made equal by `Compiler.Type.Unify`. The solver walks the
tree in order. Each equality constraint is turned into two variables, the
actual type and the expected one, which are then unified. A failed
unification does not stop the walk: its error is recorded and solving goes on,
so one run reports every error it finds. Errors are kept newest first.

What makes this more than a sequence of unifications is let-polymorphism. A
name bound by a `let` can be used at several types, so once its definition is
solved its type is _generalized_: the variables that belong to that definition
alone become placeholders, and every use of the name works on a fresh copy of
them (an _instantiation_, `makeCopy`).

Deciding which variables belong to a definition alone is what ranks are for. A
variable's _rank_ is the let-nesting depth it was made at, as
`Compiler.Type.Type` describes. The variables made at each rank are listed in
that rank's _pool_. When a `let` that generalizes is solved, its definitions
are solved one rank deeper, in the _young_ pool. Afterwards each young
variable's rank is set to the highest rank among the variables its type
reaches (`generalize`, `adjustRank`). A variable still at the young rank
mentions nothing from an enclosing scope and is generalized by being given
`Type.noRank`; one whose rank was lowered moves to the pool of that rank.
Rigid variables, the ones an annotation names, must all generalize; one that
does not is a compiler bug and crashes the solve.

After a `let` body is solved, each name the `let` bound is checked for an
infinite type (`occurs`), which is reported as an error.

The result is the environment of names captured where the tree says
`CSaveTheEnvironment`, each converted to an annotation.


# Solving

@docs run, runWithIds

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars exposing (Content, Descriptor, Mark, Variable)
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as Doc
import Compiler.Reporting.Error.Type as Error
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Type.Error as ET
import Compiler.Type.Occurs as Occurs
import Compiler.Type.Type as Type exposing (Constraint(..), Type, nextMark)
import Compiler.Type.Unify as Unify
import Compiler.Type.UnionFind as UF
import Data.IORef exposing (IORef)
import Data.Vector as Vector
import Data.Vector.Mutable as MVector
import Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== Solver Entry Point ======


{-| Solves `constraint` and returns either every type error found, newest
first, or the annotation of each name in the environment saved at
`CSaveTheEnvironment`.

Names bound by a `let` are not in that environment unless the saved point is
inside the `let`. With no `CSaveTheEnvironment` in the tree the annotations are
empty.

-}
run : Constraint -> IO (Result (NE.Nonempty Error.Error) (Dict Name.Name (Can.Annotation Name)))
run constraint =
    MVector.replicate 8 []
        |> IO.andThen
            (\pools ->
                solve Dict.empty Type.outermostRank pools emptyState constraint
                    |> IO.andThen
                        (\(State env _ errors) ->
                            case errors of
                                [] ->
                                    traverseDictIO Type.toAnnotation env
                                        |> IO.map Ok

                                e :: es ->
                                    IO.pure (Err (NE.Nonempty e es))
                        )
            )


{-| Solves `constraint` as `run` does and, on success, also returns the solved
type of each node.

`nodeVars` holds, for each node id, the solver variable recorded for that node,
if any. `nodeTypes` is the same array with each variable converted to a
`Can.Type`, all in one naming scope that avoids the names the annotations use
(`Type.toCanTypeBatch`). `annotationVars` holds the saved environment's
variables themselves, and `nodeVars` is returned unchanged.

`solverState.cells` is the store's point cells as they are at the end, after
the conversions, which write generated names into the store.

-}
runWithIds :
    Constraint
    -> Array (Maybe Variable)
    ->
        IO
            (Result
                (NE.Nonempty Error.Error)
                { annotations : Dict Name.Name (Can.Annotation Name)
                , annotationVars : Dict Name.Name Variable
                , nodeTypes : Array (Maybe (Can.Type Name))
                , nodeVars : Array (Maybe Variable)
                , solverState :
                    { cells : Array Vars.PointCell
                    }
                }
            )
runWithIds constraint nodeVars =
    MVector.replicate 8 []
        |> IO.andThen
            (\pools ->
                solve Dict.empty Type.outermostRank pools emptyState constraint
                    |> IO.andThen
                        (\(State env _ errors) ->
                            case errors of
                                [] ->
                                    traverseDictIO Type.toAnnotation env
                                        |> IO.andThen
                                            (\annotations ->
                                                Type.toCanTypeBatch (annotationVarNames annotations) nodeVars
                                                    |> IO.andThen
                                                        (\nodeTypes ->
                                                            \s ->
                                                                ( s
                                                                , Ok
                                                                    { annotations = annotations
                                                                    , annotationVars = env
                                                                    , nodeTypes = nodeTypes
                                                                    , nodeVars = nodeVars
                                                                    , solverState =
                                                                        { cells = s.ioRefsPoint
                                                                        }
                                                                    }
                                                                )
                                                        )
                                            )

                                e :: es ->
                                    IO.pure (Err (NE.Nonempty e es))
                        )
            )


{-| The state a solve starts from: an empty saved environment, no errors, and
the first mark after `Type.noMark`.
-}
emptyState : State
emptyState =
    State Dict.empty (Type.nextMark Type.noMark) []



-- ====== Solver State ======


{-| The names in scope, each with the variable holding its type. For a
generalized name that variable is the scheme a use copies.
-}
type alias Env =
    Dict Name.Name Variable


{-| The pools, one per rank, indexed by rank: the variables made or introduced
at each rank, which generalization at that rank examines.

It is a mutable vector, so every holder sees a change. It starts with 8 ranks
and is grown when a `let` nests deeper.

-}
type alias Pools =
    IORef (Array (Maybe (List Variable)))


{-| What a solve carries from one constraint to the next: the environment last
saved by `CSaveTheEnvironment`, the next unused mark, and the errors so far,
newest first.
-}
type State
    = State Env Mark (List Error.Error)



-- ====== Main Solver ======


{-| Solves `constraint` with `env` in scope at `rank`, and returns the state
after it.
-}
solve : Env -> Int -> Pools -> State -> Constraint -> IO State
solve env rank pools state constraint =
    solveGo env rank pools state constraint identity


{-| Solves `constraint` and passes the resulting state through `cont`, the work
still to do once it is solved.

It is written as direct self-tail-recursion so that it compiles to a loop: the
body of a `let` is solved by a tail call, with the occurs checks on the `let`'s
names added to `cont`, so a long chain of nested `let`s does not deepen the
stack.

A `CLet` takes one of three forms. With no rigids and a body of `CTrue`, its
flexible variables are introduced at the current rank and its header is
ignored. With no variables at all, the header is solved and its names bound at
the current rank, with no generalization. Otherwise the header is solved one
rank deeper and generalized, as the module docstring describes.

-}
solveGo : Env -> Int -> Pools -> State -> Constraint -> (IO State -> IO State) -> IO.State -> ( IO.State, State )
solveGo env rank pools ((State _ sMark sErrors) as state) constraint cont s0 =
    case constraint of
        CTrue ->
            (IO.pure state |> cont) s0

        CSaveTheEnvironment ->
            (IO.pure (State env sMark sErrors) |> cont) s0

        CEqual region category tipe expectation ->
            (typeToVariable rank pools tipe
                |> IO.andThen
                    (\actual ->
                        expectedToVariable rank pools expectation
                            |> IO.andThen
                                (\expected ->
                                    Unify.unify actual expected
                                        |> IO.andThen
                                            (\answer ->
                                                case answer of
                                                    Unify.AnswerOk vars ->
                                                        introduce rank pools vars
                                                            |> IO.andThen (\_ -> IO.pure state |> cont)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region category actualType |> addError state |> IO.pure |> cont
                                                                )
                                            )
                                )
                    )
            )
                s0

        CLocal region name expectation ->
            (makeCopy rank pools (Utils.dictFind name env)
                |> IO.andThen
                    (\actual ->
                        expectedToVariable rank pools expectation
                            |> IO.andThen
                                (\expected ->
                                    Unify.unify actual expected
                                        |> IO.andThen
                                            (\answer ->
                                                case answer of
                                                    Unify.AnswerOk vars ->
                                                        introduce rank pools vars
                                                            |> IO.andThen (\_ -> IO.pure state |> cont)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region (Error.Local name) actualType |> addError state |> IO.pure |> cont
                                                                )
                                            )
                                )
                    )
            )
                s0

        CForeign region name (Can.Forall freeVars srcType) expectation ->
            (srcTypeToVariable rank pools freeVars srcType
                |> IO.andThen
                    (\actual ->
                        expectedToVariable rank pools expectation
                            |> IO.andThen
                                (\expected ->
                                    Unify.unify actual expected
                                        |> IO.andThen
                                            (\answer ->
                                                case answer of
                                                    Unify.AnswerOk vars ->
                                                        introduce rank pools vars
                                                            |> IO.andThen (\_ -> IO.pure state |> cont)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region (Error.Foreign name) actualType |> addError state |> IO.pure |> cont
                                                                )
                                            )
                                )
                    )
            )
                s0

        CPattern region category tipe expectation ->
            (typeToVariable rank pools tipe
                |> IO.andThen
                    (\actual ->
                        patternExpectationToVariable rank pools expectation
                            |> IO.andThen
                                (\expected ->
                                    Unify.unify actual expected
                                        |> IO.andThen
                                            (\answer ->
                                                case answer of
                                                    Unify.AnswerOk vars ->
                                                        introduce rank pools vars
                                                            |> IO.andThen (\_ -> IO.pure state |> cont)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.BadPattern region
                                                                        category
                                                                        actualType
                                                                        (Error.ptypeReplace expectation expectedType)
                                                                        |> addError state
                                                                        |> IO.pure
                                                                        |> cont
                                                                )
                                            )
                                )
                    )
            )
                s0

        CAnd constraints ->
            (IO.foldM (solve env rank pools) state constraints |> cont) s0

        CLet [] flexs _ headerCon CTrue ->
            let
                ( s1, _ ) =
                    introduce rank pools flexs s0
            in
            solveGo env rank pools state headerCon cont s1

        CLet [] [] header headerCon subCon ->
            let
                ( s1, state1 ) =
                    solve env rank pools state headerCon s0

                ( s2, locals ) =
                    traverseDictIO (A.traverse (typeToVariable rank pools)) header s1

                newEnv : Env
                newEnv =
                    Dict.union env (Dict.map (\_ -> A.toValue) locals)

                newCont : IO State -> IO State
                newCont =
                    IO.andThen (\state2 -> IO.foldM occurs state2 (Dict.toList locals)) >> cont
            in
            solveGo newEnv rank pools state1 subCon newCont s2

        CLet rigids flexs header headerCon subCon ->
            let
                nextRank : Int
                nextRank =
                    rank + 1

                ( s1, poolsLength ) =
                    MVector.length pools s0

                ( s2, nextPools ) =
                    (if nextRank < poolsLength then
                        IO.pure pools

                     else
                        MVector.grow pools poolsLength
                    )
                        s1

                vars : List Variable
                vars =
                    rigids ++ flexs

                ( s3, _ ) =
                    IO.forM_ vars
                        (\var ->
                            UF.modify var <|
                                \props ->
                                    IO.makeDescriptor props.content nextRank props.mark props.copy
                        )
                        s2

                ( s4, _ ) =
                    MVector.write nextPools nextRank vars s3

                ( s5, locals ) =
                    traverseDictIO (A.traverse (typeToVariable nextRank nextPools)) header s4

                ( s6, State savedEnv mark errors ) =
                    solve env nextRank nextPools state headerCon s5

                youngMark : Mark
                youngMark =
                    mark

                visitMark : Mark
                visitMark =
                    nextMark youngMark

                finalMark : Mark
                finalMark =
                    nextMark visitMark

                ( s7, _ ) =
                    generalize youngMark visitMark nextRank nextPools s6

                ( s8, _ ) =
                    MVector.write nextPools nextRank [] s7

                ( s9, _ ) =
                    IO.mapM_ isGeneric rigids s8

                newEnv : Env
                newEnv =
                    Dict.union env (Dict.map (\_ -> A.toValue) locals)

                tempState : State
                tempState =
                    State savedEnv finalMark errors

                newCont : IO State -> IO State
                newCont =
                    IO.andThen (\newState -> IO.foldM occurs newState (Dict.toList locals)) >> cont
            in
            solveGo newEnv rank nextPools tempState subCon newCont s9


{-| Checks that `var` was generalized, that is has `Type.noRank`, and crashes
with a compiler bug report showing its type and rank if it was not.
-}
isGeneric : Variable -> IO ()
isGeneric var =
    UF.get var
        |> IO.andThen
            (\props ->
                if props.rank == Type.noRank then
                    IO.pure ()

                else
                    Type.toErrorType var
                        |> IO.andThen
                            (\tipe ->
                                crash <|
                                    "You ran into a compiler bug. Here are some details for the developers:\n\n"
                                        ++ "    "
                                        ++ Doc.toString (ET.toDoc L.empty RT.None tipe)
                                        ++ " [rank = "
                                        ++ String.fromInt props.rank
                                        ++ "]\n\n"
                                        ++ "Please create an <http://sscce.org/> and then report it\nat <https://github.com/elm/compiler/issues>\n\n"
                            )
            )



-- ====== Expectations to Variables ======


{-| Returns a variable for the type `expectation` expects, made at `rank`.
-}
expectedToVariable : Int -> Pools -> Error.Expected Type -> IO Variable
expectedToVariable rank pools expectation =
    typeToVariable rank pools <|
        case expectation of
            Error.NoExpectation tipe ->
                tipe

            Error.FromContext _ _ tipe ->
                tipe

            Error.FromAnnotation _ _ _ tipe ->
                tipe


{-| Returns a variable for the type a pattern expectation expects, made at
`rank`.
-}
patternExpectationToVariable : Int -> Pools -> Error.PExpected Type -> IO Variable
patternExpectationToVariable rank pools expectation =
    typeToVariable rank pools <|
        case expectation of
            Error.PNoExpectation tipe ->
                tipe

            Error.PFromContext _ _ tipe ->
                tipe



-- ====== Error Helpers ======


{-| Returns the state with `err` added at the front of its errors.
-}
addError : State -> Error.Error -> State
addError (State savedEnv rank errors) err =
    State savedEnv rank (err :: errors)



-- ====== Occurs Check ======


{-| Checks whether the type of the bound name `name` contains itself. If it
does, returns the state with an `InfiniteType` error added and the variable's
content set to `Error`; otherwise returns the state unchanged.
-}
occurs : State -> ( Name.Name, A.Located Variable ) -> IO State
occurs state ( name, A.At region variable ) =
    Occurs.occurs variable
        |> IO.andThen
            (\hasOccurred ->
                if hasOccurred then
                    Type.toErrorType variable
                        |> IO.andThen
                            (\errorType ->
                                UF.get variable
                                    |> IO.andThen
                                        (\props ->
                                            UF.set variable (IO.makeDescriptor Vars.Error props.rank props.mark props.copy)
                                                |> IO.map (\_ -> addError state (Error.InfiniteType region name errorType))
                                        )
                            )

                else
                    IO.pure state
            )



-- ====== Generalize ======


{-| Generalizes the young pool, the pool at `youngRank`, once a `let`'s header
has been solved.

Every young variable's rank is first set to the highest rank among the
variables its type reaches (`adjustRank`). A variable left at
`youngRank` is given `Type.noRank`; any other is added to the pool of its new
rank. A variable that is no longer the root of its class is dropped. The young
pool itself is not cleared here.

`youngMark` is the mark the young variables are stamped with first, and
`visitMark` the one a variable is stamped with once its rank is settled.

-}
generalize : Mark -> Mark -> Int -> Pools -> IO ()
generalize youngMark visitMark youngRank pools =
    MVector.read pools youngRank
        |> IO.andThen
            (\youngVars ->
                poolToRankTable youngMark youngRank youngVars
                    |> IO.andThen
                        (\rankTable ->
                            -- Low ranks first, so that one pass settles every rank.
                            Vector.imapM_
                                (\rank table ->
                                    IO.mapM_ (adjustRank youngMark visitMark rank) table
                                )
                                rankTable
                                |> IO.andThen
                                    (\_ ->
                                        Vector.forM_ (Vector.unsafeInit rankTable)
                                            (\vars ->
                                                IO.forM_ vars
                                                    (\var ->
                                                        UF.redundant var
                                                            |> IO.andThen
                                                                (\isRedundant ->
                                                                    if isRedundant then
                                                                        IO.pure ()

                                                                    else
                                                                        UF.get var
                                                                            |> IO.andThen
                                                                                (\props ->
                                                                                    MVector.modify pools ((::) var) props.rank
                                                                                )
                                                                )
                                                    )
                                            )
                                            |> IO.andThen
                                                (\_ ->
                                                    -- Variables bucketed at youngRank may have been lowered since.
                                                    Vector.unsafeLast rankTable
                                                        |> IO.andThen
                                                            (\lastRankTable ->
                                                                IO.forM_ lastRankTable <|
                                                                    \var ->
                                                                        UF.redundant var
                                                                            |> IO.andThen
                                                                                (\isRedundant ->
                                                                                    if isRedundant then
                                                                                        IO.pure ()

                                                                                    else
                                                                                        UF.get var
                                                                                            |> IO.andThen
                                                                                                (\props ->
                                                                                                    if props.rank < youngRank then
                                                                                                        MVector.modify pools ((::) var) props.rank

                                                                                                    else
                                                                                                        IO.makeDescriptor props.content Type.noRank props.mark props.copy |> UF.set var
                                                                                                )
                                                                                )
                                                            )
                                                )
                                    )
                        )
            )


{-| Returns the variables of the young pool in buckets by rank, from 0 to
`youngRank`, and stamps each with `youngMark`.
-}
poolToRankTable : Mark -> Int -> List Variable -> IO (IORef (Array (Maybe (List Variable))))
poolToRankTable youngMark youngRank youngInhabitants =
    MVector.replicate (youngRank + 1) []
        |> IO.andThen
            (\mutableTable ->
                IO.forM_ youngInhabitants
                    (\var ->
                        UF.get var
                            |> IO.andThen
                                (\props ->
                                    UF.set var (IO.makeDescriptor props.content props.rank youngMark props.copy)
                                        |> IO.andThen
                                            (\_ ->
                                                MVector.modify mutableTable ((::) var) props.rank
                                            )
                                )
                    )
                    |> IO.andThen (\_ -> Vector.unsafeFreeze mutableTable)
            )



-- ====== Adjust Rank ======


{-| Settles the rank of `var` and returns it.

A young variable not yet visited gets the highest rank among the variables its
content reaches, where a variable with no structure counts as `groupRank`. A
variable already visited keeps its rank. Any other variable, one from an
enclosing scope, gets the lower of its rank and `groupRank`.

-}
adjustRank : Mark -> Mark -> Int -> Variable -> IO Int
adjustRank youngMark visitMark groupRank var =
    UF.get var
        |> IO.andThen
            (\props ->
                if props.mark == youngMark then
                    -- Set the variable as marked first because it may be cyclic.
                    UF.set var (IO.makeDescriptor props.content props.rank visitMark props.copy)
                        |> IO.andThen
                            (\_ ->
                                adjustRankContent youngMark visitMark groupRank props.content
                                    |> IO.andThen
                                        (\maxRank ->
                                            UF.set var (IO.makeDescriptor props.content maxRank visitMark props.copy)
                                                |> IO.map (\_ -> maxRank)
                                        )
                            )

                else if props.mark == visitMark then
                    IO.pure props.rank

                else
                    let
                        minRank : Int
                        minRank =
                            min groupRank props.rank
                    in
                    UF.set var (IO.makeDescriptor props.content minRank visitMark props.copy)
                        |> IO.map (\_ -> minRank)
            )


{-| Settles the ranks of the variables `content` reaches and returns the
highest, or `groupRank` for content with no structure.

A ground structure, such as `()`, an empty record or a lambda set, is
`Type.outermostRank`. An alias counts only its arguments.

-}
adjustRankContent : Mark -> Mark -> Int -> Content -> IO Int
adjustRankContent youngMark visitMark groupRank content =
    let
        go : Variable -> IO Int
        go =
            adjustRank youngMark visitMark groupRank
    in
    case content of
        Vars.FlexVar _ ->
            IO.pure groupRank

        Vars.FlexSuper _ _ ->
            IO.pure groupRank

        Vars.RigidVar _ ->
            IO.pure groupRank

        Vars.RigidSuper _ _ ->
            IO.pure groupRank

        Vars.Structure flatType ->
            case flatType of
                Vars.App1 _ _ args ->
                    IO.foldM (\rank arg -> IO.map (max rank) (go arg)) Type.outermostRank args

                Vars.Fun1 arg result ->
                    IO.pure max
                        |> IO.apply (go arg)
                        |> IO.apply (go result)

                Vars.FunL arg result setSlot ->
                    IO.pure max
                        |> IO.apply (go arg)
                        |> IO.apply (IO.pure max |> IO.apply (go result) |> IO.apply (go setSlot))

                Vars.LambdaSet1 _ ->
                    -- Ground member ids: nothing to generalize.
                    IO.pure Type.outermostRank

                Vars.EmptyRecord1 ->
                    -- THEORY: an empty record never needs to get generalized
                    IO.pure Type.outermostRank

                Vars.Record1 fields extension ->
                    go extension
                        |> IO.andThen
                            (\extRank ->
                                IO.foldM (\rank field -> IO.map (max rank) (go field)) extRank (Dict.values fields)
                            )

                Vars.Unit1 ->
                    -- THEORY: a unit never needs to get generalized
                    IO.pure Type.outermostRank

                Vars.Tuple1 a b cs ->
                    go a
                        |> IO.andThen
                            (\ma ->
                                go b
                                    |> IO.andThen
                                        (\mb ->
                                            IO.foldM (\rank -> go >> IO.map (max rank)) (max ma mb) cs
                                        )
                            )

        Vars.Alias _ _ args _ ->
            -- THEORY: anything in the realVar would be outermostRank
            IO.foldM (\rank ( _, argVar ) -> IO.map (max rank) (go argVar)) Type.outermostRank args

        Vars.Error ->
            IO.pure groupRank



-- ====== Register Variables ======


{-| Adds `variables` to the pool at `rank` and gives each of them that rank.
-}
introduce : Int -> Pools -> List Variable -> IO ()
introduce rank pools variables =
    MVector.modify pools
        (\a -> variables ++ a)
        rank
        |> IO.andThen
            (\_ ->
                IO.forM_ variables
                    (\var ->
                        UF.modify var <|
                            \props ->
                                IO.makeDescriptor props.content rank props.mark props.copy
                    )
            )



-- ====== Type to Variable Conversion ======


{-| Returns a variable for `tipe`, with each new variable made at `rank`.
-}
typeToVariable : Int -> Pools -> Type -> IO Variable
typeToVariable rank pools tipe =
    typeToVar rank pools tipe


{-| Returns a variable for `tipe`. A variable in it is used as it is; each
structure gets a new variable at `rank`, added to that rank's pool.
-}
typeToVar : Int -> Pools -> Type -> IO Variable
typeToVar rank pools tipe =
    let
        go : Type -> IO Variable
        go =
            typeToVar rank pools
    in
    case tipe of
        Type.VarN v ->
            IO.pure v

        Type.AppN home name args ->
            IO.traverseList go args
                |> IO.andThen
                    (\argVars ->
                        register rank pools (Vars.Structure (Vars.App1 home name argVars))
                    )

        Type.FunN a b ->
            go a
                |> IO.andThen
                    (\aVar ->
                        go b
                            |> IO.andThen
                                (\bVar ->
                                    register rank pools (Vars.Structure (Vars.Fun1 aVar bVar))
                                )
                    )

        Type.AliasN home name args aliasType ->
            IO.traverseList (IO.traverseTuple go) args
                |> IO.andThen
                    (\argVars ->
                        go aliasType
                            |> IO.andThen
                                (\aliasVar ->
                                    register rank pools (Vars.Alias home name argVars aliasVar)
                                )
                    )

        Type.RecordN fields ext ->
            traverseDictIO go fields
                |> IO.andThen
                    (\fieldVars ->
                        go ext
                            |> IO.andThen
                                (\extVar ->
                                    register rank pools (Vars.Structure (Vars.Record1 fieldVars extVar))
                                )
                    )

        Type.EmptyRecordN ->
            register rank pools emptyRecord1

        Type.UnitN ->
            register rank pools unit1

        Type.TupleN a b cs ->
            go a
                |> IO.andThen
                    (\aVar ->
                        go b
                            |> IO.andThen
                                (\bVar ->
                                    IO.traverseList go cs
                                        |> IO.andThen
                                            (\cVars ->
                                                register rank pools (Vars.Structure (Vars.Tuple1 aVar bVar cVars))
                                            )
                                )
                    )


{-| Returns a new variable with `content` at `rank`, added to that rank's pool.
-}
register : Int -> Pools -> Content -> IO Variable
register rank pools content =
    UF.fresh (IO.makeDescriptor content rank Type.noMark Nothing)
        |> IO.andThen
            (\var ->
                MVector.modify pools ((::) var) rank
                    |> IO.map (\_ -> var)
            )


{-| The content of the empty record type.
-}
emptyRecord1 : Content
emptyRecord1 =
    Vars.Structure Vars.EmptyRecord1


{-| The content of the unit type.
-}
unit1 : Content
unit1 =
    Vars.Structure Vars.Unit1



-- ====== Source Type to Variable ======


{-| Returns a variable for the annotation type `srcType` of a foreign name,
whose free type variables are `freeVars`, made at `rank`.

Each free variable gets a fresh flexible variable, which is the instantiation.
Its kind is read from its name: one starting `number`, `comparable`,
`appendable` or `compappend` is constrained to that class.

-}
srcTypeToVariable : Int -> Pools -> Dict Name.Name () -> Can.Type Name -> IO Variable
srcTypeToVariable rank pools freeVars srcType =
    let
        nameToContent : Name.Name -> Content
        nameToContent name =
            if Name.isNumberType name then
                Vars.FlexSuper Vars.Number (Just name)

            else if Name.isComparableType name then
                Vars.FlexSuper Vars.Comparable (Just name)

            else if Name.isAppendableType name then
                Vars.FlexSuper Vars.Appendable (Just name)

            else if Name.isCompappendType name then
                Vars.FlexSuper Vars.CompAppend (Just name)

            else
                Vars.FlexVar (Just name)

        makeVar : Name.Name -> b -> IO Variable
        makeVar name _ =
            UF.fresh (IO.makeDescriptor (nameToContent name) rank Type.noMark Nothing)
    in
    traverseDictIOWithKey makeVar freeVars
        |> IO.andThen
            (\flexVars ->
                MVector.modify pools (\a -> Dict.values flexVars ++ a) rank
                    |> IO.andThen (\_ -> srcTypeToVar rank pools flexVars srcType)
            )


{-| Returns a variable for `srcType`, with its type variables taken from
`flexVars` and each structure a new variable at `rank`.

The body of a holey alias is converted with only the alias's own arguments in
scope. A type variable or record extension missing from `flexVars` crashes.

-}
srcTypeToVar : Int -> Pools -> Dict Name.Name Variable -> Can.Type Name -> IO Variable
srcTypeToVar rank pools flexVars srcType =
    let
        go : Can.Type Name -> IO Variable
        go =
            srcTypeToVar rank pools flexVars
    in
    case srcType of
        Can.TLambda _ argument result ->
            go argument
                |> IO.andThen
                    (\argVar ->
                        go result
                            |> IO.andThen
                                (\resultVar ->
                                    register rank pools (Vars.Structure (Vars.Fun1 argVar resultVar))
                                )
                    )

        Can.TVar name ->
            IO.pure (Utils.dictFind name flexVars)

        Can.TType home name args ->
            IO.traverseList go args
                |> IO.andThen
                    (\argVars ->
                        register rank pools (Vars.Structure (Vars.App1 home name argVars))
                    )

        Can.TRecord fields maybeExt ->
            traverseDictIO (srcFieldTypeToVar rank pools flexVars) fields
                |> IO.andThen
                    (\fieldVars ->
                        (case maybeExt of
                            Nothing ->
                                register rank pools emptyRecord1

                            Just ext ->
                                IO.pure (Utils.dictFind ext flexVars)
                        )
                            |> IO.andThen
                                (\extVar ->
                                    register rank pools (Vars.Structure (Vars.Record1 fieldVars extVar))
                                )
                    )

        Can.TUnit ->
            register rank pools unit1

        Can.TTuple a b cs ->
            go a
                |> IO.andThen
                    (\aVar ->
                        go b
                            |> IO.andThen
                                (\bVar ->
                                    IO.traverseList go cs
                                        |> IO.andThen
                                            (\cVars ->
                                                register rank pools (Vars.Structure (Vars.Tuple1 aVar bVar cVars))
                                            )
                                )
                    )

        Can.TAlias home name args aliasType ->
            IO.traverseList (IO.traverseTuple go) args
                |> IO.andThen
                    (\argVars ->
                        (case aliasType of
                            Can.Holey tipe ->
                                srcTypeToVar rank pools (Dict.fromList argVars) tipe

                            Can.Filled tipe ->
                                go tipe
                        )
                            |> IO.andThen
                                (\aliasVar ->
                                    register rank pools (Vars.Alias home name argVars aliasVar)
                                )
                    )


{-| Returns a variable for the type of a record field, as `srcTypeToVar` does.
-}
srcFieldTypeToVar : Int -> Pools -> Dict Name.Name Variable -> Can.FieldType Name -> IO Variable
srcFieldTypeToVar rank pools flexVars (Can.FieldType _ srcTipe) =
    srcTypeToVar rank pools flexVars srcTipe



-- ====== Copy (Instantiation) ======


{-| Returns an instance of the type of `var` at `rank`: its generalized
variables are replaced by fresh ones, and the rest is shared.
-}
makeCopy : Int -> Pools -> Variable -> IO Variable
makeCopy rank pools var =
    makeCopyHelp rank pools var
        |> IO.andThen
            (\copy ->
                restore var
                    |> IO.map (\_ -> copy)
            )


{-| Returns the copy of `variable` for one instantiation at `maxRank`.

A variable that is not generalized is returned as it is. A generalized one gets
a fresh variable, added to the pool at `maxRank`, with its content copied; a
rigid variable becomes a flexible one with the same name. The original records
its copy, so a variable reached twice is copied once; `restore` clears those
records afterwards.

-}
makeCopyHelp : Int -> Pools -> Variable -> IO Variable
makeCopyHelp maxRank pools variable =
    UF.get variable
        |> IO.andThen
            (\props ->
                case props.copy of
                    Just copiedVar ->
                        IO.pure copiedVar

                    Nothing ->
                        if props.rank /= Type.noRank then
                            IO.pure variable

                        else
                            let
                                makeDesc : Content -> Descriptor
                                makeDesc c =
                                    IO.makeDescriptor c maxRank Type.noMark Nothing
                            in
                            UF.fresh (makeDesc props.content)
                                |> IO.andThen
                                    (\copy ->
                                        MVector.modify pools ((::) copy) maxRank
                                            |> IO.andThen
                                                (\_ ->
                                                    -- Link the original variable to the new variable. This lets us
                                                    -- avoid making multiple copies of the variable we are instantiating.
                                                    --
                                                    -- Need to do this before recursively copying to avoid looping.
                                                    UF.set variable (IO.makeDescriptor props.content props.rank Type.noMark (Just copy))
                                                        |> IO.andThen
                                                            (\_ ->
                                                                -- Now we recursively copy the content of the variable.
                                                                -- We have already marked the variable as copied, so we
                                                                -- will not repeat this work or crawl this variable again.
                                                                case props.content of
                                                                    Vars.Structure term ->
                                                                        traverseFlatType (makeCopyHelp maxRank pools) term
                                                                            |> IO.andThen
                                                                                (\newTerm ->
                                                                                    UF.set copy (makeDesc (Vars.Structure newTerm))
                                                                                        |> IO.map (\_ -> copy)
                                                                                )

                                                                    Vars.FlexVar _ ->
                                                                        IO.pure copy

                                                                    Vars.FlexSuper _ _ ->
                                                                        IO.pure copy

                                                                    Vars.RigidVar name ->
                                                                        UF.set copy (makeDesc (Vars.FlexVar (Just name)))
                                                                            |> IO.map (\_ -> copy)

                                                                    Vars.RigidSuper super name ->
                                                                        UF.set copy (makeDesc (Vars.FlexSuper super (Just name)))
                                                                            |> IO.map (\_ -> copy)

                                                                    Vars.Alias home name args realType ->
                                                                        IO.mapM (IO.traverseTuple (makeCopyHelp maxRank pools)) args
                                                                            |> IO.andThen
                                                                                (\newArgs ->
                                                                                    makeCopyHelp maxRank pools realType
                                                                                        |> IO.andThen
                                                                                            (\newRealType ->
                                                                                                UF.set copy (makeDesc (Vars.Alias home name newArgs newRealType))
                                                                                                    |> IO.map (\_ -> copy)
                                                                                            )
                                                                                )

                                                                    Vars.Error ->
                                                                        IO.pure copy
                                                            )
                                                )
                                    )
            )



-- ====== Restore ======


{-| Clears the copy that `makeCopyHelp` recorded on `variable` and on the
variables its content reaches, resetting each to `Type.noRank` and
`Type.noMark`. A variable with no copy recorded stops the walk.
-}
restore : Variable -> IO ()
restore variable =
    UF.get variable
        |> IO.andThen
            (\props ->
                case props.copy of
                    Nothing ->
                        IO.pure ()

                    Just _ ->
                        UF.set variable (IO.makeDescriptor props.content Type.noRank Type.noMark Nothing)
                            |> IO.andThen (\_ -> restoreContent props.content)
            )


{-| Applies `restore` to each variable `content` holds.
-}
restoreContent : Content -> IO ()
restoreContent content =
    case content of
        Vars.FlexVar _ ->
            IO.pure ()

        Vars.FlexSuper _ _ ->
            IO.pure ()

        Vars.RigidVar _ ->
            IO.pure ()

        Vars.RigidSuper _ _ ->
            IO.pure ()

        Vars.Structure term ->
            case term of
                Vars.App1 _ _ args ->
                    IO.mapM_ restore args

                Vars.Fun1 arg result ->
                    restore arg
                        |> IO.andThen (\_ -> restore result)

                Vars.FunL arg result setSlot ->
                    restore arg
                        |> IO.andThen (\_ -> restore result)
                        |> IO.andThen (\_ -> restore setSlot)

                Vars.LambdaSet1 _ ->
                    IO.pure ()

                Vars.EmptyRecord1 ->
                    IO.pure ()

                Vars.Record1 fields ext ->
                    IO.mapM_ restore (Dict.values fields)
                        |> IO.andThen (\_ -> restore ext)

                Vars.Unit1 ->
                    IO.pure ()

                Vars.Tuple1 a b cs ->
                    IO.traverseList restore (a :: b :: cs)
                        |> IO.map (\_ -> ())

        Vars.Alias _ _ args var ->
            IO.mapM_ restore (List.map Tuple.second args)
                |> IO.andThen (\_ -> restore var)

        Vars.Error ->
            IO.pure ()



-- ====== Traverse Flat Type ======


{-| Returns `flatType` with `f` applied to each variable it holds.
-}
traverseFlatType : (Variable -> IO Variable) -> Vars.FlatType -> IO Vars.FlatType
traverseFlatType f flatType =
    case flatType of
        Vars.App1 home name args ->
            IO.map (Vars.App1 home name) (IO.traverseList f args)

        Vars.Fun1 a b ->
            IO.pure Vars.Fun1
                |> IO.apply (f a)
                |> IO.apply (f b)

        Vars.FunL a b s ->
            IO.pure Vars.FunL
                |> IO.apply (f a)
                |> IO.apply (f b)
                |> IO.apply (f s)

        Vars.LambdaSet1 ls ->
            -- Ground member ids, no variables. Type checking never creates a lambda set.
            IO.pure (Vars.LambdaSet1 ls)

        Vars.EmptyRecord1 ->
            IO.pure Vars.EmptyRecord1

        Vars.Record1 fields ext ->
            IO.pure Vars.Record1
                |> IO.apply (traverseDictIO f fields)
                |> IO.apply (f ext)

        Vars.Unit1 ->
            IO.pure Vars.Unit1

        Vars.Tuple1 a b cs ->
            IO.pure Vars.Tuple1
                |> IO.apply (f a)
                |> IO.apply (f b)
                |> IO.apply (IO.traverseList f cs)



-- ====== Dict Traversal Helpers ======


{-| Returns an action that applies `f` to each value of `dict`, in key order.
-}
traverseDictIO : (a -> IO b) -> Dict comparable a -> IO (Dict comparable b)
traverseDictIO f dict =
    Dict.toList dict
        |> IO.traverseList (\( k, v ) -> f v |> IO.map (\b -> ( k, b )))
        |> IO.map Dict.fromList


{-| Returns an action that applies `f` to each key and value of `dict`, in key
order.
-}
traverseDictIOWithKey : (comparable -> a -> IO b) -> Dict comparable a -> IO (Dict comparable b)
traverseDictIOWithKey f dict =
    Dict.toList dict
        |> IO.traverseList (\( k, v ) -> f k v |> IO.map (\b -> ( k, b )))
        |> IO.map Dict.fromList


{-| Returns every type variable name the quantifiers of `annotations` hold.
-}
annotationVarNames : Dict Name.Name (Can.Annotation Name) -> Dict Name ()
annotationVarNames annotations =
    Dict.foldl (\_ (Can.Forall freeVars _) acc -> Dict.union freeVars acc) Dict.empty annotations
