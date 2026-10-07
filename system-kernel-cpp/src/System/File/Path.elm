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
    { root = ""
    , directory = []
    , filename = ""
    , extension = ""
    }


{-| Build a [Path](#Path) from a `String`. The `String` should represent a Posix-compatible path.

The string is normalized first, so `"a/../b"` gives a path whose filename is `b`, repeated
separators are collapsed, and a trailing separator is ignored. `""` and `"."` give [empty](#empty).

Only `/` is a separator. A leading `./` is kept as a `"."` directory entry, so `"./a"` prints
back as `"./a"`. The extension is everything after the last dot of the final segment, unless that
dot starts the segment (`".bashrc"` has no extension).

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


{-| String representation of a [Path](#Path) for Posix systems.

The [empty](#empty) path prints as `"."`, and a non-posix root (such as a Windows drive) is
printed as `"/"`.

-}
toPosixString : Path -> String
toPosixString path =
    if isEmpty path then
        "."

    else if path.root /= "" && path.root /= "/" then
        format "/" { path | root = "/" }

    else
        format "/" path


{-| Build a [Path](#Path) from a `String`. The `String` should represent a Windows-compatible path.

Both `\` and `/` are accepted as separators, and a drive such as `C:` becomes the `root`.

The string is normalized as Windows does: `"C:foo\bar.txt"` has root `C:`, a UNC prefix such as
`\\server\share\` becomes the root, and a relative path that Windows could mistake for a drive or
a reserved device name (`CON`, `NUL`, `COM1` ...) gets a `"."` first directory entry.

-}
fromWin32String : String -> Path
fromWin32String str =
    win32Parse (win32Normalize str)


{-| `String` representation of a [Path](#Path) for Windows, using `\` as the separator.

The [empty](#empty) path prints as `"."`.

-}
toWin32String : Path -> String
toWin32String path =
    if isEmpty path then
        "."

    else
        format "\\" path


{-| Return the filename and file extension for a [Path](#Path).

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


{-| Return a [Path](#Path) that represents the directory which holds the given [Path](#Path).

    "/home/me/file.md"
        |> fromPosixString
        |> parentPath
        -- returns (Just "/home/me")

Returns `Nothing` for the [empty](#empty) path and for a path that consists of only a root.

-}
parentPath : Path -> Maybe Path
parentPath path =
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


{-| Join two paths by appending the first [Path](#Path) onto the second.

    append (fromPosixString "file.md") (fromPosixString "/home/me")
        -- returns "/home/me/file.md"

-}
append : Path -> Path -> Path
append left right =
    prepend right left


{-| Convenience function. Converts the `String` with [fromPosixString](#fromPosixString) before
appending it.
-}
appendPosixString : String -> Path -> Path
appendPosixString str path =
    prepend path (fromPosixString str)


{-| Convenience function. Converts the `String` with [fromWin32String](#fromWin32String) before
appending it.
-}
appendWin32String : String -> Path -> Path
appendWin32String str path =
    prepend path (fromWin32String str)


{-| Join two paths by prepending the first [Path](#Path) onto the second.

The result keeps the root of the first path, and its directory is the first path's directory
and filename followed by the second path's directory. The filename and extension come from the
second path.

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


{-| Convenience function. Converts the `String` with [fromPosixString](#fromPosixString) before
prepending it.
-}
prependPosixString : String -> Path -> Path
prependPosixString str path =
    prepend (fromPosixString str) path


{-| Convenience function. Converts the `String` with [fromWin32String](#fromWin32String) before
prepending it.
-}
prependWin32String : String -> Path -> Path
prependWin32String str path =
    prepend (fromWin32String str) path


{-| Join all paths in a `List`, from first to last. An empty `List` gives [empty](#empty).

The result keeps the root of the first path.

-}
join : List Path -> Path
join paths =
    case paths of
        [] ->
            empty

        first :: rest ->
            List.foldl append first rest



-- SHARED HELPERS


isEmpty : Path -> Bool
isEmpty path =
    path.root == "" && List.isEmpty path.directory && path.filename == "" && path.extension == ""


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


{-| Build a path from a root, the directory entries and the last (non-empty) segment, splitting
the segment into name and extension as node's `path.parse` does.
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


{-| node's `path.parse` name/ext split: the extension starts at the last dot, unless there is no
dot, the dot starts the segment, or the segment is `..`. The extension keeps its dot, so `"a."`
gives `( "a", "." )`.
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


{-| node's `normalizeString`: drop empty and `.` segments and resolve `..` against the previous
segment. Above the start, `..` is kept when `allowAboveRoot` and dropped otherwise.
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


unsnoc : List a -> Maybe ( List a, a )
unsnoc list =
    case List.reverse list of
        [] ->
            Nothing

        last :: initial ->
            Just ( List.reverse initial, last )


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


lastOf : List a -> Maybe a
lastOf list =
    List.head (List.reverse list)



-- WIN32 (node:path win32 `normalize` and `parse`)


isSep : Char -> Bool
isSep c =
    c == '/' || c == '\\'


isNotSep : Char -> Bool
isNotSep c =
    not (isSep c)


isDriveLetter : Char -> Bool
isDriveLetter c =
    Char.isUpper c || Char.isLower c


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


splitOnSeps : List Char -> List String
splitOnSeps chars =
    String.split "/" (String.fromList chars)
        |> List.concatMap (String.split "\\")


reservedNames : List String
reservedNames =
    [ "CON", "PRN", "AUX", "NUL" ]
        ++ List.map (\n -> "COM" ++ String.fromInt n) (List.range 1 9)
        ++ List.map (\n -> "LPT" ++ String.fromInt n) (List.range 1 9)
        ++ [ "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³" ]


{-| node's `isWindowsReservedName(path, colonIndex)`: is the text before `colonIndex` a reserved
device name? node passes `-1` (here `Nothing`) when there is no colon, and its `slice(0, -1)`
then drops the last UTF-16 unit, so `"CONx"` counts as reserved.
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
                                -- slice(0, -1) would leave a lone surrogate
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


asciiUpper : Char -> Char
asciiUpper c =
    if Char.isLower c then
        Char.toUpper c

    else
        c


type Win32Root
    = UncRootOnly String
    | Win32Root { device : Maybe String, rootEnd : Int, isAbsolute : Bool }


noDevice : Bool -> Win32Root
noDevice isAbsolute =
    Win32Root { device = Nothing, rootEnd = 0, isAbsolute = isAbsolute }


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


{-| A path starting with two separators: `\\server\share`, or a device root `\\.\X` / `\\?\X`.
If the UNC root does not match, the path is absolute with no device and `rootEnd = 0`.
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

        -- CVE-2024-36139: a relative path must not normalize to something Windows reads as a drive.
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


{-| node's win32 `path.parse` of a normalized path, mapped to a [Path](#Path) as gren's
`FilePath.js` does.
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
