module TestLogic.Canonicalize.DuplicateDecls exposing
    ( expectDuplicateCtorError
    , expectDuplicateDeclError
    , expectDuplicateTypeError
    , expectNoDuplicateErrors
    , expectShadowingError
    )

{-| Canonicalization must reject a module that declares one name twice, or that
binds a local name already bound in an enclosing scope. This module provides the
expectations that check it, given a source module built by the caller.

Each expectation runs `Compiler.Canonicalize.Module.canonicalize` on the module, as
package `eco/example`, against the stand-in interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`, and then looks only at the errors. Warnings
are ignored, and an error's regions are never examined.

Four expectations ask for one kind of error with a given name:
`expectDuplicateDeclError` for a value, `expectDuplicateTypeError` for a type,
`expectDuplicateCtorError` for a constructor, and `expectShadowingError` for a local
binding that shadows another. Each passes when at least one reported error is of that
kind and carries that name, whatever else is reported beside it, and fails when
canonicalization succeeds.

`expectNoDuplicateErrors` asks for the opposite. It passes when canonicalization
succeeds, and also when it fails with no _duplicate-related error_, which here means
an error of one of these kinds: `DuplicateDecl`, `DuplicateType`, `DuplicateCtor`,
`DuplicateBinop`, `DuplicateField`, `DuplicateAliasArg`, `DuplicateUnionArg`,
`DuplicatePattern`, `ExportDuplicate` and `Shadowing`. Canonicalization runs in
phases and stops at the first phase that fails, so a module that fails in an early
phase for another reason (an error in its imports, say) passes without the later
phases, where duplicates are detected, being run.

There is no expectation that asks for `DuplicateBinop`, `DuplicateField`,
`DuplicateAliasArg`, `DuplicateUnionArg`, `DuplicatePattern` or `ExportDuplicate`
by name.

-}

import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Expect


{-| Returns an expectation that canonicalizing `modul` reports a `DuplicateDecl`
error for the value named `expectedName`.
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


{-| Returns an expectation that canonicalizing `modul` reports a `DuplicateType`
error for the type named `expectedName`. Two aliases, two unions, or an alias and a
union sharing the name all produce this error.
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


{-| Returns an expectation that canonicalizing `modul` reports a `DuplicateCtor`
error for the constructor named `expectedName`.
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


{-| Returns an expectation that canonicalizing `modul` reports a `Shadowing` error
for the local name `expectedName`, meaning a binding of that name inside a scope
where it is already bound locally or at the top level.
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


{-| Returns an expectation that canonicalizing `modul` reports no
duplicate-related error.

It passes when canonicalization succeeds, and also when it fails only with errors
of other kinds. On failure it lists the duplicate-related errors found.

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
                Expect.pass

            else
                Expect.fail
                    ("Unexpected duplicate errors: "
                        ++ String.join ", " (List.map errorToString duplicateErrors)
                    )

        ( _, Ok _ ) ->
            Expect.pass


{-| Returns whether `error` is duplicate-related: one of the duplicate errors
(`DuplicateDecl`, `DuplicateType`, `DuplicateCtor`, `DuplicateBinop`,
`DuplicateField`, `DuplicateAliasArg`, `DuplicateUnionArg`, `DuplicatePattern`,
`ExportDuplicate`) or `Shadowing`.
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


{-| Returns an expectation that canonicalizing `modul` reports at least one error
satisfying `errorPredicate`.

`errorDescription` names the wanted error in the failure message. When no error
matches, the message also lists every reported error, naming the duplicate-related
ones; any other kind appears only as "Other error".

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


{-| Returns a one-line description of `error` for a failure message: its kind and
the name it concerns, or "Other error" for a kind that is not duplicate-related.
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
