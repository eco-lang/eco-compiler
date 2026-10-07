module PathGolden exposing (CombineCase, JoinCase, ParseCase, combineCases, joinCases, parseCases)

{-| GENERATED FILE — do not edit.

Golden tables for System.File.Path, produced by running gren-node's FilePath.js / Path.gren
semantics on node v22.23.3 (node:path posix and win32 normalize + parse).

Regenerate from system-kernel-cpp/ with:

    node scripts/gen-path-golden.js

-}


type alias P =
    { root : String, directory : List String, filename : String, extension : String }


type alias ParseCase =
    { input : String
    , posix : P
    , posixToPosix : String
    , posixToWin32 : String
    , posixFilename : String
    , posixParent : Maybe P
    , posixAncestors : List String
    , posixRoundTrip : P
    , win32 : P
    , win32ToPosix : String
    , win32ToWin32 : String
    , win32Filename : String
    , win32Parent : Maybe P
    , win32Ancestors : List String
    , win32RoundTrip : P
    }


type alias CombineCase =
    { left : String
    , right : String
    , append : P
    , appendToPosix : String
    , prepend : P
    , prependToPosix : String
    , appendPosixString : P
    , prependPosixString : P
    , appendWin32String : P
    , prependWin32String : P
    }


type alias JoinCase =
    { inputs : List String
    , posix : P
    , posixToPosix : String
    , win32 : P
    , win32ToWin32 : String
    }



parseCases : List ParseCase
parseCases =
    [
      { input = ""
      , posix = { root = "", directory = [], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "."
      , posix = { root = "", directory = [], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = ".."
      , posix = { root = "", directory = [], filename = "..", extension = "" }
      , posixToPosix = ".."
      , posixToWin32 = ".."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "..", extension = "" }
      , win32ToPosix = ".."
      , win32ToWin32 = ".."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "..."
      , posix = { root = "", directory = [], filename = "..", extension = "" }
      , posixToPosix = ".."
      , posixToWin32 = ".."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "..", extension = "" }
      , win32ToPosix = ".."
      , win32ToWin32 = ".."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "...."
      , posix = { root = "", directory = [], filename = "...", extension = "" }
      , posixToPosix = "..."
      , posixToWin32 = "..."
      , posixFilename = "..."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "...", extension = "" }
      , win32ToPosix = "..."
      , win32ToWin32 = "..."
      , win32Filename = "..."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "./"
      , posix = { root = "", directory = [ "." ], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "../"
      , posix = { root = "", directory = [], filename = "..", extension = "" }
      , posixToPosix = ".."
      , posixToWin32 = ".."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "..", extension = "" }
      , win32ToPosix = ".."
      , win32ToWin32 = ".."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = ".//"
      , posix = { root = "", directory = [ "." ], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "./."
      , posix = { root = "", directory = [ "." ], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "././"
      , posix = { root = "", directory = [ "." ], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "./.."
      , posix = { root = "", directory = [ "." ], filename = "..", extension = "" }
      , posixToPosix = "./.."
      , posixToWin32 = ".\\.."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "..", extension = "" }
      , win32ToPosix = ".."
      , win32ToWin32 = ".."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "../.."
      , posix = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , posixToPosix = "../.."
      , posixToWin32 = "..\\.."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , win32ToPosix = "../.."
      , win32ToWin32 = "..\\.."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      }
    ,
      { input = "../../"
      , posix = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , posixToPosix = "../.."
      , posixToWin32 = "..\\.."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      , win32ToPosix = "../.."
      , win32ToWin32 = "..\\.."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "..", extension = "" }
      }
    ,
      { input = "./a"
      , posix = { root = "", directory = [ "." ], filename = "a", extension = "" }
      , posixToPosix = "./a"
      , posixToWin32 = ".\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "./a/b"
      , posix = { root = "", directory = [ ".", "a" ], filename = "b", extension = "" }
      , posixToPosix = "./a/b"
      , posixToWin32 = ".\\a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [ "." ], filename = "a", extension = "" })
      , posixAncestors = [ "./a", "." ]
      , posixRoundTrip = { root = "", directory = [ ".", "a" ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "./a/"
      , posix = { root = "", directory = [ "." ], filename = "a", extension = "" }
      , posixToPosix = "./a"
      , posixToWin32 = ".\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = ".\\a"
      , posix = { root = "", directory = [], filename = ".\\a", extension = "" }
      , posixToPosix = ".\\a"
      , posixToWin32 = ".\\a"
      , posixFilename = ".\\a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".\\a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "./../a"
      , posix = { root = "", directory = [ ".", ".." ], filename = "a", extension = "" }
      , posixToPosix = "./../a"
      , posixToWin32 = ".\\..\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [ "." ], filename = "..", extension = "" })
      , posixAncestors = [ "./..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".", ".." ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      , win32ToPosix = "../a"
      , win32ToWin32 = "..\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      }
    ,
      { input = "./.hidden"
      , posix = { root = "", directory = [ "." ], filename = ".hidden", extension = "" }
      , posixToPosix = "./.hidden"
      , posixToWin32 = ".\\.hidden"
      , posixFilename = ".hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = ".hidden", extension = "" }
      , win32 = { root = "", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = ".hidden"
      , win32ToWin32 = ".hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "./a.txt"
      , posix = { root = "", directory = [ "." ], filename = "a", extension = "txt" }
      , posixToPosix = "./a.txt"
      , posixToWin32 = ".\\a.txt"
      , posixFilename = "a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "a", extension = "txt" }
      , win32 = { root = "", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "a.txt"
      , win32ToWin32 = "a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = ".../a"
      , posix = { root = "", directory = [ "..." ], filename = "a", extension = "" }
      , posixToPosix = ".../a"
      , posixToWin32 = "...\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "...", extension = "" })
      , posixAncestors = [ "...", "." ]
      , posixRoundTrip = { root = "", directory = [ "..." ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [ "..." ], filename = "a", extension = "" }
      , win32ToPosix = ".../a"
      , win32ToWin32 = "...\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "...", extension = "" })
      , win32Ancestors = [ "...", "." ]
      , win32RoundTrip = { root = "", directory = [ "..." ], filename = "a", extension = "" }
      }
    ,
      { input = "a/..."
      , posix = { root = "", directory = [ "a" ], filename = "..", extension = "" }
      , posixToPosix = "a/.."
      , posixToWin32 = "a\\.."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "..", extension = "" }
      , win32ToPosix = "a/.."
      , win32ToWin32 = "a\\.."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "a/..b"
      , posix = { root = "", directory = [ "a" ], filename = ".", extension = "b" }
      , posixToPosix = "a/..b"
      , posixToWin32 = "a\\..b"
      , posixFilename = "..b"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = ".", extension = "b" }
      , win32 = { root = "", directory = [ "a" ], filename = ".", extension = "b" }
      , win32ToPosix = "a/..b"
      , win32ToWin32 = "a\\..b"
      , win32Filename = "..b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = ".", extension = "b" }
      }
    ,
      { input = "a/../b"
      , posix = { root = "", directory = [], filename = "b", extension = "" }
      , posixToPosix = "b"
      , posixToWin32 = "b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "b", extension = "" }
      , win32 = { root = "", directory = [], filename = "b", extension = "" }
      , win32ToPosix = "b"
      , win32ToWin32 = "b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "b", extension = "" }
      }
    ,
      { input = "a/./b"
      , posix = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "a/b"
      , posixToWin32 = "a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a/b/.."
      , posix = { root = "", directory = [], filename = "a", extension = "" }
      , posixToPosix = "a"
      , posixToWin32 = "a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "a/b/../.."
      , posix = { root = "", directory = [], filename = "", extension = "" }
      , posixToPosix = "."
      , posixToWin32 = "."
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "", directory = [], filename = "", extension = "" }
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToPosix = "."
      , win32ToWin32 = "."
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "a/b/../../.."
      , posix = { root = "", directory = [], filename = "..", extension = "" }
      , posixToPosix = ".."
      , posixToWin32 = ".."
      , posixFilename = ".."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      , win32 = { root = "", directory = [], filename = "..", extension = "" }
      , win32ToPosix = ".."
      , win32ToWin32 = ".."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "a//b"
      , posix = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "a/b"
      , posixToWin32 = "a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a/b/"
      , posix = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "a/b"
      , posixToWin32 = "a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a/b//"
      , posix = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "a/b"
      , posixToWin32 = "a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "/a/../.."
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , posixToWin32 = "/"
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "/", directory = [], filename = "", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "/.."
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , posixToWin32 = "/"
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "/", directory = [], filename = "", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "/../a"
      , posix = { root = "/", directory = [], filename = "a", extension = "" }
      , posixToPosix = "/a"
      , posixToWin32 = "/a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "/./a"
      , posix = { root = "/", directory = [], filename = "a", extension = "" }
      , posixToPosix = "/a"
      , posixToWin32 = "/a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "/a/./b/../c"
      , posix = { root = "/", directory = [ "a" ], filename = "c", extension = "" }
      , posixToPosix = "/a/c"
      , posixToWin32 = "/a\\c"
      , posixFilename = "c"
      , posixParent = Just ({ root = "/", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a" ], filename = "c", extension = "" }
      , win32 = { root = "\\", directory = [ "a" ], filename = "c", extension = "" }
      , win32ToPosix = "/a/c"
      , win32ToWin32 = "\\a\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a" ], filename = "c", extension = "" }
      }
    ,
      { input = "a/../../b"
      , posix = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      , posixToPosix = "../b"
      , posixToWin32 = "..\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      , win32ToPosix = "../b"
      , win32ToWin32 = "..\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      }
    ,
      { input = "x/y/../../../z"
      , posix = { root = "", directory = [ ".." ], filename = "z", extension = "" }
      , posixToPosix = "../z"
      , posixToWin32 = "..\\z"
      , posixFilename = "z"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "z", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "z", extension = "" }
      , win32ToPosix = "../z"
      , win32ToWin32 = "..\\z"
      , win32Filename = "z"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "z", extension = "" }
      }
    ,
      { input = "/"
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , posixToWin32 = "/"
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "/", directory = [], filename = "", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "//"
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , posixToWin32 = "/"
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "/", directory = [], filename = "", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "///"
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , posixToWin32 = "/"
      , posixFilename = ""
      , posixParent = Nothing
      , posixAncestors = []
      , posixRoundTrip = { root = "/", directory = [], filename = "", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "//a//b/"
      , posix = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "/a/b"
      , posixToWin32 = "/a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "/", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "\\\\a\\b\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\a\\b\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\a\\b\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "//a"
      , posix = { root = "/", directory = [], filename = "a", extension = "" }
      , posixToPosix = "/a"
      , posixToWin32 = "/a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "///a///b///"
      , posix = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "/a/b"
      , posixToWin32 = "/a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "/", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "/a/b"
      , win32ToWin32 = "\\a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "/a"
      , posix = { root = "/", directory = [], filename = "a", extension = "" }
      , posixToPosix = "/a"
      , posixToWin32 = "/a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "/a/"
      , posix = { root = "/", directory = [], filename = "a", extension = "" }
      , posixToPosix = "/a"
      , posixToWin32 = "/a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "/a/b"
      , posix = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "/a/b"
      , posixToWin32 = "/a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "/", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , win32 = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "/a/b"
      , win32ToWin32 = "\\a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "/a/b/c.txt"
      , posix = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      , posixToPosix = "/a/b/c.txt"
      , posixToWin32 = "/a\\b\\c.txt"
      , posixFilename = "c.txt"
      , posixParent = Just ({ root = "/", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "/a/b", "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      , win32 = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      , win32ToPosix = "/a/b/c.txt"
      , win32ToWin32 = "\\a\\b\\c.txt"
      , win32Filename = "c.txt"
      , win32Parent = Just ({ root = "\\", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "/a/b", "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      }
    ,
      { input = "file"
      , posix = { root = "", directory = [], filename = "file", extension = "" }
      , posixToPosix = "file"
      , posixToWin32 = "file"
      , posixFilename = "file"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "file", extension = "" }
      , win32 = { root = "", directory = [], filename = "file", extension = "" }
      , win32ToPosix = "file"
      , win32ToWin32 = "file"
      , win32Filename = "file"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "file", extension = "" }
      }
    ,
      { input = "file.txt"
      , posix = { root = "", directory = [], filename = "file", extension = "txt" }
      , posixToPosix = "file.txt"
      , posixToWin32 = "file.txt"
      , posixFilename = "file.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "file", extension = "txt" }
      , win32 = { root = "", directory = [], filename = "file", extension = "txt" }
      , win32ToPosix = "file.txt"
      , win32ToWin32 = "file.txt"
      , win32Filename = "file.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "file", extension = "txt" }
      }
    ,
      { input = "file.tar.gz"
      , posix = { root = "", directory = [], filename = "file.tar", extension = "gz" }
      , posixToPosix = "file.tar.gz"
      , posixToWin32 = "file.tar.gz"
      , posixFilename = "file.tar.gz"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "file.tar", extension = "gz" }
      , win32 = { root = "", directory = [], filename = "file.tar", extension = "gz" }
      , win32ToPosix = "file.tar.gz"
      , win32ToWin32 = "file.tar.gz"
      , win32Filename = "file.tar.gz"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "file.tar", extension = "gz" }
      }
    ,
      { input = ".bashrc"
      , posix = { root = "", directory = [], filename = ".bashrc", extension = "" }
      , posixToPosix = ".bashrc"
      , posixToWin32 = ".bashrc"
      , posixFilename = ".bashrc"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".bashrc", extension = "" }
      , win32 = { root = "", directory = [], filename = ".bashrc", extension = "" }
      , win32ToPosix = ".bashrc"
      , win32ToWin32 = ".bashrc"
      , win32Filename = ".bashrc"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".bashrc", extension = "" }
      }
    ,
      { input = ".bashrc.bak"
      , posix = { root = "", directory = [], filename = ".bashrc", extension = "bak" }
      , posixToPosix = ".bashrc.bak"
      , posixToWin32 = ".bashrc.bak"
      , posixFilename = ".bashrc.bak"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".bashrc", extension = "bak" }
      , win32 = { root = "", directory = [], filename = ".bashrc", extension = "bak" }
      , win32ToPosix = ".bashrc.bak"
      , win32ToWin32 = ".bashrc.bak"
      , win32Filename = ".bashrc.bak"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".bashrc", extension = "bak" }
      }
    ,
      { input = "..a"
      , posix = { root = "", directory = [], filename = ".", extension = "a" }
      , posixToPosix = "..a"
      , posixToWin32 = "..a"
      , posixFilename = "..a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".", extension = "a" }
      , win32 = { root = "", directory = [], filename = ".", extension = "a" }
      , win32ToPosix = "..a"
      , win32ToWin32 = "..a"
      , win32Filename = "..a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".", extension = "a" }
      }
    ,
      { input = "a."
      , posix = { root = "", directory = [], filename = "a", extension = "" }
      , posixToPosix = "a"
      , posixToWin32 = "a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "a.."
      , posix = { root = "", directory = [], filename = "a.", extension = "" }
      , posixToPosix = "a."
      , posixToWin32 = "a."
      , posixFilename = "a."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a.", extension = "" }
      , win32ToPosix = "a."
      , win32ToWin32 = "a."
      , win32Filename = "a."
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "a.b."
      , posix = { root = "", directory = [], filename = "a.b", extension = "" }
      , posixToPosix = "a.b"
      , posixToWin32 = "a.b"
      , posixFilename = "a.b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "b" }
      , win32 = { root = "", directory = [], filename = "a.b", extension = "" }
      , win32ToPosix = "a.b"
      , win32ToWin32 = "a.b"
      , win32Filename = "a.b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "b" }
      }
    ,
      { input = ".a.b"
      , posix = { root = "", directory = [], filename = ".a", extension = "b" }
      , posixToPosix = ".a.b"
      , posixToWin32 = ".a.b"
      , posixFilename = ".a.b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".a", extension = "b" }
      , win32 = { root = "", directory = [], filename = ".a", extension = "b" }
      , win32ToPosix = ".a.b"
      , win32ToWin32 = ".a.b"
      , win32Filename = ".a.b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".a", extension = "b" }
      }
    ,
      { input = "a..b"
      , posix = { root = "", directory = [], filename = "a.", extension = "b" }
      , posixToPosix = "a..b"
      , posixToWin32 = "a..b"
      , posixFilename = "a..b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a.", extension = "b" }
      , win32 = { root = "", directory = [], filename = "a.", extension = "b" }
      , win32ToPosix = "a..b"
      , win32ToWin32 = "a..b"
      , win32Filename = "a..b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a.", extension = "b" }
      }
    ,
      { input = "noext/"
      , posix = { root = "", directory = [], filename = "noext", extension = "" }
      , posixToPosix = "noext"
      , posixToWin32 = "noext"
      , posixFilename = "noext"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "noext", extension = "" }
      , win32 = { root = "", directory = [], filename = "noext", extension = "" }
      , win32ToPosix = "noext"
      , win32ToWin32 = "noext"
      , win32Filename = "noext"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "noext", extension = "" }
      }
    ,
      { input = "dir.d/file"
      , posix = { root = "", directory = [ "dir.d" ], filename = "file", extension = "" }
      , posixToPosix = "dir.d/file"
      , posixToWin32 = "dir.d\\file"
      , posixFilename = "file"
      , posixParent = Just ({ root = "", directory = [], filename = "dir", extension = "d" })
      , posixAncestors = [ "dir.d", "." ]
      , posixRoundTrip = { root = "", directory = [ "dir.d" ], filename = "file", extension = "" }
      , win32 = { root = "", directory = [ "dir.d" ], filename = "file", extension = "" }
      , win32ToPosix = "dir.d/file"
      , win32ToWin32 = "dir.d\\file"
      , win32Filename = "file"
      , win32Parent = Just ({ root = "", directory = [], filename = "dir", extension = "d" })
      , win32Ancestors = [ "dir.d", "." ]
      , win32RoundTrip = { root = "", directory = [ "dir.d" ], filename = "file", extension = "" }
      }
    ,
      { input = "dir.d/"
      , posix = { root = "", directory = [], filename = "dir", extension = "d" }
      , posixToPosix = "dir.d"
      , posixToWin32 = "dir.d"
      , posixFilename = "dir.d"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "dir", extension = "d" }
      , win32 = { root = "", directory = [], filename = "dir", extension = "d" }
      , win32ToPosix = "dir.d"
      , win32ToWin32 = "dir.d"
      , win32Filename = "dir.d"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "dir", extension = "d" }
      }
    ,
      { input = "/home/me/file.md"
      , posix = { root = "/", directory = [ "home", "me" ], filename = "file", extension = "md" }
      , posixToPosix = "/home/me/file.md"
      , posixToWin32 = "/home\\me\\file.md"
      , posixFilename = "file.md"
      , posixParent = Just ({ root = "/", directory = [ "home" ], filename = "me", extension = "" })
      , posixAncestors = [ "/home/me", "/home", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "home", "me" ], filename = "file", extension = "md" }
      , win32 = { root = "\\", directory = [ "home", "me" ], filename = "file", extension = "md" }
      , win32ToPosix = "/home/me/file.md"
      , win32ToWin32 = "\\home\\me\\file.md"
      , win32Filename = "file.md"
      , win32Parent = Just ({ root = "\\", directory = [ "home" ], filename = "me", extension = "" })
      , win32Ancestors = [ "/home/me", "/home", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "home", "me" ], filename = "file", extension = "md" }
      }
    ,
      { input = "/home/me/.config/"
      , posix = { root = "/", directory = [ "home", "me" ], filename = ".config", extension = "" }
      , posixToPosix = "/home/me/.config"
      , posixToWin32 = "/home\\me\\.config"
      , posixFilename = ".config"
      , posixParent = Just ({ root = "/", directory = [ "home" ], filename = "me", extension = "" })
      , posixAncestors = [ "/home/me", "/home", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "home", "me" ], filename = ".config", extension = "" }
      , win32 = { root = "\\", directory = [ "home", "me" ], filename = ".config", extension = "" }
      , win32ToPosix = "/home/me/.config"
      , win32ToWin32 = "\\home\\me\\.config"
      , win32Filename = ".config"
      , win32Parent = Just ({ root = "\\", directory = [ "home" ], filename = "me", extension = "" })
      , win32Ancestors = [ "/home/me", "/home", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "home", "me" ], filename = ".config", extension = "" }
      }
    ,
      { input = "/home/me/archive.tar.gz"
      , posix = { root = "/", directory = [ "home", "me" ], filename = "archive.tar", extension = "gz" }
      , posixToPosix = "/home/me/archive.tar.gz"
      , posixToWin32 = "/home\\me\\archive.tar.gz"
      , posixFilename = "archive.tar.gz"
      , posixParent = Just ({ root = "/", directory = [ "home" ], filename = "me", extension = "" })
      , posixAncestors = [ "/home/me", "/home", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "home", "me" ], filename = "archive.tar", extension = "gz" }
      , win32 = { root = "\\", directory = [ "home", "me" ], filename = "archive.tar", extension = "gz" }
      , win32ToPosix = "/home/me/archive.tar.gz"
      , win32ToWin32 = "\\home\\me\\archive.tar.gz"
      , win32Filename = "archive.tar.gz"
      , win32Parent = Just ({ root = "\\", directory = [ "home" ], filename = "me", extension = "" })
      , win32Ancestors = [ "/home/me", "/home", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "home", "me" ], filename = "archive.tar", extension = "gz" }
      }
    ,
      { input = "src/System/File/Path.elm"
      , posix = { root = "", directory = [ "src", "System", "File" ], filename = "Path", extension = "elm" }
      , posixToPosix = "src/System/File/Path.elm"
      , posixToWin32 = "src\\System\\File\\Path.elm"
      , posixFilename = "Path.elm"
      , posixParent = Just ({ root = "", directory = [ "src", "System" ], filename = "File", extension = "" })
      , posixAncestors = [ "src/System/File", "src/System", "src", "." ]
      , posixRoundTrip = { root = "", directory = [ "src", "System", "File" ], filename = "Path", extension = "elm" }
      , win32 = { root = "", directory = [ "src", "System", "File" ], filename = "Path", extension = "elm" }
      , win32ToPosix = "src/System/File/Path.elm"
      , win32ToWin32 = "src\\System\\File\\Path.elm"
      , win32Filename = "Path.elm"
      , win32Parent = Just ({ root = "", directory = [ "src", "System" ], filename = "File", extension = "" })
      , win32Ancestors = [ "src/System/File", "src/System", "src", "." ]
      , win32RoundTrip = { root = "", directory = [ "src", "System", "File" ], filename = "Path", extension = "elm" }
      }
    ,
      { input = "Makefile"
      , posix = { root = "", directory = [], filename = "Makefile", extension = "" }
      , posixToPosix = "Makefile"
      , posixToWin32 = "Makefile"
      , posixFilename = "Makefile"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "Makefile", extension = "" }
      , win32 = { root = "", directory = [], filename = "Makefile", extension = "" }
      , win32ToPosix = "Makefile"
      , win32ToWin32 = "Makefile"
      , win32Filename = "Makefile"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "Makefile", extension = "" }
      }
    ,
      { input = "README.md"
      , posix = { root = "", directory = [], filename = "README", extension = "md" }
      , posixToPosix = "README.md"
      , posixToWin32 = "README.md"
      , posixFilename = "README.md"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "README", extension = "md" }
      , win32 = { root = "", directory = [], filename = "README", extension = "md" }
      , win32ToPosix = "README.md"
      , win32ToWin32 = "README.md"
      , win32Filename = "README.md"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "README", extension = "md" }
      }
    ,
      { input = "/usr/local/lib/libfoo.so.1.2"
      , posix = { root = "/", directory = [ "usr", "local", "lib" ], filename = "libfoo.so.1", extension = "2" }
      , posixToPosix = "/usr/local/lib/libfoo.so.1.2"
      , posixToWin32 = "/usr\\local\\lib\\libfoo.so.1.2"
      , posixFilename = "libfoo.so.1.2"
      , posixParent = Just ({ root = "/", directory = [ "usr", "local" ], filename = "lib", extension = "" })
      , posixAncestors = [ "/usr/local/lib", "/usr/local", "/usr", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "usr", "local", "lib" ], filename = "libfoo.so.1", extension = "2" }
      , win32 = { root = "\\", directory = [ "usr", "local", "lib" ], filename = "libfoo.so.1", extension = "2" }
      , win32ToPosix = "/usr/local/lib/libfoo.so.1.2"
      , win32ToWin32 = "\\usr\\local\\lib\\libfoo.so.1.2"
      , win32Filename = "libfoo.so.1.2"
      , win32Parent = Just ({ root = "\\", directory = [ "usr", "local" ], filename = "lib", extension = "" })
      , win32Ancestors = [ "/usr/local/lib", "/usr/local", "/usr", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "usr", "local", "lib" ], filename = "libfoo.so.1", extension = "2" }
      }
    ,
      { input = "photo.JPEG"
      , posix = { root = "", directory = [], filename = "photo", extension = "JPEG" }
      , posixToPosix = "photo.JPEG"
      , posixToWin32 = "photo.JPEG"
      , posixFilename = "photo.JPEG"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "photo", extension = "JPEG" }
      , win32 = { root = "", directory = [], filename = "photo", extension = "JPEG" }
      , win32ToPosix = "photo.JPEG"
      , win32ToWin32 = "photo.JPEG"
      , win32Filename = "photo.JPEG"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "photo", extension = "JPEG" }
      }
    ,
      { input = "a b/c d.txt"
      , posix = { root = "", directory = [ "a b" ], filename = "c d", extension = "txt" }
      , posixToPosix = "a b/c d.txt"
      , posixToWin32 = "a b\\c d.txt"
      , posixFilename = "c d.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "a b", extension = "" })
      , posixAncestors = [ "a b", "." ]
      , posixRoundTrip = { root = "", directory = [ "a b" ], filename = "c d", extension = "txt" }
      , win32 = { root = "", directory = [ "a b" ], filename = "c d", extension = "txt" }
      , win32ToPosix = "a b/c d.txt"
      , win32ToWin32 = "a b\\c d.txt"
      , win32Filename = "c d.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "a b", extension = "" })
      , win32Ancestors = [ "a b", "." ]
      , win32RoundTrip = { root = "", directory = [ "a b" ], filename = "c d", extension = "txt" }
      }
    ,
      { input = "with space "
      , posix = { root = "", directory = [], filename = "with space ", extension = "" }
      , posixToPosix = "with space "
      , posixToWin32 = "with space "
      , posixFilename = "with space "
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "with space ", extension = "" }
      , win32 = { root = "", directory = [], filename = "with space ", extension = "" }
      , win32ToPosix = "with space "
      , win32ToWin32 = "with space "
      , win32Filename = "with space "
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "with space ", extension = "" }
      }
    ,
      { input = " leading"
      , posix = { root = "", directory = [], filename = " leading", extension = "" }
      , posixToPosix = " leading"
      , posixToWin32 = " leading"
      , posixFilename = " leading"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = " leading", extension = "" }
      , win32 = { root = "", directory = [], filename = " leading", extension = "" }
      , win32ToPosix = " leading"
      , win32ToWin32 = " leading"
      , win32Filename = " leading"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = " leading", extension = "" }
      }
    ,
      { input = "a\\b"
      , posix = { root = "", directory = [], filename = "a\\b", extension = "" }
      , posixToPosix = "a\\b"
      , posixToWin32 = "a\\b"
      , posixFilename = "a\\b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a\\b", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a\\b/c"
      , posix = { root = "", directory = [ "a\\b" ], filename = "c", extension = "" }
      , posixToPosix = "a\\b/c"
      , posixToWin32 = "a\\b\\c"
      , posixFilename = "c"
      , posixParent = Just ({ root = "", directory = [], filename = "a\\b", extension = "" })
      , posixAncestors = [ "a\\b", "." ]
      , posixRoundTrip = { root = "", directory = [ "a\\b" ], filename = "c", extension = "" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToPosix = "a/b/c"
      , win32ToWin32 = "a\\b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      }
    ,
      { input = "\\a"
      , posix = { root = "", directory = [], filename = "\\a", extension = "" }
      , posixToPosix = "\\a"
      , posixToWin32 = "\\a"
      , posixFilename = "\\a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\a", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "\\\\server\\share\\x"
      , posix = { root = "", directory = [], filename = "\\\\server\\share\\x", extension = "" }
      , posixToPosix = "\\\\server\\share\\x"
      , posixToWin32 = "\\\\server\\share\\x"
      , posixFilename = "\\\\server\\share\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\share\\x", extension = "" }
      , win32 = { root = "\\\\server\\share\\", directory = [], filename = "x", extension = "" }
      , win32ToPosix = "/x"
      , win32ToWin32 = "\\\\server\\share\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "\\\\server\\share\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [], filename = "x", extension = "" }
      }
    ,
      { input = "C:"
      , posix = { root = "", directory = [], filename = "C:", extension = "" }
      , posixToPosix = "C:"
      , posixToWin32 = "C:"
      , posixFilename = "C:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "" }
      , win32 = { root = "C:", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:\\"
      , posix = { root = "", directory = [], filename = "C:\\", extension = "" }
      , posixToPosix = "C:\\"
      , posixToWin32 = "C:\\"
      , posixFilename = "C:\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:/"
      , posix = { root = "", directory = [], filename = "C:", extension = "" }
      , posixToPosix = "C:"
      , posixToWin32 = "C:"
      , posixFilename = "C:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "c:\\"
      , posix = { root = "", directory = [], filename = "c:\\", extension = "" }
      , posixToPosix = "c:\\"
      , posixToWin32 = "c:\\"
      , posixFilename = "c:\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "c:\\", extension = "" }
      , win32 = { root = "c:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "c:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "c:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:foo"
      , posix = { root = "", directory = [], filename = "C:foo", extension = "" }
      , posixToPosix = "C:foo"
      , posixToWin32 = "C:foo"
      , posixFilename = "C:foo"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:foo", extension = "" }
      , win32 = { root = "C:", directory = [], filename = "foo", extension = "" }
      , win32ToPosix = "/foo"
      , win32ToWin32 = "C:foo"
      , win32Filename = "foo"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:", directory = [], filename = "foo", extension = "" }
      }
    ,
      { input = "C:foo\\bar.txt"
      , posix = { root = "", directory = [], filename = "C:foo\\bar", extension = "txt" }
      , posixToPosix = "C:foo\\bar.txt"
      , posixToWin32 = "C:foo\\bar.txt"
      , posixFilename = "C:foo\\bar.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:foo\\bar", extension = "txt" }
      , win32 = { root = "C:", directory = [ "foo" ], filename = "bar", extension = "txt" }
      , win32ToPosix = "/foo/bar.txt"
      , win32ToWin32 = "C:foo\\bar.txt"
      , win32Filename = "bar.txt"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "foo", extension = "" })
      , win32Ancestors = [ "/foo", "/" ]
      , win32RoundTrip = { root = "C:", directory = [ "foo" ], filename = "bar", extension = "txt" }
      }
    ,
      { input = "C:\\foo\\bar.txt"
      , posix = { root = "", directory = [], filename = "C:\\foo\\bar", extension = "txt" }
      , posixToPosix = "C:\\foo\\bar.txt"
      , posixToWin32 = "C:\\foo\\bar.txt"
      , posixFilename = "C:\\foo\\bar.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\foo\\bar", extension = "txt" }
      , win32 = { root = "C:\\", directory = [ "foo" ], filename = "bar", extension = "txt" }
      , win32ToPosix = "/foo/bar.txt"
      , win32ToWin32 = "C:\\foo\\bar.txt"
      , win32Filename = "bar.txt"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "foo", extension = "" })
      , win32Ancestors = [ "/foo", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "foo" ], filename = "bar", extension = "txt" }
      }
    ,
      { input = "C:/foo/bar.txt"
      , posix = { root = "", directory = [ "C:", "foo" ], filename = "bar", extension = "txt" }
      , posixToPosix = "C:/foo/bar.txt"
      , posixToWin32 = "C:\\foo\\bar.txt"
      , posixFilename = "bar.txt"
      , posixParent = Just ({ root = "", directory = [ "C:" ], filename = "foo", extension = "" })
      , posixAncestors = [ "C:/foo", "C:", "." ]
      , posixRoundTrip = { root = "", directory = [ "C:", "foo" ], filename = "bar", extension = "txt" }
      , win32 = { root = "C:\\", directory = [ "foo" ], filename = "bar", extension = "txt" }
      , win32ToPosix = "/foo/bar.txt"
      , win32ToWin32 = "C:\\foo\\bar.txt"
      , win32Filename = "bar.txt"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "foo", extension = "" })
      , win32Ancestors = [ "/foo", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "foo" ], filename = "bar", extension = "txt" }
      }
    ,
      { input = "C:\\foo\\"
      , posix = { root = "", directory = [], filename = "C:\\foo\\", extension = "" }
      , posixToPosix = "C:\\foo\\"
      , posixToWin32 = "C:\\foo\\"
      , posixFilename = "C:\\foo\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\foo\\", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "foo", extension = "" }
      , win32ToPosix = "/foo"
      , win32ToWin32 = "C:\\foo"
      , win32Filename = "foo"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "foo", extension = "" }
      }
    ,
      { input = "C:\\foo\\.."
      , posix = { root = "", directory = [], filename = "C:\\foo\\.", extension = "" }
      , posixToPosix = "C:\\foo\\."
      , posixToWin32 = "C:\\foo\\."
      , posixFilename = "C:\\foo\\."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\foo\\", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:\\..\\..\\x"
      , posix = { root = "", directory = [], filename = "C:\\..\\.", extension = "\\x" }
      , posixToPosix = "C:\\..\\..\\x"
      , posixToWin32 = "C:\\..\\..\\x"
      , posixFilename = "C:\\..\\..\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\..\\.", extension = "\\x" }
      , win32 = { root = "C:\\", directory = [], filename = "x", extension = "" }
      , win32ToPosix = "/x"
      , win32ToWin32 = "C:\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "x", extension = "" }
      }
    ,
      { input = "C:..\\x"
      , posix = { root = "", directory = [], filename = "C:.", extension = "\\x" }
      , posixToPosix = "C:..\\x"
      , posixToWin32 = "C:..\\x"
      , posixFilename = "C:..\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:.", extension = "\\x" }
      , win32 = { root = "C:", directory = [ ".." ], filename = "x", extension = "" }
      , win32ToPosix = "/../x"
      , win32ToWin32 = "C:..\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "/..", "/" ]
      , win32RoundTrip = { root = "C:", directory = [ ".." ], filename = "x", extension = "" }
      }
    ,
      { input = "C:."
      , posix = { root = "", directory = [], filename = "C:", extension = "" }
      , posixToPosix = "C:"
      , posixToWin32 = "C:"
      , posixFilename = "C:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "" }
      , win32 = { root = "C:", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:.\\"
      , posix = { root = "", directory = [], filename = "C:", extension = "\\" }
      , posixToPosix = "C:.\\"
      , posixToWin32 = "C:.\\"
      , posixFilename = "C:.\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "\\" }
      , win32 = { root = "C:", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "Z:\\a/b\\c"
      , posix = { root = "", directory = [ "Z:\\a" ], filename = "b\\c", extension = "" }
      , posixToPosix = "Z:\\a/b\\c"
      , posixToWin32 = "Z:\\a\\b\\c"
      , posixFilename = "b\\c"
      , posixParent = Just ({ root = "", directory = [], filename = "Z:\\a", extension = "" })
      , posixAncestors = [ "Z:\\a", "." ]
      , posixRoundTrip = { root = "", directory = [ "Z:\\a" ], filename = "b\\c", extension = "" }
      , win32 = { root = "Z:\\", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToPosix = "/a/b/c"
      , win32ToWin32 = "Z:\\a\\b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "Z:\\", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "/a/b", "/a", "/" ]
      , win32RoundTrip = { root = "Z:\\", directory = [ "a", "b" ], filename = "c", extension = "" }
      }
    ,
      { input = "C:\\Program Files\\App\\app.exe"
      , posix = { root = "", directory = [], filename = "C:\\Program Files\\App\\app", extension = "exe" }
      , posixToPosix = "C:\\Program Files\\App\\app.exe"
      , posixToWin32 = "C:\\Program Files\\App\\app.exe"
      , posixFilename = "C:\\Program Files\\App\\app.exe"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\Program Files\\App\\app", extension = "exe" }
      , win32 = { root = "C:\\", directory = [ "Program Files", "App" ], filename = "app", extension = "exe" }
      , win32ToPosix = "/Program Files/App/app.exe"
      , win32ToWin32 = "C:\\Program Files\\App\\app.exe"
      , win32Filename = "app.exe"
      , win32Parent = Just ({ root = "C:\\", directory = [ "Program Files" ], filename = "App", extension = "" })
      , win32Ancestors = [ "/Program Files/App", "/Program Files", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "Program Files", "App" ], filename = "app", extension = "exe" }
      }
    ,
      { input = "d:\\x.y.z"
      , posix = { root = "", directory = [], filename = "d:\\x.y", extension = "z" }
      , posixToPosix = "d:\\x.y.z"
      , posixToWin32 = "d:\\x.y.z"
      , posixFilename = "d:\\x.y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "d:\\x.y", extension = "z" }
      , win32 = { root = "d:\\", directory = [], filename = "x.y", extension = "z" }
      , win32ToPosix = "/x.y.z"
      , win32ToWin32 = "d:\\x.y.z"
      , win32Filename = "x.y.z"
      , win32Parent = Just ({ root = "d:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "d:\\", directory = [], filename = "x.y", extension = "z" }
      }
    ,
      { input = "1:\\x"
      , posix = { root = "", directory = [], filename = "1:\\x", extension = "" }
      , posixToPosix = "1:\\x"
      , posixToWin32 = "1:\\x"
      , posixFilename = "1:\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "1:\\x", extension = "" }
      , win32 = { root = "", directory = [ ".", "1:" ], filename = "x", extension = "" }
      , win32ToPosix = "./1:/x"
      , win32ToWin32 = ".\\1:\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "", directory = [ "." ], filename = "1:", extension = "" })
      , win32Ancestors = [ "./1:", "." ]
      , win32RoundTrip = { root = "", directory = [ ".", "1:" ], filename = "x", extension = "" }
      }
    ,
      { input = "CC:\\x"
      , posix = { root = "", directory = [], filename = "CC:\\x", extension = "" }
      , posixToPosix = "CC:\\x"
      , posixToWin32 = "CC:\\x"
      , posixFilename = "CC:\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "CC:\\x", extension = "" }
      , win32 = { root = "", directory = [ ".", "CC:" ], filename = "x", extension = "" }
      , win32ToPosix = "./CC:/x"
      , win32ToWin32 = ".\\CC:\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "", directory = [ "." ], filename = "CC:", extension = "" })
      , win32Ancestors = [ "./CC:", "." ]
      , win32RoundTrip = { root = "", directory = [ ".", "CC:" ], filename = "x", extension = "" }
      }
    ,
      { input = "\\\\server\\share"
      , posix = { root = "", directory = [], filename = "\\\\server\\share", extension = "" }
      , posixToPosix = "\\\\server\\share"
      , posixToWin32 = "\\\\server\\share"
      , posixFilename = "\\\\server\\share"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\share", extension = "" }
      , win32 = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\server\\share\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\server\\share\\"
      , posix = { root = "", directory = [], filename = "\\\\server\\share\\", extension = "" }
      , posixToPosix = "\\\\server\\share\\"
      , posixToWin32 = "\\\\server\\share\\"
      , posixFilename = "\\\\server\\share\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\share\\", extension = "" }
      , win32 = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\server\\share\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\server\\share\\dir\\file.txt"
      , posix = { root = "", directory = [], filename = "\\\\server\\share\\dir\\file", extension = "txt" }
      , posixToPosix = "\\\\server\\share\\dir\\file.txt"
      , posixToWin32 = "\\\\server\\share\\dir\\file.txt"
      , posixFilename = "\\\\server\\share\\dir\\file.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\share\\dir\\file", extension = "txt" }
      , win32 = { root = "\\\\server\\share\\", directory = [ "dir" ], filename = "file", extension = "txt" }
      , win32ToPosix = "/dir/file.txt"
      , win32ToWin32 = "\\\\server\\share\\dir\\file.txt"
      , win32Filename = "file.txt"
      , win32Parent = Just ({ root = "\\\\server\\share\\", directory = [], filename = "dir", extension = "" })
      , win32Ancestors = [ "/dir", "/" ]
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [ "dir" ], filename = "file", extension = "txt" }
      }
    ,
      { input = "//server/share/dir/file.txt"
      , posix = { root = "/", directory = [ "server", "share", "dir" ], filename = "file", extension = "txt" }
      , posixToPosix = "/server/share/dir/file.txt"
      , posixToWin32 = "/server\\share\\dir\\file.txt"
      , posixFilename = "file.txt"
      , posixParent = Just ({ root = "/", directory = [ "server", "share" ], filename = "dir", extension = "" })
      , posixAncestors = [ "/server/share/dir", "/server/share", "/server", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "server", "share", "dir" ], filename = "file", extension = "txt" }
      , win32 = { root = "\\\\server\\share\\", directory = [ "dir" ], filename = "file", extension = "txt" }
      , win32ToPosix = "/dir/file.txt"
      , win32ToWin32 = "\\\\server\\share\\dir\\file.txt"
      , win32Filename = "file.txt"
      , win32Parent = Just ({ root = "\\\\server\\share\\", directory = [], filename = "dir", extension = "" })
      , win32Ancestors = [ "/dir", "/" ]
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [ "dir" ], filename = "file", extension = "txt" }
      }
    ,
      { input = "\\\\server"
      , posix = { root = "", directory = [], filename = "\\\\server", extension = "" }
      , posixToPosix = "\\\\server"
      , posixToWin32 = "\\\\server"
      , posixFilename = "\\\\server"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "server", extension = "" }
      , win32ToPosix = "/server"
      , win32ToWin32 = "\\server"
      , win32Filename = "server"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "server", extension = "" }
      }
    ,
      { input = "\\\\server\\"
      , posix = { root = "", directory = [], filename = "\\\\server\\", extension = "" }
      , posixToPosix = "\\\\server\\"
      , posixToWin32 = "\\\\server\\"
      , posixFilename = "\\\\server\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "server", extension = "" }
      , win32ToPosix = "/server"
      , win32ToWin32 = "\\server"
      , win32Filename = "server"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "server", extension = "" }
      }
    ,
      { input = "\\\\"
      , posix = { root = "", directory = [], filename = "\\\\", extension = "" }
      , posixToPosix = "\\\\"
      , posixToWin32 = "\\\\"
      , posixFilename = "\\\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\\\x"
      , posix = { root = "", directory = [], filename = "\\\\\\x", extension = "" }
      , posixToPosix = "\\\\\\x"
      , posixToWin32 = "\\\\\\x"
      , posixFilename = "\\\\\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\\\x", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "x", extension = "" }
      , win32ToPosix = "/x"
      , win32ToWin32 = "\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "x", extension = "" }
      }
    ,
      { input = "\\\\.\\x"
      , posix = { root = "", directory = [], filename = "\\\\", extension = "\\x" }
      , posixToPosix = "\\\\.\\x"
      , posixToWin32 = "\\\\.\\x"
      , posixFilename = "\\\\.\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\", extension = "\\x" }
      , win32 = { root = "\\\\.\\x", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\.\\x"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\.\\x", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\.\\PHYSICALDRIVE0"
      , posix = { root = "", directory = [], filename = "\\\\", extension = "\\PHYSICALDRIVE0" }
      , posixToPosix = "\\\\.\\PHYSICALDRIVE0"
      , posixToWin32 = "\\\\.\\PHYSICALDRIVE0"
      , posixFilename = "\\\\.\\PHYSICALDRIVE0"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\", extension = "\\PHYSICALDRIVE0" }
      , win32 = { root = "\\\\.\\PHYSICALDRIVE0", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\.\\PHYSICALDRIVE0"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\.\\PHYSICALDRIVE0", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\?\\C:\\x\\y"
      , posix = { root = "", directory = [], filename = "\\\\?\\C:\\x\\y", extension = "" }
      , posixToPosix = "\\\\?\\C:\\x\\y"
      , posixToWin32 = "\\\\?\\C:\\x\\y"
      , posixFilename = "\\\\?\\C:\\x\\y"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\?\\C:\\x\\y", extension = "" }
      , win32 = { root = "\\\\?\\C:\\", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "/x/y"
      , win32ToWin32 = "\\\\?\\C:\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "\\\\?\\C:\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "\\\\?\\C:\\", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "\\\\?\\COM1:"
      , posix = { root = "", directory = [], filename = "\\\\?\\COM1:", extension = "" }
      , posixToPosix = "\\\\?\\COM1:"
      , posixToWin32 = "\\\\?\\COM1:"
      , posixFilename = "\\\\?\\COM1:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\?\\COM1:", extension = "" }
      , win32 = { root = "\\\\?\\COM1:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\?\\COM1:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\?\\COM1:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\.\\COM1:\\x"
      , posix = { root = "", directory = [], filename = "\\\\", extension = "\\COM1:\\x" }
      , posixToPosix = "\\\\.\\COM1:\\x"
      , posixToWin32 = "\\\\.\\COM1:\\x"
      , posixFilename = "\\\\.\\COM1:\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\", extension = "\\COM1:\\x" }
      , win32 = { root = "\\\\?\\COM1:\\", directory = [], filename = "x", extension = "" }
      , win32ToPosix = "/x"
      , win32ToWin32 = "\\\\?\\COM1:\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "\\\\?\\COM1:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\?\\COM1:\\", directory = [], filename = "x", extension = "" }
      }
    ,
      { input = "\\\\server\\\\share"
      , posix = { root = "", directory = [], filename = "\\\\server\\\\share", extension = "" }
      , posixToPosix = "\\\\server\\\\share"
      , posixToWin32 = "\\\\server\\\\share"
      , posixFilename = "\\\\server\\\\share"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\server\\\\share", extension = "" }
      , win32 = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\server\\share\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\server\\share\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "a/b\\c"
      , posix = { root = "", directory = [ "a" ], filename = "b\\c", extension = "" }
      , posixToPosix = "a/b\\c"
      , posixToWin32 = "a\\b\\c"
      , posixFilename = "b\\c"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b\\c", extension = "" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToPosix = "a/b/c"
      , win32ToWin32 = "a\\b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      }
    ,
      { input = "a\\b/c\\d.e"
      , posix = { root = "", directory = [ "a\\b" ], filename = "c\\d", extension = "e" }
      , posixToPosix = "a\\b/c\\d.e"
      , posixToWin32 = "a\\b\\c\\d.e"
      , posixFilename = "c\\d.e"
      , posixParent = Just ({ root = "", directory = [], filename = "a\\b", extension = "" })
      , posixAncestors = [ "a\\b", "." ]
      , posixRoundTrip = { root = "", directory = [ "a\\b" ], filename = "c\\d", extension = "e" }
      , win32 = { root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      , win32ToPosix = "a/b/c/d.e"
      , win32ToWin32 = "a\\b\\c\\d.e"
      , win32Filename = "d.e"
      , win32Parent = Just ({ root = "", directory = [ "a", "b" ], filename = "c", extension = "" })
      , win32Ancestors = [ "a/b/c", "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      }
    ,
      { input = "\\a/b"
      , posix = { root = "", directory = [ "\\a" ], filename = "b", extension = "" }
      , posixToPosix = "\\a/b"
      , posixToWin32 = "\\a\\b"
      , posixFilename = "b"
      , posixParent = Just ({ root = "", directory = [], filename = "\\a", extension = "" })
      , posixAncestors = [ "\\a", "." ]
      , posixRoundTrip = { root = "", directory = [ "\\a" ], filename = "b", extension = "" }
      , win32 = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "/a/b"
      , win32ToWin32 = "\\a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "/a\\b"
      , posix = { root = "/", directory = [], filename = "a\\b", extension = "" }
      , posixToPosix = "/a\\b"
      , posixToWin32 = "/a\\b"
      , posixFilename = "a\\b"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a\\b", extension = "" }
      , win32 = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "/a/b"
      , win32ToWin32 = "\\a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a\\\\b//c"
      , posix = { root = "", directory = [ "a\\\\b" ], filename = "c", extension = "" }
      , posixToPosix = "a\\\\b/c"
      , posixToWin32 = "a\\\\b\\c"
      , posixFilename = "c"
      , posixParent = Just ({ root = "", directory = [], filename = "a\\\\b", extension = "" })
      , posixAncestors = [ "a\\\\b", "." ]
      , posixRoundTrip = { root = "", directory = [ "a\\\\b" ], filename = "c", extension = "" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToPosix = "a/b/c"
      , win32ToWin32 = "a\\b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = "c", extension = "" }
      }
    ,
      { input = "a\\.\\b"
      , posix = { root = "", directory = [], filename = "a\\", extension = "\\b" }
      , posixToPosix = "a\\.\\b"
      , posixToWin32 = "a\\.\\b"
      , posixFilename = "a\\.\\b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a\\", extension = "\\b" }
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "a/b"
      , win32ToWin32 = "a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "a\\..\\b"
      , posix = { root = "", directory = [], filename = "a\\.", extension = "\\b" }
      , posixToPosix = "a\\..\\b"
      , posixToWin32 = "a\\..\\b"
      , posixFilename = "a\\..\\b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a\\.", extension = "\\b" }
      , win32 = { root = "", directory = [], filename = "b", extension = "" }
      , win32ToPosix = "b"
      , win32ToWin32 = "b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "b", extension = "" }
      }
    ,
      { input = ":"
      , posix = { root = "", directory = [], filename = ":", extension = "" }
      , posixToPosix = ":"
      , posixToWin32 = ":"
      , posixFilename = ":"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ":", extension = "" }
      , win32 = { root = "", directory = [], filename = ":", extension = "" }
      , win32ToPosix = ":"
      , win32ToWin32 = ":"
      , win32Filename = ":"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ":", extension = "" }
      }
    ,
      { input = "a:"
      , posix = { root = "", directory = [], filename = "a:", extension = "" }
      , posixToPosix = "a:"
      , posixToWin32 = "a:"
      , posixFilename = "a:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a:", extension = "" }
      , win32 = { root = "a:", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "a:"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "a:", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "a:b"
      , posix = { root = "", directory = [], filename = "a:b", extension = "" }
      , posixToPosix = "a:b"
      , posixToWin32 = "a:b"
      , posixFilename = "a:b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a:b", extension = "" }
      , win32 = { root = "a:", directory = [], filename = "b", extension = "" }
      , win32ToPosix = "/b"
      , win32ToWin32 = "a:b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "a:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "a:", directory = [], filename = "b", extension = "" }
      }
    ,
      { input = "ab:c"
      , posix = { root = "", directory = [], filename = "ab:c", extension = "" }
      , posixToPosix = "ab:c"
      , posixToWin32 = "ab:c"
      , posixFilename = "ab:c"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "ab:c", extension = "" }
      , win32 = { root = "", directory = [], filename = "ab:c", extension = "" }
      , win32ToPosix = "ab:c"
      , win32ToWin32 = "ab:c"
      , win32Filename = "ab:c"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "ab:c", extension = "" }
      }
    ,
      { input = "foo:bar\\baz"
      , posix = { root = "", directory = [], filename = "foo:bar\\baz", extension = "" }
      , posixToPosix = "foo:bar\\baz"
      , posixToWin32 = "foo:bar\\baz"
      , posixFilename = "foo:bar\\baz"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "foo:bar\\baz", extension = "" }
      , win32 = { root = "", directory = [ "foo:bar" ], filename = "baz", extension = "" }
      , win32ToPosix = "foo:bar/baz"
      , win32ToWin32 = "foo:bar\\baz"
      , win32Filename = "baz"
      , win32Parent = Just ({ root = "", directory = [], filename = "foo:bar", extension = "" })
      , win32Ancestors = [ "foo:bar", "." ]
      , win32RoundTrip = { root = "", directory = [ "foo:bar" ], filename = "baz", extension = "" }
      }
    ,
      { input = "a/b:c"
      , posix = { root = "", directory = [ "a" ], filename = "b:c", extension = "" }
      , posixToPosix = "a/b:c"
      , posixToWin32 = "a\\b:c"
      , posixFilename = "b:c"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b:c", extension = "" }
      , win32 = { root = "", directory = [ "a" ], filename = "b:c", extension = "" }
      , win32ToPosix = "a/b:c"
      , win32ToWin32 = "a\\b:c"
      , win32Filename = "b:c"
      , win32Parent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a" ], filename = "b:c", extension = "" }
      }
    ,
      { input = "x:/y"
      , posix = { root = "", directory = [ "x:" ], filename = "y", extension = "" }
      , posixToPosix = "x:/y"
      , posixToWin32 = "x:\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [], filename = "x:", extension = "" })
      , posixAncestors = [ "x:", "." ]
      , posixRoundTrip = { root = "", directory = [ "x:" ], filename = "y", extension = "" }
      , win32 = { root = "x:\\", directory = [], filename = "y", extension = "" }
      , win32ToPosix = "/y"
      , win32ToWin32 = "x:\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "x:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "x:\\", directory = [], filename = "y", extension = "" }
      }
    ,
      { input = "CON"
      , posix = { root = "", directory = [], filename = "CON", extension = "" }
      , posixToPosix = "CON"
      , posixToWin32 = "CON"
      , posixFilename = "CON"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "CON", extension = "" }
      , win32 = { root = "", directory = [], filename = "CON", extension = "" }
      , win32ToPosix = "CON"
      , win32ToWin32 = "CON"
      , win32Filename = "CON"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "CON", extension = "" }
      }
    ,
      { input = "CON:"
      , posix = { root = "", directory = [], filename = "CON:", extension = "" }
      , posixToPosix = "CON:"
      , posixToWin32 = "CON:"
      , posixFilename = "CON:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "CON:", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "CON:", extension = "" }
      , win32ToPosix = "./CON:"
      , win32ToWin32 = ".\\CON:"
      , win32Filename = "CON:"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [ "." ], filename = "CON:", extension = "" }
      }
    ,
      { input = "con:x"
      , posix = { root = "", directory = [], filename = "con:x", extension = "" }
      , posixToPosix = "con:x"
      , posixToWin32 = "con:x"
      , posixFilename = "con:x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "con:x", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "con:x", extension = "" }
      , win32ToPosix = "./con:x"
      , win32ToWin32 = ".\\con:x"
      , win32Filename = "con:x"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "con:x", extension = "" }
      }
    ,
      { input = "NUL"
      , posix = { root = "", directory = [], filename = "NUL", extension = "" }
      , posixToPosix = "NUL"
      , posixToWin32 = "NUL"
      , posixFilename = "NUL"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "NUL", extension = "" }
      , win32 = { root = "", directory = [], filename = "NUL", extension = "" }
      , win32ToPosix = "NUL"
      , win32ToWin32 = "NUL"
      , win32Filename = "NUL"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "NUL", extension = "" }
      }
    ,
      { input = "CONx"
      , posix = { root = "", directory = [], filename = "CONx", extension = "" }
      , posixToPosix = "CONx"
      , posixToWin32 = "CONx"
      , posixFilename = "CONx"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "CONx", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "CONx", extension = "" }
      , win32ToPosix = "./CONx"
      , win32ToWin32 = ".\\CONx"
      , win32Filename = "CONx"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "CONx", extension = "" }
      }
    ,
      { input = "aux.txt"
      , posix = { root = "", directory = [], filename = "aux", extension = "txt" }
      , posixToPosix = "aux.txt"
      , posixToWin32 = "aux.txt"
      , posixFilename = "aux.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "aux", extension = "txt" }
      , win32 = { root = "", directory = [], filename = "aux", extension = "txt" }
      , win32ToPosix = "aux.txt"
      , win32ToWin32 = "aux.txt"
      , win32Filename = "aux.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "aux", extension = "txt" }
      }
    ,
      { input = "LPT1:\\x"
      , posix = { root = "", directory = [], filename = "LPT1:\\x", extension = "" }
      , posixToPosix = "LPT1:\\x"
      , posixToWin32 = "LPT1:\\x"
      , posixFilename = "LPT1:\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "LPT1:\\x", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "LPT1:x", extension = "" }
      , win32ToPosix = "./LPT1:x"
      , win32ToWin32 = ".\\LPT1:x"
      , win32Filename = "LPT1:x"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "LPT1:x", extension = "" }
      }
    ,
      { input = "COM\u{00B9}:"
      , posix = { root = "", directory = [], filename = "COM\u{00B9}:", extension = "" }
      , posixToPosix = "COM\u{00B9}:"
      , posixToWin32 = "COM\u{00B9}:"
      , posixFilename = "COM\u{00B9}:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "COM\u{00B9}:", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "COM\u{00B9}:", extension = "" }
      , win32ToPosix = "./COM\u{00B9}:"
      , win32ToWin32 = ".\\COM\u{00B9}:"
      , win32Filename = "COM\u{00B9}:"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [ "." ], filename = "COM\u{00B9}:", extension = "" }
      }
    ,
      { input = "a/b/c/d/e.f"
      , posix = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      , posixToPosix = "a/b/c/d/e.f"
      , posixToWin32 = "a\\b\\c\\d\\e.f"
      , posixFilename = "e.f"
      , posixParent = Just ({ root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "" })
      , posixAncestors = [ "a/b/c/d", "a/b/c", "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      , win32 = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      , win32ToPosix = "a/b/c/d/e.f"
      , win32ToWin32 = "a\\b\\c\\d\\e.f"
      , win32Filename = "e.f"
      , win32Parent = Just ({ root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "" })
      , win32Ancestors = [ "a/b/c/d", "a/b/c", "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      }
    ,
      { input = "/a/b/c/"
      , posix = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "" }
      , posixToPosix = "/a/b/c"
      , posixToWin32 = "/a\\b\\c"
      , posixFilename = "c"
      , posixParent = Just ({ root = "/", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "/a/b", "/a", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32 = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToPosix = "/a/b/c"
      , win32ToWin32 = "\\a\\b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "\\", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "/a/b", "/a", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "" }
      }
    ,
      { input = "~"
      , posix = { root = "", directory = [], filename = "~", extension = "" }
      , posixToPosix = "~"
      , posixToWin32 = "~"
      , posixFilename = "~"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "~", extension = "" }
      , win32 = { root = "", directory = [], filename = "~", extension = "" }
      , win32ToPosix = "~"
      , win32ToWin32 = "~"
      , win32Filename = "~"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "~", extension = "" }
      }
    ,
      { input = "~/x"
      , posix = { root = "", directory = [ "~" ], filename = "x", extension = "" }
      , posixToPosix = "~/x"
      , posixToWin32 = "~\\x"
      , posixFilename = "x"
      , posixParent = Just ({ root = "", directory = [], filename = "~", extension = "" })
      , posixAncestors = [ "~", "." ]
      , posixRoundTrip = { root = "", directory = [ "~" ], filename = "x", extension = "" }
      , win32 = { root = "", directory = [ "~" ], filename = "x", extension = "" }
      , win32ToPosix = "~/x"
      , win32ToWin32 = "~\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "", directory = [], filename = "~", extension = "" })
      , win32Ancestors = [ "~", "." ]
      , win32RoundTrip = { root = "", directory = [ "~" ], filename = "x", extension = "" }
      }
    ,
      { input = "a~b"
      , posix = { root = "", directory = [], filename = "a~b", extension = "" }
      , posixToPosix = "a~b"
      , posixToWin32 = "a~b"
      , posixFilename = "a~b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a~b", extension = "" }
      , win32 = { root = "", directory = [], filename = "a~b", extension = "" }
      , win32ToPosix = "a~b"
      , win32ToWin32 = "a~b"
      , win32Filename = "a~b"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a~b", extension = "" }
      }
    ,
      { input = "-"
      , posix = { root = "", directory = [], filename = "-", extension = "" }
      , posixToPosix = "-"
      , posixToWin32 = "-"
      , posixFilename = "-"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "-", extension = "" }
      , win32 = { root = "", directory = [], filename = "-", extension = "" }
      , win32ToPosix = "-"
      , win32ToWin32 = "-"
      , win32Filename = "-"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "-", extension = "" }
      }
    ,
      { input = "--x"
      , posix = { root = "", directory = [], filename = "--x", extension = "" }
      , posixToPosix = "--x"
      , posixToWin32 = "--x"
      , posixFilename = "--x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "--x", extension = "" }
      , win32 = { root = "", directory = [], filename = "--x", extension = "" }
      , win32ToPosix = "--x"
      , win32ToWin32 = "--x"
      , win32Filename = "--x"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "--x", extension = "" }
      }
    ,
      { input = "a/.b/c"
      , posix = { root = "", directory = [ "a", ".b" ], filename = "c", extension = "" }
      , posixToPosix = "a/.b/c"
      , posixToWin32 = "a\\.b\\c"
      , posixFilename = "c"
      , posixParent = Just ({ root = "", directory = [ "a" ], filename = "", extension = "b" })
      , posixAncestors = [ "a/.b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", ".b" ], filename = "c", extension = "" }
      , win32 = { root = "", directory = [ "a", ".b" ], filename = "c", extension = "" }
      , win32ToPosix = "a/.b/c"
      , win32ToWin32 = "a\\.b\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "", extension = "b" })
      , win32Ancestors = [ "a/.b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", ".b" ], filename = "c", extension = "" }
      }
    ,
      { input = ".git/config"
      , posix = { root = "", directory = [ ".git" ], filename = "config", extension = "" }
      , posixToPosix = ".git/config"
      , posixToWin32 = ".git\\config"
      , posixFilename = "config"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "git" })
      , posixAncestors = [ ".git", "." ]
      , posixRoundTrip = { root = "", directory = [ ".git" ], filename = "config", extension = "" }
      , win32 = { root = "", directory = [ ".git" ], filename = "config", extension = "" }
      , win32ToPosix = ".git/config"
      , win32ToWin32 = ".git\\config"
      , win32Filename = "config"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "git" })
      , win32Ancestors = [ ".git", "." ]
      , win32RoundTrip = { root = "", directory = [ ".git" ], filename = "config", extension = "" }
      }
    ,
      { input = "node_modules/.bin/"
      , posix = { root = "", directory = [ "node_modules" ], filename = ".bin", extension = "" }
      , posixToPosix = "node_modules/.bin"
      , posixToWin32 = "node_modules\\.bin"
      , posixFilename = ".bin"
      , posixParent = Just ({ root = "", directory = [], filename = "node_modules", extension = "" })
      , posixAncestors = [ "node_modules", "." ]
      , posixRoundTrip = { root = "", directory = [ "node_modules" ], filename = ".bin", extension = "" }
      , win32 = { root = "", directory = [ "node_modules" ], filename = ".bin", extension = "" }
      , win32ToPosix = "node_modules/.bin"
      , win32ToWin32 = "node_modules\\.bin"
      , win32Filename = ".bin"
      , win32Parent = Just ({ root = "", directory = [], filename = "node_modules", extension = "" })
      , win32Ancestors = [ "node_modules", "." ]
      , win32RoundTrip = { root = "", directory = [ "node_modules" ], filename = ".bin", extension = "" }
      }
    ,
      { input = "/etc/passwd"
      , posix = { root = "/", directory = [ "etc" ], filename = "passwd", extension = "" }
      , posixToPosix = "/etc/passwd"
      , posixToWin32 = "/etc\\passwd"
      , posixFilename = "passwd"
      , posixParent = Just ({ root = "/", directory = [], filename = "etc", extension = "" })
      , posixAncestors = [ "/etc", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "etc" ], filename = "passwd", extension = "" }
      , win32 = { root = "\\", directory = [ "etc" ], filename = "passwd", extension = "" }
      , win32ToPosix = "/etc/passwd"
      , win32ToWin32 = "\\etc\\passwd"
      , win32Filename = "passwd"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "etc", extension = "" })
      , win32Ancestors = [ "/etc", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "etc" ], filename = "passwd", extension = "" }
      }
    ,
      { input = "/tmp/"
      , posix = { root = "/", directory = [], filename = "tmp", extension = "" }
      , posixToPosix = "/tmp"
      , posixToWin32 = "/tmp"
      , posixFilename = "tmp"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "tmp", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "tmp", extension = "" }
      , win32ToPosix = "/tmp"
      , win32ToWin32 = "\\tmp"
      , win32Filename = "tmp"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "tmp", extension = "" }
      }
    ,
      { input = "x.y/z.w/"
      , posix = { root = "", directory = [ "x.y" ], filename = "z", extension = "w" }
      , posixToPosix = "x.y/z.w"
      , posixToWin32 = "x.y\\z.w"
      , posixFilename = "z.w"
      , posixParent = Just ({ root = "", directory = [], filename = "x", extension = "y" })
      , posixAncestors = [ "x.y", "." ]
      , posixRoundTrip = { root = "", directory = [ "x.y" ], filename = "z", extension = "w" }
      , win32 = { root = "", directory = [ "x.y" ], filename = "z", extension = "w" }
      , win32ToPosix = "x.y/z.w"
      , win32ToWin32 = "x.y\\z.w"
      , win32Filename = "z.w"
      , win32Parent = Just ({ root = "", directory = [], filename = "x", extension = "y" })
      , win32Ancestors = [ "x.y", "." ]
      , win32RoundTrip = { root = "", directory = [ "x.y" ], filename = "z", extension = "w" }
      }
    ,
      { input = "\\"
      , posix = { root = "", directory = [], filename = "\\", extension = "" }
      , posixToPosix = "\\"
      , posixToWin32 = "\\"
      , posixFilename = "\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\", extension = "" }
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "C:\\a\\.\\b"
      , posix = { root = "", directory = [], filename = "C:\\a\\", extension = "\\b" }
      , posixToPosix = "C:\\a\\.\\b"
      , posixToWin32 = "C:\\a\\.\\b"
      , posixFilename = "C:\\a\\.\\b"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\a\\", extension = "\\b" }
      , win32 = { root = "C:\\", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToPosix = "/a/b"
      , win32ToWin32 = "C:\\a\\b"
      , win32Filename = "b"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "a", extension = "" })
      , win32Ancestors = [ "/a", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { input = "C:\\a\\b\\..\\..\\.."
      , posix = { root = "", directory = [], filename = "C:\\a\\b\\..\\..\\.", extension = "" }
      , posixToPosix = "C:\\a\\b\\..\\..\\."
      , posixToWin32 = "C:\\a\\b\\..\\..\\."
      , posixFilename = "C:\\a\\b\\..\\..\\."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\a\\b\\..\\..\\", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\..\\x"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\.", extension = "\\x" }
      , posixToPosix = "\\\\srv\\shr\\..\\x"
      , posixToWin32 = "\\\\srv\\shr\\..\\x"
      , posixFilename = "\\\\srv\\shr\\..\\x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\.", extension = "\\x" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = "x", extension = "" }
      , win32ToPosix = "/x"
      , win32ToWin32 = "\\\\srv\\shr\\x"
      , win32Filename = "x"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = "x", extension = "" }
      }
    ,
      { input = "\\\\.\\COM1"
      , posix = { root = "", directory = [], filename = "\\\\", extension = "\\COM1" }
      , posixToPosix = "\\\\.\\COM1"
      , posixToWin32 = "\\\\.\\COM1"
      , posixFilename = "\\\\.\\COM1"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\", extension = "\\COM1" }
      , win32 = { root = "\\\\.\\COM1", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\.\\COM1"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\.\\COM1", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\?\\UNC\\srv\\shr\\f"
      , posix = { root = "", directory = [], filename = "\\\\?\\UNC\\srv\\shr\\f", extension = "" }
      , posixToPosix = "\\\\?\\UNC\\srv\\shr\\f"
      , posixToWin32 = "\\\\?\\UNC\\srv\\shr\\f"
      , posixFilename = "\\\\?\\UNC\\srv\\shr\\f"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\?\\UNC\\srv\\shr\\f", extension = "" }
      , win32 = { root = "\\\\?\\UNC\\", directory = [ "srv", "shr" ], filename = "f", extension = "" }
      , win32ToPosix = "/srv/shr/f"
      , win32ToWin32 = "\\\\?\\UNC\\srv\\shr\\f"
      , win32Filename = "f"
      , win32Parent = Just ({ root = "\\\\?\\UNC\\", directory = [ "srv" ], filename = "shr", extension = "" })
      , win32Ancestors = [ "/srv/shr", "/srv", "/" ]
      , win32RoundTrip = { root = "\\\\?\\UNC\\", directory = [ "srv", "shr" ], filename = "f", extension = "" }
      }
    ,
      { input = "PRN.txt"
      , posix = { root = "", directory = [], filename = "PRN", extension = "txt" }
      , posixToPosix = "PRN.txt"
      , posixToWin32 = "PRN.txt"
      , posixFilename = "PRN.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "PRN", extension = "txt" }
      , win32 = { root = "", directory = [], filename = "PRN", extension = "txt" }
      , win32ToPosix = "PRN.txt"
      , win32ToWin32 = "PRN.txt"
      , win32Filename = "PRN.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "PRN", extension = "txt" }
      }
    ,
      { input = "nul:"
      , posix = { root = "", directory = [], filename = "nul:", extension = "" }
      , posixToPosix = "nul:"
      , posixToWin32 = "nul:"
      , posixFilename = "nul:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "nul:", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "nul:", extension = "" }
      , win32ToPosix = "./nul:"
      , win32ToWin32 = ".\\nul:"
      , win32Filename = "nul:"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [ "." ], filename = "nul:", extension = "" }
      }
    ,
      { input = "LPT9:x"
      , posix = { root = "", directory = [], filename = "LPT9:x", extension = "" }
      , posixToPosix = "LPT9:x"
      , posixToWin32 = "LPT9:x"
      , posixFilename = "LPT9:x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "LPT9:x", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "LPT9:x", extension = "" }
      , win32ToPosix = "./LPT9:x"
      , win32ToWin32 = ".\\LPT9:x"
      , win32Filename = "LPT9:x"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "LPT9:x", extension = "" }
      }
    ,
      { input = "c:/a:b"
      , posix = { root = "", directory = [ "c:" ], filename = "a:b", extension = "" }
      , posixToPosix = "c:/a:b"
      , posixToWin32 = "c:\\a:b"
      , posixFilename = "a:b"
      , posixParent = Just ({ root = "", directory = [], filename = "c:", extension = "" })
      , posixAncestors = [ "c:", "." ]
      , posixRoundTrip = { root = "", directory = [ "c:" ], filename = "a:b", extension = "" }
      , win32 = { root = "c:\\", directory = [], filename = "a:b", extension = "" }
      , win32ToPosix = "/a:b"
      , win32ToWin32 = "c:\\a:b"
      , win32Filename = "a:b"
      , win32Parent = Just ({ root = "c:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "c:\\", directory = [], filename = "a:b", extension = "" }
      }
    ,
      { input = "1:"
      , posix = { root = "", directory = [], filename = "1:", extension = "" }
      , posixToPosix = "1:"
      , posixToWin32 = "1:"
      , posixFilename = "1:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "1:", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "1:", extension = "" }
      , win32ToPosix = "./1:"
      , win32ToWin32 = ".\\1:"
      , win32Filename = "1:"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [ "." ], filename = "1:", extension = "" }
      }
    ,
      { input = "ab:\\c"
      , posix = { root = "", directory = [], filename = "ab:\\c", extension = "" }
      , posixToPosix = "ab:\\c"
      , posixToWin32 = "ab:\\c"
      , posixFilename = "ab:\\c"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "ab:\\c", extension = "" }
      , win32 = { root = "", directory = [ ".", "ab:" ], filename = "c", extension = "" }
      , win32ToPosix = "./ab:/c"
      , win32ToWin32 = ".\\ab:\\c"
      , win32Filename = "c"
      , win32Parent = Just ({ root = "", directory = [ "." ], filename = "ab:", extension = "" })
      , win32Ancestors = [ "./ab:", "." ]
      , win32RoundTrip = { root = "", directory = [ ".", "ab:" ], filename = "c", extension = "" }
      }
    ,
      { input = "a/b:"
      , posix = { root = "", directory = [ "a" ], filename = "b:", extension = "" }
      , posixToPosix = "a/b:"
      , posixToWin32 = "a\\b:"
      , posixFilename = "b:"
      , posixParent = Just ({ root = "", directory = [], filename = "a", extension = "" })
      , posixAncestors = [ "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a" ], filename = "b:", extension = "" }
      , win32 = { root = "", directory = [ ".", "a" ], filename = "b:", extension = "" }
      , win32ToPosix = "./a/b:"
      , win32ToWin32 = ".\\a\\b:"
      , win32Filename = "b:"
      , win32Parent = Just ({ root = "", directory = [ "." ], filename = "a", extension = "" })
      , win32Ancestors = [ "./a", "." ]
      , win32RoundTrip = { root = "", directory = [ ".", "a" ], filename = "b:", extension = "" }
      }
    ,
      { input = "a:/"
      , posix = { root = "", directory = [], filename = "a:", extension = "" }
      , posixToPosix = "a:"
      , posixToWin32 = "a:"
      , posixFilename = "a:"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a:", extension = "" }
      , win32 = { root = "a:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "a:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "a:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "./C:x"
      , posix = { root = "", directory = [ "." ], filename = "C:x", extension = "" }
      , posixToPosix = "./C:x"
      , posixToWin32 = ".\\C:x"
      , posixFilename = "C:x"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "C:x", extension = "" }
      , win32 = { root = "", directory = [ "." ], filename = "C:x", extension = "" }
      , win32ToPosix = "./C:x"
      , win32ToWin32 = ".\\C:x"
      , win32Filename = "C:x"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [ "." ], filename = "C:x", extension = "" }
      }
    ,
      { input = "\u{00E9}t\u{00E9}/caf\u{00E9}.txt"
      , posix = { root = "", directory = [ "\u{00E9}t\u{00E9}" ], filename = "caf\u{00E9}", extension = "txt" }
      , posixToPosix = "\u{00E9}t\u{00E9}/caf\u{00E9}.txt"
      , posixToWin32 = "\u{00E9}t\u{00E9}\\caf\u{00E9}.txt"
      , posixFilename = "caf\u{00E9}.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "\u{00E9}t\u{00E9}", extension = "" })
      , posixAncestors = [ "\u{00E9}t\u{00E9}", "." ]
      , posixRoundTrip = { root = "", directory = [ "\u{00E9}t\u{00E9}" ], filename = "caf\u{00E9}", extension = "txt" }
      , win32 = { root = "", directory = [ "\u{00E9}t\u{00E9}" ], filename = "caf\u{00E9}", extension = "txt" }
      , win32ToPosix = "\u{00E9}t\u{00E9}/caf\u{00E9}.txt"
      , win32ToWin32 = "\u{00E9}t\u{00E9}\\caf\u{00E9}.txt"
      , win32Filename = "caf\u{00E9}.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "\u{00E9}t\u{00E9}", extension = "" })
      , win32Ancestors = [ "\u{00E9}t\u{00E9}", "." ]
      , win32RoundTrip = { root = "", directory = [ "\u{00E9}t\u{00E9}" ], filename = "caf\u{00E9}", extension = "txt" }
      }
    ,
      { input = "\u{65E5}\u{672C}/\u{6587}\u{5B57}.md"
      , posix = { root = "", directory = [ "\u{65E5}\u{672C}" ], filename = "\u{6587}\u{5B57}", extension = "md" }
      , posixToPosix = "\u{65E5}\u{672C}/\u{6587}\u{5B57}.md"
      , posixToWin32 = "\u{65E5}\u{672C}\\\u{6587}\u{5B57}.md"
      , posixFilename = "\u{6587}\u{5B57}.md"
      , posixParent = Just ({ root = "", directory = [], filename = "\u{65E5}\u{672C}", extension = "" })
      , posixAncestors = [ "\u{65E5}\u{672C}", "." ]
      , posixRoundTrip = { root = "", directory = [ "\u{65E5}\u{672C}" ], filename = "\u{6587}\u{5B57}", extension = "md" }
      , win32 = { root = "", directory = [ "\u{65E5}\u{672C}" ], filename = "\u{6587}\u{5B57}", extension = "md" }
      , win32ToPosix = "\u{65E5}\u{672C}/\u{6587}\u{5B57}.md"
      , win32ToWin32 = "\u{65E5}\u{672C}\\\u{6587}\u{5B57}.md"
      , win32Filename = "\u{6587}\u{5B57}.md"
      , win32Parent = Just ({ root = "", directory = [], filename = "\u{65E5}\u{672C}", extension = "" })
      , win32Ancestors = [ "\u{65E5}\u{672C}", "." ]
      , win32RoundTrip = { root = "", directory = [ "\u{65E5}\u{672C}" ], filename = "\u{6587}\u{5B57}", extension = "md" }
      }
    ,
      { input = "\u{1F600}/\u{1F600}.\u{1F600}"
      , posix = { root = "", directory = [ "\u{1F600}" ], filename = "\u{1F600}", extension = "\u{1F600}" }
      , posixToPosix = "\u{1F600}/\u{1F600}.\u{1F600}"
      , posixToWin32 = "\u{1F600}\\\u{1F600}.\u{1F600}"
      , posixFilename = "\u{1F600}.\u{1F600}"
      , posixParent = Just ({ root = "", directory = [], filename = "\u{1F600}", extension = "" })
      , posixAncestors = [ "\u{1F600}", "." ]
      , posixRoundTrip = { root = "", directory = [ "\u{1F600}" ], filename = "\u{1F600}", extension = "\u{1F600}" }
      , win32 = { root = "", directory = [ "\u{1F600}" ], filename = "\u{1F600}", extension = "\u{1F600}" }
      , win32ToPosix = "\u{1F600}/\u{1F600}.\u{1F600}"
      , win32ToWin32 = "\u{1F600}\\\u{1F600}.\u{1F600}"
      , win32Filename = "\u{1F600}.\u{1F600}"
      , win32Parent = Just ({ root = "", directory = [], filename = "\u{1F600}", extension = "" })
      , win32Ancestors = [ "\u{1F600}", "." ]
      , win32RoundTrip = { root = "", directory = [ "\u{1F600}" ], filename = "\u{1F600}", extension = "\u{1F600}" }
      }
    ,
      { input = "/\u{0394}/\u{03A9}.\u{03B1}"
      , posix = { root = "/", directory = [ "\u{0394}" ], filename = "\u{03A9}", extension = "\u{03B1}" }
      , posixToPosix = "/\u{0394}/\u{03A9}.\u{03B1}"
      , posixToWin32 = "/\u{0394}\\\u{03A9}.\u{03B1}"
      , posixFilename = "\u{03A9}.\u{03B1}"
      , posixParent = Just ({ root = "/", directory = [], filename = "\u{0394}", extension = "" })
      , posixAncestors = [ "/\u{0394}", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "\u{0394}" ], filename = "\u{03A9}", extension = "\u{03B1}" }
      , win32 = { root = "\\", directory = [ "\u{0394}" ], filename = "\u{03A9}", extension = "\u{03B1}" }
      , win32ToPosix = "/\u{0394}/\u{03A9}.\u{03B1}"
      , win32ToWin32 = "\\\u{0394}\\\u{03A9}.\u{03B1}"
      , win32Filename = "\u{03A9}.\u{03B1}"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "\u{0394}", extension = "" })
      , win32Ancestors = [ "/\u{0394}", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "\u{0394}" ], filename = "\u{03A9}", extension = "\u{03B1}" }
      }
    ,
      { input = "C:\\\u{00FC}ber\\na\u{00EF}ve.txt"
      , posix = { root = "", directory = [], filename = "C:\\\u{00FC}ber\\na\u{00EF}ve", extension = "txt" }
      , posixToPosix = "C:\\\u{00FC}ber\\na\u{00EF}ve.txt"
      , posixToWin32 = "C:\\\u{00FC}ber\\na\u{00EF}ve.txt"
      , posixFilename = "C:\\\u{00FC}ber\\na\u{00EF}ve.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\\u{00FC}ber\\na\u{00EF}ve", extension = "txt" }
      , win32 = { root = "C:\\", directory = [ "\u{00FC}ber" ], filename = "na\u{00EF}ve", extension = "txt" }
      , win32ToPosix = "/\u{00FC}ber/na\u{00EF}ve.txt"
      , win32ToWin32 = "C:\\\u{00FC}ber\\na\u{00EF}ve.txt"
      , win32Filename = "na\u{00EF}ve.txt"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "\u{00FC}ber", extension = "" })
      , win32Ancestors = [ "/\u{00FC}ber", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "\u{00FC}ber" ], filename = "na\u{00EF}ve", extension = "txt" }
      }
    ,
      { input = "\u{00E9}"
      , posix = { root = "", directory = [], filename = "\u{00E9}", extension = "" }
      , posixToPosix = "\u{00E9}"
      , posixToWin32 = "\u{00E9}"
      , posixFilename = "\u{00E9}"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\u{00E9}", extension = "" }
      , win32 = { root = "", directory = [], filename = "\u{00E9}", extension = "" }
      , win32ToPosix = "\u{00E9}"
      , win32ToWin32 = "\u{00E9}"
      , win32Filename = "\u{00E9}"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "\u{00E9}", extension = "" }
      }
    ,
      { input = "\u{1F600}"
      , posix = { root = "", directory = [], filename = "\u{1F600}", extension = "" }
      , posixToPosix = "\u{1F600}"
      , posixToWin32 = "\u{1F600}"
      , posixFilename = "\u{1F600}"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\u{1F600}", extension = "" }
      , win32 = { root = "", directory = [], filename = "\u{1F600}", extension = "" }
      , win32ToPosix = "\u{1F600}"
      , win32ToWin32 = "\u{1F600}"
      , win32Filename = "\u{1F600}"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "\u{1F600}", extension = "" }
      }
    ,
      { input = "a"
      , posix = { root = "", directory = [], filename = "a", extension = "" }
      , posixToPosix = "a"
      , posixToWin32 = "a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "a"
      , win32ToWin32 = "a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "a.txt"
      , posix = { root = "", directory = [], filename = "a", extension = "txt" }
      , posixToPosix = "a.txt"
      , posixToWin32 = "a.txt"
      , posixFilename = "a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "a", extension = "txt" }
      , win32 = { root = "", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "a.txt"
      , win32ToWin32 = "a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = ".hidden"
      , posix = { root = "", directory = [], filename = ".hidden", extension = "" }
      , posixToPosix = ".hidden"
      , posixToWin32 = ".hidden"
      , posixFilename = ".hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = ".hidden", extension = "" }
      , win32 = { root = "", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = ".hidden"
      , win32ToWin32 = ".hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "." ]
      , win32RoundTrip = { root = "", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "x/y/"
      , posix = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      , posixToPosix = "x/y"
      , posixToWin32 = "x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [], filename = "x", extension = "" })
      , posixAncestors = [ "x", "." ]
      , posixRoundTrip = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      , win32 = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "x/y"
      , win32ToWin32 = "x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "x", "." ]
      , win32RoundTrip = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "x\\y.z"
      , posix = { root = "", directory = [], filename = "x\\y", extension = "z" }
      , posixToPosix = "x\\y.z"
      , posixToWin32 = "x\\y.z"
      , posixFilename = "x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "x\\y", extension = "z" }
      , win32 = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "x/y.z"
      , win32ToWin32 = "x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "x", "." ]
      , win32RoundTrip = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "/a.txt"
      , posix = { root = "/", directory = [], filename = "a", extension = "txt" }
      , posixToPosix = "/a.txt"
      , posixToWin32 = "/a.txt"
      , posixFilename = "a.txt"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "a", extension = "txt" }
      , win32 = { root = "\\", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "/a.txt"
      , win32ToWin32 = "\\a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = "/.hidden"
      , posix = { root = "/", directory = [], filename = ".hidden", extension = "" }
      , posixToPosix = "/.hidden"
      , posixToWin32 = "/.hidden"
      , posixFilename = ".hidden"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = ".hidden", extension = "" }
      , win32 = { root = "\\", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = "/.hidden"
      , win32ToWin32 = "\\.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "/x/y/"
      , posix = { root = "/", directory = [ "x" ], filename = "y", extension = "" }
      , posixToPosix = "/x/y"
      , posixToWin32 = "/x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "/", directory = [], filename = "x", extension = "" })
      , posixAncestors = [ "/x", "/" ]
      , posixRoundTrip = { root = "/", directory = [ "x" ], filename = "y", extension = "" }
      , win32 = { root = "\\", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "/x/y"
      , win32ToWin32 = "\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "/x\\y.z"
      , posix = { root = "/", directory = [], filename = "x\\y", extension = "z" }
      , posixToPosix = "/x\\y.z"
      , posixToWin32 = "/x\\y.z"
      , posixFilename = "x\\y.z"
      , posixParent = Just ({ root = "/", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "/" ]
      , posixRoundTrip = { root = "/", directory = [], filename = "x\\y", extension = "z" }
      , win32 = { root = "\\", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "/x/y.z"
      , win32ToWin32 = "\\x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "\\", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "./x/y/"
      , posix = { root = "", directory = [ ".", "x" ], filename = "y", extension = "" }
      , posixToPosix = "./x/y"
      , posixToWin32 = ".\\x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [ "." ], filename = "x", extension = "" })
      , posixAncestors = [ "./x", "." ]
      , posixRoundTrip = { root = "", directory = [ ".", "x" ], filename = "y", extension = "" }
      , win32 = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "x/y"
      , win32ToWin32 = "x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "x", "." ]
      , win32RoundTrip = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "./x\\y.z"
      , posix = { root = "", directory = [ "." ], filename = "x\\y", extension = "z" }
      , posixToPosix = "./x\\y.z"
      , posixToWin32 = ".\\x\\y.z"
      , posixFilename = "x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [ "." ], filename = "x\\y", extension = "z" }
      , win32 = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "x/y.z"
      , win32ToWin32 = "x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "x", "." ]
      , win32RoundTrip = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "../a"
      , posix = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      , posixToPosix = "../a"
      , posixToWin32 = "..\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      , win32ToPosix = "../a"
      , win32ToWin32 = "..\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "a", extension = "" }
      }
    ,
      { input = "../a.txt"
      , posix = { root = "", directory = [ ".." ], filename = "a", extension = "txt" }
      , posixToPosix = "../a.txt"
      , posixToWin32 = "..\\a.txt"
      , posixFilename = "a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "a", extension = "txt" }
      , win32 = { root = "", directory = [ ".." ], filename = "a", extension = "txt" }
      , win32ToPosix = "../a.txt"
      , win32ToWin32 = "..\\a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = "a", extension = "txt" }
      }
    ,
      { input = "../.hidden"
      , posix = { root = "", directory = [ ".." ], filename = ".hidden", extension = "" }
      , posixToPosix = "../.hidden"
      , posixToWin32 = "..\\.hidden"
      , posixFilename = ".hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = ".hidden", extension = "" }
      , win32 = { root = "", directory = [ ".." ], filename = ".hidden", extension = "" }
      , win32ToPosix = "../.hidden"
      , win32ToWin32 = "..\\.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , win32Ancestors = [ "..", "." ]
      , win32RoundTrip = { root = "", directory = [ ".." ], filename = ".hidden", extension = "" }
      }
    ,
      { input = "../x/y/"
      , posix = { root = "", directory = [ "..", "x" ], filename = "y", extension = "" }
      , posixToPosix = "../x/y"
      , posixToWin32 = "..\\x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [ ".." ], filename = "x", extension = "" })
      , posixAncestors = [ "../x", "..", "." ]
      , posixRoundTrip = { root = "", directory = [ "..", "x" ], filename = "y", extension = "" }
      , win32 = { root = "", directory = [ "..", "x" ], filename = "y", extension = "" }
      , win32ToPosix = "../x/y"
      , win32ToWin32 = "..\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "", directory = [ ".." ], filename = "x", extension = "" })
      , win32Ancestors = [ "../x", "..", "." ]
      , win32RoundTrip = { root = "", directory = [ "..", "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "../x\\y.z"
      , posix = { root = "", directory = [ ".." ], filename = "x\\y", extension = "z" }
      , posixToPosix = "../x\\y.z"
      , posixToWin32 = "..\\x\\y.z"
      , posixFilename = "x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "..", extension = "" })
      , posixAncestors = [ "..", "." ]
      , posixRoundTrip = { root = "", directory = [ ".." ], filename = "x\\y", extension = "z" }
      , win32 = { root = "", directory = [ "..", "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "../x/y.z"
      , win32ToWin32 = "..\\x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "", directory = [ ".." ], filename = "x", extension = "" })
      , win32Ancestors = [ "../x", "..", "." ]
      , win32RoundTrip = { root = "", directory = [ "..", "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "C:a"
      , posix = { root = "", directory = [], filename = "C:a", extension = "" }
      , posixToPosix = "C:a"
      , posixToWin32 = "C:a"
      , posixFilename = "C:a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:a", extension = "" }
      , win32 = { root = "C:", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "C:a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "C:a.txt"
      , posix = { root = "", directory = [], filename = "C:a", extension = "txt" }
      , posixToPosix = "C:a.txt"
      , posixToWin32 = "C:a.txt"
      , posixFilename = "C:a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:a", extension = "txt" }
      , win32 = { root = "C:", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "/a.txt"
      , win32ToWin32 = "C:a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = "C:.hidden"
      , posix = { root = "", directory = [], filename = "C:", extension = "hidden" }
      , posixToPosix = "C:.hidden"
      , posixToWin32 = "C:.hidden"
      , posixFilename = "C:.hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "hidden" }
      , win32 = { root = "C:", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = "/.hidden"
      , win32ToWin32 = "C:.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "C:x/y/"
      , posix = { root = "", directory = [ "C:x" ], filename = "y", extension = "" }
      , posixToPosix = "C:x/y"
      , posixToWin32 = "C:x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [], filename = "C:x", extension = "" })
      , posixAncestors = [ "C:x", "." ]
      , posixRoundTrip = { root = "", directory = [ "C:x" ], filename = "y", extension = "" }
      , win32 = { root = "C:", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "/x/y"
      , win32ToWin32 = "C:x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "C:", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "C:x\\y.z"
      , posix = { root = "", directory = [], filename = "C:x\\y", extension = "z" }
      , posixToPosix = "C:x\\y.z"
      , posixToWin32 = "C:x\\y.z"
      , posixFilename = "C:x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:x\\y", extension = "z" }
      , win32 = { root = "C:", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "/x/y.z"
      , win32ToWin32 = "C:x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "C:", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "C:", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "C:.."
      , posix = { root = "", directory = [], filename = "C:.", extension = "" }
      , posixToPosix = "C:."
      , posixToWin32 = "C:."
      , posixFilename = "C:."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:", extension = "" }
      , win32 = { root = "C:", directory = [], filename = "..", extension = "" }
      , win32ToPosix = "/.."
      , win32ToWin32 = "C:.."
      , win32Filename = ".."
      , win32Parent = Just ({ root = "C:", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:", directory = [], filename = "..", extension = "" }
      }
    ,
      { input = "C:\\a"
      , posix = { root = "", directory = [], filename = "C:\\a", extension = "" }
      , posixToPosix = "C:\\a"
      , posixToWin32 = "C:\\a"
      , posixFilename = "C:\\a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\a", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "C:\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "C:\\a.txt"
      , posix = { root = "", directory = [], filename = "C:\\a", extension = "txt" }
      , posixToPosix = "C:\\a.txt"
      , posixToWin32 = "C:\\a.txt"
      , posixFilename = "C:\\a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\a", extension = "txt" }
      , win32 = { root = "C:\\", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "/a.txt"
      , win32ToWin32 = "C:\\a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = "C:\\.hidden"
      , posix = { root = "", directory = [], filename = "C:\\", extension = "hidden" }
      , posixToPosix = "C:\\.hidden"
      , posixToWin32 = "C:\\.hidden"
      , posixFilename = "C:\\.hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\", extension = "hidden" }
      , win32 = { root = "C:\\", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = "/.hidden"
      , win32ToWin32 = "C:\\.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "C:\\x/y/"
      , posix = { root = "", directory = [ "C:\\x" ], filename = "y", extension = "" }
      , posixToPosix = "C:\\x/y"
      , posixToWin32 = "C:\\x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [], filename = "C:\\x", extension = "" })
      , posixAncestors = [ "C:\\x", "." ]
      , posixRoundTrip = { root = "", directory = [ "C:\\x" ], filename = "y", extension = "" }
      , win32 = { root = "C:\\", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "/x/y"
      , win32ToWin32 = "C:\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "C:\\x\\y.z"
      , posix = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , posixToPosix = "C:\\x\\y.z"
      , posixToWin32 = "C:\\x\\y.z"
      , posixFilename = "C:\\x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , win32 = { root = "C:\\", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "/x/y.z"
      , win32ToWin32 = "C:\\x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "C:\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "C:\\", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "C:\\.."
      , posix = { root = "", directory = [], filename = "C:\\.", extension = "" }
      , posixToPosix = "C:\\."
      , posixToWin32 = "C:\\."
      , posixFilename = "C:\\."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "C:\\", extension = "" }
      , win32 = { root = "C:\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "C:\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "C:\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\", extension = "" }
      , posixToPosix = "\\\\srv\\shr\\"
      , posixToWin32 = "\\\\srv\\shr\\"
      , posixFilename = "\\\\srv\\shr\\"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\", extension = "" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\srv\\shr\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\a"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\a", extension = "" }
      , posixToPosix = "\\\\srv\\shr\\a"
      , posixToWin32 = "\\\\srv\\shr\\a"
      , posixFilename = "\\\\srv\\shr\\a"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\a", extension = "" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = "a", extension = "" }
      , win32ToPosix = "/a"
      , win32ToWin32 = "\\\\srv\\shr\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = "a", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\a.txt"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\a", extension = "txt" }
      , posixToPosix = "\\\\srv\\shr\\a.txt"
      , posixToWin32 = "\\\\srv\\shr\\a.txt"
      , posixFilename = "\\\\srv\\shr\\a.txt"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\a", extension = "txt" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = "a", extension = "txt" }
      , win32ToPosix = "/a.txt"
      , win32ToWin32 = "\\\\srv\\shr\\a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = "a", extension = "txt" }
      }
    ,
      { input = "\\\\srv\\shr\\.hidden"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\", extension = "hidden" }
      , posixToPosix = "\\\\srv\\shr\\.hidden"
      , posixToWin32 = "\\\\srv\\shr\\.hidden"
      , posixFilename = "\\\\srv\\shr\\.hidden"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\", extension = "hidden" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = ".hidden", extension = "" }
      , win32ToPosix = "/.hidden"
      , win32ToWin32 = "\\\\srv\\shr\\.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" })
      , win32Ancestors = [ "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = ".hidden", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\x/y/"
      , posix = { root = "", directory = [ "\\\\srv\\shr\\x" ], filename = "y", extension = "" }
      , posixToPosix = "\\\\srv\\shr\\x/y"
      , posixToWin32 = "\\\\srv\\shr\\x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [], filename = "\\\\srv\\shr\\x", extension = "" })
      , posixAncestors = [ "\\\\srv\\shr\\x", "." ]
      , posixRoundTrip = { root = "", directory = [ "\\\\srv\\shr\\x" ], filename = "y", extension = "" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToPosix = "/x/y"
      , win32ToWin32 = "\\\\srv\\shr\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [ "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "\\\\srv\\shr\\x\\y.z"
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\x\\y", extension = "z" }
      , posixToPosix = "\\\\srv\\shr\\x\\y.z"
      , posixToWin32 = "\\\\srv\\shr\\x\\y.z"
      , posixFilename = "\\\\srv\\shr\\x\\y.z"
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\x\\y", extension = "z" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [ "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "/x/y.z"
      , win32ToWin32 = "\\\\srv\\shr\\x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "\\\\srv\\shr\\", directory = [], filename = "x", extension = "" })
      , win32Ancestors = [ "/x", "/" ]
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { input = "\\\\srv\\shr\\.."
      , posix = { root = "", directory = [], filename = "\\\\srv\\shr\\.", extension = "" }
      , posixToPosix = "\\\\srv\\shr\\."
      , posixToWin32 = "\\\\srv\\shr\\."
      , posixFilename = "\\\\srv\\shr\\."
      , posixParent = Just ({ root = "", directory = [], filename = "", extension = "" })
      , posixAncestors = [ "." ]
      , posixRoundTrip = { root = "", directory = [], filename = "\\\\srv\\shr\\", extension = "" }
      , win32 = { root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" }
      , win32ToPosix = "/"
      , win32ToWin32 = "\\\\srv\\shr\\"
      , win32Filename = ""
      , win32Parent = Nothing
      , win32Ancestors = []
      , win32RoundTrip = { root = "\\\\srv\\shr\\", directory = [], filename = "", extension = "" }
      }
    ,
      { input = "a/b/a"
      , posix = { root = "", directory = [ "a", "b" ], filename = "a", extension = "" }
      , posixToPosix = "a/b/a"
      , posixToWin32 = "a\\b\\a"
      , posixFilename = "a"
      , posixParent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b" ], filename = "a", extension = "" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = "a", extension = "" }
      , win32ToPosix = "a/b/a"
      , win32ToWin32 = "a\\b\\a"
      , win32Filename = "a"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = "a", extension = "" }
      }
    ,
      { input = "a/b/a.txt"
      , posix = { root = "", directory = [ "a", "b" ], filename = "a", extension = "txt" }
      , posixToPosix = "a/b/a.txt"
      , posixToWin32 = "a\\b\\a.txt"
      , posixFilename = "a.txt"
      , posixParent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b" ], filename = "a", extension = "txt" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = "a", extension = "txt" }
      , win32ToPosix = "a/b/a.txt"
      , win32ToWin32 = "a\\b\\a.txt"
      , win32Filename = "a.txt"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = "a", extension = "txt" }
      }
    ,
      { input = "a/b/.hidden"
      , posix = { root = "", directory = [ "a", "b" ], filename = ".hidden", extension = "" }
      , posixToPosix = "a/b/.hidden"
      , posixToWin32 = "a\\b\\.hidden"
      , posixFilename = ".hidden"
      , posixParent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b" ], filename = ".hidden", extension = "" }
      , win32 = { root = "", directory = [ "a", "b" ], filename = ".hidden", extension = "" }
      , win32ToPosix = "a/b/.hidden"
      , win32ToWin32 = "a\\b\\.hidden"
      , win32Filename = ".hidden"
      , win32Parent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , win32Ancestors = [ "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b" ], filename = ".hidden", extension = "" }
      }
    ,
      { input = "a/b/x/y/"
      , posix = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "" }
      , posixToPosix = "a/b/x/y"
      , posixToWin32 = "a\\b\\x\\y"
      , posixFilename = "y"
      , posixParent = Just ({ root = "", directory = [ "a", "b" ], filename = "x", extension = "" })
      , posixAncestors = [ "a/b/x", "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "" }
      , win32 = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "" }
      , win32ToPosix = "a/b/x/y"
      , win32ToWin32 = "a\\b\\x\\y"
      , win32Filename = "y"
      , win32Parent = Just ({ root = "", directory = [ "a", "b" ], filename = "x", extension = "" })
      , win32Ancestors = [ "a/b/x", "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "" }
      }
    ,
      { input = "a/b/x\\y.z"
      , posix = { root = "", directory = [ "a", "b" ], filename = "x\\y", extension = "z" }
      , posixToPosix = "a/b/x\\y.z"
      , posixToWin32 = "a\\b\\x\\y.z"
      , posixFilename = "x\\y.z"
      , posixParent = Just ({ root = "", directory = [ "a" ], filename = "b", extension = "" })
      , posixAncestors = [ "a/b", "a", "." ]
      , posixRoundTrip = { root = "", directory = [ "a", "b" ], filename = "x\\y", extension = "z" }
      , win32 = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "z" }
      , win32ToPosix = "a/b/x/y.z"
      , win32ToWin32 = "a\\b\\x\\y.z"
      , win32Filename = "y.z"
      , win32Parent = Just ({ root = "", directory = [ "a", "b" ], filename = "x", extension = "" })
      , win32Ancestors = [ "a/b/x", "a/b", "a", "." ]
      , win32RoundTrip = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "z" }
      }
    ]


combineCases : List CombineCase
combineCases =
    [
      { left = ""
      , right = ""
      , append = { root = "", directory = [], filename = "", extension = "" }
      , appendToPosix = "."
      , prepend = { root = "", directory = [], filename = "", extension = "" }
      , prependToPosix = "."
      , appendPosixString = { root = "", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { left = ""
      , right = "/"
      , append = { root = "/", directory = [], filename = "", extension = "" }
      , appendToPosix = "/"
      , prepend = { root = "", directory = [], filename = "", extension = "" }
      , prependToPosix = "."
      , appendPosixString = { root = "/", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { left = ""
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , appendToPosix = "b"
      , prepend = { root = "", directory = [], filename = "b", extension = "" }
      , prependToPosix = "b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "b", extension = "" }
      }
    ,
      { left = ""
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , appendToPosix = "/root/dir"
      , prepend = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      , prependToPosix = "root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = ""
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , appendToPosix = "c/d.e"
      , prepend = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      , prependToPosix = "c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = ""
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , appendToPosix = "C:\\x\\y.z"
      , prepend = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = ""
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , appendToPosix = "../up"
      , prepend = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      , prependToPosix = "../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      }
    ,
      { left = ""
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , appendToPosix = "./here"
      , prepend = { root = "", directory = [ "." ], filename = "here", extension = "" }
      , prependToPosix = "./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "here", extension = "" }
      }
    ,
      { left = "."
      , right = ""
      , append = { root = "", directory = [], filename = "", extension = "" }
      , appendToPosix = "."
      , prepend = { root = "", directory = [], filename = "", extension = "" }
      , prependToPosix = "."
      , appendPosixString = { root = "", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "."
      , right = "/"
      , append = { root = "/", directory = [], filename = "", extension = "" }
      , appendToPosix = "/"
      , prepend = { root = "", directory = [], filename = "", extension = "" }
      , prependToPosix = "."
      , appendPosixString = { root = "/", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "."
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , appendToPosix = "b"
      , prepend = { root = "", directory = [], filename = "b", extension = "" }
      , prependToPosix = "b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "b", extension = "" }
      }
    ,
      { left = "."
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , appendToPosix = "/root/dir"
      , prepend = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      , prependToPosix = "root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "."
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , appendToPosix = "c/d.e"
      , prepend = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      , prependToPosix = "c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "."
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , appendToPosix = "C:\\x\\y.z"
      , prepend = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "."
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , appendToPosix = "../up"
      , prepend = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      , prependToPosix = "../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "."
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , appendToPosix = "./here"
      , prepend = { root = "", directory = [ "." ], filename = "here", extension = "" }
      , prependToPosix = "./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , prependPosixString = { root = "", directory = [ "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "", extension = "" }
      , prependWin32String = { root = "", directory = [], filename = "here", extension = "" }
      }
    ,
      { left = "/"
      , right = ""
      , append = { root = "", directory = [], filename = "", extension = "" }
      , appendToPosix = "."
      , prepend = { root = "/", directory = [], filename = "", extension = "" }
      , prependToPosix = "/"
      , appendPosixString = { root = "", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "/"
      , right = "/"
      , append = { root = "/", directory = [], filename = "", extension = "" }
      , appendToPosix = "/"
      , prepend = { root = "/", directory = [], filename = "", extension = "" }
      , prependToPosix = "/"
      , appendPosixString = { root = "/", directory = [], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "/"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , appendToPosix = "b"
      , prepend = { root = "/", directory = [], filename = "b", extension = "" }
      , prependToPosix = "/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [], filename = "b", extension = "" }
      }
    ,
      { left = "/"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , appendToPosix = "/root/dir"
      , prepend = { root = "/", directory = [ "root" ], filename = "dir", extension = "" }
      , prependToPosix = "/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [ "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "/"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , appendToPosix = "c/d.e"
      , prepend = { root = "/", directory = [ "c" ], filename = "d", extension = "e" }
      , prependToPosix = "/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [ "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "/"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , appendToPosix = "C:\\x\\y.z"
      , prepend = { root = "/", directory = [], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "/"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , appendToPosix = "../up"
      , prepend = { root = "/", directory = [ ".." ], filename = "up", extension = "" }
      , prependToPosix = "/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [ ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [ ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "/"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , appendToPosix = "./here"
      , prepend = { root = "/", directory = [ "." ], filename = "here", extension = "" }
      , prependToPosix = "/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "", extension = "" }
      , prependPosixString = { root = "/", directory = [ "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "", extension = "" }
      , prependWin32String = { root = "\\", directory = [], filename = "here", extension = "" }
      }
    ,
      { left = "a"
      , right = ""
      , append = { root = "", directory = [], filename = "a", extension = "" }
      , appendToPosix = "a"
      , prepend = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , prependToPosix = "a"
      , appendPosixString = { root = "", directory = [], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "", extension = "" }
      }
    ,
      { left = "a"
      , right = "/"
      , append = { root = "/", directory = [], filename = "a", extension = "" }
      , appendToPosix = "/a"
      , prepend = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , prependToPosix = "a"
      , appendPosixString = { root = "/", directory = [], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "", extension = "" }
      }
    ,
      { left = "a"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , appendToPosix = "b/a"
      , prepend = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependToPosix = "a/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { left = "a"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , appendToPosix = "/root/dir/a"
      , prepend = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "a/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "a"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , appendToPosix = "c/d.e/a"
      , prepend = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "a/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "a"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "a", extension = "" }
      , appendToPosix = "C:\\x\\y.z/a"
      , prepend = { root = "", directory = [ "a" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "a/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "a"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , appendToPosix = "../up/a"
      , prepend = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      , prependToPosix = "a/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "a"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "a", extension = "" }
      , appendToPosix = "./here/a"
      , prepend = { root = "", directory = [ "a", "." ], filename = "here", extension = "" }
      , prependToPosix = "a/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "here", extension = "" }
      }
    ,
      { left = "a/b"
      , right = ""
      , append = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , appendToPosix = "a/b"
      , prepend = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      , prependToPosix = "a/b"
      , appendPosixString = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      }
    ,
      { left = "a/b"
      , right = "/"
      , append = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , appendToPosix = "/a/b"
      , prepend = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      , prependToPosix = "a/b"
      , appendPosixString = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b" ], filename = "", extension = "" }
      }
    ,
      { left = "a/b"
      , right = "b"
      , append = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , appendToPosix = "b/a/b"
      , prepend = { root = "", directory = [ "a", "b" ], filename = "b", extension = "" }
      , prependToPosix = "a/b/b"
      , appendPosixString = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b" ], filename = "b", extension = "" }
      }
    ,
      { left = "a/b"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , appendToPosix = "/root/dir/a/b"
      , prepend = { root = "", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "a/b/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "a/b"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , appendToPosix = "c/d.e/a/b"
      , prepend = { root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "a/b/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "a/b"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z", "a" ], filename = "b", extension = "" }
      , appendToPosix = "C:\\x\\y.z/a/b"
      , prepend = { root = "", directory = [ "a", "b" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "a/b/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "a/b"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , appendToPosix = "../up/a/b"
      , prepend = { root = "", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      , prependToPosix = "a/b/../up"
      , appendPosixString = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "a/b"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here", "a" ], filename = "b", extension = "" }
      , appendToPosix = "./here/a/b"
      , prepend = { root = "", directory = [ "a", "b", "." ], filename = "here", extension = "" }
      , prependToPosix = "a/b/./here"
      , appendPosixString = { root = "", directory = [ ".", "here", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "b", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "b" ], filename = "here", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = ""
      , append = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , appendToPosix = "a/b"
      , prepend = { root = "/", directory = [ "a", "b" ], filename = "", extension = "" }
      , prependToPosix = "/a/b"
      , appendPosixString = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b" ], filename = "", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = "/"
      , append = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , appendToPosix = "/a/b"
      , prepend = { root = "/", directory = [ "a", "b" ], filename = "", extension = "" }
      , prependToPosix = "/a/b"
      , appendPosixString = { root = "/", directory = [ "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b" ], filename = "", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = "b"
      , append = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , appendToPosix = "b/a/b"
      , prepend = { root = "/", directory = [ "a", "b" ], filename = "b", extension = "" }
      , prependToPosix = "/a/b/b"
      , appendPosixString = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b" ], filename = "b", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , appendToPosix = "/root/dir/a/b"
      , prepend = { root = "/", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "/a/b/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , appendToPosix = "c/d.e/a/b"
      , prepend = { root = "/", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "/a/b/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "/a/b"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z", "a" ], filename = "b", extension = "" }
      , appendToPosix = "C:\\x\\y.z/a/b"
      , prepend = { root = "/", directory = [ "a", "b" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "/a/b/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "/a/b"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , appendToPosix = "../up/a/b"
      , prepend = { root = "/", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      , prependToPosix = "/a/b/../up"
      , appendPosixString = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "/a/b"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here", "a" ], filename = "b", extension = "" }
      , appendToPosix = "./here/a/b"
      , prepend = { root = "/", directory = [ "a", "b", "." ], filename = "here", extension = "" }
      , prependToPosix = "/a/b/./here"
      , appendPosixString = { root = "", directory = [ ".", "here", "a" ], filename = "b", extension = "" }
      , prependPosixString = { root = "/", directory = [ "a", "b", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here", "a" ], filename = "b", extension = "" }
      , prependWin32String = { root = "\\", directory = [ "a", "b" ], filename = "here", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = ""
      , append = { root = "", directory = [], filename = "file", extension = "txt" }
      , appendToPosix = "file.txt"
      , prepend = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      , prependToPosix = "file.txt"
      , appendPosixString = { root = "", directory = [], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = "/"
      , append = { root = "/", directory = [], filename = "file", extension = "txt" }
      , appendToPosix = "/file.txt"
      , prepend = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      , prependToPosix = "file.txt"
      , appendPosixString = { root = "/", directory = [], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt" ], filename = "", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "file", extension = "txt" }
      , appendToPosix = "b/file.txt"
      , prepend = { root = "", directory = [ "file.txt" ], filename = "b", extension = "" }
      , prependToPosix = "file.txt/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt" ], filename = "b", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "file", extension = "txt" }
      , appendToPosix = "/root/dir/file.txt"
      , prepend = { root = "", directory = [ "file.txt", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "file.txt/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "file", extension = "txt" }
      , appendToPosix = "c/d.e/file.txt"
      , prepend = { root = "", directory = [ "file.txt", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "file.txt/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "file.txt"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "file", extension = "txt" }
      , appendToPosix = "C:\\x\\y.z/file.txt"
      , prepend = { root = "", directory = [ "file.txt" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "file.txt/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "file.txt"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "file", extension = "txt" }
      , appendToPosix = "../up/file.txt"
      , prepend = { root = "", directory = [ "file.txt", ".." ], filename = "up", extension = "" }
      , prependToPosix = "file.txt/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "file.txt"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "file", extension = "txt" }
      , appendToPosix = "./here/file.txt"
      , prepend = { root = "", directory = [ "file.txt", "." ], filename = "here", extension = "" }
      , prependToPosix = "file.txt/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "file", extension = "txt" }
      , prependPosixString = { root = "", directory = [ "file.txt", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "file", extension = "txt" }
      , prependWin32String = { root = "", directory = [ "file.txt" ], filename = "here", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = ""
      , append = { root = "", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      , prependToPosix = "dir/file.tar.gz"
      , appendPosixString = { root = "", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "/"
      , append = { root = "/", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      , prependToPosix = "dir/file.tar.gz"
      , appendPosixString = { root = "/", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "b"
      , append = { root = "", directory = [ "b", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "b/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "b", extension = "" }
      , prependToPosix = "dir/file.tar.gz/b"
      , appendPosixString = { root = "", directory = [ "b", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "b", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "/root/dir/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "dir/file.tar.gz/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "c/d.e/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "dir/file.tar.gz/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "C:\\x\\y.z/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "dir/file.tar.gz/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "../up/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz", ".." ], filename = "up", extension = "" }
      , prependToPosix = "dir/file.tar.gz/../up"
      , appendPosixString = { root = "", directory = [ "..", "up", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "dir/file.tar.gz"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here", "dir" ], filename = "file.tar", extension = "gz" }
      , appendToPosix = "./here/dir/file.tar.gz"
      , prepend = { root = "", directory = [ "dir", "file.tar.gz", "." ], filename = "here", extension = "" }
      , prependToPosix = "dir/file.tar.gz/./here"
      , appendPosixString = { root = "", directory = [ ".", "here", "dir" ], filename = "file.tar", extension = "gz" }
      , prependPosixString = { root = "", directory = [ "dir", "file.tar.gz", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here", "dir" ], filename = "file.tar", extension = "gz" }
      , prependWin32String = { root = "", directory = [ "dir", "file.tar.gz" ], filename = "here", extension = "" }
      }
    ,
      { left = "../x"
      , right = ""
      , append = { root = "", directory = [ ".." ], filename = "x", extension = "" }
      , appendToPosix = "../x"
      , prepend = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      , prependToPosix = "../x"
      , appendPosixString = { root = "", directory = [ ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [ ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      }
    ,
      { left = "../x"
      , right = "/"
      , append = { root = "/", directory = [ ".." ], filename = "x", extension = "" }
      , appendToPosix = "/../x"
      , prepend = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      , prependToPosix = "../x"
      , appendPosixString = { root = "/", directory = [ ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [ ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x" ], filename = "", extension = "" }
      }
    ,
      { left = "../x"
      , right = "b"
      , append = { root = "", directory = [ "b", ".." ], filename = "x", extension = "" }
      , appendToPosix = "b/../x"
      , prepend = { root = "", directory = [ "..", "x" ], filename = "b", extension = "" }
      , prependToPosix = "../x/b"
      , appendPosixString = { root = "", directory = [ "b", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x" ], filename = "b", extension = "" }
      }
    ,
      { left = "../x"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir", ".." ], filename = "x", extension = "" }
      , appendToPosix = "/root/dir/../x"
      , prepend = { root = "", directory = [ "..", "x", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "../x/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "../x"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e", ".." ], filename = "x", extension = "" }
      , appendToPosix = "c/d.e/../x"
      , prepend = { root = "", directory = [ "..", "x", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "../x/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "../x"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z", ".." ], filename = "x", extension = "" }
      , appendToPosix = "C:\\x\\y.z/../x"
      , prepend = { root = "", directory = [ "..", "x" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "../x/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "../x"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up", ".." ], filename = "x", extension = "" }
      , appendToPosix = "../up/../x"
      , prepend = { root = "", directory = [ "..", "x", ".." ], filename = "up", extension = "" }
      , prependToPosix = "../x/../up"
      , appendPosixString = { root = "", directory = [ "..", "up", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "../x"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here", ".." ], filename = "x", extension = "" }
      , appendToPosix = "./here/../x"
      , prepend = { root = "", directory = [ "..", "x", "." ], filename = "here", extension = "" }
      , prependToPosix = "../x/./here"
      , appendPosixString = { root = "", directory = [ ".", "here", ".." ], filename = "x", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "x", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here", ".." ], filename = "x", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x" ], filename = "here", extension = "" }
      }
    ,
      { left = "./y"
      , right = ""
      , append = { root = "", directory = [ "." ], filename = "y", extension = "" }
      , appendToPosix = "./y"
      , prepend = { root = "", directory = [ ".", "y" ], filename = "", extension = "" }
      , prependToPosix = "./y"
      , appendPosixString = { root = "", directory = [ "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y" ], filename = "", extension = "" }
      }
    ,
      { left = "./y"
      , right = "/"
      , append = { root = "/", directory = [ "." ], filename = "y", extension = "" }
      , appendToPosix = "/./y"
      , prepend = { root = "", directory = [ ".", "y" ], filename = "", extension = "" }
      , prependToPosix = "./y"
      , appendPosixString = { root = "/", directory = [ "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y" ], filename = "", extension = "" }
      }
    ,
      { left = "./y"
      , right = "b"
      , append = { root = "", directory = [ "b", "." ], filename = "y", extension = "" }
      , appendToPosix = "b/./y"
      , prepend = { root = "", directory = [ ".", "y" ], filename = "b", extension = "" }
      , prependToPosix = "./y/b"
      , appendPosixString = { root = "", directory = [ "b", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y" ], filename = "b", extension = "" }
      }
    ,
      { left = "./y"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir", "." ], filename = "y", extension = "" }
      , appendToPosix = "/root/dir/./y"
      , prepend = { root = "", directory = [ ".", "y", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "./y/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "./y"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e", "." ], filename = "y", extension = "" }
      , appendToPosix = "c/d.e/./y"
      , prepend = { root = "", directory = [ ".", "y", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "./y/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "./y"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z", "." ], filename = "y", extension = "" }
      , appendToPosix = "C:\\x\\y.z/./y"
      , prepend = { root = "", directory = [ ".", "y" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "./y/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "./y"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up", "." ], filename = "y", extension = "" }
      , appendToPosix = "../up/./y"
      , prepend = { root = "", directory = [ ".", "y", ".." ], filename = "up", extension = "" }
      , prependToPosix = "./y/../up"
      , appendPosixString = { root = "", directory = [ "..", "up", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "./y"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here", "." ], filename = "y", extension = "" }
      , appendToPosix = "./here/./y"
      , prepend = { root = "", directory = [ ".", "y", "." ], filename = "here", extension = "" }
      , prependToPosix = "./y/./here"
      , appendPosixString = { root = "", directory = [ ".", "here", "." ], filename = "y", extension = "" }
      , prependPosixString = { root = "", directory = [ ".", "y", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "y", extension = "" }
      , prependWin32String = { root = "", directory = [ "y" ], filename = "here", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = ""
      , append = { root = "", directory = [], filename = ".hidden", extension = "" }
      , appendToPosix = ".hidden"
      , prepend = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      , prependToPosix = ".hidden"
      , appendPosixString = { root = "", directory = [], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = "/"
      , append = { root = "/", directory = [], filename = ".hidden", extension = "" }
      , appendToPosix = "/.hidden"
      , prepend = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      , prependToPosix = ".hidden"
      , appendPosixString = { root = "/", directory = [], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden" ], filename = "", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = ".hidden", extension = "" }
      , appendToPosix = "b/.hidden"
      , prepend = { root = "", directory = [ ".hidden" ], filename = "b", extension = "" }
      , prependToPosix = ".hidden/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden" ], filename = "b", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = ".hidden", extension = "" }
      , appendToPosix = "/root/dir/.hidden"
      , prepend = { root = "", directory = [ ".hidden", "root" ], filename = "dir", extension = "" }
      , prependToPosix = ".hidden/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = ".hidden", extension = "" }
      , appendToPosix = "c/d.e/.hidden"
      , prepend = { root = "", directory = [ ".hidden", "c" ], filename = "d", extension = "e" }
      , prependToPosix = ".hidden/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = ".hidden"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = ".hidden", extension = "" }
      , appendToPosix = "C:\\x\\y.z/.hidden"
      , prepend = { root = "", directory = [ ".hidden" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = ".hidden/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = ".hidden"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = ".hidden", extension = "" }
      , appendToPosix = "../up/.hidden"
      , prepend = { root = "", directory = [ ".hidden", ".." ], filename = "up", extension = "" }
      , prependToPosix = ".hidden/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = ".hidden"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = ".hidden", extension = "" }
      , appendToPosix = "./here/.hidden"
      , prepend = { root = "", directory = [ ".hidden", "." ], filename = "here", extension = "" }
      , prependToPosix = ".hidden/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = ".hidden", extension = "" }
      , prependPosixString = { root = "", directory = [ ".hidden", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = ".hidden", extension = "" }
      , prependWin32String = { root = "", directory = [ ".hidden" ], filename = "here", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = ""
      , append = { root = "", directory = [], filename = "C:\\w", extension = "" }
      , appendToPosix = "C:\\w"
      , prepend = { root = "", directory = [ "C:\\w" ], filename = "", extension = "" }
      , prependToPosix = "C:\\w"
      , appendPosixString = { root = "", directory = [], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w" ], filename = "", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = "/"
      , append = { root = "/", directory = [], filename = "C:\\w", extension = "" }
      , appendToPosix = "/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w" ], filename = "", extension = "" }
      , prependToPosix = "C:\\w"
      , appendPosixString = { root = "/", directory = [], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w" ], filename = "", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "b/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w" ], filename = "b", extension = "" }
      , prependToPosix = "C:\\w/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w" ], filename = "b", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "/root/dir/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "C:\\w/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "c/d.e/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "C:\\w/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "C:\\w"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "C:\\x\\y.z/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "C:\\w/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "C:\\w"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "../up/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w", ".." ], filename = "up", extension = "" }
      , prependToPosix = "C:\\w/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "C:\\w"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "C:\\w", extension = "" }
      , appendToPosix = "./here/C:\\w"
      , prepend = { root = "", directory = [ "C:\\w", "." ], filename = "here", extension = "" }
      , prependToPosix = "C:\\w/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "C:\\w", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:\\w", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "w", extension = "" }
      , prependWin32String = { root = "C:\\", directory = [ "w" ], filename = "here", extension = "" }
      }
    ,
      { left = "C:"
      , right = ""
      , append = { root = "", directory = [], filename = "C:", extension = "" }
      , appendToPosix = "C:"
      , prepend = { root = "", directory = [ "C:" ], filename = "", extension = "" }
      , prependToPosix = "C:"
      , appendPosixString = { root = "", directory = [], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "C:"
      , right = "/"
      , append = { root = "/", directory = [], filename = "C:", extension = "" }
      , appendToPosix = "/C:"
      , prepend = { root = "", directory = [ "C:" ], filename = "", extension = "" }
      , prependToPosix = "C:"
      , appendPosixString = { root = "/", directory = [], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [], filename = "", extension = "" }
      }
    ,
      { left = "C:"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "C:", extension = "" }
      , appendToPosix = "b/C:"
      , prepend = { root = "", directory = [ "C:" ], filename = "b", extension = "" }
      , prependToPosix = "C:/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [], filename = "b", extension = "" }
      }
    ,
      { left = "C:"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "C:", extension = "" }
      , appendToPosix = "/root/dir/C:"
      , prepend = { root = "", directory = [ "C:", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "C:/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [ "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "C:"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "C:", extension = "" }
      , appendToPosix = "c/d.e/C:"
      , prepend = { root = "", directory = [ "C:", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "C:/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [ "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "C:"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "C:", extension = "" }
      , appendToPosix = "C:\\x\\y.z/C:"
      , prepend = { root = "", directory = [ "C:" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "C:/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [ "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "C:"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "C:", extension = "" }
      , appendToPosix = "../up/C:"
      , prepend = { root = "", directory = [ "C:", ".." ], filename = "up", extension = "" }
      , prependToPosix = "C:/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [ ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "C:"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "C:", extension = "" }
      , appendToPosix = "./here/C:"
      , prepend = { root = "", directory = [ "C:", "." ], filename = "here", extension = "" }
      , prependToPosix = "C:/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "C:", extension = "" }
      , prependPosixString = { root = "", directory = [ "C:", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "", extension = "" }
      , prependWin32String = { root = "C:", directory = [], filename = "here", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = ""
      , append = { root = "", directory = [], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z"
      , appendPosixString = { root = "", directory = [], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z" ], filename = "", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "/"
      , append = { root = "/", directory = [], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z"
      , appendPosixString = { root = "/", directory = [], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z" ], filename = "", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "b/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "b", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z" ], filename = "b", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "/root/dir/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "c/d.e/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "\\\\srv\\shr\\z/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "C:\\x\\y.z/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "\\\\srv\\shr\\z/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "../up/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z", ".." ], filename = "up", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "\\\\srv\\shr\\z"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , appendToPosix = "./here/\\\\srv\\shr\\z"
      , prepend = { root = "", directory = [ "\\\\srv\\shr\\z", "." ], filename = "here", extension = "" }
      , prependToPosix = "\\\\srv\\shr\\z/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "\\\\srv\\shr\\z", extension = "" }
      , prependPosixString = { root = "", directory = [ "\\\\srv\\shr\\z", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "z", extension = "" }
      , prependWin32String = { root = "\\\\srv\\shr\\", directory = [ "z" ], filename = "here", extension = "" }
      }
    ,
      { left = "a/"
      , right = ""
      , append = { root = "", directory = [], filename = "a", extension = "" }
      , appendToPosix = "a"
      , prepend = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , prependToPosix = "a"
      , appendPosixString = { root = "", directory = [], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "", extension = "" }
      }
    ,
      { left = "a/"
      , right = "/"
      , append = { root = "/", directory = [], filename = "a", extension = "" }
      , appendToPosix = "/a"
      , prepend = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , prependToPosix = "a"
      , appendPosixString = { root = "/", directory = [], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "", extension = "" }
      }
    ,
      { left = "a/"
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , appendToPosix = "b/a"
      , prepend = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , prependToPosix = "a/b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      }
    ,
      { left = "a/"
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , appendToPosix = "/root/dir/a"
      , prepend = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "a/root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = "a/"
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , appendToPosix = "c/d.e/a"
      , prepend = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "a/c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = "a/"
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "a", extension = "" }
      , appendToPosix = "C:\\x\\y.z/a"
      , prepend = { root = "", directory = [ "a" ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "a/C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a" ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = "a/"
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , appendToPosix = "../up/a"
      , prepend = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      , prependToPosix = "a/../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = "a/"
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "a", extension = "" }
      , appendToPosix = "./here/a"
      , prepend = { root = "", directory = [ "a", "." ], filename = "here", extension = "" }
      , prependToPosix = "a/./here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "a", extension = "" }
      , prependPosixString = { root = "", directory = [ "a", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "a", extension = "" }
      , prependWin32String = { root = "", directory = [ "a" ], filename = "here", extension = "" }
      }
    ,
      { left = ".."
      , right = ""
      , append = { root = "", directory = [], filename = "..", extension = "" }
      , appendToPosix = ".."
      , prepend = { root = "", directory = [ ".." ], filename = "", extension = "" }
      , prependToPosix = ".."
      , appendPosixString = { root = "", directory = [], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "", extension = "" }
      , appendWin32String = { root = "", directory = [], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "", extension = "" }
      }
    ,
      { left = ".."
      , right = "/"
      , append = { root = "/", directory = [], filename = "..", extension = "" }
      , appendToPosix = "/.."
      , prepend = { root = "", directory = [ ".." ], filename = "", extension = "" }
      , prependToPosix = ".."
      , appendPosixString = { root = "/", directory = [], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "", extension = "" }
      , appendWin32String = { root = "\\", directory = [], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "", extension = "" }
      }
    ,
      { left = ".."
      , right = "b"
      , append = { root = "", directory = [ "b" ], filename = "..", extension = "" }
      , appendToPosix = "b/.."
      , prepend = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      , prependToPosix = "../b"
      , appendPosixString = { root = "", directory = [ "b" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      , appendWin32String = { root = "", directory = [ "b" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "b", extension = "" }
      }
    ,
      { left = ".."
      , right = "/root/dir"
      , append = { root = "/", directory = [ "root", "dir" ], filename = "..", extension = "" }
      , appendToPosix = "/root/dir/.."
      , prepend = { root = "", directory = [ "..", "root" ], filename = "dir", extension = "" }
      , prependToPosix = "../root/dir"
      , appendPosixString = { root = "/", directory = [ "root", "dir" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "root" ], filename = "dir", extension = "" }
      , appendWin32String = { root = "\\", directory = [ "root", "dir" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "root" ], filename = "dir", extension = "" }
      }
    ,
      { left = ".."
      , right = "c/d.e"
      , append = { root = "", directory = [ "c", "d.e" ], filename = "..", extension = "" }
      , appendToPosix = "c/d.e/.."
      , prepend = { root = "", directory = [ "..", "c" ], filename = "d", extension = "e" }
      , prependToPosix = "../c/d.e"
      , appendPosixString = { root = "", directory = [ "c", "d.e" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "c" ], filename = "d", extension = "e" }
      , appendWin32String = { root = "", directory = [ "c", "d.e" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "c" ], filename = "d", extension = "e" }
      }
    ,
      { left = ".."
      , right = "C:\\x\\y.z"
      , append = { root = "", directory = [ "C:\\x\\y.z" ], filename = "..", extension = "" }
      , appendToPosix = "C:\\x\\y.z/.."
      , prepend = { root = "", directory = [ ".." ], filename = "C:\\x\\y", extension = "z" }
      , prependToPosix = "../C:\\x\\y.z"
      , appendPosixString = { root = "", directory = [ "C:\\x\\y.z" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ ".." ], filename = "C:\\x\\y", extension = "z" }
      , appendWin32String = { root = "C:\\", directory = [ "x", "y.z" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", "x" ], filename = "y", extension = "z" }
      }
    ,
      { left = ".."
      , right = "../up"
      , append = { root = "", directory = [ "..", "up" ], filename = "..", extension = "" }
      , appendToPosix = "../up/.."
      , prepend = { root = "", directory = [ "..", ".." ], filename = "up", extension = "" }
      , prependToPosix = "../../up"
      , appendPosixString = { root = "", directory = [ "..", "up" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", ".." ], filename = "up", extension = "" }
      , appendWin32String = { root = "", directory = [ "..", "up" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ "..", ".." ], filename = "up", extension = "" }
      }
    ,
      { left = ".."
      , right = "./here"
      , append = { root = "", directory = [ ".", "here" ], filename = "..", extension = "" }
      , appendToPosix = "./here/.."
      , prepend = { root = "", directory = [ "..", "." ], filename = "here", extension = "" }
      , prependToPosix = ".././here"
      , appendPosixString = { root = "", directory = [ ".", "here" ], filename = "..", extension = "" }
      , prependPosixString = { root = "", directory = [ "..", "." ], filename = "here", extension = "" }
      , appendWin32String = { root = "", directory = [ "here" ], filename = "..", extension = "" }
      , prependWin32String = { root = "", directory = [ ".." ], filename = "here", extension = "" }
      }
    ]


joinCases : List JoinCase
joinCases =
    [
      { inputs = []
      , posix = { root = "", directory = [], filename = "", extension = "" }
      , posixToPosix = "."
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToWin32 = "."
      }
    ,
      { inputs = [ "" ]
      , posix = { root = "", directory = [], filename = "", extension = "" }
      , posixToPosix = "."
      , win32 = { root = "", directory = [], filename = "", extension = "" }
      , win32ToWin32 = "."
      }
    ,
      { inputs = [ "/" ]
      , posix = { root = "/", directory = [], filename = "", extension = "" }
      , posixToPosix = "/"
      , win32 = { root = "\\", directory = [], filename = "", extension = "" }
      , win32ToWin32 = "\\"
      }
    ,
      { inputs = [ "a" ]
      , posix = { root = "", directory = [], filename = "a", extension = "" }
      , posixToPosix = "a"
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToWin32 = "a"
      }
    ,
      { inputs = [ "/a", "b", "c.txt" ]
      , posix = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      , posixToPosix = "/a/b/c.txt"
      , win32 = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "txt" }
      , win32ToWin32 = "\\a\\b\\c.txt"
      }
    ,
      { inputs = [ "a", "/b" ]
      , posix = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , posixToPosix = "a/b"
      , win32 = { root = "", directory = [ "a" ], filename = "b", extension = "" }
      , win32ToWin32 = "a\\b"
      }
    ,
      { inputs = [ "/", "x" ]
      , posix = { root = "/", directory = [], filename = "x", extension = "" }
      , posixToPosix = "/x"
      , win32 = { root = "\\", directory = [], filename = "x", extension = "" }
      , win32ToWin32 = "\\x"
      }
    ,
      { inputs = [ "a/b", "c/d", "e.f" ]
      , posix = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      , posixToPosix = "a/b/c/d/e.f"
      , win32 = { root = "", directory = [ "a", "b", "c", "d" ], filename = "e", extension = "f" }
      , win32ToWin32 = "a\\b\\c\\d\\e.f"
      }
    ,
      { inputs = [ "", "a", "" ]
      , posix = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , posixToPosix = "a"
      , win32 = { root = "", directory = [ "a" ], filename = "", extension = "" }
      , win32ToWin32 = "a"
      }
    ,
      { inputs = [ ".", "a" ]
      , posix = { root = "", directory = [], filename = "a", extension = "" }
      , posixToPosix = "a"
      , win32 = { root = "", directory = [], filename = "a", extension = "" }
      , win32ToWin32 = "a"
      }
    ,
      { inputs = [ "..", "..", "x" ]
      , posix = { root = "", directory = [ "..", ".." ], filename = "x", extension = "" }
      , posixToPosix = "../../x"
      , win32 = { root = "", directory = [ "..", ".." ], filename = "x", extension = "" }
      , win32ToWin32 = "..\\..\\x"
      }
    ,
      { inputs = [ "/a/", "b/", "c/" ]
      , posix = { root = "/", directory = [ "a", "b" ], filename = "c", extension = "" }
      , posixToPosix = "/a/b/c"
      , win32 = { root = "\\", directory = [ "a", "b" ], filename = "c", extension = "" }
      , win32ToWin32 = "\\a\\b\\c"
      }
    ,
      { inputs = [ "C:\\x", "y" ]
      , posix = { root = "", directory = [ "C:\\x" ], filename = "y", extension = "" }
      , posixToPosix = "C:\\x/y"
      , win32 = { root = "C:\\", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToWin32 = "C:\\x\\y"
      }
    ,
      { inputs = [ "a.b", "c.d", "e.f" ]
      , posix = { root = "", directory = [ "a.b", "c.d" ], filename = "e", extension = "f" }
      , posixToPosix = "a.b/c.d/e.f"
      , win32 = { root = "", directory = [ "a.b", "c.d" ], filename = "e", extension = "f" }
      , win32ToWin32 = "a.b\\c.d\\e.f"
      }
    ,
      { inputs = [ "/usr", "local", "bin", "eco" ]
      , posix = { root = "/", directory = [ "usr", "local", "bin" ], filename = "eco", extension = "" }
      , posixToPosix = "/usr/local/bin/eco"
      , win32 = { root = "\\", directory = [ "usr", "local", "bin" ], filename = "eco", extension = "" }
      , win32ToWin32 = "\\usr\\local\\bin\\eco"
      }
    ,
      { inputs = [ "./x", "./y" ]
      , posix = { root = "", directory = [ ".", "x", "." ], filename = "y", extension = "" }
      , posixToPosix = "./x/./y"
      , win32 = { root = "", directory = [ "x" ], filename = "y", extension = "" }
      , win32ToWin32 = "x\\y"
      }
    ]
