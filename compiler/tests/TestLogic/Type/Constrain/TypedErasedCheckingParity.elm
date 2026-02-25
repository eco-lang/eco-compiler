module TestLogic.Type.Constrain.TypedErasedCheckingParity exposing
    ( expectEquivalentTypeChecking
    , expectEquivalentTypeCheckingCanonical
    )

{-| Shared test infrastructure for constraint equivalence testing.

This module provides test runners that compare `constrain` and `constrainWithIds` paths.

For Canonical AST builders, use Compiler.AST.CanonicalBuilder.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
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
import Data.Map as Dict exposing (Dict)
import Expect
import Set exposing (Set)
import System.TypeCheck.IO as IO


{-| Convert a canonicalization error to a string for debugging.
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



-- ============================================================================
-- TEST INFRASTRUCTURE
-- ============================================================================


{-| Run both constraint paths and verify they produce equivalent results.

Both paths should either:

  - Both succeed (annotations may differ in internal details but should be equivalent)
  - Both fail with errors

Additionally, when WithIds path succeeds, we verify that ALL expression IDs
from the original module are present in the nodeTypes map.

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

                -- Extract all expression IDs from the module
                allExprIds =
                    extractModuleExprIds modul
            in
            case ( standardResult, withIdsResult ) of
                ( Ok _, Ok { nodeTypes } ) ->
                    -- Both succeeded - now check that all IDs are in nodeTypes
                    let
                        nodeTypeIds =
                            Dict.keys compare nodeTypes |> Set.fromList

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
                    -- Both failed - check if they failed for equivalent reasons
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
                        -- Check that errors are equivalent
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


{-| Run both constraint paths on a Canonical module and verify they produce equivalent results.

This skips canonicalization and directly tests the constraint generation paths.
Useful for testing kernel variables and other constructs that can only be created
by directly constructing canonical AST.

-}
expectEquivalentTypeCheckingCanonical : Can.Module -> Expect.Expectation
expectEquivalentTypeCheckingCanonical modul =
    let
        standardResult =
            IO.unsafePerformIO (runStandardPath modul)

        withIdsResult =
            IO.unsafePerformIO (runWithIdsPath modul)

        -- Extract all expression IDs from the module
        allExprIds =
            extractModuleExprIds modul
    in
    case ( standardResult, withIdsResult ) of
        ( Ok _, Ok { nodeTypes } ) ->
            -- Both succeeded - now check that all IDs are in nodeTypes
            let
                nodeTypeIds =
                    Dict.keys compare nodeTypes |> Set.fromList

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
            -- Both failed - check if they failed for equivalent reasons
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
                -- Check that errors are equivalent
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


{-| Convert a type error to a string for debugging output.
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


{-| Convert a T.Type to a string for debugging.
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
                    Dict.foldr compare (\k v acc -> (k ++ ": " ++ tTypeToString v) :: acc) [] fields

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


{-| Convert a TypeError.Expected to a string for debugging.
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


{-| Convert a TypeError.PExpected to a string for debugging.
-}
tPExpectedToString : TypeError.PExpected T.Type -> String
tPExpectedToString expected =
    case expected of
        TypeError.PNoExpectation tType ->
            "PNoExpect(" ++ tTypeToString tType ++ ")"

        TypeError.PFromContext _ pContext tType ->
            "PFromContext(" ++ pContextToString pContext ++ ", " ++ tTypeToString tType ++ ")"


{-| Convert a PContext to a string.
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


{-| Convert a Context to a string.
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


{-| Convert a region to a string for debugging.
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


{-| Convert an expression category to a string.
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


{-| Convert a pattern category to a string.
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


{-| Compare two type errors for equivalence.
Returns Nothing if they match, or Just a description of the mismatch.
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


{-| Check if two categories are equivalent.
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


{-| Check if two pattern categories are equivalent.
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


{-| Run the standard constraint generation and solving path.
Returns actual errors instead of just a count.
-}
runStandardPath : Can.Module -> IO.IO (Result (NE.Nonempty TypeError.Error) (Dict String Name.Name Can.Annotation))
runStandardPath modul =
    ConstrainErased.constrain modul
        |> IO.andThen Solve.run


{-| Run the WithIds constraint generation and solving path.
Returns both annotations and the nodeTypes map, or actual errors.
-}
runWithIdsPath : Can.Module -> IO.IO (Result (NE.Nonempty TypeError.Error) { annotations : Dict String Name.Name Can.Annotation, nodeTypes : Dict Int Int Can.Type })
runWithIdsPath modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars ) ->
                Solve.runWithIds constraint nodeVars
            )


{-| Extract all expression IDs from a module.
-}
extractModuleExprIds : Can.Module -> Set Int
extractModuleExprIds (Can.Module { decls }) =
    extractDeclsExprIds decls


{-| Extract expression IDs from declarations.
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


{-| Extract expression IDs from a definition.
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


{-| Extract all expression IDs from an expression (recursively).
-}
extractAllExprIds : Can.Expr -> Set Int
extractAllExprIds (A.At _ { id, node }) =
    Set.insert id (extractExprNodeIds node)


{-| Extract expression IDs from an expression node.
-}
extractExprNodeIds : Can.Expr_ -> Set Int
extractExprNodeIds node =
    case node of
        Can.VarLocal _ ->
            Set.empty

        Can.VarTopLevel _ _ ->
            Set.empty

        Can.VarKernel _ _ ->
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
            Dict.foldl A.compareLocated
                (\_ (Can.FieldUpdate _ expr) acc -> Set.union (extractAllExprIds expr) acc)
                (extractAllExprIds record)
                fields

        Can.Record fields ->
            Dict.foldl A.compareLocated (\_ expr acc -> Set.union (extractAllExprIds expr) acc) Set.empty fields

        Can.Unit ->
            Set.empty

        Can.Tuple a b rest ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (Set.union (extractAllExprIds a) (extractAllExprIds b))
                rest

        Can.Shader _ _ ->
            Set.empty


{-| Extract expression IDs from a pattern (patterns don't have expression IDs,
but they may contain nested patterns that we need to traverse).
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
