module Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..), lub)

{-| Borrow inference needs to say, in several modules, whether a use of a heap
value must own it, and this module holds that shared vocabulary.

An _access mode_ belongs to one heap position of a value, and says whether the
value at that position must be owned or can be borrowed. A mode is `Owned` when
ownership is forced on it, such as by capturing the value in a closure, or
when ownership is propagated to it. A use that only reads the value can still be
`Owned` that way.

The two modes form a lattice with `Borrowed` below `Owned`, and `lub` is its
join. `Compiler.GlobalOpt.Borrow.Solve` combines modes with `lub`, so a mode it
solves can only rise from `Borrowed` to `Owned`. Not every combination of modes
is a join: `Compiler.GlobalOpt.Borrow.LssFacts`, when it meets several
signatures, lets `Borrowed` win on the result.

The module imports nothing, so any borrow module can import it without an
import cycle.

-}


{-| The access mode of one heap position of a value, ordered `Borrowed` below
`Owned`.

`Borrowed` means the value at that position is only borrowed: ownership of it
is not handed over.

`Owned` means ownership of the value at that position is taken, so a use whose
mode is `Owned` consumes the value instead of borrowing it.

-}
type Mode
    = Borrowed
    | Owned


{-| Returns the least upper bound of two modes: `Owned` if either is `Owned`,
otherwise `Borrowed`.
-}
lub : Mode -> Mode -> Mode
lub a b =
    case ( a, b ) of
        ( Owned, _ ) ->
            Owned

        ( _, Owned ) ->
            Owned

        _ ->
            Borrowed
