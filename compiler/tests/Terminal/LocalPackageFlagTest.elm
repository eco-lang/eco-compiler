module Terminal.LocalPackageFlagTest exposing (suite)

{-| Checks how `eco make` reads its `--local-package` flags.

`Terminal.Make.parseLocalPackage` turns one mapping, `author/project=path`,
into a package name and a path. It splits on the **first** `=` only, so a path
may itself contain `=`, and it rejects a mapping with no `=`, no `/` in the
package name, or an empty path.

`Terminal.Terminal.Chomp.chompRepeatableFlag` collects every occurrence of a
flag, in command-line order, written either `--flag value` or `--flag=value`.
Because it takes every occurrence out, `checkForUnknownFlags` accepts the
repeats; a repeat of an ordinary `chompNormalFlag` flag is still rejected as
unknown. A bad value fails with `FlagWithBadValue`.

There is no fixture: the tests chomp literal command lines.

-}

import Expect
import Terminal.Make as Make
import Terminal.Terminal.Chomp as Chomp
import Terminal.Terminal.Internal exposing (Error(..), Flag(..), FlagError(..), Flags(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "--local-package"
        [ describe "parseLocalPackage"
            [ test "parses a simple mapping" <|
                \_ ->
                    Make.parseLocalPackage "eco/kernel=../eco-kernel-cpp"
                        |> Expect.equal (Just ( ( "eco", "kernel" ), "../eco-kernel-cpp" ))
            , test "splits on the first = only, so the path may contain =" <|
                \_ ->
                    Make.parseLocalPackage "eco/system=/tmp/a=b/c=d"
                        |> Expect.equal (Just ( ( "eco", "system" ), "/tmp/a=b/c=d" ))
            , test "rejects a mapping with no =" <|
                \_ ->
                    Make.parseLocalPackage "eco/kernel"
                        |> Expect.equal Nothing
            , test "rejects a package name with no /" <|
                \_ ->
                    Make.parseLocalPackage "ecokernel=../k"
                        |> Expect.equal Nothing
            , test "rejects an = inside the package name" <|
                \_ ->
                    Make.parseLocalPackage "eco=x/kernel=../k"
                        |> Expect.equal Nothing
            , test "rejects an empty path" <|
                \_ ->
                    Make.parseLocalPackage "eco/kernel="
                        |> Expect.equal Nothing
            ]
        , describe "chompRepeatableFlag"
            [ test "collects repeated flags in order" <|
                \_ ->
                    chompRepeatable
                        [ "--local-package"
                        , "eco/kernel=/opt/k"
                        , "Main.elm"
                        , "--local-package=eco/system=/opt/s=1"
                        ]
                        |> Expect.equal
                            (Ok
                                [ ( ( "eco", "kernel" ), "/opt/k" )
                                , ( ( "eco", "system" ), "/opt/s=1" )
                                ]
                            )
            , test "gives the empty list when the flag is absent" <|
                \_ ->
                    chompRepeatable [ "Main.elm" ]
                        |> Expect.equal (Ok [])
            , test "a single flag gives a one-element list" <|
                \_ ->
                    chompRepeatable [ "--local-package=eco/kernel=../k" ]
                        |> Expect.equal (Ok [ ( ( "eco", "kernel" ), "../k" ) ])
            , test "a bad value fails with FlagWithBadValue" <|
                \_ ->
                    chompRepeatable [ "--local-package=eco/kernel=../k", "--local-package", "nonsense" ]
                        |> Expect.equal (Err "bad value: local-package nonsense")
            , test "a flag with no value fails with FlagWithNoValue" <|
                \_ ->
                    chompRepeatable [ "--local-package" ]
                        |> Expect.equal (Err "no value: local-package")
            , test "a repeated ordinary flag is still rejected as unknown" <|
                \_ ->
                    chompNormal [ "--local-package=eco/kernel=../k", "--local-package=eco/system=../s" ]
                        |> Expect.equal (Err "unknown: --local-package=eco/system=../s")
            ]
        ]


flags : Flags
flags =
    FMore FDone (Flag "local-package" Make.localPackage "Resolve a package from a local path.")


chompRepeatable : List String -> Result String (List ( ( String, String ), String ))
chompRepeatable strings =
    run strings (Chomp.chompRepeatableFlag "local-package" Make.localPackage Make.parseLocalPackage)


chompNormal : List String -> Result String (Maybe ( ( String, String ), String ))
chompNormal strings =
    run strings (Chomp.chompNormalFlag "local-package" Make.localPackage Make.parseLocalPackage)


{-| Chomps `strings` with `flagChomper` followed by `checkForUnknownFlags`,
accepting any positional arguments, and renders a failure as a string (the
error values hold tasks, which cannot be compared).
-}
run : List String -> Chomp.Chomper FlagError a -> Result String a
run strings flagChomper =
    Chomp.chomp Nothing
        strings
        [ \suggest _ -> ( suggest, Ok () ) ]
        (flagChomper
            |> Chomp.andThen
                (\value ->
                    Chomp.checkForUnknownFlags flags
                        |> Chomp.map (\_ -> value)
                )
        )
        |> Tuple.second
        |> Result.map Tuple.second
        |> Result.mapError describeError


describeError : Error -> String
describeError error =
    case error of
        BadArgs _ ->
            "bad args"

        BadFlag (FlagWithValue name _) ->
            "with value: " ++ name

        BadFlag (FlagWithBadValue name value _) ->
            "bad value: " ++ name ++ " " ++ value

        BadFlag (FlagWithNoValue name _) ->
            "no value: " ++ name

        BadFlag (FlagUnknown string _) ->
            "unknown: " ++ string
