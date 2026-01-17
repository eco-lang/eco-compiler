module Compiler.Canonicalize.DuplicateDecls exposing
    ( expectDuplicateCtorError
    , expectDuplicateDeclError
    , expectDuplicateTypeError
    , expectNoDuplicateErrors
    , expectShadowingError
    )

{-| Test logic for invariant CANON\_003: No duplicate top-level declarations.

Generate modules with intentional duplicate value, type, ctor, binop, and export names;
run canonicalization and assert it produces DuplicateDecl, DuplicateType, DuplicateCtor,
DuplicateBinop, or ExportDuplicate errors as appropriate.

-}

import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Expect


{-| Expect canonicalization to produce a DuplicateDecl error.
-}
expectDuplicateDeclError : String -> Src.Module -> Expect.Expectation
expectDuplicateDeclError expectedName modul =
    expectSpecificError
        (\error ->
            case error of
                CanError.DuplicateDecl name _ _ ->
                    name == expectedName

                _ ->
                    False
        )
        ("DuplicateDecl for '" ++ expectedName ++ "'")
        modul


{-| Expect canonicalization to produce a DuplicateType error.
-}
expectDuplicateTypeError : String -> Src.Module -> Expect.Expectation
expectDuplicateTypeError expectedName modul =
    expectSpecificError
        (\error ->
            case error of
                CanError.DuplicateType name _ _ ->
                    name == expectedName

                _ ->
                    False
        )
        ("DuplicateType for '" ++ expectedName ++ "'")
        modul


{-| Expect canonicalization to produce a DuplicateCtor error.
-}
expectDuplicateCtorError : String -> Src.Module -> Expect.Expectation
expectDuplicateCtorError expectedName modul =
    expectSpecificError
        (\error ->
            case error of
                CanError.DuplicateCtor name _ _ ->
                    name == expectedName

                _ ->
                    False
        )
        ("DuplicateCtor for '" ++ expectedName ++ "'")
        modul


{-| Expect canonicalization to produce a Shadowing error.
-}
expectShadowingError : String -> Src.Module -> Expect.Expectation
expectShadowingError expectedName modul =
    expectSpecificError
        (\error ->
            case error of
                CanError.Shadowing name _ _ ->
                    name == expectedName

                _ ->
                    False
        )
        ("Shadowing for '" ++ expectedName ++ "'")
        modul


{-| Expect canonicalization to succeed without any duplicate-related errors.
-}
expectNoDuplicateErrors : Src.Module -> Expect.Expectation
expectNoDuplicateErrors modul =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                duplicateErrors =
                    List.filter isDuplicateError errorList
            in
            if List.isEmpty duplicateErrors then
                -- Other errors are OK, we're only checking for duplicate-related errors
                Expect.pass

            else
                Expect.fail
                    ("Unexpected duplicate errors: "
                        ++ String.join ", " (List.map errorToString duplicateErrors)
                    )

        ( _, Ok _ ) ->
            Expect.pass


{-| Check if an error is a duplicate-related error.
-}
isDuplicateError : CanError.Error -> Bool
isDuplicateError error =
    case error of
        CanError.DuplicateDecl _ _ _ ->
            True

        CanError.DuplicateType _ _ _ ->
            True

        CanError.DuplicateCtor _ _ _ ->
            True

        CanError.DuplicateBinop _ _ _ ->
            True

        CanError.DuplicateField _ _ _ ->
            True

        CanError.DuplicateAliasArg _ _ _ _ ->
            True

        CanError.DuplicateUnionArg _ _ _ _ ->
            True

        CanError.DuplicatePattern _ _ _ _ ->
            True

        CanError.ExportDuplicate _ _ _ ->
            True

        CanError.Shadowing _ _ _ ->
            True

        _ ->
            False


{-| Helper to expect a specific error from canonicalization.
-}
expectSpecificError : (CanError.Error -> Bool) -> String -> Src.Module -> Expect.Expectation
expectSpecificError errorPredicate errorDescription modul =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                matchingErrors =
                    List.filter errorPredicate errorList
            in
            if List.isEmpty matchingErrors then
                Expect.fail
                    ("Expected "
                        ++ errorDescription
                        ++ " but got: "
                        ++ String.join ", " (List.map errorToString errorList)
                    )

            else
                Expect.pass

        ( _, Ok _ ) ->
            Expect.fail
                ("Expected " ++ errorDescription ++ " but canonicalization succeeded")


{-| Convert an error to a string for debugging.
-}
errorToString : CanError.Error -> String
errorToString error =
    case error of
        CanError.DuplicateDecl name _ _ ->
            "DuplicateDecl: " ++ name

        CanError.DuplicateType name _ _ ->
            "DuplicateType: " ++ name

        CanError.DuplicateCtor name _ _ ->
            "DuplicateCtor: " ++ name

        CanError.DuplicateBinop name _ _ ->
            "DuplicateBinop: " ++ name

        CanError.DuplicateField name _ _ ->
            "DuplicateField: " ++ name

        CanError.DuplicateAliasArg typeName argName _ _ ->
            "DuplicateAliasArg: " ++ typeName ++ "." ++ argName

        CanError.DuplicateUnionArg typeName argName _ _ ->
            "DuplicateUnionArg: " ++ typeName ++ "." ++ argName

        CanError.DuplicatePattern _ name _ _ ->
            "DuplicatePattern: " ++ name

        CanError.ExportDuplicate name _ _ ->
            "ExportDuplicate: " ++ name

        CanError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        _ ->
            "Other error"
