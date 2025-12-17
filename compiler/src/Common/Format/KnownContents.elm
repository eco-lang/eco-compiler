module Common.Format.KnownContents exposing
    ( KnownContents
    , fromFunction
    , get
    , isKnown
    , mempty
    )

import Maybe.Extra as Maybe


{-| A mapping from module names to their exported contents.
Used to resolve exposing-all imports by looking up what values a module exports.
-}
type KnownContents
    = KnownContents (String -> Maybe (List String)) -- return Nothing if the contents are unknown



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
fromFunction =
    KnownContents


{-| Check if a module's contents are known.
-}
isKnown : KnownContents -> String -> Bool
isKnown (KnownContents lookup) =
    lookup >> Maybe.unwrap False (always True)


{-| Get the list of exported values for a module, if known.
Returns Nothing if the module's contents are unknown.
-}
get : String -> KnownContents -> Maybe (List String)
get ns (KnownContents lookup) =
    lookup ns
