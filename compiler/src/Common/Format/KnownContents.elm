module Common.Format.KnownContents exposing (KnownContents, mempty)

{-| A placeholder for knowledge of what other modules expose. It exists so that
`fromModule` and `fromImports` in `Common.Format.ImportInfo` keep a parameter
for this knowledge.

The name stands for a table from module names to the names each module
exposes, the information needed to say which names an `exposing (..)` import
brings into scope. This module holds no such table. `KnownContents` carries no
information at all, and `mempty` is its only value.

-}


{-| A stand-in for knowledge of what other modules expose, holding none.

Every value is the same value, and nothing can be looked up in one. Outside
this module the only way to get one is `mempty`.

-}
type KnownContents
    = KnownContents


{-| The `KnownContents` value, knowing about no module.
-}
mempty : KnownContents
mempty =
    fromFunction (always Nothing)


{-| Returns the `KnownContents` value, discarding the given lookup function, so
nothing it would answer is kept.
-}
fromFunction : (String -> Maybe (List String)) -> KnownContents
fromFunction _ =
    KnownContents
