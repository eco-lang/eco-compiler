module TestLogic.Type.UnificationErrors exposing
    ( expectNoTypeErrors
    , expectTypeMismatchError
    )

{-| Test logic for invariant TYPE\_002: Unification failures become type errors.

Craft constraints with known conflicting types (e.g., unify Int and String).
Run solver and assert a Type.Error is produced and the final result surfaces
as BadTypes. Assert there is no path where inconsistencies are silently dropped.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Error as T
import Compiler.Type.Solve as Solve
import Data.Map
import Dict
import Expect
import System.TypeCheck.IO as IO


{-| Expect a type mismatch error (BadExpr or BadPattern).
-}
expectTypeMismatchError : Src.Module -> Expect.Expectation
expectTypeMismatchError srcModule =
    case canonicalizeModule srcModule of
        Err msg ->
            Expect.fail msg

        Ok modul ->
            let
                result =
                    IO.unsafePerformIO (runTypeCheck modul)
            in
            case result of
                Err errors ->
                    let
                        errorList =
                            NE.toList errors

                        hasMismatch =
                            List.any isMismatchError errorList
                    in
                    if hasMismatch then
                        Expect.pass

                    else
                        Expect.fail
                            ("Expected a type mismatch error but got: "
                                ++ (List.map typeErrorToString errorList |> String.join ", ")
                            )

                Ok _ ->
                    Expect.fail "Expected a type mismatch error but type checking succeeded"


{-| Expect type checking to succeed without errors.
-}
expectNoTypeErrors : Src.Module -> Expect.Expectation
expectNoTypeErrors srcModule =
    case canonicalizeModule srcModule of
        Err msg ->
            Expect.fail msg

        Ok modul ->
            let
                result =
                    IO.unsafePerformIO (runTypeCheck modul)
            in
            case result of
                Err errors ->
                    let
                        errorList =
                            NE.toList errors
                    in
                    Expect.fail
                        ("Expected no type errors but got: "
                            ++ (List.map typeErrorToString errorList |> String.join ", ")
                        )

                Ok _ ->
                    Expect.pass


{-| Check if an error is a type mismatch.
-}
isMismatchError : TypeError.Error -> Bool
isMismatchError error =
    case error of
        TypeError.BadExpr _ _ _ _ ->
            True

        TypeError.BadPattern _ _ _ _ ->
            True

        TypeError.InfiniteType _ _ _ ->
            False


{-| Canonicalize a source module.
-}
canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) (Data.Map.fromList identity (Dict.toList Basic.testIfaces)) srcModule
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                firstError =
                    List.head errorList
                        |> Maybe.map canErrorToString
                        |> Maybe.withDefault "unknown"
            in
            Err ("Canonicalization failed: " ++ firstError)

        ( _, Ok modul ) ->
            Ok modul


{-| Run type checking on a canonical module.
-}
runTypeCheck :
    Can.Module
    ->
        IO.IO
            (Result
                (NE.Nonempty TypeError.Error)
                { annotations : Data.Map.Dict String String Can.Annotation
                , nodeTypes : Array.Array (Maybe Can.Type)
                , nodeVars : Array.Array (Maybe IO.Variable)
                , annotationVars : Data.Map.Dict String String IO.Variable
                , solverState :
                    { descriptors : Array.Array IO.Descriptor
                    , pointInfo : Array.Array IO.PointInfo
                    , weights : Array.Array Int
                    }
                }
            )
runTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars ) ->
                Solve.runWithIds constraint nodeVars
            )


{-| Convert a type error to a string.
-}
typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr region _ actualType _ ->
            "BadExpr at "
                ++ regionToString region
                ++ ": "
                ++ tTypeToString actualType
                ++ " vs expected"

        TypeError.BadPattern region _ _ _ ->
            "BadPattern at " ++ regionToString region

        TypeError.InfiniteType region name _ ->
            "InfiniteType: " ++ name ++ " at " ++ regionToString region


{-| Convert a canonicalization error to a string.
-}
canErrorToString : CanError.Error -> String
canErrorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        _ ->
            "Other canonicalization error"


{-| Convert a region to a string.
-}
regionToString : A.Region -> String
regionToString (A.Region (A.Position startRow startCol) (A.Position _ _)) =
    String.fromInt startRow ++ ":" ++ String.fromInt startCol


{-| Convert a T.Type to a string.
-}
tTypeToString : T.Type -> String
tTypeToString tType =
    case tType of
        T.Type _ name _ ->
            name

        T.FlexVar name ->
            name

        T.RigidVar name ->
            name

        T.Unit ->
            "()"

        _ ->
            "..."
