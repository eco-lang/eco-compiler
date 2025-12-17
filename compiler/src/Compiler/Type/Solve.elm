module Compiler.Type.Solve exposing (run)

{-| Constraint solver for Hindley-Milner type inference.

This module solves type constraints generated during type checking. It implements
Algorithm W with rank-based let-polymorphism, using pools to track variable scopes
and enable efficient generalization.

The solver works through constraints recursively:

1.  Converts types to unification variables
2.  Unifies actual types with expected types
3.  Manages variable ranks for generalization
4.  Detects infinite types via occurs check

Variables are organized into pools by rank. Higher ranks represent more deeply
nested scopes. During generalization, variables in young pools are either promoted
to older pools or generalized to `noRank` (making them polymorphic).


# Solving

@docs run

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
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
import Data.Map as Dict exposing (Dict)
import Data.Vector as Vector
import Data.Vector.Mutable as MVector
import System.TypeCheck.IO as IO exposing (Content, Descriptor(..), IO, Mark, Variable)
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== Solver Entry Point ======


{-| Solve a constraint tree and return either errors or type annotations.

Takes a constraint tree generated during type checking and solves it by
unifying types. Returns either a non-empty list of type errors or a
dictionary mapping names to their inferred type annotations.

-}
run : Constraint -> IO (Result (NE.Nonempty Error.Error) (Dict String Name.Name Can.Annotation))
run constraint =
    MVector.replicate 8 []
        |> IO.andThen
            (\pools ->
                solve Dict.empty Type.outermostRank pools emptyState constraint
                    |> IO.andThen
                        (\(State env _ errors) ->
                            case errors of
                                [] ->
                                    IO.traverseMap identity compare Type.toAnnotation env
                                        |> IO.map Ok

                                e :: es ->
                                    IO.pure (Err (NE.Nonempty e es))
                        )
            )


{-| Initialize an empty solver state with no variables, no errors, and initial mark.
-}
emptyState : State
emptyState =
    State Dict.empty (Type.nextMark Type.noMark) []



-- ====== Solver State ======


{-| Maps variable names to their unification variables.
-}
type alias Env =
    Dict String Name.Name Variable


{-| Mutable array of variable pools indexed by rank.
Each pool contains variables at that rank level for generalization.
-}
type alias Pools =
    IORef (Array (Maybe (List Variable)))


{-| Solver state containing environment, current mark, and accumulated errors.
-}
type State
    = State Env Mark (List Error.Error)



-- ====== Main Solver ======


{-| Main solver loop using tail recursion via IO.loop.
Processes constraints recursively, maintaining pools and state.
-}
solve : Env -> Int -> Pools -> State -> Constraint -> IO State
solve env rank pools state constraint =
    IO.loop solveHelp ( ( env, rank ), ( pools, state ), ( constraint, identity ) )


{-| Helper function for the solver loop that processes individual constraints.
Handles all constraint types: CTrue, CSaveTheEnvironment, CEqual, CLocal, CForeign, CPattern, CAnd, and CLet.
-}
solveHelp : ( ( Env, Int ), ( Pools, State ), ( Type.Constraint, IO State -> IO State ) ) -> IO (IO.Step ( ( Env, Int ), ( Pools, State ), ( Type.Constraint, IO State -> IO State ) ) State)
solveHelp ( ( env, rank ), ( pools, (State _ sMark sErrors) as state ), ( constraint, cont ) ) =
    case constraint of
        CTrue ->
            IO.pure state |> cont |> IO.map IO.Done

        CSaveTheEnvironment ->
            IO.pure (State env sMark sErrors) |> cont |> IO.map IO.Done

        CEqual region category tipe expectation ->
            typeToVariable rank pools tipe
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
                                                            |> IO.andThen (\_ -> IO.pure state |> cont |> IO.map IO.Done)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region category actualType |> addError state |> IO.pure |> cont |> IO.map IO.Done
                                                                )
                                            )
                                )
                    )

        CLocal region name expectation ->
            makeCopy rank pools (Utils.find identity name env)
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
                                                            |> IO.andThen (\_ -> IO.pure state |> cont |> IO.map IO.Done)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region (Error.Local name) actualType |> addError state |> IO.pure |> cont |> IO.map IO.Done
                                                                )
                                            )
                                )
                    )

        CForeign region name (Can.Forall freeVars srcType) expectation ->
            srcTypeToVariable rank pools freeVars srcType
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
                                                            |> IO.andThen (\_ -> IO.pure state |> cont |> IO.map IO.Done)

                                                    Unify.AnswerErr vars actualType expectedType ->
                                                        introduce rank pools vars
                                                            |> IO.andThen
                                                                (\_ ->
                                                                    Error.typeReplace expectation expectedType |> Error.BadExpr region (Error.Foreign name) actualType |> addError state |> IO.pure |> cont |> IO.map IO.Done
                                                                )
                                            )
                                )
                    )

        CPattern region category tipe expectation ->
            typeToVariable rank pools tipe
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
                                                            |> IO.andThen (\_ -> IO.pure state |> cont |> IO.map IO.Done)

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
                                                                        |> IO.map IO.Done
                                                                )
                                            )
                                )
                    )

        CAnd constraints ->
            IO.foldM (solve env rank pools) state constraints |> cont |> IO.map IO.Done

        CLet [] flexs _ headerCon CTrue ->
            introduce rank pools flexs
                |> IO.map (\_ -> IO.Loop ( ( env, rank ), ( pools, state ), ( headerCon, cont ) ))

        CLet [] [] header headerCon subCon ->
            solve env rank pools state headerCon
                |> IO.andThen
                    (\state1 ->
                        IO.traverseMap identity compare (A.traverse (typeToVariable rank pools)) header
                            |> IO.map
                                (\locals ->
                                    let
                                        newEnv : Env
                                        newEnv =
                                            Dict.union env (Dict.map (\_ -> A.toValue) locals)
                                    in
                                    IO.Loop
                                        ( ( newEnv, rank )
                                        , ( pools, state1 )
                                        , ( subCon
                                          , IO.andThen
                                                (\state2 ->
                                                    IO.foldM occurs state2 (Dict.toList compare locals)
                                                )
                                                >> cont
                                          )
                                        )
                                )
                    )

        CLet rigids flexs header headerCon subCon ->
            let
                -- work in the next pool to localize header
                nextRank : Int
                nextRank =
                    rank + 1
            in
            MVector.length pools
                |> IO.andThen
                    (\poolsLength ->
                        (if nextRank < poolsLength then
                            IO.pure pools

                         else
                            MVector.grow pools poolsLength
                        )
                            |> IO.andThen
                                (\nextPools ->
                                    let
                                        -- introduce variables
                                        vars : List Variable
                                        vars =
                                            rigids ++ flexs
                                    in
                                    IO.forM_ vars
                                        (\var ->
                                            UF.modify var <|
                                                \(Descriptor props) ->
                                                    IO.makeDescriptor props.content nextRank props.mark props.copy
                                        )
                                        |> IO.andThen
                                            (\_ ->
                                                MVector.write nextPools nextRank vars
                                                    |> IO.andThen
                                                        (\_ ->
                                                            -- run solver in next pool
                                                            IO.traverseMap identity compare (A.traverse (typeToVariable nextRank nextPools)) header
                                                                |> IO.andThen
                                                                    (\locals ->
                                                                        solve env nextRank nextPools state headerCon
                                                                            |> IO.andThen
                                                                                (\(State savedEnv mark errors) ->
                                                                                    let
                                                                                        youngMark : Mark
                                                                                        youngMark =
                                                                                            mark

                                                                                        visitMark : Mark
                                                                                        visitMark =
                                                                                            nextMark youngMark

                                                                                        finalMark : Mark
                                                                                        finalMark =
                                                                                            nextMark visitMark
                                                                                    in
                                                                                    -- pop pool
                                                                                    generalize youngMark visitMark nextRank nextPools
                                                                                        |> IO.andThen
                                                                                            (\_ ->
                                                                                                MVector.write nextPools nextRank []
                                                                                                    |> IO.andThen
                                                                                                        (\_ ->
                                                                                                            -- check that things went well
                                                                                                            IO.mapM_ isGeneric rigids
                                                                                                                |> IO.map
                                                                                                                    (\_ ->
                                                                                                                        let
                                                                                                                            newEnv : Env
                                                                                                                            newEnv =
                                                                                                                                Dict.union env (Dict.map (\_ -> A.toValue) locals)

                                                                                                                            tempState : State
                                                                                                                            tempState =
                                                                                                                                State savedEnv finalMark errors
                                                                                                                        in
                                                                                                                        IO.Loop
                                                                                                                            ( ( newEnv, rank )
                                                                                                                            , ( nextPools, tempState )
                                                                                                                            , ( subCon
                                                                                                                              , IO.andThen
                                                                                                                                    (\newState ->
                                                                                                                                        IO.foldM occurs newState (Dict.toList compare locals)
                                                                                                                                    )
                                                                                                                                    >> cont
                                                                                                                              )
                                                                                                                            )
                                                                                                                    )
                                                                                                        )
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                            )
                                )
                    )



{-| Check that a variable has rank == noRank, meaning that it can be generalized.
Crashes with a compiler bug message if the variable is not generic.
-}
isGeneric : Variable -> IO ()
isGeneric var =
    UF.get var
        |> IO.andThen
            (\(Descriptor props) ->
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


{-| Convert an expected type into a unification variable.
Extracts the underlying type from the expectation wrapper.
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


{-| Convert a pattern expectation into a unification variable.
Extracts the underlying type from the pattern expectation wrapper.
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


{-| Add a type error to the solver state.
-}
addError : State -> Error.Error -> State
addError (State savedEnv rank errors) err =
    State savedEnv rank (err :: errors)



-- ====== Occurs Check ======


{-| Perform occurs check on a variable to detect infinite types.
If an infinite type is detected, marks the variable as Error and adds an error to state.
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
                                        (\(Descriptor props) ->
                                            UF.set variable (IO.makeDescriptor IO.Error props.rank props.mark props.copy)
                                                |> IO.map (\_ -> addError state (Error.InfiniteType region name errorType))
                                        )
                            )

                else
                    IO.pure state
            )



-- ====== Generalize ======


{-| Generalize variables in the young pool after processing a let binding.
Variables with rank less than youngRank are demoted to older pools.
Variables with rank equal to youngRank are generalized to noRank (polymorphic).
-}
generalize : Mark -> Mark -> Int -> Pools -> IO ()
generalize youngMark visitMark youngRank pools =
    MVector.read pools youngRank
        |> IO.andThen
            (\youngVars ->
                poolToRankTable youngMark youngRank youngVars
                    |> IO.andThen
                        (\rankTable ->
                            -- get the ranks right for each entry.
                            -- start at low ranks so that we only have to pass
                            -- over the information once.
                            Vector.imapM_
                                (\rank table ->
                                    IO.mapM_ (adjustRank youngMark visitMark rank) table
                                )
                                rankTable
                                |> IO.andThen
                                    (\_ ->
                                        -- For variables that have rank lowerer than youngRank, register them in
                                        -- the appropriate old pool if they are not redundant.
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
                                                                                (\(Descriptor props) ->
                                                                                    MVector.modify pools ((::) var) props.rank
                                                                                )
                                                                )
                                                    )
                                            )
                                            |> IO.andThen
                                                (\_ ->
                                                    -- For variables with rank youngRank
                                                    --   If rank < youngRank: register in oldPool
                                                    --   otherwise generalize
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
                                                                                                (\(Descriptor props) ->
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


{-| Build a table mapping ranks to variables, sorting the young pool by rank.
Marks all variables with youngMark during the process.
-}
poolToRankTable : Mark -> Int -> List Variable -> IO (IORef (Array (Maybe (List Variable))))
poolToRankTable youngMark youngRank youngInhabitants =
    MVector.replicate (youngRank + 1) []
        |> IO.andThen
            (\mutableTable ->
                -- Sort the youngPool variables into buckets by rank.
                IO.forM_ youngInhabitants
                    (\var ->
                        UF.get var
                            |> IO.andThen
                                (\(Descriptor props) ->
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


{-| Adjust variable ranks such that ranks never increase as you move deeper.
Returns the maximum rank found in the variable's structure.
This ensures the outermost rank is representative of the entire structure.
-}
adjustRank : Mark -> Mark -> Int -> Variable -> IO Int
adjustRank youngMark visitMark groupRank var =
    UF.get var
        |> IO.andThen
            (\(Descriptor props) ->
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
                    -- TODO how can minRank ever be groupRank?
                    UF.set var (IO.makeDescriptor props.content minRank visitMark props.copy)
                        |> IO.map (\_ -> minRank)
            )


{-| Adjust ranks for the content of a variable descriptor.
Recursively adjusts ranks for all variables contained in the content.
-}
adjustRankContent : Mark -> Mark -> Int -> Content -> IO Int
adjustRankContent youngMark visitMark groupRank content =
    let
        go : Variable -> IO Int
        go =
            adjustRank youngMark visitMark groupRank
    in
    case content of
        IO.FlexVar _ ->
            IO.pure groupRank

        IO.FlexSuper _ _ ->
            IO.pure groupRank

        IO.RigidVar _ ->
            IO.pure groupRank

        IO.RigidSuper _ _ ->
            IO.pure groupRank

        IO.Structure flatType ->
            case flatType of
                IO.App1 _ _ args ->
                    IO.foldM (\rank arg -> IO.map (max rank) (go arg)) Type.outermostRank args

                IO.Fun1 arg result ->
                    IO.pure max
                        |> IO.apply (go arg)
                        |> IO.apply (go result)

                IO.EmptyRecord1 ->
                    -- THEORY: an empty record never needs to get generalized
                    IO.pure Type.outermostRank

                IO.Record1 fields extension ->
                    go extension
                        |> IO.andThen
                            (\extRank ->
                                IO.foldMDict compare (\rank field -> IO.map (max rank) (go field)) extRank fields
                            )

                IO.Unit1 ->
                    -- THEORY: a unit never needs to get generalized
                    IO.pure Type.outermostRank

                IO.Tuple1 a b cs ->
                    go a
                        |> IO.andThen
                            (\ma ->
                                go b
                                    |> IO.andThen
                                        (\mb ->
                                            IO.foldM (\rank -> go >> IO.map (max rank)) (max ma mb) cs
                                        )
                            )

        IO.Alias _ _ args _ ->
            -- THEORY: anything in the realVar would be outermostRank
            IO.foldM (\rank ( _, argVar ) -> IO.map (max rank) (go argVar)) Type.outermostRank args

        IO.Error ->
            IO.pure groupRank



-- ====== Register Variables ======


{-| Register variables at the given rank by adding them to the pool and updating their descriptors.
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
                            \(Descriptor props) ->
                                IO.makeDescriptor props.content rank props.mark props.copy
                    )
            )



-- ====== Type to Variable Conversion ======


{-| Convert a Type to a unification Variable at the given rank.
-}
typeToVariable : Int -> Pools -> Type -> IO Variable
typeToVariable rank pools tipe =
    typeToVar rank pools Dict.empty tipe


{-| Convert a Type to a Variable, tracking alias placeholders in aliasDict.
Recursively converts all contained types to variables and registers them in pools.
-}
typeToVar : Int -> Pools -> Dict String Name.Name Variable -> Type -> IO Variable
typeToVar rank pools aliasDict tipe =
    let
        go : Type -> IO Variable
        go =
            typeToVar rank pools aliasDict
    in
    case tipe of
        Type.VarN v ->
            IO.pure v

        Type.AppN home name args ->
            IO.traverseList go args
                |> IO.andThen
                    (\argVars ->
                        register rank pools (IO.Structure (IO.App1 home name argVars))
                    )

        Type.FunN a b ->
            go a
                |> IO.andThen
                    (\aVar ->
                        go b
                            |> IO.andThen
                                (\bVar ->
                                    register rank pools (IO.Structure (IO.Fun1 aVar bVar))
                                )
                    )

        Type.AliasN home name args aliasType ->
            IO.traverseList (IO.traverseTuple go) args
                |> IO.andThen
                    (\argVars ->
                        typeToVar rank pools (Dict.fromList identity argVars) aliasType
                            |> IO.andThen
                                (\aliasVar ->
                                    register rank pools (IO.Alias home name argVars aliasVar)
                                )
                    )

        Type.PlaceHolder name ->
            IO.pure (Utils.find identity name aliasDict)

        Type.RecordN fields ext ->
            IO.traverseMap identity compare go fields
                |> IO.andThen
                    (\fieldVars ->
                        go ext
                            |> IO.andThen
                                (\extVar ->
                                    register rank pools (IO.Structure (IO.Record1 fieldVars extVar))
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
                                                register rank pools (IO.Structure (IO.Tuple1 aVar bVar cVars))
                                            )
                                )
                    )


{-| Register a new variable with the given content at the specified rank.
Creates a fresh unification variable and adds it to the appropriate pool.
-}
register : Int -> Pools -> Content -> IO Variable
register rank pools content =
    UF.fresh (IO.makeDescriptor content rank Type.noMark Nothing)
        |> IO.andThen
            (\var ->
                MVector.modify pools ((::) var) rank
                    |> IO.map (\_ -> var)
            )


{-| Content for an empty record type.
-}
emptyRecord1 : Content
emptyRecord1 =
    IO.Structure IO.EmptyRecord1


{-| Content for a unit type.
-}
unit1 : Content
unit1 =
    IO.Structure IO.Unit1



-- ====== Source Type to Variable ======


{-| Convert a canonical source type to a unification variable.
Creates fresh variables for all free type variables based on their constraints.
-}
srcTypeToVariable : Int -> Pools -> Dict String Name.Name () -> Can.Type -> IO Variable
srcTypeToVariable rank pools freeVars srcType =
    let
        nameToContent : Name.Name -> Content
        nameToContent name =
            if Name.isNumberType name then
                IO.FlexSuper IO.Number (Just name)

            else if Name.isComparableType name then
                IO.FlexSuper IO.Comparable (Just name)

            else if Name.isAppendableType name then
                IO.FlexSuper IO.Appendable (Just name)

            else if Name.isCompappendType name then
                IO.FlexSuper IO.CompAppend (Just name)

            else
                IO.FlexVar (Just name)

        makeVar : Name.Name -> b -> IO Variable
        makeVar name _ =
            UF.fresh (IO.makeDescriptor (nameToContent name) rank Type.noMark Nothing)
    in
    IO.traverseMapWithKey identity compare makeVar freeVars
        |> IO.andThen
            (\flexVars ->
                MVector.modify pools (\a -> Dict.values compare flexVars ++ a) rank
                    |> IO.andThen (\_ -> srcTypeToVar rank pools flexVars srcType)
            )


{-| Convert a canonical source type to a variable, with flexVars mapping free variable names.
Recursively converts all contained types to variables.
-}
srcTypeToVar : Int -> Pools -> Dict String Name.Name Variable -> Can.Type -> IO Variable
srcTypeToVar rank pools flexVars srcType =
    let
        go : Can.Type -> IO Variable
        go =
            srcTypeToVar rank pools flexVars
    in
    case srcType of
        Can.TLambda argument result ->
            go argument
                |> IO.andThen
                    (\argVar ->
                        go result
                            |> IO.andThen
                                (\resultVar ->
                                    register rank pools (IO.Structure (IO.Fun1 argVar resultVar))
                                )
                    )

        Can.TVar name ->
            IO.pure (Utils.find identity name flexVars)

        Can.TType home name args ->
            IO.traverseList go args
                |> IO.andThen
                    (\argVars ->
                        register rank pools (IO.Structure (IO.App1 home name argVars))
                    )

        Can.TRecord fields maybeExt ->
            IO.traverseMap identity compare (srcFieldTypeToVar rank pools flexVars) fields
                |> IO.andThen
                    (\fieldVars ->
                        (case maybeExt of
                            Nothing ->
                                register rank pools emptyRecord1

                            Just ext ->
                                IO.pure (Utils.find identity ext flexVars)
                        )
                            |> IO.andThen
                                (\extVar ->
                                    register rank pools (IO.Structure (IO.Record1 fieldVars extVar))
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
                                                register rank pools (IO.Structure (IO.Tuple1 aVar bVar cVars))
                                            )
                                )
                    )

        Can.TAlias home name args aliasType ->
            IO.traverseList (IO.traverseTuple go) args
                |> IO.andThen
                    (\argVars ->
                        (case aliasType of
                            Can.Holey tipe ->
                                srcTypeToVar rank pools (Dict.fromList identity argVars) tipe

                            Can.Filled tipe ->
                                go tipe
                        )
                            |> IO.andThen
                                (\aliasVar ->
                                    register rank pools (IO.Alias home name argVars aliasVar)
                                )
                    )


{-| Convert a canonical field type to a variable.
Unwraps the FieldType wrapper and converts the inner type.
-}
srcFieldTypeToVar : Int -> Pools -> Dict String Name.Name Variable -> Can.FieldType -> IO Variable
srcFieldTypeToVar rank pools flexVars (Can.FieldType _ srcTipe) =
    srcTypeToVar rank pools flexVars srcTipe



-- ====== Copy (Instantiation) ======


{-| Create a copy of a polymorphic variable by instantiating it at the given rank.
Used when referencing let-bound polymorphic variables.
-}
makeCopy : Int -> Pools -> Variable -> IO Variable
makeCopy rank pools var =
    makeCopyHelp rank pools var
        |> IO.andThen
            (\copy ->
                restore var
                    |> IO.map (\_ -> copy)
            )


{-| Helper for makeCopy that recursively copies variable structure.
Links the original to the copy to avoid duplicating work during recursive copying.
-}
makeCopyHelp : Int -> Pools -> Variable -> IO Variable
makeCopyHelp maxRank pools variable =
    UF.get variable
        |> IO.andThen
            (\(Descriptor props) ->
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
                                                                    IO.Structure term ->
                                                                        traverseFlatType (makeCopyHelp maxRank pools) term
                                                                            |> IO.andThen
                                                                                (\newTerm ->
                                                                                    UF.set copy (makeDesc (IO.Structure newTerm))
                                                                                        |> IO.map (\_ -> copy)
                                                                                )

                                                                    IO.FlexVar _ ->
                                                                        IO.pure copy

                                                                    IO.FlexSuper _ _ ->
                                                                        IO.pure copy

                                                                    IO.RigidVar name ->
                                                                        UF.set copy (makeDesc (IO.FlexVar (Just name)))
                                                                            |> IO.map (\_ -> copy)

                                                                    IO.RigidSuper super name ->
                                                                        UF.set copy (makeDesc (IO.FlexSuper super (Just name)))
                                                                            |> IO.map (\_ -> copy)

                                                                    IO.Alias home name args realType ->
                                                                        IO.mapM (IO.traverseTuple (makeCopyHelp maxRank pools)) args
                                                                            |> IO.andThen
                                                                                (\newArgs ->
                                                                                    makeCopyHelp maxRank pools realType
                                                                                        |> IO.andThen
                                                                                            (\newRealType ->
                                                                                                UF.set copy (makeDesc (IO.Alias home name newArgs newRealType))
                                                                                                    |> IO.map (\_ -> copy)
                                                                                            )
                                                                                )

                                                                    IO.Error ->
                                                                        IO.pure copy
                                                            )
                                                )
                                    )
            )



-- ====== Restore ======


{-| Restore a variable to its pre-copy state by clearing copy links.
Recursively restores all variables in the structure.
-}
restore : Variable -> IO ()
restore variable =
    UF.get variable
        |> IO.andThen
            (\(Descriptor props) ->
                case props.copy of
                    Nothing ->
                        IO.pure ()

                    Just _ ->
                        UF.set variable (IO.makeDescriptor props.content Type.noRank Type.noMark Nothing)
                            |> IO.andThen (\_ -> restoreContent props.content)
            )


{-| Restore the content of a variable by recursively restoring all contained variables.
-}
restoreContent : Content -> IO ()
restoreContent content =
    case content of
        IO.FlexVar _ ->
            IO.pure ()

        IO.FlexSuper _ _ ->
            IO.pure ()

        IO.RigidVar _ ->
            IO.pure ()

        IO.RigidSuper _ _ ->
            IO.pure ()

        IO.Structure term ->
            case term of
                IO.App1 _ _ args ->
                    IO.mapM_ restore args

                IO.Fun1 arg result ->
                    restore arg
                        |> IO.andThen (\_ -> restore result)

                IO.EmptyRecord1 ->
                    IO.pure ()

                IO.Record1 fields ext ->
                    IO.mapM_ restore (Dict.values compare fields)
                        |> IO.andThen (\_ -> restore ext)

                IO.Unit1 ->
                    IO.pure ()

                IO.Tuple1 a b cs ->
                    IO.traverseList restore (a :: b :: cs)
                        |> IO.map (\_ -> ())

        IO.Alias _ _ args var ->
            IO.mapM_ restore (List.map Tuple.second args)
                |> IO.andThen (\_ -> restore var)

        IO.Error ->
            IO.pure ()



-- ====== Traverse Flat Type ======


{-| Apply a function to all variables in a FlatType structure.
Used during copying to transform all contained variables.
-}
traverseFlatType : (Variable -> IO Variable) -> IO.FlatType -> IO IO.FlatType
traverseFlatType f flatType =
    case flatType of
        IO.App1 home name args ->
            IO.map (IO.App1 home name) (IO.traverseList f args)

        IO.Fun1 a b ->
            IO.pure IO.Fun1
                |> IO.apply (f a)
                |> IO.apply (f b)

        IO.EmptyRecord1 ->
            IO.pure IO.EmptyRecord1

        IO.Record1 fields ext ->
            IO.pure IO.Record1
                |> IO.apply (IO.traverseMap identity compare f fields)
                |> IO.apply (f ext)

        IO.Unit1 ->
            IO.pure IO.Unit1

        IO.Tuple1 a b cs ->
            IO.pure IO.Tuple1
                |> IO.apply (f a)
                |> IO.apply (f b)
                |> IO.apply (IO.traverseList f cs)
