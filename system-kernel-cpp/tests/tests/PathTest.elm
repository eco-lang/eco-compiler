module PathTest exposing (suite)

{-| Tests for System.File.Path: the generated golden tables (PathGolden, from
scripts/gen-path-golden.js, which runs gren-node's FilePath.js semantics on node:path) plus
hand-written cases for the rules in plans/eco-system-library.md Appendix E.2.
-}

import Expect
import PathGolden exposing (CombineCase, JoinCase, ParseCase)
import System.File.Path as Path exposing (Path)
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "System.File.Path"
        [ describe "golden: fromPosixString" (List.map posixCase PathGolden.parseCases)
        , describe "golden: fromWin32String" (List.map win32Case PathGolden.parseCases)
        , describe "golden: append / prepend" (List.map combineCase PathGolden.combineCases)
        , describe "golden: join" (List.map joinCase PathGolden.joinCases)
        , rules
        ]



-- GOLDEN


ancestors : Path -> List String
ancestors path =
    case Path.parentPath path of
        Just parent ->
            Path.toPosixString parent :: ancestors parent

        Nothing ->
            []


flavourExpectations :
    (String -> Path)
    -> Path
    -> { expected : Path, toPosix : String, toWin32 : String, filename : String, parent : Maybe Path, ancestors : List String, roundTrip : Path, print : Path -> String }
    -> List (() -> Expect.Expectation)
flavourExpectations parse actual e =
    [ \_ -> actual |> Expect.equal e.expected
    , \_ -> Path.toPosixString actual |> Expect.equal e.toPosix
    , \_ -> Path.toWin32String actual |> Expect.equal e.toWin32
    , \_ -> Path.filenameWithExtension actual |> Expect.equal e.filename
    , \_ -> Path.parentPath actual |> Expect.equal e.parent
    , \_ -> ancestors actual |> Expect.equal e.ancestors
    , \_ -> parse (e.print actual) |> Expect.equal e.roundTrip
    ]


posixCase : ParseCase -> Test
posixCase c =
    test (Debug.toString c.input) <|
        \_ ->
            ()
                |> Expect.all
                    (flavourExpectations Path.fromPosixString
                        (Path.fromPosixString c.input)
                        { expected = c.posix
                        , toPosix = c.posixToPosix
                        , toWin32 = c.posixToWin32
                        , filename = c.posixFilename
                        , parent = c.posixParent
                        , ancestors = c.posixAncestors
                        , roundTrip = c.posixRoundTrip
                        , print = Path.toPosixString
                        }
                    )


win32Case : ParseCase -> Test
win32Case c =
    test (Debug.toString c.input) <|
        \_ ->
            ()
                |> Expect.all
                    (flavourExpectations Path.fromWin32String
                        (Path.fromWin32String c.input)
                        { expected = c.win32
                        , toPosix = c.win32ToPosix
                        , toWin32 = c.win32ToWin32
                        , filename = c.win32Filename
                        , parent = c.win32Parent
                        , ancestors = c.win32Ancestors
                        , roundTrip = c.win32RoundTrip
                        , print = Path.toWin32String
                        }
                    )


combineCase : CombineCase -> Test
combineCase c =
    let
        left =
            Path.fromPosixString c.left

        right =
            Path.fromPosixString c.right

        rightWin32 =
            Path.fromWin32String c.right
    in
    test (Debug.toString ( c.left, c.right )) <|
        \_ ->
            ()
                |> Expect.all
                    [ \_ -> Path.append left right |> Expect.equal c.append
                    , \_ -> Path.toPosixString (Path.append left right) |> Expect.equal c.appendToPosix
                    , \_ -> Path.prepend left right |> Expect.equal c.prepend
                    , \_ -> Path.toPosixString (Path.prepend left right) |> Expect.equal c.prependToPosix
                    , \_ -> Path.appendPosixString c.left right |> Expect.equal c.appendPosixString
                    , \_ -> Path.prependPosixString c.left right |> Expect.equal c.prependPosixString
                    , \_ -> Path.appendWin32String c.left rightWin32 |> Expect.equal c.appendWin32String
                    , \_ -> Path.prependWin32String c.left rightWin32 |> Expect.equal c.prependWin32String
                    ]


joinCase : JoinCase -> Test
joinCase c =
    test (Debug.toString c.inputs) <|
        \_ ->
            ()
                |> Expect.all
                    [ \_ -> Path.join (List.map Path.fromPosixString c.inputs) |> Expect.equal c.posix
                    , \_ -> Path.toPosixString (Path.join (List.map Path.fromPosixString c.inputs)) |> Expect.equal c.posixToPosix
                    , \_ -> Path.join (List.map Path.fromWin32String c.inputs) |> Expect.equal c.win32
                    , \_ -> Path.toWin32String (Path.join (List.map Path.fromWin32String c.inputs)) |> Expect.equal c.win32ToWin32
                    ]



-- APPENDIX E.2 RULES


posix : String -> Path
posix =
    Path.fromPosixString


win32 : String -> Path
win32 =
    Path.fromWin32String


rules : Test
rules =
    describe "Appendix E.2"
        [ describe "parsing"
            [ test "\"a/../b\" has filename b" <|
                \_ -> posix "a/../b" |> Expect.equal { root = "", directory = [], filename = "b", extension = "" }
            , test "\"//a//b/\" is root /, directory [a], filename b" <|
                \_ -> posix "//a//b/" |> Expect.equal { root = "/", directory = [ "a" ], filename = "b", extension = "" }
            , test "\"C:foo\\bar.txt\" has root C:" <|
                \_ -> win32 "C:foo\\bar.txt" |> Expect.equal { root = "C:", directory = [ "foo" ], filename = "bar", extension = "txt" }
            , test "\"\" and \".\" are empty (posix)" <|
                \_ -> [ posix "", posix "." ] |> Expect.equal [ Path.empty, Path.empty ]
            , test "\"\" and \".\" are empty (win32)" <|
                \_ -> [ win32 "", win32 "." ] |> Expect.equal [ Path.empty, Path.empty ]
            , test "extension is stored without its dot, last dot wins" <|
                \_ -> posix "/x/file.tar.gz" |> Expect.equal { root = "/", directory = [ "x" ], filename = "file.tar", extension = "gz" }
            , test "a dotfile has no extension" <|
                \_ -> posix ".bashrc" |> Expect.equal { root = "", directory = [], filename = ".bashrc", extension = "" }
            , test "UNC share becomes the root" <|
                \_ -> win32 "\\\\server\\share\\x" |> Expect.equal { root = "\\\\server\\share\\", directory = [], filename = "x", extension = "" }
            ]
        , describe "printing"
            [ test "empty prints \".\" (posix)" <|
                \_ -> Path.toPosixString Path.empty |> Expect.equal "."
            , test "empty prints \".\" (win32)" <|
                \_ -> Path.toWin32String Path.empty |> Expect.equal "."
            , test "toPosixString rewrites a non-/ root to /" <|
                \_ -> win32 "C:\\foo\\bar.txt" |> Path.toPosixString |> Expect.equal "/foo/bar.txt"
            , test "toPosixString rewrites a UNC root to /" <|
                \_ -> win32 "\\\\server\\share\\x\\y" |> Path.toPosixString |> Expect.equal "/x/y"
            , test "toWin32String uses \\" <|
                \_ -> posix "a/b/c.txt" |> Path.toWin32String |> Expect.equal "a\\b\\c.txt"
            , test "the ./ quirk is kept for posix" <|
                \_ -> posix "./a/b" |> Path.toPosixString |> Expect.equal "./a/b"
            , test "the ./ quirk is not applied to win32" <|
                \_ -> win32 "./a/b" |> Path.toWin32String |> Expect.equal "a\\b"
            ]
        , describe "combining"
            [ test "append left right puts left after right" <|
                \_ -> Path.append (posix "file.md") (posix "/home/me") |> Path.toPosixString |> Expect.equal "/home/me/file.md"
            , test "prepend left right = left.directory ++ [ left filename ] ++ right.directory" <|
                \_ ->
                    Path.prepend (posix "/home/me") (posix "docs/file.md")
                        |> Expect.equal { root = "/", directory = [ "home", "me", "docs" ], filename = "file", extension = "md" }
            , test "prepend keeps the first root and drops the second" <|
                \_ -> Path.prepend (posix "a") (posix "/b/c") |> Path.toPosixString |> Expect.equal "a/b/c"
            , test "appendPosixString" <|
                \_ -> Path.appendPosixString "c.txt" (posix "/a/b") |> Path.toPosixString |> Expect.equal "/a/b/c.txt"
            , test "prependPosixString" <|
                \_ -> Path.prependPosixString "/a/b" (posix "c.txt") |> Path.toPosixString |> Expect.equal "/a/b/c.txt"
            , test "appendWin32String" <|
                \_ -> Path.appendWin32String "c.txt" (win32 "C:\\a") |> Path.toWin32String |> Expect.equal "C:\\a\\c.txt"
            , test "prependWin32String" <|
                \_ -> Path.prependWin32String "C:\\a" (win32 "b\\c.txt") |> Path.toWin32String |> Expect.equal "C:\\a\\b\\c.txt"
            , test "join [] is empty" <|
                \_ -> Path.join [] |> Expect.equal Path.empty
            , test "join goes first to last and keeps the first root" <|
                \_ -> Path.join [ posix "/usr", posix "local", posix "bin/eco" ] |> Path.toPosixString |> Expect.equal "/usr/local/bin/eco"
            , test "appending empty moves the filename into the directory but prints the same" <|
                \_ ->
                    Path.append Path.empty (posix "/a/b.c")
                        |> Expect.all
                            [ Expect.equal { root = "/", directory = [ "a", "b.c" ], filename = "", extension = "" }
                            , Path.toPosixString >> Expect.equal "/a/b.c"
                            ]
            ]
        , describe "parentPath"
            [ test "of empty is Nothing" <|
                \_ -> Path.parentPath Path.empty |> Expect.equal Nothing
            , test "of the posix root is Nothing" <|
                \_ -> Path.parentPath (posix "/") |> Expect.equal Nothing
            , test "of a drive root is Nothing" <|
                \_ -> Path.parentPath (win32 "C:\\") |> Expect.equal Nothing
            , test "of a UNC root is Nothing" <|
                \_ -> Path.parentPath (win32 "\\\\server\\share\\") |> Expect.equal Nothing
            , test "of /home/me/file.md is /home/me" <|
                \_ -> posix "/home/me/file.md" |> Path.parentPath |> Maybe.map Path.toPosixString |> Expect.equal (Just "/home/me")
            , test "of /a is /" <|
                \_ -> posix "/a" |> Path.parentPath |> Maybe.map Path.toPosixString |> Expect.equal (Just "/")
            , test "of a relative single segment is empty" <|
                \_ -> posix "a" |> Path.parentPath |> Expect.equal (Just Path.empty)
            , test "filenameWithExtension of /home/me/file.md" <|
                \_ -> posix "/home/me/file.md" |> Path.filenameWithExtension |> Expect.equal "file.md"
            ]
        ]
