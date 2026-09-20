module Eco.CellStore exposing
    ( Store
    , new, size, get, set, push
    , pushMark, rollback, commit
    , disposeThen, freeze, renew, release
    )

{-| A mutable, index-addressed store of boxed cells with an undo trail.

This is the kernel-backed variant. The store lives OFF the Elm heap, because
the collector has no write barrier: a mutated heap object could hold an
old-to-young pointer that a minor GC would never see (HEAP\_005). Its cells and
its trail are registered as GC roots through an external root scanner, the same
mechanism the list scratch stack (HEAP\_040) and `Eco.MVar` use.

**LINEARITY CONTRACT — the only rule.** After `set`, `push`, `rollback`,
`commit`, `renew` or `release`, use ONLY the handle they returned. A read
through an older handle observes the NEW contents, because there is one store
and it is mutated in place. Never let two live handles denote the same store.
Every mutator returns the handle precisely so that threading it makes the
ordering a data dependency the optimizer must respect.

Two consequences worth stating, because breaking either is silent:

  - `new` takes an argument. A zero-argument definition would be a memoised
    constant, and every "fresh" store minted from it would be the same object.
  - Disposal must be data-dependent. `disposeThen` returns its second argument
    so it can be; a discarded `let _ = dispose st` is a dead binding the
    optimizer may drop.

A `Store a` must never be instantiated at `Int`, `Float` or `Char`: the cell
crosses the kernel ABI boxed (REP\_ABI\_001), and a primitive instantiation
would derive an unboxed parameter against a boxed C signature.


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
import Eco.Kernel.CellStore


{-| A handle to a store of `a`-valued cells.
-}
type Store a
    = Store Int


{-| A new, empty store. `cap` is a capacity hint only.

ALWAYS call this with an argument; never bind it as a value.

-}
new : Int -> Store a
new cap =
    Store (Eco.Kernel.CellStore.new cap)


{-| How many cells the store holds. The next `push` lands at this index.
-}
size : Store a -> Int
size (Store h) =
    Eco.Kernel.CellStore.size h


{-| Read cell `ix`. Crashes if `ix` is out of range, exactly as the `Array.get`
plus `Maybe` crash it replaces did.
-}
get : Int -> Store a -> a
get ix (Store h) =
    Eco.Kernel.CellStore.get ix h


{-| Write cell `ix`, returning the handle to thread onward.
-}
set : Int -> a -> Store a -> Store a
set ix cell (Store h) =
    Store (Eco.Kernel.CellStore.set ix cell h)


{-| Append a cell. Its index is the `size` taken BEFORE this call.
-}
push : a -> Store a -> Store a
push cell (Store h) =
    Store (Eco.Kernel.CellStore.push cell h)


{-| Open an undo scope. Scopes nest.
-}
pushMark : Store a -> Store a
pushMark (Store h) =
    Store (Eco.Kernel.CellStore.pushMark h)


{-| Close the innermost scope, restoring every cell AND the cell count to what
they were at the mark. This is what makes speculation cheap: it is the
in-place equivalent of throwing away a persistent array and keeping the old
one.
-}
rollback : Store a -> Store a
rollback (Store h) =
    Store (Eco.Kernel.CellStore.rollback h)


{-| Close the innermost scope, keeping the writes.
-}
commit : Store a -> Store a
commit (Store h) =
    Store (Eco.Kernel.CellStore.commit h)


{-| Free the store and return the second argument unchanged. Idempotent.

The value is threaded through so that disposal is a data dependency rather
than a statement that could be dropped.

-}
disposeThen : Store a -> b -> b
disposeThen (Store h) x =
    Eco.Kernel.CellStore.disposeThen h x


{-| Copy the live cells out into an ordinary `Array` and dispose the store.

For a snapshot that has to outlive the store — the type checker hands one to
`SolverSnapshot`/`SolverRoots` after the IO run is over.

-}
freeze : Store a -> Array a
freeze st =
    let
        n =
            size st

        arr =
            Array.initialize n (\i -> get i st)
    in
    disposeThen st arr


{-| Dispose the store and return a fresh empty one, sized for what the old one
held. For a per-item reset.
-}
renew : Store a -> Store a
renew st =
    disposeThen st (new (size st))


{-| Dispose the first store and return the second. For leaving a scratch scope:
`release scratch stashed`.
-}
release : Store a -> Store b -> Store b
release dead keep =
    disposeThen dead keep
