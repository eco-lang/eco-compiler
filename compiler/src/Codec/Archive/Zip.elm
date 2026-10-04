module Codec.Archive.Zip exposing
    ( Archive, Entry, FilePath
    , zEntries
    , eRelativePath, fromEntry
    )

{-| Names for the contents of a ZIP archive once it has been extracted, using
the names of the Haskell `Codec.Archive.Zip` module (from the `zip-archive`
package) so that code ported from Haskell reads the same.

An archive here is a list of entries, and an entry is one path within the
archive together with its contents as a `String`. Nothing in this module reads
or writes the ZIP format: an `Archive` is built from contents extracted
elsewhere, and the functions here only read the pieces back.


# Types

@docs Archive, Entry, FilePath


# Archive Operations

@docs zEntries


# Entry Operations

@docs eRelativePath, fromEntry

-}


{-| A file path, as text.

This is a name for `String`, not a new type. Any `String` is accepted where a
`FilePath` is expected, and nothing checks that it is a well-formed path.

-}
type alias FilePath =
    String


{-| An extracted ZIP archive: its entries, in the order the list was built.

This is a name for `List Entry`, not a new type, so any list of entries is an
`Archive`. Nothing here sorts the entries or checks that their paths are
distinct.

-}
type alias Archive =
    List Entry


{-| One item from an extracted ZIP archive: its path within the archive and its
contents.
-}
type alias Entry =
    { eRelativePath : FilePath
    , eData : String
    }


{-| Returns the entries of an archive, in the archive's own order.
-}
zEntries : Archive -> List Entry
zEntries =
    identity


{-| Returns the path of an entry within its archive.
-}
eRelativePath : Entry -> FilePath
eRelativePath zipEntry =
    zipEntry.eRelativePath


{-| Returns the contents of an entry.
-}
fromEntry : Entry -> String
fromEntry zipEntry =
    zipEntry.eData
