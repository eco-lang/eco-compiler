module TestLogic.Monomorphize.LssDirectedFlowTest exposing (suite)

{-| LSS_023 — directed set flow, store level
(`plans/lss-directed-set-flow.md` §7 test 4).

Legal Elm cannot reach an `LsFrom` CYCLE through the §5.2 flip sites (mutual
let VALUES are rejected by the canonicalizer; function-izing turns the
back-reference into a call → `WpOpaque` → the hub poisons), so the resolver's
cycle behaviour is tested DIRECTLY against a hand-built store rather than
through a pipeline fixture — the `LssGroundingTest` layer-1 precedent.

Deviation from the plan's sketch, recorded: content is written with `UF.set`
rather than through `Store.addSlotSource` (which is `Step`-typed and needs a
full `Engine.S`); the installer's own transitions are exercised end-to-end by
the pipeline tests in `LssSigFlowTest` (edges installed by `applyFactsGo`).
This file owns exactly the resolver semantics: termination on cycles, SCC
exactness, ⊤ short-circuit, diamond dedupe, and FlexVar contribution.

`IO.IO` is a transparent alias (`State -> ( State, a )`), so the fixture
captures the threaded state with an inline `\\st -> ( st, st )` and builds the
`ZonkCtx` record directly — `resolveSlotMembers` reads only its `store` field.

-}

import Compiler.AST.Intern as Intern
import Dict
import Compiler.AST.TypeIds as TypeIds
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.describe "LSS_023 directed set flow (resolver, store level)"
        [ Test.test "1. a 2-cycle terminates and reads the exact SCC union" <|
            \() ->
                -- A = LsFrom [1] [B]; B = LsFrom [2] [A]. Resolving A must
                -- terminate (entry-marked visited) and read {1,2} — every SCC
                -- node's own members, each exactly once.
                let
                    ( resA, resB ) =
                        IO.unsafePerformIO
                            (mint (IO.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (IO.FlexVar Nothing)
                                            |> IO.andThen
                                                (\b ->
                                                    UF.set a (desc (lsFrom [ 1 ] [ b ]))
                                                        |> IO.andThen (\_ -> UF.set b (desc (lsFrom [ 2 ] [ a ])))
                                                        |> IO.andThen
                                                            (\_ ->
                                                                captureState
                                                                    |> IO.map
                                                                        (\st ->
                                                                            ( resolveAt st [ 1 ] [ b ]
                                                                            , resolveAt st [ 2 ] [ a ]
                                                                            )
                                                                        )
                                                            )
                                                )
                                    )
                            )
                in
                Expect.equal ( Just [ 1, 2 ], Just [ 1, 2 ] ) ( resA, resB )
        , Test.test "2. a reachable ⊤ short-circuits the whole resolution to Nothing" <|
            \() ->
                let
                    res =
                        IO.unsafePerformIO
                            (mint (IO.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (IO.Structure (IO.LambdaSet1 (IO.LsTop 7)))
                                            |> IO.andThen
                                                (\b ->
                                                    UF.set a (desc (lsFrom [ 1 ] [ b ]))
                                                        |> IO.andThen (\_ -> captureState |> IO.map (\st -> resolveAt st [ 1 ] [ b ]))
                                                )
                                    )
                            )
                in
                Expect.equal Nothing res
        , Test.test "3. ⊤ INSIDE a cycle still short-circuits" <|
            \() ->
                -- A ⊇ B ⊇ C ⊇ A with C = ⊤ (written after edge setup).
                let
                    res =
                        IO.unsafePerformIO
                            (mint (IO.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (IO.FlexVar Nothing)
                                            |> IO.andThen
                                                (\b ->
                                                    mint (IO.FlexVar Nothing)
                                                        |> IO.andThen
                                                            (\c ->
                                                                UF.set a (desc (lsFrom [ 1 ] [ b ]))
                                                                    |> IO.andThen (\_ -> UF.set b (desc (lsFrom [ 2 ] [ c ])))
                                                                    |> IO.andThen (\_ -> UF.set c (desc (IO.Structure (IO.LambdaSet1 (IO.LsTop 7)))))
                                                                    |> IO.andThen (\_ -> captureState |> IO.map (\st -> resolveAt st [ 1 ] [ b ]))
                                                            )
                                                )
                                    )
                            )
                in
                Expect.equal Nothing res
        , Test.test "4. diamond edges dedupe: a doubly-reachable source contributes once" <|
            \() ->
                -- A ⊇ {B, C}; B ⊇ D; C ⊇ D; D = LsMembers [9].
                let
                    res =
                        IO.unsafePerformIO
                            (mint (IO.FlexVar Nothing)
                                |> IO.andThen
                                    (\b ->
                                        mint (IO.FlexVar Nothing)
                                            |> IO.andThen
                                                (\c ->
                                                    mint (IO.Structure (IO.LambdaSet1 (IO.LsMembers [ 9 ])))
                                                        |> IO.andThen
                                                            (\d ->
                                                                UF.set b (desc (lsFrom [ 3 ] [ d ]))
                                                                    |> IO.andThen (\_ -> UF.set c (desc (lsFrom [ 5 ] [ d ])))
                                                                    |> IO.andThen (\_ -> captureState |> IO.map (\st -> resolveAt st [ 1 ] [ b, c ]))
                                                            )
                                                )
                                    )
                            )
                in
                Expect.equal (Just [ 1, 3, 5, 9 ]) res
        , Test.test "5. a FlexVar source contributes nothing (and does not poison)" <|
            \() ->
                let
                    res =
                        IO.unsafePerformIO
                            (mint (IO.FlexVar Nothing)
                                |> IO.andThen
                                    (\b -> captureState |> IO.map (\st -> resolveAt st [ 7 ] [ b ]))
                            )
                in
                Expect.equal (Just [ 7 ]) res
        ]



-- ====== HARNESS ======


mint : IO.Content -> IO.IO IO.Variable
mint content =
    UF.fresh (desc content)


desc : IO.Content -> IO.Descriptor
desc content =
    IO.makeDescriptor content Type.noRank Type.noMark Nothing


lsFrom : List Int -> List IO.Variable -> IO.Content
lsFrom members sources =
    IO.Structure (IO.LambdaSet1 (IO.LsFrom members sources))


captureState : IO.IO IO.State
captureState =
    \st -> ( st, st )


{-| Run the resolver against a captured store. Only `store` is read by
`resolveSlotMembers`; the other `ZonkCtx` fields are inert placeholders.
-}
resolveAt : IO.State -> List Int -> List IO.Variable -> Maybe (List Int)
resolveAt st members sources =
    Store.resolveSlotMembers members
        sources
        { store = st
        , next = TypeIds.firstMVarId
        , lss = Nothing
        , ecoReads = []
        , intern = Intern.empty
        , memberTable = Engine.emptyMemberTable
        , nextMemberId = 0
        , arrowOf = Dict.empty
        , varOf = Dict.empty
        , nextVar = 0
        }
        |> Tuple.first
