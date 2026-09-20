module Eco.CellStore exposing
    ( Store
    , new, size, get, set, push
    , pushMark, rollback, commit
    , disposeThen, freeze, renew, release
    )

{-| A mutable, index-addressed store of boxed cells with an undo trail —
the PURE twin of the kernel module in `eco-kernel-cpp/src/Eco/CellStore.elm`.

Stock Elm has no mutation, so this implements the same interface over a
persistent `Array` plus a stack of saved arrays. The two modules must keep
IDENTICAL exports and identical observable behaviour under the linearity
contract; they differ only in what happens if a caller BREAKS that contract,
and that difference is exactly why this file cannot be the test oracle for
aliasing:

  - kernel: a read through a stale handle sees the NEW contents.
  - here: a read through a stale handle sees the OLD contents, because handles
    are values.

So a passing unit suite proves the API contract and the rollback algebra, and
proves nothing at all about aliasing. The aliasing gates are the native pins
in `test/eco-kernel` and the byte-identity check in the compile loop.

This twin is what Stage 1 and the elm-test-rs suite compile, since both are
built by stock Elm.


# Types

@docs Store


# Reading and writing

@docs new, size, get, set, push


# Undo scopes

@docs pushMark, rollback, commit


# Lifecycle

@docs disposeThen, freeze, renew, release

-}

import Array exposing (Array)


{-| A store of `a`-valued cells: the cells, and the saved copies of one per
open mark (innermost first).
-}
type Store a
    = Store (Array a) (List (Array a))


{-| A new, empty store. The capacity hint is ignored here.
-}
new : Int -> Store a
new _ =
    Store Array.empty []


{-| How many cells the store holds.
-}
size : Store a -> Int
size (Store arr _) =
    Array.length arr


{-| Read cell `ix`. Crashes if out of range, matching the kernel.
-}
get : Int -> Store a -> a
get ix (Store arr _) =
    case Array.get ix arr of
        Just cell ->
            cell

        Nothing ->
            crashOutOfRange ix


{-| Write cell `ix`.
-}
set : Int -> a -> Store a -> Store a
set ix cell (Store arr marks) =
    if ix < 0 || ix >= Array.length arr then
        crashOutOfRange ix

    else
        Store (Array.set ix cell arr) marks


{-| Append a cell, at index `size` taken before the call.
-}
push : a -> Store a -> Store a
push cell (Store arr marks) =
    Store (Array.push cell arr) marks


{-| Open an undo scope: save the current cells.
-}
pushMark : Store a -> Store a
pushMark (Store arr marks) =
    Store arr (arr :: marks)


{-| Close the innermost scope, restoring the saved cells (and with them the
cell count).
-}
rollback : Store a -> Store a
rollback (Store arr marks) =
    case marks of
        saved :: rest ->
            Store saved rest

        [] ->
            crashNoMark "rollback"


{-| Close the innermost scope, keeping the writes.
-}
commit : Store a -> Store a
commit (Store arr marks) =
    case marks of
        _ :: rest ->
            Store arr rest

        [] ->
            crashNoMark "commit"


{-| Disposal is a no-op here; the value is threaded through so callers can be
written once against both implementations.
-}
disposeThen : Store a -> b -> b
disposeThen _ x =
    x


{-| The live cells as an ordinary `Array`.
-}
freeze : Store a -> Array a
freeze (Store arr _) =
    arr


{-| A fresh empty store.
-}
renew : Store a -> Store a
renew _ =
    new 0


{-| Drop the first store, keep the second.
-}
release : Store a -> Store b -> Store b
release _ keep =
    keep


crashOutOfRange : Int -> a
crashOutOfRange ix =
    crashWith ("Eco.CellStore: index out of range (" ++ String.fromInt ix ++ ")")


crashNoMark : String -> a
crashNoMark op =
    crashWith ("Eco.CellStore: " ++ op ++ " without a mark")


{-| `Debug.todo`, as `Eco.Crash`'s XHR twin does — this module is only ever
compiled by the non-optimized stock-Elm builds (Stage 1 and the unit suite).
-}
crashWith : String -> a
crashWith message =
    Debug.todo message
