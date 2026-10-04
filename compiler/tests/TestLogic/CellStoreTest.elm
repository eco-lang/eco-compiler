module TestLogic.CellStoreTest exposing (suite)

{-| Tests for `Eco.CellStore`, an index-addressed store of cells with nested
undo scopes. Without them, a write that is lost, or a rollback that forgets a
cell pushed inside its scope, would go unnoticed until something built on the
store misbehaved.

An _undo scope_ is opened by `pushMark` and closed by either `rollback`, which
puts the cells and the cell count back to what they were when the scope was
opened, or `commit`, which keeps what was written. Scopes nest, and closing one
closes the innermost scope still open.

Stock Elm compiles this suite, so it runs against the pure twin of
`Eco.CellStore`, the one in `src-xhr`, whose stores are immutable values.
`Eco.CellStore`'s module docstring states what that twin shares with the kernel
implementation. Within each test, the store an operation returns is the one
passed to the next.

The fixture is `seeded`, a store holding 10, 20 and 30 at indices 0, 1 and 2,
with no undo scope open. Most tests start from it and read the result back with
`toList`. Every test that starts from it reuses the one store value; that is
safe here only because the pure twin's operations neither change nor free a
store.

The tests establish:

  - Reading and writing: `new 8` has size 0; `seeded` reads back as
    `[ 10, 20, 30 ]`; `set 1 99` changes cell 1 and no other; `set 0 7` leaves
    the size at 3.
  - Rollback: writes to two existing cells inside a scope are undone; two
    pushes inside a scope are undone and the size returns to 3; a push, a write
    to the pushed cell and a write to an existing cell are all undone together,
    and the size returns to 3.
  - Commit: a write and a push inside a scope survive `commit`, giving
    `[ 111, 20, 30, 40 ]`.
  - Nesting: an inner `rollback` followed by an outer `commit` keeps the outer
    scope's write and drops the inner one's; an inner `commit` followed by an
    outer `rollback` drops both writes; three nested scopes, each writing cell
    0, closed by three `rollback`s, leave the original contents. Only the final
    contents are checked, not the state between rollbacks.
  - Padding: pushing zeros onto an empty store until its size is 5 and then
    pushing 42 gives a store of size 6 with 42 at index 5.
  - Lifecycle: `freeze seeded` is the `Array` `[ 10, 20, 30 ]`;
    `renew seeded` has size 0; `release (new 1) seeded` reads back as
    `seeded`; `disposeThen seeded "kept"` is `"kept"`.

Among what is not tested: aliasing, that is, reading a store value after a
later operation has been applied to it, which the pure twin cannot exhibit
(`Eco.CellStore` describes how its two implementations differ there); the
crashes on an out-of-range index and on `rollback` or `commit` with no scope
open; whether `renew` discards open scopes; the capacity argument of `new`; and
the kernel implementation itself.

-}

import Array
import Eco.CellStore as CellStore
import Expect
import Test exposing (Test)


{-| A store holding 10, 20 and 30 at indices 0, 1 and 2, with no undo scope
open.
-}
seeded : CellStore.Store Int
seeded =
    CellStore.new 4
        |> CellStore.push 10
        |> CellStore.push 20
        |> CellStore.push 30


{-| Reads the cells of `st` into a list, in index order from 0.
-}
toList : CellStore.Store Int -> List Int
toList st =
    List.map (\i -> CellStore.get i st) (List.range 0 (CellStore.size st - 1))


{-| The tests of `Eco.CellStore` that the module docstring lists.
-}
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
