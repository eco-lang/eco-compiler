module TestLogic.GlobalOpt.BorrowTailCallEscapeTest exposing (suite)

{-| Borrow inference decides where a heap value is dead from how long it is
live, and the arguments of a tail call are values the function's next
iteration still uses. Without this test, a change to the analysis could let a
tail-call argument be reported dead before the function body ends, which would
allow it to be released while still in use.

The analysis tracks _resources_: one per heap position of a value's type,
numbered from 0 within each definition. A scalar such as an `Int` has none, and
a `List Int` has one. For each resource, `Compiler.GlobalOpt.Borrow.Solve`
computes an approximate lifetime, `ltA`, the latest point at which the resource
is live, as `Compiler.GlobalOpt.Borrow.Lifetime` describes. The point this test
asks about is the empty path, which is the end of the whole function body.
`Compiler.GlobalOpt.Borrow.Constrain` seeds every resource of a `MonoTailCall`
argument at that point (in the test's own messages, it is _escape-seeded_), so
its `ltA` should reach the end of the body.

The fixture, `fixtureModule`, is one tail-recursive function `loop` whose
accumulator is a `List Int`, plus a `testValue` that calls it. It is compiled
through `TestLogic.TestPipeline.runToGlobalOpt`, and `loop` is expected to come
out as a `MonoTailFunc` whose body holds a `MonoTailCall`.

The one test, `suite`, takes one `MonoTailFunc` whose tail calls have argument
resources, analyses it with `Compiler.GlobalOpt.Borrow.analyzeDefForTest`, and
checks:

  - that every tail-call argument resource has an `ltA` that is not `LEmpty`
    and that `Lifetime.endsBefore` does not report dead at the end of the body;
  - that at least one resource of the same definition has a local `ltA` (not
    `LEmpty`) that `endsBefore` reports dead there, so the first check is not
    passing because `endsBefore` answers `False` for every live resource. The
    let-bound list `xs` in the fixture is that resource: the `case` reads it
    inside the `else` arm, so its lifetime ends there.

It fails if the pipeline fails or if no `MonoTailFunc` with tail-call argument
resources is found.

Among what is not tested: any `MonoTailFunc` other than the one taken, the
precise lifetimes `ltP`, access modes, the escape analysis that the borrow
census starts from the tail-call resources, which local resource satisfies the
second check, and whether any later stage places
or omits a release after a tail call.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as B
import Compiler.GlobalOpt.Borrow as Borrow
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime(..))
import Compiler.GlobalOpt.Borrow.Solve as Solve
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The single test: compiles `fixtureModule` with
`TestLogic.TestPipeline.runToGlobalOpt` and checks the optimized graph with
`checkGraph`. A pipeline failure fails the test with the pipeline's message.
-}
suite : Test
suite =
    Test.test "BORROW_005: MonoTailCall heap args are escape-seeded (never dead at/before the tail call)" <|
        \_ ->
            case Pipeline.runToGlobalOpt fixtureModule of
                Err msg ->
                    Expect.fail ("pipeline: " ++ msg)

                Ok { optimizedMonoGraph } ->
                    checkGraph optimizedMonoGraph


{-| The source module `Test`, with two annotated definitions. Written as Elm,
they are:

    loop : Int -> List Int -> List Int
    loop n acc =
        if n <= 0 then
            acc

        else
            let
                xs =
                    [ n, n ]
            in
            case xs of
                x :: _ ->
                    loop (n - 1) (x :: acc)

                _ ->
                    acc

    testValue : List Int
    testValue =
        loop 10 []

The self-call in the `case` branch is the tail call. Of its two arguments, only
`x :: acc` has a resource. `xs` is a heap value that is live only up to the
`case`, which gives the negative control a resource that is dead at the end of
the body. `testValue` is there so that the test pipeline's
generated `main` reaches `loop`.

-}
fixtureModule : Src.Module
fixtureModule =
    let
        intType =
            B.tType "Int" []

        listIntType =
            B.tType "List" [ intType ]

        loopBody =
            B.ifExpr
                (B.binopsExpr [ ( B.varExpr "n", "<=" ) ] (B.intExpr 0))
                (B.varExpr "acc")
                (B.letExpr [ B.define "xs" [] (B.listExpr [ B.varExpr "n", B.varExpr "n" ]) ]
                    (B.caseExpr (B.varExpr "xs")
                        [ ( B.pCons (B.pVar "x") B.pAnything
                          , B.callExpr (B.varExpr "loop")
                                [ B.binopsExpr [ ( B.varExpr "n", "-" ) ] (B.intExpr 1)
                                , B.binopsExpr [ ( B.varExpr "x", "::" ) ] (B.varExpr "acc")
                                ]
                          )
                        , ( B.pAnything, B.varExpr "acc" )
                        ]
                    )
                )
    in
    B.makeModuleWithTypedDefs "Test"
        [ { name = "loop"
          , args = [ B.pVar "n", B.pVar "acc" ]
          , tipe = B.tLambda intType (B.tLambda listIntType listIntType)
          , body = loopBody
          }
        , { name = "testValue"
          , args = []
          , tipe = listIntType
          , body = B.callExpr (B.varExpr "loop") [ B.intExpr 10, B.listExpr [] ]
          }
        ]


{-| Returns the test's expectation for the optimized graph `graph`.

It collects the `MonoTailFunc` nodes, analyses each with
`Compiler.GlobalOpt.Borrow.analyzeDefForTest`, and keeps those whose tail-call
argument resources are not empty. Of those, it checks only the one with the
highest `SpecId`, and fails if there is none. For that one, it expects both
that no tail-call argument resource has an `ltA` that is `LEmpty` or that
`Lifetime.endsBefore` reports dead at the empty path, and that some resource of
the definition, any number below its resource count, has an `ltA` other than
`LEmpty` that `endsBefore` reports dead there.

-}
checkGraph : Mono.MonoGraph -> Expect.Expectation
checkGraph graph =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        -- A node's SpecId is its index in `nodes`. Consing makes the list
        -- descending, so the highest SpecId is checked below.
        tailFuncSpecIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just (Mono.MonoTailFunc _ _ _) ->
                            ( specId + 1, specId :: acc )

                        _ ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second

        analyses =
            List.filterMap (\sid -> Borrow.analyzeDefForTest graph sid) tailFuncSpecIds

        withTailArgs =
            List.filter (\( _, tailArgRes, _ ) -> not (List.isEmpty tailArgRes)) analyses
    in
    case withTailArgs of
        [] ->
            Expect.fail "no MonoTailFunc with escape-seeded tail-call args was found (expected `loop`)"

        ( solved, tailArgRes, nRes ) :: _ ->
            let
                -- At the empty path, endsBefore is False only for `LLocal Star`
                -- and `LParams`, so it already rules out `LEmpty`.
                escapeOk =
                    List.all
                        (\r ->
                            ltaNonEmpty (Solve.ltAOf r solved)
                                && not (L.endsBefore (Solve.ltAOf r solved) [])
                        )
                        tailArgRes

                someDies =
                    List.any
                        (\r ->
                            ltaNonEmpty (Solve.ltAOf r solved)
                                && L.endsBefore (Solve.ltAOf r solved) []
                        )
                        (List.range 0 (nRes - 1))
            in
            Expect.equal ( True, True ) ( escapeOk, someDies )


{-| Returns whether `lt` is anything other than `LEmpty`, the lifetime of a
resource that is never live.
-}
ltaNonEmpty : Lifetime -> Bool
ltaNonEmpty lt =
    case lt of
        LEmpty ->
            False

        _ ->
            True
