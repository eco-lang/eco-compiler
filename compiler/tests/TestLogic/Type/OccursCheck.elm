module TestLogic.Type.OccursCheck exposing
    ( expectInfiniteTypeDetected
    , expectNoInfiniteTypes
    )

{-| Expectations for tests of the occurs check, the type checker's refusal of an
infinite type.

A type is infinite when a type variable would have to equal a type that
contains that same variable, as in `a = List a`: no finite type satisfies the
equation. Where the type checker runs the check is described in
`Compiler.Type.Solve` and `Compiler.Type.Occurs`.
`expectInfiniteTypeDetected` lets a test fail when a program with an infinite
type is accepted.

Each expectation takes a test program, a `Src.Module`, and runs it through
`TestLogic.TestPipeline.runToPostSolve`: canonicalization, type checking and
PostSolve (`Compiler.Type.PostSolve`, a pass over the solved _node types_,
which are the types recorded for each expression and pattern by node id).
PostSolve itself cannot fail. That pipeline's `Err` carries only a count of
errors, so neither expectation can see what kind of error a failure was.

  - `expectInfiniteTypeDetected` passes when the pipeline fails and fails when
    it succeeds.
  - `expectNoInfiniteTypes` fails when the pipeline fails. When it succeeds,
    the node types after PostSolve are walked for a type variable inside its
    own definition. The walk reports a variable only if it has already marked
    that name as seen, and it never marks one, so this expectation passes
    whenever the pipeline succeeds.

Among what is not tested: that a failure is an infinite-type error rather than
any other canonicalization or type error, the top-level annotations, and the
node types before PostSolve.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Data.Set as Set exposing (EverySet)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that passes when `srcModule` fails to canonicalize
or type check, and fails when it gets through PostSolve.

The failure is not inspected, so any canonicalization or type error passes,
not only an infinite type.

-}
expectInfiniteTypeDetected : Src.Module -> Expect.Expectation
expectInfiniteTypeDetected srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err _ ->
            Expect.pass

        Ok _ ->
            Expect.fail "Expected infinite type to be detected, but compilation succeeded"


{-| Returns an expectation that fails with the pipeline's message when
`srcModule` does not get through PostSolve, and otherwise fails with one line
per issue `collectInfiniteTypeIssues` finds in the node types after PostSolve.

That walk finds no issue in any type, so the expectation passes whenever the
pipeline succeeds.

-}
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectInfiniteTypeIssues result.nodeTypesPost
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- INFINITE TYPE DETECTION
-- ============================================================================


{-| Returns the messages `checkForInfiniteType` gives for every type in
`nodeTypes`, each prefixed with the node id, which is the type's index in the
array. A node with no type is skipped.

Each walk starts with no variables seen, so the result is always empty.

-}
collectInfiniteTypeIssues : Array.Array (Maybe (Can.Type Name)) -> List String
collectInfiniteTypeIssues nodeTypes =
    Array.foldl
        (\maybeType ( nodeId, acc ) ->
            case maybeType of
                Nothing ->
                    ( nodeId + 1, acc )

                Just canType ->
                    let
                        context =
                            "NodeId " ++ String.fromInt nodeId
                    in
                    ( nodeId + 1, checkForInfiniteType context Set.empty canType ++ acc )
        )
        ( 0, [] )
        nodeTypes
        |> Tuple.second


{-| Returns one message, prefixed with `context`, for each occurrence of a type
variable in `canType` whose name is in `seenVars`, other than a record's
extension variable.

The walk descends into function types, the arguments of named types, tuples
and record fields, and into both an alias's arguments and its body; a record's
extension variable is not looked at. `seenVars` is passed down unchanged and
never added to, so a walk started with an empty set, as
`collectInfiniteTypeIssues` starts it, returns nothing.

-}
checkForInfiniteType : String -> EverySet String String -> Can.Type Name -> List String
checkForInfiniteType context seenVars canType =
    case canType of
        Can.TVar name ->
            if Set.member identity name seenVars then
                [ context ++ ": Infinite type detected - type variable '" ++ name ++ "' appears in its own definition" ]

            else
                []

        Can.TLambda _ argType resultType ->
            checkForInfiniteType context seenVars argType
                ++ checkForInfiniteType context seenVars resultType

        Can.TType _ _ args ->
            List.concatMap (checkForInfiniteType context seenVars) args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ fieldType) acc ->
                    checkForInfiniteType context seenVars fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkForInfiniteType context seenVars a
                ++ checkForInfiniteType context seenVars b
                ++ List.concatMap (checkForInfiniteType context seenVars) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkForInfiniteType context seenVars argType) args
                ++ (case aliasedType of
                        Can.Holey t ->
                            checkForInfiniteType context seenVars t

                        Can.Filled t ->
                            checkForInfiniteType context seenVars t
                   )
