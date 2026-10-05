module TestLogic.Type.KernelIntrinsicsTest exposing (suite)

{-| These tests check that the type checker applies two kernel intrinsic
annotations, that it leaves a kernel without one unconstrained, and that every
row of the annotation table passes a few checks on its bookkeeping fields.

A kernel reference is a name qualified with a kernel module, such as
`Elm.Kernel.List.fromArray`, standing for a function the runtime implements
rather than for Elm code. Neither canonicalization nor the type checker checks
that the runtime has a function of that name. A kernel intrinsic annotation is
a row of the table in `Compiler.Type.KernelIntrinsics` that gives one kernel a
type. A row is keyed by the kernel's prefix (`Elm` or `Eco`), its home module
and its name. When a kernel reference has a row, the type checker checks the
use against the row's type, instantiated afresh for that use. A kernel without
a row contributes no constraint of its own, so its type is bounded only by its
context. `Compiler.Type.KernelIntrinsics` owns the table and the rules a row
must follow.

Tests 1, 2, 3 and 5 each build a module named `Test` holding one annotated
function of one argument, whose body applies a kernel reference to that
argument; test 4's module holds one unannotated definition applying a kernel to
an integer literal. Each is run through canonicalization and type checking
with `TestLogic.Type.TypeCheckErrors.typeCheck`, which keeps the errors, so a
rejection test can require the error it is about. Kernel syntax is accepted
there because canonicalization (`findVarQual` in
`Compiler.Canonicalize.Expression`) turns a reference qualified with
`Elm.Kernel.X` or `Eco.Kernel.X` into a kernel reference when the module belongs
to a kernel package, and the pipeline canonicalizes as the package
`eco/example`, which is one. Three kernels are used. `Elm.Kernel.List.fromArray`
has a row typed `List a -> List a`. `Elm.Kernel.Json.addEntry` has a row typed
`(a -> Value) -> a -> Value -> Value`. `Elm.Kernel.List.nonesuch` has no row.

What the tests establish:

  - Test 1: `fromArray` used at `List String -> List String` type checks.
  - Test 2: `fromArray` used at `List String -> List Int` is rejected with an
    error on the call's result against the enclosing annotation, which shows
    that the row's argument and result share one `a`.
  - Test 3: `fromArray` given an `Int` argument, with a `List String` result,
    is rejected with an error on the call's first argument.
  - Test 4: `badEncoder = addEntry 42` is rejected with an error on the call's
    first argument: a number literal where the row wants `a -> Value`. The
    definition is unannotated, so nothing else constrains the call and the
    row's first parameter is the only thing that can reject it.
  - Test 5: `nonesuch` used at `Int -> List String` type checks, so a kernel
    without a row is unconstrained.
  - Test 6: every entry of `KernelIntrinsics.rows` has the prefix `Elm` or
    `Eco`, a non-empty `files` whose every path contains a `/` and does not
    start with one, an `evidence` containing the text `audited:`, and a
    non-empty `useSites`. Every row that fails is reported, with its full
    kernel name and each check it fails.
  - Test 7: `KernelIntrinsics.auditedFiles` is non-empty, sorted, and has no
    repeated entry.
  - Test 8: `KernelIntrinsics.lookup` finds a row for `Elm`, `List`,
    `fromArray` and none for `Eco`, `List`, `fromArray`. The prefix has to be
    part of the key because one home and name can name two different kernels,
    such as `File.size` under `Elm` and under `Eco`.

Among what is not tested: how the type checker applies the `addField` and
`toArray` rows; the name a type error is reported under; that `useSites` and
`evidence` say anything beyond the checks of test 6; and that `auditedFiles`
agrees with any manifest.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , makeModuleWithDefs
        , makeModuleWithTypedDefs
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Type.KernelIntrinsics as KernelIntrinsics
import Expect
import Test exposing (Test)
import TestLogic.Type.TypeCheckErrors as TypeCheckErrors


{-| The eight kernel intrinsic annotation tests described above.
-}
suite : Test
suite =
    Test.describe "Kernel intrinsic annotations"
        [ Test.test "1. a use that INSTANTIATES the annotation typechecks" <|
            \() ->
                expectTypeChecks "expected the annotated use to typecheck" (fromArrayModule (tListOf tString) (tListOf tString))
        , Test.test "2. the two `a`s are CONNECTED — a result type differing from the argument is rejected" <|
            \() ->
                TypeCheckErrors.expectTypeErrorWhere
                    "List String -> List Int through fromArray to be rejected against the annotation of useFromArray (the row's shared `a`)"
                    (TypeCheckErrors.isAnnotationMismatch "useFromArray")
                    (fromArrayModule (tListOf tString) (tListOf tInt))
        , Test.test "3. fail-stop: an argument the annotation forbids is a type ERROR" <|
            \() ->
                TypeCheckErrors.expectTypeErrorWhere
                    "passing an Int to fromArray to be a type error on its first argument"
                    (TypeCheckErrors.isCallArgMismatch 0)
                    (fromArrayModule tInt (tListOf tString))
        , Test.test "4. fail-stop reaches a kernel applied to a NON-FUNCTION where the annotation wants one" <|
            \() ->
                TypeCheckErrors.expectTypeErrorWhere
                    "passing a number as Json.addEntry's encoder to be a type error on its first argument"
                    (TypeCheckErrors.isCallArgMismatch 0)
                    addEntryBadModule
        , Test.test "5. an UNANNOTATED kernel is still unconstrained (the table is opt-in)" <|
            \() ->
                expectTypeChecks "an unannotated kernel must stay unconstrained" unannotatedKernelModule
        , Test.test "6. discipline: every row is prefix-keyed, evidenced and pins its C++" <|
            \() ->
                let
                    bad =
                        List.filterMap
                            (\( ( prefix, home, name ), row ) ->
                                let
                                    key =
                                        prefix ++ ".Kernel." ++ home ++ "." ++ name

                                    problems =
                                        List.filterMap identity
                                            [ if prefix == "Elm" || prefix == "Eco" then
                                                Nothing

                                              else
                                                Just "prefix must be Elm or Eco"
                                            , if List.isEmpty row.files then
                                                Just "empty files (unguarded by the rot manifest)"

                                              else
                                                Nothing
                                            , if String.contains "audited:" row.evidence then
                                                Nothing

                                              else
                                                Just "evidence lacks an `audited:` date"
                                            , if String.isEmpty row.useSites then
                                                Just "empty useSites (the fail-stop evidence)"

                                              else
                                                Nothing
                                            , if List.all (\f -> not (String.startsWith "/" f) && String.contains "/" f) row.files then
                                                Nothing

                                              else
                                                Just "files must be repo-relative"
                                            ]
                                in
                                if List.isEmpty problems then
                                    Nothing

                                else
                                    Just (key ++ ": " ++ String.join ", " problems)
                            )
                            KernelIntrinsics.rows
                in
                Expect.equal [] bad
        , Test.test "7. discipline: auditedFiles is non-empty, sorted and deduplicated" <|
            \() ->
                let
                    files =
                        KernelIntrinsics.auditedFiles
                in
                Expect.all
                    [ \() -> Expect.notEqual [] files
                    , \() -> Expect.equal (List.sort files) files
                    , \() -> Expect.equal (List.length (dedupe (List.sort files))) (List.length files)
                    ]
                    ()
        , Test.test "8. discipline: lookup is keyed by PREFIX, not just (home, name)" <|
            \() ->
                Expect.all
                    [ \() -> Expect.notEqual Nothing (KernelIntrinsics.lookup "Elm" "List" "fromArray")
                    , \() -> Expect.equal Nothing (KernelIntrinsics.lookup "Eco" "List" "fromArray")
                    ]
                    ()
        ]


{-| Passes when `modul` type checks; otherwise fails with `what` and the
errors.
-}
expectTypeChecks : String -> Src.Module -> Expect.Expectation
expectTypeChecks what modul =
    case TypeCheckErrors.typeCheck modul of
        TypeCheckErrors.TypeChecks ->
            Expect.pass

        outcome ->
            Expect.fail (what ++ ", but " ++ TypeCheckErrors.describeOutcome outcome)


{-| Removes each element that equals the one before it, so a sorted list loses
its repeats.
-}
dedupe : List String -> List String
dedupe xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupe (b :: rest)

            else
                a :: dedupe (b :: rest)

        _ ->
            xs


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The source type `String`.
-}
tString : Src.Type
tString =
    tType "String" []


{-| Builds the source type `List el`.
-}
tListOf : Src.Type -> Src.Type
tListOf el =
    tType "List" [ el ]


{-| Builds a module whose one function, `useFromArray`, is annotated
`argType -> resultType` and returns `Elm.Kernel.List.fromArray` applied to its
argument.
-}
fromArrayModule : Src.Type -> Src.Type -> Src.Module
fromArrayModule argType resultType =
    makeModuleWithTypedDefs "Test"
        [ { name = "useFromArray"
          , args = [ pVar "x" ]
          , tipe = tLambda argType resultType
          , body = callExpr (qualVarExpr "Elm.Kernel.List" "fromArray") [ varExpr "x" ]
          }
        ]


{-| A module whose one definition, `badEncoder`, is unannotated and is
`Elm.Kernel.Json.addEntry` applied to the integer literal `42` alone.

It is unannotated so that nothing but `addEntry`'s row constrains the call:
the partial application's result, `a -> Value -> Value`, is free to be
whatever it is, and the literal, a `number`, contradicts only the row's first
parameter, `a -> Value`.

-}
addEntryBadModule : Src.Module
addEntryBadModule =
    makeModuleWithDefs "Test"
        [ ( "badEncoder"
          , []
          , callExpr (qualVarExpr "Elm.Kernel.Json" "addEntry") [ intExpr 42 ]
          )
        ]


{-| A module whose one function, `useUnannotated`, is annotated
`Int -> List String` and returns `Elm.Kernel.List.nonesuch` applied to its
argument. No row exists for `nonesuch`, so nothing ties the argument to the
result.
-}
unannotatedKernelModule : Src.Module
unannotatedKernelModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "useUnannotated"
          , args = [ pVar "x" ]
          , tipe = tLambda tInt (tListOf tString)
          , body = callExpr (qualVarExpr "Elm.Kernel.List" "nonesuch") [ varExpr "x" ]
          }
        ]
