module Common.Format.KnownContents exposing (KnownContents, mempty)

{-| A mapping from module names to their exported contents.
Used to resolve exposing-all imports by looking up what values a module exports.

@docs KnownContents, mempty

-}


{-| A mapping from module names to their exported contents.
Used to resolve exposing-all imports by looking up what values a module exports.
-}
type KnownContents
    = KnownContents



-- instance Semigroup KnownContents where
--     (KnownContents a) <> (KnownContents b) = KnownContents (\ns -> a ns <> b ns)


{-| Empty known contents that knows about no modules.
-}
mempty : KnownContents
mempty =
    fromFunction (always Nothing)


{-| Create known contents from a lookup function.
The function returns Nothing if the module contents are unknown.
-}
fromFunction : (String -> Maybe (List String)) -> KnownContents
fromFunction _ =
    KnownContents
