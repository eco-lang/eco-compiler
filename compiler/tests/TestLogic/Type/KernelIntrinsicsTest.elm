module TestLogic.Type.KernelIntrinsicsTest exposing (suite)

{-| Intrinsic kernel type annotations
(`plans/kernel-intrinsic-annotations.md`).

A kernel reference used to generate `CTrue` — no constraint at all — so an
inline-used kernel was bounded by nothing and `List.toArray` behaved as
`α -> β` with the two sides never equated. A row in
`Compiler.Type.KernelIntrinsics` makes the generator emit a `CForeign`, which
the solver instantiates fresh per occurrence and unifies with the context.

The behavioural tests below run the real canonicalize+typecheck pipeline over
fixtures that write kernel syntax directly. That is legal here because
`Canonicalize.Expression.findVarQual` produces a `Can.VarKernel` when the
prefix is `Elm.Kernel.*`/`Eco.Kernel.*` AND the enclosing package is a kernel
package — and the test harness canonicalizes as `( "eco", "example" )`, which
`Pkg.isKernel` accepts.

Test 2 is the one that matters: it pins that the two `a`s in `List a -> List a`
are now the SAME `a`. Before intrinsics that fixture typechecked, because
nothing connected them.

Tests 3-4 pin the FAIL-STOP contract from the other side: a use that
contradicts the annotation must produce a type ERROR, not a crash and not
silent acceptance. That property is what makes the table dangerous enough to
need `useSites` evidence per row, so it deserves a test rather than a comment.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
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
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Kernel intrinsic annotations"
        [ Test.test "1. a use that INSTANTIATES the annotation typechecks" <|
            \() ->
                -- `List.fromArray : List a -> List a` at a = String, which is
                -- exactly elm/core's `String.split` use site.
                case Pipeline.runToTypeCheck (fromArrayModule (tListOf tString) (tListOf tString)) of
                    Ok _ ->
                        Expect.pass

                    Err msg ->
                        Expect.fail ("expected the annotated use to typecheck, got: " ++ msg)
        , Test.test "2. the two `a`s are CONNECTED — a result type differing from the argument is rejected" <|
            \() ->
                -- THE pin for this whole change. `List String -> List Int`
                -- through `fromArray` must fail, because the annotation shares
                -- one `a` across argument and result. Pre-intrinsics this
                -- typechecked: the kernel contributed `CTrue`, so the argument
                -- and result types were never equated and the kernel behaved as
                -- `α -> β`.
                case Pipeline.runToTypeCheck (fromArrayModule (tListOf tString) (tListOf tInt)) of
                    Err _ ->
                        Expect.pass

                    Ok _ ->
                        Expect.fail "List String -> List Int through fromArray must NOT typecheck — the annotation's shared `a` is not being enforced"
        , Test.test "3. fail-stop: an argument the annotation forbids is a type ERROR" <|
            \() ->
                -- `Int` cannot instantiate `List a`.
                case Pipeline.runToTypeCheck (fromArrayModule tInt (tListOf tString)) of
                    Err _ ->
                        Expect.pass

                    Ok _ ->
                        Expect.fail "passing an Int to fromArray must be a type error"
        , Test.test "4. fail-stop reaches a kernel applied to a NON-FUNCTION where the annotation wants one" <|
            \() ->
                -- `Json.addEntry`'s first parameter is `(a -> Value)`; an Int
                -- cannot instantiate it. (`Value` itself is unnameable in the
                -- mock interface env, so this fixture constrains only the
                -- parameter — which is the position the row's shape asserts.)
                case Pipeline.runToTypeCheck addEntryBadModule of
                    Err _ ->
                        Expect.pass

                    Ok _ ->
                        Expect.fail "passing an Int as Json.addEntry's encoder must be a type error"
        , Test.test "5. an UNANNOTATED kernel is still unconstrained (the table is opt-in)" <|
            \() ->
                -- Negative control. `Elm.Kernel.List.nonesuch` has no row, so
                -- the generator still emits `CTrue` and any shape is accepted.
                -- If this ever fails, something started constraining kernels
                -- globally and the opt-in property is gone.
                case Pipeline.runToTypeCheck unannotatedKernelModule of
                    Ok _ ->
                        Expect.pass

                    Err msg ->
                        Expect.fail ("an unannotated kernel must stay unconstrained, got: " ++ msg)
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
                -- `KernelSetFacts` collides on `File.size` because it drops the
                -- prefix. An annotation table must not: the two `File.size`
                -- kernels have different types. Pin that a wrong prefix misses.
                Expect.all
                    [ \() -> Expect.notEqual Nothing (KernelIntrinsics.lookup "Elm" "List" "fromArray")
                    , \() -> Expect.equal Nothing (KernelIntrinsics.lookup "Eco" "List" "fromArray")
                    ]
                    ()
        ]



-- ====== HARNESS ======


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



-- ====== FIXTURES ======


tInt : Src.Type
tInt =
    tType "Int" []


tString : Src.Type
tString =
    tType "String" []


tListOf : Src.Type -> Src.Type
tListOf el =
    tType "List" [ el ]


{-| `f : <argType> -> <resultType>` whose body is `Elm.Kernel.List.fromArray x`.
Varying the two types is what tests 1-3 do.
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


addEntryBadModule : Src.Module
addEntryBadModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "badEncoder"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt (tListOf tInt)
          , body = callExpr (qualVarExpr "Elm.Kernel.Json" "addEntry") [ varExpr "n" ]
          }
        ]


{-| Negative control: no row for this name, so it stays `CTrue` and the
deliberately absurd shape is accepted.
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
