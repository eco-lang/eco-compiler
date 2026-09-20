module TestLogic.CellStoreTest exposing (suite)

{-| The `Eco.CellStore` API contract and its rollback algebra.

This suite runs against the PURE twin (`compiler/src-xhr/Eco/CellStore.elm`),
because stock Elm is what compiles the unit suite. That bounds what it can
prove: the twin's handles are values, so a stale handle reads the OLD cells
here and the NEW ones under the kernel. **Aliasing is therefore out of scope
for this file** — the native pins under `test/eco-kernel` are the gate for it,
and the byte-identity check in `benchmarks/lss-compile-opt-loop.md` is the
backstop.

What IS in scope, and is the same for both implementations as long as callers
thread handles linearly: indices, `size`, the first-write-wins padding pattern
the union-find store depends on, and above all the rollback algebra — restore
cells AND the cell count, nest correctly, and let an inner `commit` still be
undone by an outer `rollback`. That last one is the property the union-find
scratch scopes actually rely on.

-}

import Array
import Eco.CellStore as CellStore
import Expect
import Test exposing (Test)


{-| `[ 10, 20, 30 ]` as a store.
-}
seeded : CellStore.Store Int
seeded =
    CellStore.new 4
        |> CellStore.push 10
        |> CellStore.push 20
        |> CellStore.push 30


toList : CellStore.Store Int -> List Int
toList st =
    List.map (\i -> CellStore.get i st) (List.range 0 (CellStore.size st - 1))


suite : Test
suite =
    Test.describe "Eco.CellStore"
        [ Test.describe "reading and writing"
            [ Test.test "a new store is empty" <|
                \_ -> CellStore.size (CellStore.new 8) |> Expect.equal 0
            , Test.test "push appends at the index size reported before it" <|
                \_ -> toList seeded |> Expect.equalLists [ 10, 20, 30 ]
            , Test.test "set replaces one cell and leaves the rest" <|
                \_ ->
                    seeded
                        |> CellStore.set 1 99
                        |> toList
                        |> Expect.equalLists [ 10, 99, 30 ]
            , Test.test "set does not change the size" <|
                \_ ->
                    seeded |> CellStore.set 0 7 |> CellStore.size |> Expect.equal 3
            ]
        , Test.describe "rollback restores cells and the cell count"
            [ Test.test "writes made inside a scope are undone" <|
                \_ ->
                    seeded
                        |> CellStore.pushMark
                        |> CellStore.set 0 111
                        |> CellStore.set 2 333
                        |> CellStore.rollback
                        |> toList
                        |> Expect.equalLists [ 10, 20, 30 ]
            , Test.test "pushes made inside a scope are undone, count included" <|
                \_ ->
                    let
                        rolled =
                            seeded
                                |> CellStore.pushMark
                                |> CellStore.push 40
                                |> CellStore.push 50
                                |> CellStore.rollback
                    in
                    ( CellStore.size rolled, toList rolled )
                        |> Expect.equal ( 3, [ 10, 20, 30 ] )
            , Test.test "a write to a cell pushed inside the scope is undone with it" <|
                \_ ->
                    let
                        rolled =
                            seeded
                                |> CellStore.pushMark
                                |> CellStore.push 40
                                |> CellStore.set 3 44
                                |> CellStore.set 0 111
                                |> CellStore.rollback
                    in
                    ( CellStore.size rolled, toList rolled )
                        |> Expect.equal ( 3, [ 10, 20, 30 ] )
            , Test.test "commit keeps the writes" <|
                \_ ->
                    seeded
                        |> CellStore.pushMark
                        |> CellStore.set 0 111
                        |> CellStore.push 40
                        |> CellStore.commit
                        |> toList
                        |> Expect.equalLists [ 111, 20, 30, 40 ]
            ]
        , Test.describe "nesting"
            [ Test.test "an inner rollback leaves the outer scope's writes alone" <|
                \_ ->
                    seeded
                        |> CellStore.pushMark
                        |> CellStore.set 0 111
                        |> CellStore.pushMark
                        |> CellStore.set 1 222
                        |> CellStore.rollback
                        |> CellStore.commit
                        |> toList
                        |> Expect.equalLists [ 111, 20, 30 ]
            , Test.test "an outer rollback undoes an inner COMMIT too" <|
                \_ ->
                    -- The scratch-scope property: committing an inner
                    -- speculation does not make it survive the outer one.
                    seeded
                        |> CellStore.pushMark
                        |> CellStore.set 0 111
                        |> CellStore.pushMark
                        |> CellStore.set 1 222
                        |> CellStore.commit
                        |> CellStore.rollback
                        |> toList
                        |> Expect.equalLists [ 10, 20, 30 ]
            , Test.test "three levels unwind in order" <|
                \_ ->
                    seeded
                        |> CellStore.pushMark
                        |> CellStore.set 0 1
                        |> CellStore.pushMark
                        |> CellStore.set 0 2
                        |> CellStore.pushMark
                        |> CellStore.set 0 3
                        |> CellStore.rollback
                        |> CellStore.rollback
                        |> CellStore.rollback
                        |> toList
                        |> Expect.equalLists [ 10, 20, 30 ]
            ]
        , Test.describe "the padding pattern the union-find store uses"
            [ Test.test "pad-then-push lands the value at the requested index" <|
                \_ ->
                    let
                        padTo target st =
                            if CellStore.size st >= target then
                                st

                            else
                                padTo target (CellStore.push 0 st)

                        built =
                            CellStore.new 4 |> padTo 5 |> CellStore.push 42
                    in
                    ( CellStore.size built, CellStore.get 5 built )
                        |> Expect.equal ( 6, 42 )
            ]
        , Test.describe "lifecycle"
            [ Test.test "freeze copies the live cells out in index order" <|
                \_ ->
                    CellStore.freeze seeded
                        |> Expect.equal (Array.fromList [ 10, 20, 30 ])
            , Test.test "renew gives an empty store" <|
                \_ -> CellStore.renew seeded |> CellStore.size |> Expect.equal 0
            , Test.test "release returns the store it was told to keep" <|
                \_ ->
                    CellStore.release (CellStore.new 1) seeded
                        |> toList
                        |> Expect.equalLists [ 10, 20, 30 ]
            , Test.test "disposeThen returns its second argument" <|
                \_ ->
                    CellStore.disposeThen seeded "kept" |> Expect.equal "kept"
            ]
        ]
