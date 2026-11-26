module System.OsPath exposing (toPath, fromPath)

{-| Converts between the compiler's paths, which are plain text with `/` as the
separator (`System.IO.FilePath`), and eco/system's `Path`.

eco/system parses every path it is given with `Path.fromPosixString` and prints
every path it hands back with `Path.toPosixString`, so these two are all the
conversion there is. Both are lexical, as the `Path` module describes: parsing
drops repeated separators, `.` entries and a trailing separator or dot, and
lets `..` cancel the entry before it. One more thing follows: `""` parses to
the current directory, so a caller must deal with an empty path before
converting it (plans/compiler-io-on-eco-system.md §6.1).

On Windows, a path the system hands back, such as the current directory or a
resolved path, holds `\`; `fromPath` turns each into `/`, as the eco/kernel
kernels did, because the compiler's `fp*` helpers split on `/` only.

@docs toPath, fromPath

-}

import Path exposing (Path)
import System


{-| The `Path` eco/system reads the text as.
-}
toPath : String -> Path
toPath =
    Path.fromPosixString


{-| The text of a path eco/system gave, with every `\` turned into `/` on
Windows.
-}
fromPath : System.Platform -> Path -> String
fromPath platform path =
    let
        text : String
        text =
            Path.toPosixString path
    in
    case platform of
        System.Win32 ->
            String.replace "\\" "/" text

        _ ->
            text
