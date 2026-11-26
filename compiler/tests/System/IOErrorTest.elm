module System.IOErrorTest exposing (suite)

{-| `System.IOError.fromFileSystem` classifies eco/system failures as the eco/kernel kernels
classified the same errno (ENOENT 1, EACCES/EPERM 2, ENOTDIR 3, EISDIR 4, EEXIST 5, ENOSPC 6,
EMFILE/ENFILE 7, EBADF 9), always naming the path the compiler gave, so the reports built from
them read as before (plans/compiler-io-on-eco-system.md D8).
-}

import Expect
import FileSystem.Internal
import Path
import System.IOError as IOErr exposing (IOError(..))
import Test exposing (Test)


{-| A failure as eco/system's kernels report one, about a path eco/system parsed (which the
conversion must not use).
-}
fsError : String -> IOError
fsError code =
    IOErr.fromFileSystem "src/Main.elm"
        (FileSystem.Internal.decodeError (Path.fromPosixString "/elsewhere") ( code, code ++ ": described, open '/elsewhere'" ))


suite : Test
suite =
    Test.describe "System.IOError"
        [ Test.test "classifies each errno as the kernels did" <|
            \_ ->
                List.map fsError [ "ENOENT", "EACCES", "EPERM", "ENOTDIR", "EISDIR", "ERR_FS_EISDIR", "EEXIST", "ENOSPC", "EMFILE", "ENFILE", "EBADF" ]
                    |> Expect.equal
                        [ FileNotFound "src/Main.elm"
                        , PermissionDenied "src/Main.elm"
                        , PermissionDenied "src/Main.elm"
                        , NotADirectory "src/Main.elm"
                        , IsADirectory "src/Main.elm"
                        , IsADirectory "src/Main.elm"
                        , AlreadyExists "src/Main.elm"
                        , NoSpaceLeft (Just "src/Main.elm")
                        , TooManyOpenFiles
                        , TooManyOpenFiles
                        , BadFileDescriptor
                        ]
        , Test.test "keeps the message of any other failure" <|
            \_ ->
                IOErr.toString (fsError "EBUSY")
                    |> Expect.equal "EBUSY: described, open '/elsewhere' (src/Main.elm)"
        , Test.test "renders as Eco.IO.Error did" <|
            \_ ->
                List.map IOErr.toString [ FileNotFound "a", NoSpaceLeft Nothing, BrokenPipe (Just "b") ]
                    |> Expect.equal [ "file not found: a", "no space left on device", "broken pipe (b)" ]
        ]
