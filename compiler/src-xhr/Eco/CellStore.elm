module Eco.CellStore exposing
    ( Store
    , new, size, get, set, push
    , pushMark, rollback, commit
    , disposeThen, freeze, renew, release
    )

{-| An index-addressed array of cells that can be written and wound back to an
earlier state, in the form stock Elm can compile.

The native build replaces this module with a kernel module of the same name and
the same exposed signatures, whose store is mutated in place. This module
exists so that code written against that interface also builds with stock Elm,
which has no mutation.

A store holds cells numbered from 0. Cells are read with `get`, replaced with
`set`, and added at the end with `push`. A _mark_ opens an undo scope:
`pushMark` records the cells as they are, the matching `rollback` puts them
back, cell count included, and `commit` closes the scope keeping what was
written. Scopes nest, and `rollback` and `commit` close the innermost one still
open.

Code that uses either module must obey the _linearity contract_: once a store
has been passed to an operation that returns a store, only the returned store is
used again, and once it has been passed to `disposeThen` or `freeze`, or as the
first argument of `release`, it is not used at all. Under that contract the two
modules behave alike. They differ when a caller keeps a _stale handle_, an
earlier store value, and reads through it. In the kernel module a store is
changed in place, so the read sees the store's current contents, or, once the
store has been freed by `disposeThen`, `freeze`, `renew` or `release`, fails
with a use-after-dispose error. Here every store is an immutable value, so the
read sees the contents the store had when the handle was current. A test
compiled against this module can therefore check reading, writing and the undo
scopes, but cannot detect a read through a stale handle.

Here a store is a persistent `Array` and a stack of saved arrays, one per open
mark, so `rollback` simply returns to the saved array. The lifecycle functions
free nothing: the kernel module frees the store in `disposeThen`, `freeze`,
`renew` and `release`, while here the old store stays readable. An
out-of-range index, or a `rollback` or `commit` with no mark open, crashes
through `Debug.todo`, so a build containing this module cannot use
`--optimize`.


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


{-| A store of cells of type `a`, indexed from 0 to one less than its `size`,
together with the undo scopes open on it.

A store is made by `new` or `renew`, and new cells are added only by `push`, so
every index below `size` holds a cell. Each operation that changes the store
returns the store to use from then on, under the linearity contract described
in the module docstring.

-}
type Store a
    = Store (Array a) (List (Array a))


{-| Creates an empty store with no mark open. The argument is a capacity hint,
which this module ignores.
-}
new : Int -> Store a
new _ =
    Store Array.empty []


{-| Returns the number of cells in the store, which is also the index the next
`push` fills.
-}
size : Store a -> Int
size (Store arr _) =
    Array.length arr


{-| Returns the cell at index `ix`. Crashes if `ix` is negative or not less than
`size`.
-}
get : Int -> Store a -> a
get ix (Store arr _) =
    case Array.get ix arr of
        Just cell ->
            cell

        Nothing ->
            crashOutOfRange ix


{-| Returns the store with the cell at index `ix` replaced by `cell`. Crashes if
`ix` is negative or not less than `size`, so `set` never adds a cell.
-}
set : Int -> a -> Store a -> Store a
set ix cell (Store arr marks) =
    if ix < 0 || ix >= Array.length arr then
        crashOutOfRange ix

    else
        Store (Array.set ix cell arr) marks


{-| Returns the store with `cell` added at the end, at the index `size` gave
before the call.
-}
push : a -> Store a -> Store a
push cell (Store arr marks) =
    Store (Array.push cell arr) marks


{-| Opens an undo scope inside any already open, recording the cells and their
count as they are now.
-}
pushMark : Store a -> Store a
pushMark (Store arr marks) =
    Store arr (arr :: marks)


{-| Closes the innermost open scope and returns the store with its cells and
cell count as they were when that scope was opened. This also undoes writes
that scopes nested inside it committed. Crashes if no scope is open.
-}
rollback : Store a -> Store a
rollback (Store arr marks) =
    case marks of
        saved :: rest ->
            Store saved rest

        [] ->
            crashNoMark "rollback"


{-| Closes the innermost open scope, keeping every write made in it. The writes
then belong to the enclosing scope, so a later `rollback` of that scope still
undoes them. Crashes if no scope is open.
-}
commit : Store a -> Store a
commit (Store arr marks) =
    case marks of
        _ :: rest ->
            Store arr rest

        [] ->
            crashNoMark "commit"


{-| Returns `x` unchanged and does nothing else. The kernel module frees the
store here, so under the linearity contract the store is not used again.
-}
disposeThen : Store a -> b -> b
disposeThen _ x =
    x


{-| Returns the cells as an ordinary `Array`, in index order. The store is left
as it was, but the kernel module frees it here, so it is not used again.
-}
freeze : Store a -> Array a
freeze (Store arr _) =
    arr


{-| Returns a new empty store with no mark open, to use in place of the given
one, which is discarded.
-}
renew : Store a -> Store a
renew _ =
    new 0


{-| Returns `keep` unchanged and does nothing with the first store, which the
kernel module frees here.
-}
release : Store a -> Store b -> Store b
release _ keep =
    keep


{-| Crashes with a message naming the out-of-range index `ix`.
-}
crashOutOfRange : Int -> a
crashOutOfRange ix =
    crashWith ("Eco.CellStore: index out of range (" ++ String.fromInt ix ++ ")")


{-| Crashes with a message saying that the operation named `op` was called with
no mark open.
-}
crashNoMark : String -> a
crashNoMark op =
    crashWith ("Eco.CellStore: " ++ op ++ " without a mark")


{-| Crashes with `message` through `Debug.todo`.
-}
crashWith : String -> a
crashWith message =
    Debug.todo message
