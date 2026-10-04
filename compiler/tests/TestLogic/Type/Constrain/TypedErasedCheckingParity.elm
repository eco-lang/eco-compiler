module TestLogic.Type.Constrain.TypedErasedCheckingParity exposing
    ( expectEquivalentTypeChecking
    , expectEquivalentTypeCheckingCanonical
    )

{-| Expectations that type-check one module in two ways and fail when the two
disagree.

The compiler can type-check a module on either of two paths. The _erased
path_ generates constraints with `Compiler.Type.Constrain.Erased.Module.constrain`
and solves them with `Compiler.Type.Solve.run`. The _typed path_ generates them
with `Compiler.Type.Constrain.Typed.Module.constrainWithIds` and solves them
with `Compiler.Type.Solve.runWithIds`, which also returns `nodeTypes`: an array
indexed by node id holding, for each id, `Maybe` the type the solver found. A
_node id_ is the integer that every canonical expression and pattern carries.
If the two paths disagreed, a module could be accepted on one and rejected on
the other; these expectations exist to catch that, and to catch the typed path
leaving an expression with no type.

Both expectations run the two paths on one canonical module, and pass in
exactly two cases:

  - Both paths succeed, and every expression id in the module has a `Just`
    entry in the typed path's `nodeTypes`. The ids are those of every
    expression node reachable from the module's declarations, nested ones
    included.
  - Both paths fail with the same number of errors, and the errors match
    pairwise in list order: the same constructor and the same region, and in
    addition the same category constructor for `BadExpr` and `BadPattern`
    (ignoring any payload the category carries) and the same variable name for
    `InfiniteType`.

Any other outcome fails, with a message describing the difference.

`expectEquivalentTypeChecking` starts from source and canonicalizes it first;
`expectEquivalentTypeCheckingCanonical` starts from a canonical module.

Among what is not checked:

  - When both paths succeed, their annotations are not compared, and neither
    is any node type: only its presence.
  - A pattern's own node id is never collected, so a pattern with no type
    passes.
  - The types an error carries (actual, expected, or the infinite type), and
    the payload of a category.
  - Whether the module is accepted: two matching failures pass as surely as
    two successes.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Erased.Module as ConstrainErased
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Error as T
import Compiler.Type.Solve as Solve
import Compiler.Type.Vars as Vars
import Data.Map
import Dict exposing (Dict)
import Expect
import Set exposing (Set)
import System.TypeCheck.IO as IO


{-| Returns a one-line description of a canonicalization error for a failure
message: its kind and the name it concerns. For `NotFoundVar`, `NotFoundType`
and `NotFoundVariant` the name is prefixed with the qualifier it was written
with, if any, and `BadArity` also gives the expected and actual argument
counts. Kinds this function has no case for, such as `AmbiguousVariant`, all
give `"Other error (unhandled)"`.
-}
errorToString : CanError.Error -> String
errorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundBinop _ name _ ->
            "NotFoundBinop: " ++ name

        CanError.RecursiveLet (A.At _ name) _ ->
            "RecursiveLet: " ++ name

        CanError.NotFoundType _ maybeModule name _ ->
            "NotFoundType: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundVariant _ maybeModule name _ ->
            "NotFoundVariant: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        CanError.BadArity _ _ name expected got ->
            "BadArity: " ++ name ++ " expected " ++ String.fromInt expected ++ " got " ++ String.fromInt got

        CanError.DuplicateDecl name _ _ ->
            "DuplicateDecl: " ++ name

        CanError.DuplicatePattern _ name _ _ ->
            "DuplicatePattern: " ++ name

        CanError.AnnotationTooShort _ name _ _ ->
            "AnnotationTooShort: " ++ name

        CanError.Binop _ op _ ->
            "Binop error: " ++ op

        CanError.AmbiguousVar _ _ name _ _ ->
            "AmbiguousVar: " ++ name

        CanError.AmbiguousType _ _ name _ _ ->
            "AmbiguousType: " ++ name

        CanError.AmbiguousBinop _ name _ _ ->
            "AmbiguousBinop: " ++ name

        CanError.ExportNotFound _ _ name _ ->
            "ExportNotFound: " ++ name

        CanError.ImportNotFound _ name _ ->
            "ImportNotFound: " ++ name

        CanError.ImportExposingNotFound _ _ name _ ->
            "ImportExposingNotFound: " ++ name

        _ ->
            "Other error (unhandled)"


{-| Creates an expectation that `srcModule`, once canonicalized, type-checks
the same way on the erased and the typed path.

It canonicalizes as package `eco/example` against
`Compiler.Elm.Interface.Basic.testIfaces`, and fails with the error count and
a description of the first error if canonicalization fails. Otherwise it
passes when both paths succeed and the typed path gives every expression id a
node type, or when both fail with matching errors: the same count and,
pairwise in order, the same constructor and region, the same category
constructor for `BadExpr` and `BadPattern`, and the same variable name for
`InfiniteType`. Annotations, and the types inside errors, are not compared.

-}
expectEquivalentTypeChecking : Src.Module -> Expect.Expectation
expectEquivalentTypeChecking srcModule =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                errorCount =
                    List.length errorList

                firstError =
                    List.head errorList
                        |> Maybe.map errorToString
                        |> Maybe.withDefault "unknown"
            in
            Expect.fail
                ("Canonicalization failed with "
                    ++ String.fromInt errorCount
                    ++ " error(s): "
                    ++ firstError
                )

        ( _, Ok modul ) ->
            let
                standardResult =
                    IO.unsafePerformIO (runStandardPath modul)

                withIdsResult =
                    IO.unsafePerformIO (runWithIdsPath modul)

                allExprIds =
                    extractModuleExprIds modul
            in
            case ( standardResult, withIdsResult ) of
                ( Ok _, Ok { nodeTypes } ) ->
                    let
                        nodeTypeIds =
                            Array.foldl
                                (\maybeType ( idx, acc ) ->
                                    case maybeType of
                                        Just _ ->
                                            ( idx + 1, Set.insert idx acc )

                                        Nothing ->
                                            ( idx + 1, acc )
                                )
                                ( 0, Set.empty )
                                nodeTypes
                                |> Tuple.second

                        missingIds =
                            Set.diff allExprIds nodeTypeIds
                    in
                    if Set.isEmpty missingIds then
                        Expect.pass

                    else
                        Expect.fail
                            ("WithIds path succeeded but missing types for expression IDs: "
                                ++ (Set.toList missingIds |> List.map String.fromInt |> String.join ", ")
                                ++ "\nExpected IDs: "
                                ++ (Set.toList allExprIds |> List.map String.fromInt |> String.join ", ")
                                ++ "\nGot IDs: "
                                ++ (Set.toList nodeTypeIds |> List.map String.fromInt |> String.join ", ")
                            )

                ( Err standardErrors, Err withIdsErrors ) ->
                    let
                        standardErrorList =
                            NE.toList standardErrors

                        withIdsErrorList =
                            NE.toList withIdsErrors

                        standardCount =
                            List.length standardErrorList

                        withIdsCount =
                            List.length withIdsErrorList
                    in
                    if standardCount /= withIdsCount then
                        Expect.fail
                            ("Both paths failed but with different error counts. "
                                ++ "Standard: "
                                ++ String.fromInt standardCount
                                ++ " error(s), WithIds: "
                                ++ String.fromInt withIdsCount
                                ++ " error(s)"
                                ++ "\nStandard errors: "
                                ++ (List.map typeErrorToString standardErrorList |> String.join "; ")
                                ++ "\nWithIds errors: "
                                ++ (List.map typeErrorToString withIdsErrorList |> String.join "; ")
                            )

                    else
                        let
                            mismatches =
                                List.map2 compareTypeErrors standardErrorList withIdsErrorList
                                    |> List.filterMap identity
                        in
                        if List.isEmpty mismatches then
                            Expect.pass

                        else
                            Expect.fail
                                ("Both paths failed but with different error reasons:\n"
                                    ++ String.join "\n" mismatches
                                )

                ( Ok _, Err withIdsErrors ) ->
                    let
                        errorList =
                            NE.toList withIdsErrors
                    in
                    Expect.fail
                        ("Standard path succeeded but WithIds path failed with "
                            ++ String.fromInt (List.length errorList)
                            ++ " error(s):\n"
                            ++ (List.map typeErrorToString errorList |> String.join "\n")
                        )

                ( Err standardErrors, Ok _ ) ->
                    let
                        errorList =
                            NE.toList standardErrors
                    in
                    Expect.fail
                        ("WithIds path succeeded but standard path failed with "
                            ++ String.fromInt (List.length errorList)
                            ++ " error(s):\n"
                            ++ (List.map typeErrorToString errorList |> String.join "\n")
                        )


{-| Creates an expectation that the canonical module `modul` type-checks the
same way on the erased and the typed path.

It makes the same comparison as `expectEquivalentTypeChecking`, with no
canonicalization step, so it suits a module built directly as canonical AST
with its node ids already assigned.

-}
expectEquivalentTypeCheckingCanonical : Can.Module -> Expect.Expectation
expectEquivalentTypeCheckingCanonical modul =
    let
        standardResult =
            IO.unsafePerformIO (runStandardPath modul)

        withIdsResult =
            IO.unsafePerformIO (runWithIdsPath modul)

        allExprIds =
            extractModuleExprIds modul
    in
    case ( standardResult, withIdsResult ) of
        ( Ok _, Ok { nodeTypes } ) ->
            let
                nodeTypeIds =
                    Array.foldl
                        (\maybeType ( idx, acc ) ->
                            case maybeType of
                                Just _ ->
                                    ( idx + 1, Set.insert idx acc )

                                Nothing ->
                                    ( idx + 1, acc )
                        )
                        ( 0, Set.empty )
                        nodeTypes
                        |> Tuple.second

                missingIds =
                    Set.diff allExprIds nodeTypeIds
            in
            if Set.isEmpty missingIds then
                Expect.pass

            else
                Expect.fail
                    ("WithIds path succeeded but missing types for expression IDs: "
                        ++ (Set.toList missingIds |> List.map String.fromInt |> String.join ", ")
                        ++ "\nExpected IDs: "
                        ++ (Set.toList allExprIds |> List.map String.fromInt |> String.join ", ")
                        ++ "\nGot IDs: "
                        ++ (Set.toList nodeTypeIds |> List.map String.fromInt |> String.join ", ")
                    )

        ( Err standardErrors, Err withIdsErrors ) ->
            let
                standardErrorList =
                    NE.toList standardErrors

                withIdsErrorList =
                    NE.toList withIdsErrors

                standardCount =
                    List.length standardErrorList

                withIdsCount =
                    List.length withIdsErrorList
            in
            if standardCount /= withIdsCount then
                Expect.fail
                    ("Both paths failed but with different error counts. "
                        ++ "Standard: "
                        ++ String.fromInt standardCount
                        ++ " error(s), WithIds: "
                        ++ String.fromInt withIdsCount
                        ++ " error(s)"
                        ++ "\nStandard errors: "
                        ++ (List.map typeErrorToString standardErrorList |> String.join "; ")
                        ++ "\nWithIds errors: "
                        ++ (List.map typeErrorToString withIdsErrorList |> String.join "; ")
                    )

            else
                let
                    mismatches =
                        List.map2 compareTypeErrors standardErrorList withIdsErrorList
                            |> List.filterMap identity
                in
                if List.isEmpty mismatches then
                    Expect.pass

                else
                    Expect.fail
                        ("Both paths failed but with different error reasons:\n"
                            ++ String.join "\n" mismatches
                        )

        ( Ok _, Err withIdsErrors ) ->
            let
                errorList =
                    NE.toList withIdsErrors
            in
            Expect.fail
                ("Standard path succeeded but WithIds path failed with "
                    ++ String.fromInt (List.length errorList)
                    ++ " error(s):\n"
                    ++ (List.map typeErrorToString errorList |> String.join "\n")
                )

        ( Err standardErrors, Ok _ ) ->
            let
                errorList =
                    NE.toList standardErrors
            in
            Expect.fail
                ("WithIds path succeeded but standard path failed with "
                    ++ String.fromInt (List.length errorList)
                    ++ " error(s):\n"
                    ++ (List.map typeErrorToString errorList |> String.join "\n")
                )


{-| Returns a one-line description of a type error for a failure message: its
constructor, region, category or variable name, and the types it carries.
-}
typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr region category actualType expectedType ->
            "BadExpr at "
                ++ regionToString region
                ++ " ("
                ++ categoryToString category
                ++ ") actual="
                ++ tTypeToString actualType
                ++ " expected="
                ++ tExpectedToString expectedType

        TypeError.BadPattern region pCategory actualType expectedType ->
            "BadPattern at "
                ++ regionToString region
                ++ " ("
                ++ pCategoryToString pCategory
                ++ ") actual="
                ++ tTypeToString actualType
                ++ " expected="
                ++ tPExpectedToString expectedType

        TypeError.InfiniteType region name tType ->
            "InfiniteType at "
                ++ regionToString region
                ++ " (var: "
                ++ name
                ++ ") type="
                ++ tTypeToString tType


{-| Returns an error type as readable text for a failure message.

Type and alias names are printed without their module, and a constrained
variable by its name alone, so two different types can print the same.

-}
tTypeToString : T.Type -> String
tTypeToString tType =
    case tType of
        T.Lambda arg result rest ->
            let
                args =
                    arg :: result :: rest
            in
            "(" ++ String.join " -> " (List.map tTypeToString args) ++ ")"

        T.Infinite ->
            "Infinite"

        T.Error ->
            "Error"

        T.FlexVar name ->
            name

        T.FlexSuper _ name ->
            name

        T.RigidVar name ->
            name

        T.RigidSuper _ name ->
            name

        T.Type _ name args ->
            if List.isEmpty args then
                name

            else
                name ++ " " ++ String.join " " (List.map tTypeToString args)

        T.Record fields ext ->
            let
                fieldStrs =
                    Dict.foldr (\k v acc -> (k ++ ": " ++ tTypeToString v) :: acc) [] fields

                extStr =
                    case ext of
                        T.Closed ->
                            ""

                        T.FlexOpen name ->
                            " | " ++ name

                        T.RigidOpen name ->
                            " | " ++ name
            in
            "{ " ++ String.join ", " fieldStrs ++ extStr ++ " }"

        T.Unit ->
            "()"

        T.Tuple a b cs ->
            "( " ++ String.join ", " (List.map tTypeToString (a :: b :: cs)) ++ " )"

        T.Alias _ name args _ ->
            name ++ " " ++ String.join " " (List.map (\( _, t ) -> tTypeToString t) args)


{-| Returns an expression's expected type as text for a failure message,
naming where the expectation came from.
-}
tExpectedToString : TypeError.Expected T.Type -> String
tExpectedToString expected =
    case expected of
        TypeError.NoExpectation tType ->
            "NoExpect(" ++ tTypeToString tType ++ ")"

        TypeError.FromContext _ context tType ->
            "FromContext(" ++ contextToString context ++ ", " ++ tTypeToString tType ++ ")"

        TypeError.FromAnnotation name _ _ tType ->
            "FromAnnotation(" ++ name ++ ", " ++ tTypeToString tType ++ ")"


{-| Returns a pattern's expected type as text for a failure message, naming
where the expectation came from.
-}
tPExpectedToString : TypeError.PExpected T.Type -> String
tPExpectedToString expected =
    case expected of
        TypeError.PNoExpectation tType ->
            "PNoExpect(" ++ tTypeToString tType ++ ")"

        TypeError.PFromContext _ pContext tType ->
            "PFromContext(" ++ pContextToString pContext ++ ", " ++ tTypeToString tType ++ ")"


{-| Returns the name of a pattern context's constructor, with the name it
carries for `PTypedArg` and `PCtorArg`.
-}
pContextToString : TypeError.PContext -> String
pContextToString pContext =
    case pContext of
        TypeError.PTypedArg name _ ->
            "PTypedArg(" ++ name ++ ")"

        TypeError.PCaseMatch _ ->
            "PCaseMatch"

        TypeError.PCtorArg name _ ->
            "PCtorArg(" ++ name ++ ")"

        TypeError.PListEntry _ ->
            "PListEntry"

        TypeError.PTail ->
            "PTail"


{-| Returns the name of an expression context's constructor, without its
payload.
-}
contextToString : TypeError.Context -> String
contextToString context =
    case context of
        TypeError.ListEntry _ ->
            "ListEntry"

        TypeError.Negate ->
            "Negate"

        TypeError.OpLeft _ ->
            "OpLeft"

        TypeError.OpRight _ ->
            "OpRight"

        TypeError.IfCondition ->
            "IfCondition"

        TypeError.IfBranch _ ->
            "IfBranch"

        TypeError.CaseBranch _ ->
            "CaseBranch"

        TypeError.CallArity _ _ ->
            "CallArity"

        TypeError.CallArg _ _ ->
            "CallArg"

        TypeError.RecordAccess _ _ _ _ ->
            "RecordAccess"

        TypeError.RecordUpdateKeys _ ->
            "RecordUpdateKeys"

        TypeError.RecordUpdateValue _ ->
            "RecordUpdateValue"

        TypeError.Destructure ->
            "Destructure"


{-| Returns a region as `startRow:startCol-endRow:endCol`.
-}
regionToString : A.Region -> String
regionToString (A.Region (A.Position startRow startCol) (A.Position endRow endCol)) =
    String.fromInt startRow
        ++ ":"
        ++ String.fromInt startCol
        ++ "-"
        ++ String.fromInt endRow
        ++ ":"
        ++ String.fromInt endCol


{-| Returns the name of an expression category's constructor, without its
payload.
-}
categoryToString : TypeError.Category -> String
categoryToString category =
    case category of
        TypeError.List ->
            "List"

        TypeError.Number ->
            "Number"

        TypeError.Float ->
            "Float"

        TypeError.String ->
            "String"

        TypeError.Char ->
            "Char"

        TypeError.If ->
            "If"

        TypeError.Case ->
            "Case"

        TypeError.CallResult _ ->
            "CallResult"

        TypeError.Lambda ->
            "Lambda"

        TypeError.Accessor _ ->
            "Accessor"

        TypeError.Access _ ->
            "Access"

        TypeError.Record ->
            "Record"

        TypeError.Tuple ->
            "Tuple"

        TypeError.Unit ->
            "Unit"

        TypeError.Shader ->
            "Shader"

        TypeError.Effects ->
            "Effects"

        TypeError.Local _ ->
            "Local"

        TypeError.Foreign _ ->
            "Foreign"


{-| Returns the name of a pattern category's constructor, without its payload.
-}
pCategoryToString : TypeError.PCategory -> String
pCategoryToString pCategory =
    case pCategory of
        TypeError.PRecord ->
            "PRecord"

        TypeError.PUnit ->
            "PUnit"

        TypeError.PTuple ->
            "PTuple"

        TypeError.PList ->
            "PList"

        TypeError.PCtor _ ->
            "PCtor"

        TypeError.PInt ->
            "PInt"

        TypeError.PStr ->
            "PStr"

        TypeError.PChr ->
            "PChr"

        TypeError.PBool ->
            "PBool"


{-| Returns `Nothing` when `err1` and `err2` count as the same error, or `Just`
a description of how they differ.

They match when they have the same constructor and the same region, and in
addition the same category constructor for `BadExpr` and `BadPattern` (as
`categoriesEquivalent` and `pCategoriesEquivalent` decide) and the same
variable name for `InfiniteType`. The types an error carries are never
compared.

-}
compareTypeErrors : TypeError.Error -> TypeError.Error -> Maybe String
compareTypeErrors err1 err2 =
    case ( err1, err2 ) of
        ( TypeError.BadExpr region1 category1 _ _, TypeError.BadExpr region2 category2 _ _ ) ->
            if region1 /= region2 then
                Just
                    ("BadExpr region mismatch: "
                        ++ regionToString region1
                        ++ " vs "
                        ++ regionToString region2
                    )

            else if not (categoriesEquivalent category1 category2) then
                Just
                    ("BadExpr category mismatch: "
                        ++ categoryToString category1
                        ++ " vs "
                        ++ categoryToString category2
                    )

            else
                Nothing

        ( TypeError.BadPattern region1 pCategory1 _ _, TypeError.BadPattern region2 pCategory2 _ _ ) ->
            if region1 /= region2 then
                Just
                    ("BadPattern region mismatch: "
                        ++ regionToString region1
                        ++ " vs "
                        ++ regionToString region2
                    )

            else if not (pCategoriesEquivalent pCategory1 pCategory2) then
                Just
                    ("BadPattern category mismatch: "
                        ++ pCategoryToString pCategory1
                        ++ " vs "
                        ++ pCategoryToString pCategory2
                    )

            else
                Nothing

        ( TypeError.InfiniteType region1 name1 _, TypeError.InfiniteType region2 name2 _ ) ->
            if region1 /= region2 then
                Just
                    ("InfiniteType region mismatch: "
                        ++ regionToString region1
                        ++ " vs "
                        ++ regionToString region2
                    )

            else if name1 /= name2 then
                Just
                    ("InfiniteType name mismatch: "
                        ++ name1
                        ++ " vs "
                        ++ name2
                    )

            else
                Nothing

        _ ->
            Just
                ("Error type mismatch: "
                    ++ typeErrorToString err1
                    ++ " vs "
                    ++ typeErrorToString err2
                )


{-| Returns whether two expression categories have the same constructor. The
payload of `CallResult` (what was called) and the name carried by `Accessor`,
`Access`, `Local` and `Foreign` are ignored.
-}
categoriesEquivalent : TypeError.Category -> TypeError.Category -> Bool
categoriesEquivalent cat1 cat2 =
    case ( cat1, cat2 ) of
        ( TypeError.List, TypeError.List ) ->
            True

        ( TypeError.Number, TypeError.Number ) ->
            True

        ( TypeError.Float, TypeError.Float ) ->
            True

        ( TypeError.String, TypeError.String ) ->
            True

        ( TypeError.Char, TypeError.Char ) ->
            True

        ( TypeError.If, TypeError.If ) ->
            True

        ( TypeError.Case, TypeError.Case ) ->
            True

        ( TypeError.CallResult _, TypeError.CallResult _ ) ->
            True

        ( TypeError.Lambda, TypeError.Lambda ) ->
            True

        ( TypeError.Accessor _, TypeError.Accessor _ ) ->
            True

        ( TypeError.Access _, TypeError.Access _ ) ->
            True

        ( TypeError.Record, TypeError.Record ) ->
            True

        ( TypeError.Tuple, TypeError.Tuple ) ->
            True

        ( TypeError.Unit, TypeError.Unit ) ->
            True

        ( TypeError.Shader, TypeError.Shader ) ->
            True

        ( TypeError.Effects, TypeError.Effects ) ->
            True

        ( TypeError.Local _, TypeError.Local _ ) ->
            True

        ( TypeError.Foreign _, TypeError.Foreign _ ) ->
            True

        _ ->
            False


{-| Returns whether two pattern categories have the same constructor. The
constructor name carried by `PCtor` is ignored.
-}
pCategoriesEquivalent : TypeError.PCategory -> TypeError.PCategory -> Bool
pCategoriesEquivalent pCat1 pCat2 =
    case ( pCat1, pCat2 ) of
        ( TypeError.PRecord, TypeError.PRecord ) ->
            True

        ( TypeError.PUnit, TypeError.PUnit ) ->
            True

        ( TypeError.PTuple, TypeError.PTuple ) ->
            True

        ( TypeError.PList, TypeError.PList ) ->
            True

        ( TypeError.PCtor _, TypeError.PCtor _ ) ->
            True

        ( TypeError.PInt, TypeError.PInt ) ->
            True

        ( TypeError.PStr, TypeError.PStr ) ->
            True

        ( TypeError.PChr, TypeError.PChr ) ->
            True

        ( TypeError.PBool, TypeError.PBool ) ->
            True

        _ ->
            False


{-| Type-checks `modul` on the erased path: generates its constraints with
`ConstrainErased.constrain` and solves them with `Solve.run`, giving the
solver's errors or its annotations.
-}
runStandardPath : Can.Module -> IO.IO (Result (NE.Nonempty TypeError.Error) (Dict Name.Name (Can.Annotation Name)))
runStandardPath modul =
    ConstrainErased.constrain modul
        |> IO.andThen Solve.run


{-| Type-checks `modul` on the typed path: generates its constraints and node
variables with `ConstrainTyped.constrainWithIds` and solves them with
`Solve.runWithIds`, giving the solver's errors or its full result, `nodeTypes`
included. The scheme binder variables `constrainWithIds` also returns are
dropped.
-}
runWithIdsPath :
    Can.Module
    ->
        IO.IO
            (Result
                (NE.Nonempty TypeError.Error)
                { annotations : Dict Name.Name (Can.Annotation Name)
                , nodeTypes : Array.Array (Maybe (Can.Type Name))
                , nodeVars : Array.Array (Maybe Vars.Variable)
                , annotationVars : Dict Name.Name Vars.Variable
                , solverState :
                    { cells : Array.Array Vars.PointCell
                    }
                }
            )
runWithIdsPath modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars, _ ) ->
                Solve.runWithIds constraint nodeVars
            )


{-| Returns the node id of every expression in the module's declarations.
-}
extractModuleExprIds : Can.Module -> Set Int
extractModuleExprIds (Can.Module { decls }) =
    extractDeclsExprIds decls


{-| Returns the expression ids of every definition in a chain of declarations,
recursive groups included.
-}
extractDeclsExprIds : Can.Decls -> Set Int
extractDeclsExprIds decls =
    case decls of
        Can.Declare def rest ->
            Set.union (extractDefExprIds def) (extractDeclsExprIds rest)

        Can.DeclareRec def defs rest ->
            List.foldl
                (\d acc -> Set.union (extractDefExprIds d) acc)
                (Set.union (extractDefExprIds def) (extractDeclsExprIds rest))
                defs

        Can.SaveTheEnvironment ->
            Set.empty


{-| Returns the expression ids of a definition's body. Its argument patterns
are walked too, but contribute none (see `extractPatternExprIds`).
-}
extractDefExprIds : Can.Def -> Set Int
extractDefExprIds def =
    case def of
        Can.Def _ patterns expr ->
            Set.union
                (List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns)
                (extractAllExprIds expr)

        Can.TypedDef _ _ patternsWithTypes expr _ ->
            Set.union
                (List.foldl (\( p, _ ) acc -> Set.union (extractPatternExprIds p) acc) Set.empty patternsWithTypes)
                (extractAllExprIds expr)


{-| Returns the id of an expression together with the ids of every expression
nested inside it.
-}
extractAllExprIds : Can.Expr -> Set Int
extractAllExprIds (A.At _ { id, node }) =
    Set.insert id (extractExprNodeIds node)


{-| Returns the ids of the expressions nested in an expression node, not
including the node's own id, which the enclosing `Can.Expr` holds.
-}
extractExprNodeIds : Can.Expr_ -> Set Int
extractExprNodeIds node =
    case node of
        Can.VarLocal _ ->
            Set.empty

        Can.VarTopLevel _ _ ->
            Set.empty

        Can.VarKernel _ _ _ ->
            Set.empty

        Can.VarForeign _ _ _ ->
            Set.empty

        Can.VarCtor _ _ _ _ _ ->
            Set.empty

        Can.VarDebug _ _ _ ->
            Set.empty

        Can.VarOperator _ _ _ _ ->
            Set.empty

        Can.Chr _ ->
            Set.empty

        Can.Str _ ->
            Set.empty

        Can.Int _ ->
            Set.empty

        Can.Float _ ->
            Set.empty

        Can.List exprs ->
            List.foldl (\e acc -> Set.union (extractAllExprIds e) acc) Set.empty exprs

        Can.Negate expr ->
            extractAllExprIds expr

        Can.Binop _ _ _ _ left right ->
            Set.union (extractAllExprIds left) (extractAllExprIds right)

        Can.Lambda patterns body ->
            Set.union
                (List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns)
                (extractAllExprIds body)

        Can.Call func args ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (extractAllExprIds func)
                args

        Can.If branches final ->
            List.foldl
                (\( cond, then_ ) acc ->
                    Set.union (extractAllExprIds cond) (Set.union (extractAllExprIds then_) acc)
                )
                (extractAllExprIds final)
                branches

        Can.Let def body ->
            Set.union (extractDefExprIds def) (extractAllExprIds body)

        Can.LetRec defs body ->
            List.foldl
                (\d acc -> Set.union (extractDefExprIds d) acc)
                (extractAllExprIds body)
                defs

        Can.LetDestruct pattern expr body ->
            Set.union
                (extractPatternExprIds pattern)
                (Set.union (extractAllExprIds expr) (extractAllExprIds body))

        Can.Case subject branches ->
            List.foldl
                (\(Can.CaseBranch pattern body) acc ->
                    Set.union (extractPatternExprIds pattern) (Set.union (extractAllExprIds body) acc)
                )
                (extractAllExprIds subject)
                branches

        Can.Accessor _ ->
            Set.empty

        Can.Access record _ ->
            extractAllExprIds record

        Can.Update record fields ->
            Data.Map.foldl
                (\_ (Can.FieldUpdate _ expr) acc -> Set.union (extractAllExprIds expr) acc)
                (extractAllExprIds record)
                fields

        Can.Record fields ->
            Data.Map.foldl (\_ expr acc -> Set.union (extractAllExprIds expr) acc) Set.empty fields

        Can.Unit ->
            Set.empty

        Can.Tuple a b rest ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (Set.union (extractAllExprIds a) (extractAllExprIds b))
                rest

        Can.Shader _ _ ->
            Set.empty


{-| Returns the empty set for every pattern.

It walks the nested sub-patterns, but a pattern contains no expression, and
the node id each pattern carries is never collected.

-}
extractPatternExprIds : Can.Pattern -> Set Int
extractPatternExprIds (A.At _ { node }) =
    case node of
        Can.PAnything ->
            Set.empty

        Can.PVar _ ->
            Set.empty

        Can.PRecord _ ->
            Set.empty

        Can.PAlias pattern _ ->
            extractPatternExprIds pattern

        Can.PUnit ->
            Set.empty

        Can.PTuple a b rest ->
            List.foldl
                (\p acc -> Set.union (extractPatternExprIds p) acc)
                (Set.union (extractPatternExprIds a) (extractPatternExprIds b))
                rest

        Can.PList patterns ->
            List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns

        Can.PCons head tail ->
            Set.union (extractPatternExprIds head) (extractPatternExprIds tail)

        Can.PBool _ _ ->
            Set.empty

        Can.PChr _ ->
            Set.empty

        Can.PStr _ _ ->
            Set.empty

        Can.PInt _ ->
            Set.empty

        Can.PCtor { args } ->
            List.foldl (\(Can.PatternCtorArg _ _ p) acc -> Set.union (extractPatternExprIds p) acc) Set.empty args
