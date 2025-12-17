module Codec.Archive.Zip exposing
    ( Archive, Entry, FilePath
    , zEntries
    , eRelativePath, fromEntry
    )

{-| A simplified interface for working with ZIP archive structures.

This module provides types and accessor functions for representing ZIP archives as collections
of entries with file paths and data. It is based on the Haskell zip library interface.

Ref.: <https://hackage.haskell.org/package/zip-2.1.0/docs/Codec-Archive-Zip.html>


# Types

@docs Archive, Entry, FilePath


# Archive Operations

@docs zEntries


# Entry Operations

@docs eRelativePath, fromEntry

-}


{-| A file path represented as a string. FIXME: Should use System.IO.FilePath.
-}
type alias FilePath =
    String


{-| A ZIP archive represented as a list of entries.
-}
type alias Archive =
    List Entry


{-| A single entry in a ZIP archive containing a relative file path and its data.
-}
type alias Entry =
    { eRelativePath : FilePath
    , eData : String
    }


{-| Extracts the list of entries from a ZIP archive.
-}
zEntries : Archive -> List Entry
zEntries =
    identity


{-| Extracts the relative file path from a ZIP entry.
-}
eRelativePath : Entry -> FilePath
eRelativePath zipEntry =
    zipEntry.eRelativePath


{-| Extracts the file data from a ZIP entry.
-}
fromEntry : Entry -> String
fromEntry zipEntry =
    zipEntry.eData
