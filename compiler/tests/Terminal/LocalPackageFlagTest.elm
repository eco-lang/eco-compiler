module Terminal.LocalPackageFlagTest exposing (suite)

{-| Checks how `eco make` reads its `--local-package` flags. Without these
tests, a path containing `=` could be cut short, a malformed mapping accepted,
or a repeated flag lost or rejected, with nothing else failing.

There is no fixture: the tests parse literal strings and chomp literal command
lines, declaring the one flag `--local-package`.

What the tests establish, for `Terminal.Make.parseLocalPackage`:

  - `eco/kernel=../eco-kernel-cpp` gives the name `( "eco", "kernel" )` and
    the path `../eco-kernel-cpp`.
  - The mapping is split at the first `=` only, so `eco/system=/tmp/a=b/c=d`
    keeps `/tmp/a=b/c=d` as its path.
  - A mapping with no `=`, a name with no `/`, a name containing `=` (split
    at the first `=`, it has no `/`), and an empty path each give `Nothing`.

For `Terminal.Terminal.Chomp.chompRepeatableFlag`, each command line followed
by `checkForUnknownFlags`:

  - Two occurrences, one written `--flag value` and one `--flag=value`, with a
    positional argument between them, give both mappings in command-line order,
    and the check accepts the repeat.
  - No occurrence gives the empty list; one gives a one-element list.
  - A valid occurrence followed by `--local-package nonsense` fails with
    `FlagWithBadValue` naming `nonsense`.
  - A lone `--local-package` with nothing after it fails with
    `FlagWithNoValue`.

For `chompNormalFlag`, the same flag given twice fails with `FlagRepeated`
naming the flag.

Among what is not tested: the expectation and suggestion carried by an error,
a value written after a following flag, and an empty package author or project.

-}

import Expect
import Terminal.Make as Make
import Terminal.Terminal.Chomp as Chomp
import Terminal.Terminal.Internal exposing (Error(..), Flag(..), FlagError(..), Flags(..))
import Test exposing (Test, describe, test)


{-| The `--local-package` tests: one group for `parseLocalPackage` and one for
chomping the flag.
-}
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
            , test "a repeated ordinary flag is rejected as repeated" <|
                \_ ->
                    chompNormal [ "--local-package=eco/kernel=../k", "--local-package=eco/system=../s" ]
                        |> Expect.equal (Err "repeated: local-package")
            ]
        ]


{-| The flag description given to `checkForUnknownFlags`: the single flag
`--local-package`.
-}
flags : Flags
flags =
    FMore FDone (Flag "local-package" Make.localPackage "Resolve a package from a local path.")


{-| Chomps `strings` with `--local-package` read as a repeatable flag, giving
every mapping in command-line order or the failure rendered by `describeError`.
-}
chompRepeatable : List String -> Result String (List ( ( String, String ), String ))
chompRepeatable strings =
    run strings (Chomp.chompRepeatableFlag "local-package" Make.localPackage Make.parseLocalPackage)


{-| Chomps `strings` with `--local-package` read as an ordinary flag, giving
the first mapping, if any, or the failure rendered by `describeError`.
-}
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


{-| Renders a chomp error as its kind followed by the flag name (and the bad
value, for a bad value), or, for an unknown flag, the unknown string; `BadArgs`
gives only its kind.
-}
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

        BadFlag (FlagRepeated name) ->
            "repeated: " ++ name
