module TestLogic.Monomorphize.LssDirectedFlowTest exposing (suite)

{-| Tests for `Compiler.MonoSolver.Store.resolveSlotMembers`, which reads the
members of a lambda-set slot that has inclusion edges to other slots. Without
them, a resolver that loops on a cycle of edges, misses a reachable ⊤, or drops
the members of a source could go unnoticed.

A lambda-set slot is a union-find point whose content is a lambda set, as
`Compiler.Type.Vars.LambdaSet` describes. Three kinds of content matter here.
`LsMembers` holds known member ids. `LsTop` is ⊤, meaning the members are not
known. `LsFrom members sources` holds the slot's own members plus one edge per
source slot, each edge saying that this slot includes every member of that
source. Resolving a slot follows the edges: the result is `Nothing` when a ⊤
slot, or a source whose content is neither a lambda set nor a `FlexVar`, is
reachable. Otherwise, with the honest-sources rule described below switched
off, it is `Just` the ascending union of the members of the slot and of every
slot reached.

The fixture is a store built by hand rather than one produced by compiling a
program. The tests make points with `mint`, giving a point its content there
or later with `UF.set`, and call `resolveAt` with a slot's own members and
sources, as a reader of an `LsFrom` content would; tests 4 and 5 pass these
directly, without a slot holding them. The resolver context has
`lssOn = False`, which switches off the honest-sources rule: with the rule on,
a resolution that has members and also reaches an unwritten (`FlexVar`) source
reads as `Nothing`. Test 5 depends on the rule being off.

  - Test 1 builds a cycle, A = `LsFrom [1] [B]` and B = `LsFrom [2] [A]`, and
    checks that resolving from A's content and from B's content both return
    `Just [1, 2]`.
  - Test 2 gives a slot with member 1 a source holding `LsTop`, and checks the
    result is `Nothing`.
  - Test 3 builds a chain, A = `LsFrom [1] [B]`, B = `LsFrom [2] [C]` and C =
    `LsTop`, and checks that resolving from A's content returns `Nothing`.
    Despite the test's name, C has no edge back to A, so the store holds no
    cycle.
  - Test 4 resolves members [1] with sources B and C, where B =
    `LsFrom [3] [D]`, C = `LsFrom [5] [D]` and D = `LsMembers [9]`, and checks
    the result is `Just [1, 3, 5, 9]`.
  - Test 5 resolves members [7] with one source that is still a `FlexVar`, and
    checks the result is `Just [7]`.

Among what is not tested: the honest-sources rule switched on, which
`TestLogic.Monomorphize.LssHonestSourcesTest` covers; how edges are installed
by `Store.addSlotSource`, since contents here are written directly; the
resolver's counters, since the context keeps none; and whether D in test 4 is
visited once, since a union of ascending lists drops duplicates and the result
would be the same if D were visited twice.

-}

import Compiler.AST.Intern as Intern
import Compiler.AST.TypeIds as TypeIds
import Compiler.MonoSolver.Engine as Engine
import Compiler.MonoSolver.Store as Store
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Compiler.Type.Vars as Vars
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


{-| The five resolver tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "LSS_023 directed set flow (resolver, store level)"
        [ Test.test "1. a 2-cycle terminates and reads the exact SCC union" <|
            \() ->
                -- A = LsFrom [1] [B]; B = LsFrom [2] [A].
                let
                    ( resA, resB ) =
                        IO.unsafePerformIO
                            (mint (Vars.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (Vars.FlexVar Nothing)
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
                            (mint (Vars.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (Vars.Structure (Vars.LambdaSet1 (Vars.LsTop 7)))
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
                -- A ⊇ B ⊇ C with C = ⊤; C has no edge back to A.
                let
                    res =
                        IO.unsafePerformIO
                            (mint (Vars.FlexVar Nothing)
                                |> IO.andThen
                                    (\a ->
                                        mint (Vars.FlexVar Nothing)
                                            |> IO.andThen
                                                (\b ->
                                                    mint (Vars.FlexVar Nothing)
                                                        |> IO.andThen
                                                            (\c ->
                                                                UF.set a (desc (lsFrom [ 1 ] [ b ]))
                                                                    |> IO.andThen (\_ -> UF.set b (desc (lsFrom [ 2 ] [ c ])))
                                                                    |> IO.andThen (\_ -> UF.set c (desc (Vars.Structure (Vars.LambdaSet1 (Vars.LsTop 7)))))
                                                                    |> IO.andThen (\_ -> captureState |> IO.map (\st -> resolveAt st [ 1 ] [ b ]))
                                                            )
                                                )
                                    )
                            )
                in
                Expect.equal Nothing res
        , Test.test "4. diamond edges dedupe: a doubly-reachable source contributes once" <|
            \() ->
                -- Resolves [1] with sources B, C; B ⊇ D; C ⊇ D; D = LsMembers [9].
                let
                    res =
                        IO.unsafePerformIO
                            (mint (Vars.FlexVar Nothing)
                                |> IO.andThen
                                    (\b ->
                                        mint (Vars.FlexVar Nothing)
                                            |> IO.andThen
                                                (\c ->
                                                    mint (Vars.Structure (Vars.LambdaSet1 (Vars.LsMembers [ 9 ])))
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
                            (mint (Vars.FlexVar Nothing)
                                |> IO.andThen
                                    (\b -> captureState |> IO.map (\st -> resolveAt st [ 7 ] [ b ]))
                            )
                in
                Expect.equal (Just [ 7 ]) res
        ]



-- ====== HARNESS ======


{-| Creates a fresh union-find point holding `content`, as `desc` builds it.
-}
mint : Vars.Content -> IO.IO Vars.Variable
mint content =
    UF.fresh (desc content)


{-| Builds a descriptor holding `content`, with no rank, the initial mark and no
copy.
-}
desc : Vars.Content -> Vars.Descriptor
desc content =
    IO.makeDescriptor content Type.noRank Type.noMark Nothing


{-| Builds the content of a lambda-set slot whose own members are `members` and
which includes every member of each slot in `sources`.
-}
lsFrom : List Int -> List Vars.Variable -> Vars.Content
lsFrom members sources =
    Vars.Structure (Vars.LambdaSet1 (Vars.LsFrom members sources))


{-| An action that returns the current state unchanged. A test uses it to read
the store it has built while still inside the action, because
`IO.unsafePerformIO` disposes of the store once the action finishes.
-}
captureState : IO.IO IO.State
captureState =
    \st -> ( st, st )


{-| Returns what `Store.resolveSlotMembers` reads in the store `st` for a slot
whose own members are `members` and whose sources are `sources`: `Nothing` when
a ⊤ slot, or a source holding content other than a lambda set or a `FlexVar`,
is reachable; otherwise `Just` the union of `members` and the members reached.

The context switches the honest-sources rule off (`lssOn = False`) and keeps no
counters (`lss = Nothing`).

-}
resolveAt : IO.State -> List Int -> List Vars.Variable -> Maybe (List Int)
resolveAt st members sources =
    Store.resolveSlotMembers members
        sources
        { store = st
        , next = TypeIds.firstMVarId
        , lssOn = False
        , maxSetSize = 0
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
