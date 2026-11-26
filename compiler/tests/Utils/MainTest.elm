module Utils.MainTest exposing (suite)

{-| Regression tests for helpers in `Utils.Main`.

  - `appDataDirFor` keeps the per-OS rules of eco/kernel's `appDataDir`
    (plans/compiler-io-on-eco-system.md §2.4; the scenarios of eco/kernel's old
    `FileAppDataDir*Test` E2E tests): no XDG, macOS's Application Support,
    `APPDATA` then the home directory on Windows, and `FileNotFound ""` with no
    home.
  - `dictFromListWith` once folded with `Dict.update k (Maybe.map ...)`, which
    never inserts an absent key, so it always returned `Dict.empty` and its
    callers (`Builder.Build.checkUniqueRoots`, `Builder.Build.checkRoots`,
    `Builder.Elm.Outline.detectDuplicates`) never detected duplicates.

-}

import Dict
import Expect
import System
import System.IOError as IOErr
import Test exposing (Test)
import Utils.Main as Utils


suite : Test
suite =
    Test.describe "Utils.Main"
        [ Test.test "dictFromListWith keeps every key" <|
            \_ ->
                Utils.dictFromListWith (++) [ ( "a", [ 1 ] ), ( "b", [ 2 ] ) ]
                    |> Dict.toList
                    |> Expect.equal [ ( "a", [ 1 ] ), ( "b", [ 2 ] ) ]
        , Test.test "dictFromListWith combines the values of a repeated key" <|
            \_ ->
                Utils.dictFromListWith (++) [ ( "a", [ 1 ] ), ( "a", [ 2 ] ) ]
                    |> Dict.get "a"
                    |> Maybe.map List.length
                    |> Expect.equal (Just 2)
                , Test.test "appDataDirFor on Linux is ~/.name" <|
            \_ ->
                Utils.appDataDirFor System.Linux Dict.empty "/home/u" "eco"
                    |> Expect.equal (Ok "/home/u/.eco")
        , Test.test "appDataDirFor on macOS is under Application Support" <|
            \_ ->
                Utils.appDataDirFor System.Darwin Dict.empty "/Users/u" "eco"
                    |> Expect.equal (Ok "/Users/u/Library/Application Support/eco")
        , Test.test "appDataDirFor on Windows is under APPDATA, with forward slashes" <|
            \_ ->
                Utils.appDataDirFor System.Win32 (Dict.fromList [ ( "APPDATA", "C:\\Users\\u\\AppData\\Roaming" ) ]) "C:/Users/u" "eco"
                    |> Expect.equal (Ok "C:/Users/u/AppData/Roaming/eco")
        , Test.test "appDataDirFor on Windows without APPDATA is under the home directory" <|
            \_ ->
                Utils.appDataDirFor System.Win32 (Dict.fromList [ ( "APPDATA", "" ) ]) "C:/Users/u" "eco"
                    |> Expect.equal (Ok "C:/Users/u/eco")
        , Test.test "appDataDirFor with no home directory fails as a missing file" <|
            \_ ->
                [ Utils.appDataDirFor System.Linux Dict.empty "" "eco"
                , Utils.appDataDirFor System.Darwin Dict.empty "." "eco"
                , Utils.appDataDirFor System.Win32 Dict.empty "" "eco"
                ]
                    |> Expect.equal (List.repeat 3 (Err (IOErr.FileNotFound "")))
        ]
