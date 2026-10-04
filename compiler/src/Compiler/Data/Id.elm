module Compiler.Data.Id exposing (Id, toComparable, first, succ)

{-| An integer identity is easily mistaken for an identity of another kind,
because both are plain numbers. This module gives each kind of identity a type
of its own.

An `Id a` is an identity of kind `a`. The `a` is a phantom type: a type
parameter that no value carries, used only to tell kinds apart. The compiler
rejects an `Id` of one kind where an `Id` of another kind is expected.

Ids are made from an _id supply_, a sequence that starts at `first` and
advances with `succ`. Ids taken in turn from one supply, each the `succ` of
the one before, are all distinct. Nothing here ties an id to a supply: two
supplies of the same kind produce the same ids, and applying `succ` twice to
one id gives the same id twice. Keeping the ids of a kind unique is up to
whoever holds the supply.

@docs Id, toComparable, first, succ

-}


{-| An identity of kind `a`, made only by `first` and `succ`.

Every id is therefore some number of `succ` steps from `first`, and two ids of
the same kind are `==` exactly when they are the same number of steps from it.
An `Id` is not `comparable`, so it cannot itself be a `Dict` key or be sorted;
`toComparable` provides that.

-}
type Id a
    = Id Int


{-| Returns the number of `succ` steps the given id is from `first`, for use
as a `Dict` key, a `Set` member or an array index.

The kind is lost: ids of different kinds at the same position give the same
`Int`.

-}
toComparable : Id a -> Int
toComparable (Id n) =
    n


{-| The id at the start of every supply, of whatever kind is needed. Its
`toComparable` is 0.
-}
first : Id a
first =
    Id 0


{-| Returns the id one step after the given one.
-}
succ : Id a -> Id a
succ (Id n) =
    Id (n + 1)
