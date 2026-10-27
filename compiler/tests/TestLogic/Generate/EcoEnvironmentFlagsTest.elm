module TestLogic.Generate.EcoEnvironmentFlagsTest exposing (suite)

{-| An eco/system program's flags are `System.Environment`, which cannot be
decoded from JSON, so the compiler must recognise such a `main` and give it
eco/system's own environment decoder instead. These tests check that
recognition, `Compiler.Elm.EcoEnvironment.isEnvironmentFlags`, which owns the
rule; a mistake there would either hand an eco/system program a JSON decoder
or take the JSON decoder away from an ordinary program.

The fixture is built directly as canonical types. `program` makes a
`Platform.Program flags () ()`, `environment` is the alias `Environment` of the
`System` module of package `eco/system`, standing for an empty record, and
`userAlias` wraps a type in an alias of a module `Main` of package
`author/project`. The empty record matters only in that it is not itself
recognisable: the alias's name is what the check looks for.

The tests establish that:

  - `Program System.Environment () ()` is recognised.
  - Flags given as a user alias of `System.Environment` are recognised.
  - A user alias of the whole `Program` type is looked through and recognised.
  - Unit flags are not recognised.
  - An alias named `Environment` in a `System` module of another package, with
    the same empty record, is not recognised.
  - `System.Environment` on its own, not as the flags of a `Program`, is not
    recognised.

Among what is not tested: a `Program` with a different number of arguments, a
`Program` from a module other than `Platform`, and an alias with type
arguments.

-}
import Compiler.AST.Canonical as Can
import Compiler.Elm.EcoEnvironment as EcoEnvironment
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict
import Expect
import Test exposing (Test)


{-| The six recognition tests, one per case listed in the module docstring.
-}
suite : Test
suite =
    Test.describe "eco/system Environment flags (eco-system-api-refactor D13)"
        [ Test.test "Program System.Environment model msg" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags (program environment)
                    |> Expect.equal True
        , Test.test "a user alias of System.Environment" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags (program (userAlias "Env" environment))
                    |> Expect.equal True
        , Test.test "a user alias of the whole Program type" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags (userAlias "Main" (program environment))
                    |> Expect.equal True
        , Test.test "unit flags are ordinary flags" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags (program Can.TUnit)
                    |> Expect.equal False
        , Test.test "an Environment alias of another module is ordinary flags" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags
                    (program (Can.TAlias (ModuleName.Canonical ( "author", "project" ) "System") "Environment" [] (Can.Filled environmentRecord)))
                    |> Expect.equal False
        , Test.test "System.Environment that is not a Program's flags" <|
            \_ ->
                EcoEnvironment.isEnvironmentFlags environment
                    |> Expect.equal False
        ]


{-| Returns the type `Platform.Program flags () ()`.
-}
program : Can.Type String -> Can.Type String
program flags =
    Can.TType ModuleName.platform "Program" [ flags, Can.TUnit, Can.TUnit ]


{-| The alias `System.Environment` of package `eco/system`, standing for an
empty record.
-}
environment : Can.Type String
environment =
    Can.TAlias (ModuleName.Canonical Pkg.ecoSystem "System") "Environment" [] (Can.Filled environmentRecord)


{-| An empty closed record, used as the expansion of every `Environment` alias
in these tests.
-}
environmentRecord : Can.Type String
environmentRecord =
    Can.TRecord Dict.empty Nothing


{-| Returns an alias called `name`, in module `Main` of package
`author/project`, standing for `aliased`.
-}
userAlias : String -> Can.Type String -> Can.Type String
userAlias name aliased =
    Can.TAlias (ModuleName.Canonical ( "author", "project" ) "Main") name [] (Can.Filled aliased)
