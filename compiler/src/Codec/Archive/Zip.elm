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


{-| FIXME System.IO.FilePath
-}
type alias FilePath =
    String


type alias Archive =
    List Entry


type alias Entry =
    { eRelativePath : FilePath
    , eData : String
    }


zEntries : Archive -> List Entry
zEntries =
    identity


eRelativePath : Entry -> FilePath
eRelativePath zipEntry =
    zipEntry.eRelativePath


fromEntry : Entry -> String
fromEntry zipEntry =
    zipEntry.eData
