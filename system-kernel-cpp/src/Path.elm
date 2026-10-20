module Path exposing
    ( Path
    , empty, fromPosixString, toPosixString, fromWin32String, toWin32String
    , filenameWithExtension, parent
    , append, appendPosixString, appendWin32String, prepend, prependPosixString, prependWin32String, join
    )

{-| A program needs to name files and directories before it can act on them, and this module
builds, prints and combines those names without touching the file system, in POSIX or Windows
syntax. The functions in [FileSystem](FileSystem) act on what a path names.

A [Path](#Path) is the text of a path split into parts: a _root_, which is what the path starts
from (`""` for a path relative to the current directory, `"/"` for an absolute POSIX path, or a
Windows prefix such as `C:\` or `\\server\share\`), then the directory entries, then the last
entry, split into a filename and an extension.

Because nothing here looks at a disk, paths are a lexical model, and two facts follow.

Parsing normalizes the text alone. `..` cancels the entry before it as text, so `"a/../b"` gives
the same path as `"b"` whether or not `a` exists or is a link. Repeated separators are dropped,
and so are `.` entries, except a leading `./` in POSIX syntax.

Parsing loses information. A trailing separator and a trailing dot are dropped (`"a."` prints as
`"a"`), and [toPosixString](#toPosixString) prints any Windows root as `/`. Printing a parsed
path does not always give back the text it came from.

A third fact is about the type: a `Path` is a record alias, so any record of its shape is a
path, and only the paths that [fromPosixString](#fromPosixString) and
[fromWin32String](#fromWin32String) return are sure to be normalized, apart from a last entry
`...`, which [fromPosixString](#fromPosixString) describes.

Elsewhere in this package a path reaches the operating system only as text printed by
[toPosixString](#toPosixString), and paths coming back are parsed with
[fromPosixString](#fromPosixString). A path parsed from Windows syntax therefore reaches the
file system with its drive or share printed as `/`.

[append](#append), [prepend](#prepend) and [join](#join) combine paths by their entries. The
result keeps the root of the path whose entries come first in it and discards the other root, so
adding an absolute path onto another does not start over from its root.

Most of this file is the Windows parser. Windows syntax has more kinds of root than POSIX: drives,
drive-relative paths (`C:foo`), UNC shares and device paths (`\\?\C:\x`, `\\.\COM1:`). It also
reserves device names such as `CON` and `NUL`, and the parser marks some relative paths with a
leading `.\`; [fromWin32String](#fromWin32String) says which.

@docs Path


## Constructors

@docs empty, fromPosixString, toPosixString, fromWin32String, toWin32String


## Query

@docs filenameWithExtension, parent


## Manipulation

@docs append, appendPosixString, appendWin32String, prepend, prependPosixString, prependWin32String, join

-}


{-| A file system path, split into the parts that both POSIX and Windows syntax have.

`root` is what the path starts from: `""` for a path relative to the current directory, `"/"`
for an absolute POSIX path, and for a Windows path its prefix together with the separator after
it, such as `C:\`, `\` or `\\server\share\`. A Windows path relative to a drive's current
directory, such as `C:foo`, has the root `C:`. A device path with a single entry, such as
`\\.\x`, is all root, with no separator after it.

`filename` and `extension` together are the last entry, which may name a directory as well as a
file. The extension is stored without its dot. Both are empty when the path has no last entry,
as for a path that is only a root.

Any record of this shape is a `Path`, since this is a record alias. Only the paths that
[fromPosixString](#fromPosixString) and [fromWin32String](#fromWin32String) return are sure to
be normalized, apart from a last entry `...`, which [fromPosixString](#fromPosixString)
describes.

-}
type alias Path =
    { root : String
    , directory : List String
    , filename : String
    , extension : String
    }


{-| The path with no root and no entries, which both printers print as `"."`, the current
directory.

Parsing `""` or `"."` gives this path.

-}
empty : Path
empty =
    { root = ""
    , directory = []
    , filename = ""
    , extension = ""
    }


{-| Parses a path in POSIX syntax, where only `/` separates entries and a leading `/` is the root.

The result is normalized, except for the last case below. Repeated separators, a trailing
separator and `.` entries are dropped, and each `..` cancels the entry before it, so `"a/../b"`
gives the same path as `"b"`. A `..` with nothing before it to cancel is dropped from an absolute
path (`"/../a"` gives `"/a"`) and kept in a relative one (`"../a"`). `""`, `"."` and
`"a/.."` give [empty](#empty).

A leading `./` is the one `.` entry that is kept, as a `"."` directory entry, so `"./a"` prints
back as `"./a"`.

The extension is what follows the last dot of the last entry. An entry has none when it has no
dot, when its last dot is its first character (`".bashrc"`), or when it is `".."`. A trailing
dot gives an empty extension and is lost: `"a."` gives the filename `"a"`, and a last entry
`...` becomes `..`, so `"/x/..."` prints as `"/x/.."`, which names a different directory.

-}
fromPosixString : String -> Path
fromPosixString str =
    let
        root =
            if String.startsWith "/" str then
                "/"

            else
                ""

        segments =
            normalizeSegments (root == "") (String.split "/" str)

        dotPrefix =
            if String.startsWith "./" str then
                [ "." ]

            else
                []
    in
    case unsnoc segments of
        Nothing ->
            { root = root, directory = dotPrefix, filename = "", extension = "" }

        Just ( directory, base ) ->
            fromParts root (dotPrefix ++ directory) base


{-| Prints a path in POSIX syntax, with `/` between the entries.

[empty](#empty) prints as `"."`. A root other than `""` and `"/"`, such as a Windows drive or
share, prints as `/`, so the Windows path `C:\a\b` prints as `/a/b`, and the drive-relative
`C:foo` prints as the absolute `/foo`.

-}
toPosixString : Path -> String
toPosixString path =
    if isEmpty path then
        "."

    else if path.root /= "" && path.root /= "/" then
        format "/" { path | root = "/" }

    else
        format "/" path


{-| Parses a path in Windows syntax, where both `\` and `/` separate entries.

The root is the path's prefix with the separator after it: a drive (`C:\`, or `C:` in the
drive-relative `C:foo\bar.txt`), a lone `\`, a UNC share (`\\server\share\`) or a device path
(`\\?\C:\`). A device path with a single entry, such as `\\.\x`, is all root, with no separator
after it.

The result is normalized as [fromPosixString](#fromPosixString) normalizes, except that a leading
`.\` is dropped too (`.\a\b` gives `a\b`), and the extension is split off the same way.

A path with no root gets a `"."` first directory entry, so that it prints with a leading `.\`,
when a colon ends an entry (`foo:`), when the normalized path would start with a drive
(`x\..\c:`), when the text before the first colon, as written, is a reserved device name in any
mix of upper and lower case (`CON:`, `COM1:x`), and, in a path with no colon, when the text as
written without its last character is a reserved name (`NULL`, `COM10`, `CONx`), unless that last
character lies outside the Basic Multilingual Plane, as an emoji does. These checks come before
`..` is resolved, so `x\..\CON:a` gives the unmarked `CON:a`. A bare `CON` or `CON.txt` is not
marked.

-}
fromWin32String : String -> Path
fromWin32String str =
    win32Parse (win32Normalize str)


{-| Prints a path in Windows syntax, with `\` between the entries.

[empty](#empty) prints as `"."`. The root is printed as it is, so a POSIX root stays `/`: the
POSIX path `/a/b` prints as `/a\b`.

-}
toWin32String : Path -> String
toWin32String path =
    if isEmpty path then
        "."

    else
        format "\\" path


{-| Returns the last entry of a path: its filename, followed by a dot and the extension when
there is one.

    "/home/me/file.md"
        |> fromPosixString
        |> filenameWithExtension
        -- returns "file.md"

-}
filenameWithExtension : Path -> String
filenameWithExtension path =
    if String.isEmpty path.extension then
        path.filename

    else
        path.filename ++ "." ++ path.extension


{-| Returns the path of the directory that holds a path's last entry, or `Nothing` for
[empty](#empty) and for a path that is only a root.

    "/home/me/file.md"
        |> fromPosixString
        |> parent
        |> Maybe.map toPosixString
        -- returns Just "/home/me"

This is lexical: the parent of `"a"` is [empty](#empty), and so is the parent of `".."`.

The last directory entry becomes the result's last entry, split into a filename and an extension
only when it has exactly one dot, at that dot. For some entries this differs from
[fromPosixString](#fromPosixString): `.bashrc` gets the filename `""` and the extension
`"bashrc"`, and `a.b.c` gets no extension. These two print the same as the parsed parent but are
different records. An entry whose one dot is its last character loses the dot, so the parent of
`/x/a./f` prints as `/x/a`. The entry `a.b.` keeps its trailing dot, which parsing drops: the
parent of `/x/a.b./f` prints as `/x/a.b.`, and `fromPosixString "/x/a.b."` prints as `/x/a.b`.

A path with directory entries and an empty last entry, such as
`append empty (fromPosixString "/a/b")`, has its last directory entry moved into the last entry,
so its parent prints the same as the path itself, unless that entry ends in its only dot, which
the paragraph above says is lost.

-}
parent : Path -> Maybe Path
parent path =
    case unsnoc path.directory of
        Nothing ->
            if filenameWithExtension path == "" then
                Nothing

            else
                Just { path | filename = "", extension = "" }

        Just ( initial, last ) ->
            case String.split "." last of
                [ file, ext ] ->
                    Just { path | directory = initial, filename = file, extension = ext }

                _ ->
                    Just { path | directory = initial, filename = last, extension = "" }


{-| Returns the second path with the first added at its end, which is [prepend](#prepend) with
the arguments swapped. The second path is the base, so `base |> append child` reads in order.

    append (fromPosixString "file.md") (fromPosixString "/home/me")
        |> toPosixString
        -- returns "/home/me/file.md"

The result keeps the base's root and discards the first path's, so appending an absolute path
does not replace the base.

-}
append : Path -> Path -> Path
append left right =
    prepend right left


{-| Parses the string with [fromPosixString](#fromPosixString) and [append](#append)s it to the
path.
-}
appendPosixString : String -> Path -> Path
appendPosixString str path =
    prepend path (fromPosixString str)


{-| Parses the string with [fromWin32String](#fromWin32String) and [append](#append)s it to the
path.
-}
appendWin32String : String -> Path -> Path
appendWin32String str path =
    prepend path (fromWin32String str)


{-| Returns the second path with the first put in front of it.

The result has the first path's root. Its directory is the first path's directory entries and
last entry, then the second path's directory entries, with empty entries left out, and its last
entry is the second path's. The second path's root is discarded, so the prepended path of
`/home/me` and `/etc/x` is `/home/me/etc/x`.

The entries are not normalized again: a `.` or `..` entry of the second path stays where it is.

-}
prepend : Path -> Path -> Path
prepend left right =
    { left
        | directory =
            List.filter (\dir -> dir /= "")
                (left.directory ++ filenameWithExtension left :: right.directory)
        , filename = right.filename
        , extension = right.extension
    }


{-| Parses the string with [fromPosixString](#fromPosixString) and [prepend](#prepend)s it to the
path.
-}
prependPosixString : String -> Path -> Path
prependPosixString str path =
    prepend (fromPosixString str) path


{-| Parses the string with [fromWin32String](#fromWin32String) and [prepend](#prepend)s it to the
path.
-}
prependWin32String : String -> Path -> Path
prependWin32String str path =
    prepend (fromWin32String str) path


{-| Combines the paths of a list from first to last, [append](#append)ing each to the result so
far. An empty list gives [empty](#empty).

The result keeps the root of the first path and discards the roots of the others.

-}
join : List Path -> Path
join paths =
    case paths of
        [] ->
            empty

        first :: rest ->
            List.foldl append first rest



-- SHARED HELPERS


{-| Checks whether a path has no root, no directory entries, no filename and no extension.
-}
isEmpty : Path -> Bool
isEmpty path =
    path.root == "" && List.isEmpty path.directory && path.filename == "" && path.extension == ""


{-| Prints a path as its root followed by its entries with `separator` between them. The root is
written as it is, with no separator added after it.
-}
format : String -> Path -> String
format separator path =
    let
        filename =
            filenameWithExtension path

        parts =
            if filename == "" then
                path.directory

            else
                path.directory ++ [ filename ]
    in
    path.root ++ String.join separator parts


{-| Builds a path from a root, the directory entries and the last entry, splitting the last
entry with `splitExtension` and dropping the extension's dot. A last entry of `.` gives an
empty filename.
-}
fromParts : String -> List String -> String -> Path
fromParts root directory base =
    let
        ( name, ext ) =
            splitExtension base
    in
    { root = root
    , directory = directory
    , filename =
        if name == "." && ext == "" then
            ""

        else
            name
    , extension = String.dropLeft 1 ext
    }


{-| Splits an entry into its name and its extension, the extension keeping its dot. The
extension starts at the last dot, and is empty when there is no dot, when the last dot is the
first character, or when the entry is `..`. So `"a."` gives `( "a", "." )`.
-}
splitExtension : String -> ( String, String )
splitExtension base =
    case List.reverse (String.indexes "." base) of
        [] ->
            ( base, "" )

        lastDot :: _ ->
            if lastDot == 0 || base == ".." then
                ( base, "" )

            else
                ( String.left lastDot base, String.dropLeft lastDot base )


{-| Normalizes a list of entries as text: drops empty and `.` entries and lets each `..` cancel
the entry before it. A `..` with nothing left to cancel is kept when `allowAboveRoot` is `True`,
as for a relative path, and dropped otherwise.
-}
normalizeSegments : Bool -> List String -> List String
normalizeSegments allowAboveRoot segments =
    let
        step segment stack =
            if segment == "" || segment == "." then
                stack

            else if segment == ".." then
                case stack of
                    top :: rest ->
                        if top == ".." then
                            ".." :: stack

                        else
                            rest

                    [] ->
                        if allowAboveRoot then
                            [ ".." ]

                        else
                            []

            else
                segment :: stack
    in
    List.reverse (List.foldl step [] segments)


{-| Splits a list into all but its last element and its last element, or returns `Nothing` for
an empty list.
-}
unsnoc : List a -> Maybe ( List a, a )
unsnoc list =
    case List.reverse list of
        [] ->
            Nothing

        last :: initial ->
            Just ( List.reverse initial, last )


{-| Splits a list before the first element that fails `predicate`.
-}
span : (a -> Bool) -> List a -> ( List a, List a )
span predicate list =
    case list of
        x :: xs ->
            if predicate x then
                let
                    ( matched, rest ) =
                        span predicate xs
                in
                ( x :: matched, rest )

            else
                ( [], list )

        [] ->
            ( [], [] )


{-| Drops elements from the front of a list while they satisfy `predicate`.
-}
dropWhile : (a -> Bool) -> List a -> List a
dropWhile predicate list =
    case list of
        x :: xs ->
            if predicate x then
                dropWhile predicate xs

            else
                list

        [] ->
            []


{-| Returns the last element of a list, or `Nothing` for an empty list.
-}
lastOf : List a -> Maybe a
lastOf list =
    List.head (List.reverse list)



-- WIN32 PARSING: normalize the text, then split it into a Path


{-| Checks whether a character is a Windows separator, `/` or `\`.
-}
isSep : Char -> Bool
isSep c =
    c == '/' || c == '\\'


{-| Checks whether a character is not a Windows separator.
-}
isNotSep : Char -> Bool
isNotSep c =
    not (isSep c)


{-| Checks whether a character can name a drive, which any ASCII letter can.
-}
isDriveLetter : Char -> Bool
isDriveLetter c =
    Char.isUpper c || Char.isLower c


{-| Returns the position, counting from 0, of the first `target` in `chars`, or `Nothing` if
there is none.
-}
indexOfChar : Char -> List Char -> Maybe Int
indexOfChar target chars =
    let
        go i rest =
            case rest of
                [] ->
                    Nothing

                c :: more ->
                    if c == target then
                        Just i

                    else
                        go (i + 1) more
    in
    go 0 chars


{-| Splits characters into entries at every `/` and `\`.
-}
splitOnSeps : List Char -> List String
splitOnSeps chars =
    String.split "/" (String.fromList chars)
        |> List.concatMap (String.split "\\")


{-| The reserved Windows device names, in upper case: `CON`, `PRN`, `AUX`, `NUL`, `COM1` to
`COM9`, `LPT1` to `LPT9`, and `COM` and `LPT` with a superscript 1, 2 or 3.
-}
reservedNames : List String
reservedNames =
    [ "CON", "PRN", "AUX", "NUL" ]
        ++ List.map (\n -> "COM" ++ String.fromInt n) (List.range 1 9)
        ++ List.map (\n -> "LPT" ++ String.fromInt n) (List.range 1 9)
        ++ [ "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³" ]


{-| Checks whether the text of `chars` before `colonIndex`, with ASCII letters upper-cased, is
one of `reservedNames`.

With no colon (`Nothing`) it checks the text without its last character, so `"CONx"` counts as
reserved and `"CON"` does not. When that last character lies outside the Basic Multilingual
Plane, the answer is `False`.

-}
isReservedName : List Char -> Maybe Int -> Bool
isReservedName chars colonIndex =
    let
        devicePart =
            case colonIndex of
                Just i ->
                    Just (List.take i chars)

                Nothing ->
                    case unsnoc chars of
                        Just ( initial, last ) ->
                            if Char.toCode last > 0xFFFF then
                                -- a character outside the BMP is two UTF-16 units; dropping
                                -- one would leave half a character, which no reserved
                                -- name ends with
                                Nothing

                            else
                                Just initial

                        Nothing ->
                            Just []
    in
    case devicePart of
        Just part ->
            List.member (String.fromList (List.map asciiUpper part)) reservedNames

        Nothing ->
            False


{-| Returns an ASCII lower-case letter in upper case, and any other character unchanged.
-}
asciiUpper : Char -> Char
asciiUpper c =
    if Char.isLower c then
        Char.toUpper c

    else
        c


{-| What the start of a Windows path is, as the normalizer finds it.

`UncRootOnly` is a path that ends at its UNC share name, with nothing after it, and carries its
finished normalized text (`\\server\share\`).

`Win32Root` is any other path. Its `device` is the prefix written in front of the entries: a
drive such as `C:` or a reserved device name with its colon, as typed; a UNC share or device
prefix, rebuilt with `\` separators (`\\.\COM1:` becomes `\\?\COM1:`); or `Nothing` for none.
`rootEnd` is how many characters of the original text come before the entries, and
`isAbsolute` is whether the path starts from a root rather than from a current directory.

-}
type Win32Root
    = UncRootOnly String
    | Win32Root { device : Maybe String, rootEnd : Int, isAbsolute : Bool }


{-| Returns the start of a path that has no device and no characters to skip, absolute or not
as `isAbsolute` says.
-}
noDevice : Bool -> Win32Root
noDevice isAbsolute =
    Win32Root { device = Nothing, rootEnd = 0, isAbsolute = isAbsolute }


{-| Returns the normalized Windows text of a path. Every separator becomes `\`, the entries are
normalized as `normalizeSegments` does, a trailing separator is kept, and a path with no root is
prefixed with `.\` in the cases `win32NormalizeTail` lists. The empty string gives `"."`, and a
single `/` gives `\`.
-}
win32Normalize : String -> String
win32Normalize path =
    case String.toList path of
        [] ->
            "."

        [ c ] ->
            if c == '/' then
                "\\"

            else
                path

        chars ->
            case win32NormalizeRoot chars of
                UncRootOnly root ->
                    root

                Win32Root root ->
                    win32NormalizeTail chars root


{-| Finds the start of a Windows path. Two separators may start a UNC or device path, as
`win32NormalizeUnc` decides; one separator is the root of the current drive; a letter and a
colon are a drive, absolute when a separator follows; and a reserved device name before the
first colon is a device. Anything else, including a path of fewer than two characters, is
relative with no device.
-}
win32NormalizeRoot : List Char -> Win32Root
win32NormalizeRoot chars =
    case chars of
        c0 :: c1 :: afterTwo ->
            if isSep c0 then
                if isSep c1 then
                    win32NormalizeUnc chars afterTwo

                else
                    Win32Root { device = Nothing, rootEnd = 1, isAbsolute = True }

            else
                case indexOfChar ':' chars of
                    Just colonIndex ->
                        if colonIndex == 1 && isDriveLetter c0 then
                            case afterTwo of
                                c2 :: _ ->
                                    if isSep c2 then
                                        Win32Root { device = Just (String.fromList [ c0, c1 ]), rootEnd = 3, isAbsolute = True }

                                    else
                                        Win32Root { device = Just (String.fromList [ c0, c1 ]), rootEnd = 2, isAbsolute = False }

                                [] ->
                                    Win32Root { device = Just (String.fromList [ c0, c1 ]), rootEnd = 2, isAbsolute = False }

                        else if colonIndex > 0 && isReservedName chars (Just colonIndex) then
                            Win32Root
                                { device = Just (String.fromList (List.take (colonIndex + 1) chars))
                                , rootEnd = colonIndex + 1
                                , isAbsolute = False
                                }

                        else
                            noDevice False

                    Nothing ->
                        noDevice False

        _ ->
            noDevice False


{-| Finds the start of a path that begins with two separators, given the whole path and what
follows the two.

The path needs a first entry, separators, and the start of a second entry; otherwise it is
absolute with no device and nothing to skip. A first entry of `.` or `?` makes a device path,
whose device is `\\?\` and a reserved name with its colon when one follows (`\\.\COM1:`), and
otherwise `\\.` or `\\?`. Any other first entry is a UNC share `\\server\share`, which is
`UncRootOnly` when nothing follows the share name.

-}
win32NormalizeUnc : List Char -> List Char -> Win32Root
win32NormalizeUnc chars afterTwo =
    let
        ( firstPart, afterFirst ) =
            span isNotSep afterTwo

        ( seps, afterSeps ) =
            span isSep afterFirst

        ( secondPart, afterSecond ) =
            span isNotSep afterSeps

        first =
            String.fromList firstPart
    in
    if List.isEmpty firstPart || List.isEmpty afterFirst || List.isEmpty afterSeps then
        noDevice True

    else if first == "." || first == "?" then
        let
            possibleDevice =
                case indexOfChar ':' chars of
                    Just colonIndex ->
                        List.drop 4 (List.take (colonIndex + 1) chars)

                    Nothing ->
                        []
        in
        if not (List.isEmpty possibleDevice) && isReservedName possibleDevice (Just (List.length possibleDevice - 1)) then
            Win32Root
                { device = Just ("\\\\?\\" ++ String.fromList possibleDevice)
                , rootEnd = 4 + List.length possibleDevice
                , isAbsolute = True
                }

        else
            Win32Root { device = Just ("\\\\" ++ first), rootEnd = 4, isAbsolute = True }

    else if List.isEmpty afterSecond then
        UncRootOnly ("\\\\" ++ first ++ "\\" ++ String.fromList secondPart ++ "\\")

    else
        Win32Root
            { device = Just ("\\\\" ++ first ++ "\\" ++ String.fromList secondPart)
            , rootEnd = 2 + List.length firstPart + List.length seps + List.length secondPart
            , isAbsolute = True
            }


{-| Returns the normalized text of a Windows path from its start. The text after `rootEnd` is
split at both separators, normalized (keeping `..` above the start only for a relative path) and
joined with `\` after the device. A relative path with nothing left is `.`, and a trailing
separator of the original is kept.

The result starts with `.\` when the path is relative with no device and has a colon that ends
an entry or would make it start with a drive, or when `isReservedName` holds for the path and
the position of its first colon, which for a path with no colon means its text without the last
character.

-}
win32NormalizeTail : List Char -> { device : Maybe String, rootEnd : Int, isAbsolute : Bool } -> String
win32NormalizeTail chars { device, rootEnd, isAbsolute } =
    let
        rest =
            List.drop rootEnd chars

        normalized =
            String.join "\\" (normalizeSegments (not isAbsolute) (splitOnSeps rest))

        tail0 =
            if normalized == "" && not isAbsolute then
                "."

            else
                normalized

        tail =
            if tail0 /= "" && Maybe.withDefault False (Maybe.map isSep (lastOf chars)) then
                tail0 ++ "\\"

            else
                tail0

        -- a relative path must not normalize to text that Windows reads as a drive
        looksLikeDrive =
            case String.toList tail of
                d :: ':' :: _ ->
                    isDriveLetter d

                _ ->
                    False

        colonBeforeSepOrEnd list =
            case list of
                ':' :: [] ->
                    True

                ':' :: next :: more ->
                    isSep next || colonBeforeSepOrEnd (next :: more)

                _ :: more ->
                    colonBeforeSepOrEnd more

                [] ->
                    False
    in
    if not isAbsolute && device == Nothing && List.member ':' chars && (looksLikeDrive || colonBeforeSepOrEnd chars) then
        ".\\" ++ tail

    else if isReservedName chars (indexOfChar ':' chars) then
        ".\\" ++ Maybe.withDefault "" device ++ tail

    else
        case device of
            Nothing ->
                if isAbsolute then
                    "\\" ++ tail

                else
                    tail

            Just d ->
                if isAbsolute then
                    d ++ "\\" ++ tail

                else
                    d ++ tail


{-| Splits a normalized Windows path, as `win32Normalize` returns it, into a [Path](#Path). The
root is the prefix `win32ParseRootEnd` measures, the last entry ignores trailing separators and
is split by `fromParts`, and the entries in between are the directory.
-}
win32Parse : String -> Path
win32Parse normalized =
    let
        chars =
            String.toList normalized

        rootEnd =
            win32ParseRootEnd chars

        -- the last segment and what precedes it, ignoring trailing separators
        ( baseReversed, beforeReversed ) =
            List.drop rootEnd chars
                |> List.reverse
                |> dropWhile isSep
                |> span isNotSep

        directory =
            case beforeReversed of
                -- drop the separator in front of the last segment
                _ :: dirReversed ->
                    String.split "\\" (String.fromList (List.reverse dirReversed))
                        |> List.filter (not << String.isEmpty)

                [] ->
                    []
    in
    fromParts (String.fromList (List.take rootEnd chars)) directory (String.fromList (List.reverse baseReversed))


{-| Returns how many characters at the start of a normalized Windows path form its root: a UNC or
device prefix with the separator after it, a drive with its separator if it has one, a lone
leading separator, or 0 for a relative path.
-}
win32ParseRootEnd : List Char -> Int
win32ParseRootEnd chars =
    case chars of
        c0 :: c1 :: afterTwo ->
            if isSep c0 then
                if isSep c1 then
                    let
                        ( firstPart, afterFirst ) =
                            span isNotSep afterTwo

                        ( seps, afterSeps ) =
                            span isSep afterFirst

                        ( secondPart, afterSecond ) =
                            span isNotSep afterSeps

                        uncEnd =
                            2 + List.length firstPart + List.length seps + List.length secondPart
                    in
                    if List.isEmpty firstPart || List.isEmpty afterFirst || List.isEmpty afterSeps then
                        1

                    else if List.isEmpty afterSecond then
                        uncEnd

                    else
                        uncEnd + 1

                else
                    1

            else if c1 == ':' && isDriveLetter c0 then
                case afterTwo of
                    c2 :: _ ->
                        if isSep c2 then
                            3

                        else
                            2

                    [] ->
                        2

            else
                0

        [ c0 ] ->
            if isSep c0 then
                1

            else
                0

        [] ->
            0
