module System.File.Path exposing
    ( Path
    , empty, fromPosixString, toPosixString, fromWin32String, toWin32String
    , filenameWithExtension, parentPath
    , append, appendPosixString, appendWin32String, prepend, prependPosixString, prependWin32String, join
    )

{-| A path represents the location of a file or directory in a file system.

This module is pure Elm: building, printing and combining paths never touches the file system,
so it behaves the same on every platform. Use the functions in [System.File](System-File) to act
on the entity a path points at.

@docs Path


## Constructors

@docs empty, fromPosixString, toPosixString, fromWin32String, toWin32String


## Query

@docs filenameWithExtension, parentPath


## Manipulation

@docs append, appendPosixString, appendWin32String, prepend, prependPosixString, prependWin32String, join

-}


{-| A cross-platform representation of a file system path.

If `root` is empty, the path is relative to the working directory.
On posix-compatible systems (Linux, Mac...), the root value is `"/"` if not empty.
On Windows, the root refers to the specific disk that the path applies to.

`filename` (and `extension`) refers to the last part of a path. It can still
represent a directory. `extension` is stored without its leading dot.

-}
type alias Path =
    { root : String
    , directory : List String
    , filename : String
    , extension : String
    }


{-| The empty [Path](#Path). Normally treated as the current directory.

[toPosixString](#toPosixString) prints it as `"."`.

-}
empty : Path
empty =
    Debug.todo "Implement System API"


{-| Build a [Path](#Path) from a `String`. The `String` should represent a Posix-compatible path.

The string is normalized first, so `"a/../b"` gives a path whose filename is `b`, repeated
separators are collapsed, and a trailing separator is ignored. `""` and `"."` give [empty](#empty).

-}
fromPosixString : String -> Path
fromPosixString str =
    Debug.todo "Implement System API"


{-| String representation of a [Path](#Path) for Posix systems.

The [empty](#empty) path prints as `"."`, and a non-posix root (such as a Windows drive) is
printed as `"/"`.

-}
toPosixString : Path -> String
toPosixString path =
    Debug.todo "Implement System API"


{-| Build a [Path](#Path) from a `String`. The `String` should represent a Windows-compatible path.

Both `\` and `/` are accepted as separators, and a drive such as `C:` becomes the `root`.

-}
fromWin32String : String -> Path
fromWin32String str =
    Debug.todo "Implement System API"


{-| `String` representation of a [Path](#Path) for Windows, using `\` as the separator.
-}
toWin32String : Path -> String
toWin32String path =
    Debug.todo "Implement System API"


{-| Return the filename and file extension for a [Path](#Path).

    "/home/me/file.md"
        |> fromPosixString
        |> filenameWithExtension
        -- returns "file.md"

-}
filenameWithExtension : Path -> String
filenameWithExtension path =
    Debug.todo "Implement System API"


{-| Return a [Path](#Path) that represents the directory which holds the given [Path](#Path).

    "/home/me/file.md"
        |> fromPosixString
        |> parentPath
        -- returns (Just "/home/me")

Returns `Nothing` for the [empty](#empty) path and for a path that consists of only a root.

-}
parentPath : Path -> Maybe Path
parentPath path =
    Debug.todo "Implement System API"


{-| Join two paths by appending the first [Path](#Path) onto the second.

    append (fromPosixString "file.md") (fromPosixString "/home/me")
        -- returns "/home/me/file.md"

-}
append : Path -> Path -> Path
append left right =
    Debug.todo "Implement System API"


{-| Convenience function. Converts the `String` with [fromPosixString](#fromPosixString) before
appending it.
-}
appendPosixString : String -> Path -> Path
appendPosixString str path =
    Debug.todo "Implement System API"


{-| Convenience function. Converts the `String` with [fromWin32String](#fromWin32String) before
appending it.
-}
appendWin32String : String -> Path -> Path
appendWin32String str path =
    Debug.todo "Implement System API"


{-| Join two paths by prepending the first [Path](#Path) onto the second.

The result keeps the root of the first path, and its directory is the first path's directory
and filename followed by the second path's directory. The filename and extension come from the
second path.

-}
prepend : Path -> Path -> Path
prepend left right =
    Debug.todo "Implement System API"


{-| Convenience function. Converts the `String` with [fromPosixString](#fromPosixString) before
prepending it.
-}
prependPosixString : String -> Path -> Path
prependPosixString str path =
    Debug.todo "Implement System API"


{-| Convenience function. Converts the `String` with [fromWin32String](#fromWin32String) before
prepending it.
-}
prependWin32String : String -> Path -> Path
prependWin32String str path =
    Debug.todo "Implement System API"


{-| Join all paths in a `List`, from first to last. An empty `List` gives [empty](#empty).
-}
join : List Path -> Path
join paths =
    Debug.todo "Implement System API"
