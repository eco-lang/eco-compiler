module TestLogic.Generate.EcoEnvironmentFlagsTest exposing (suite)

{-| Pins `Compiler.Elm.EcoEnvironment.isEnvironmentFlags`
(plans/eco-system-api-refactor.md D13, §10.1): a `main` whose flags are
eco/system's `System.Environment` gets the environment decoder of `System`
instead of a JSON flags decoder. The check looks through aliases of the flags
type and of the whole `Program` type, and only matches the `System` module of
package `eco/system`.
-}

import Compiler.AST.Canonical as Can
import Compiler.Elm.EcoEnvironment as EcoEnvironment
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict
import Expect
import Test exposing (Test)


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


program : Can.Type String -> Can.Type String
program flags =
    Can.TType ModuleName.platform "Program" [ flags, Can.TUnit, Can.TUnit ]


environment : Can.Type String
environment =
    Can.TAlias (ModuleName.Canonical Pkg.ecoSystem "System") "Environment" [] (Can.Filled environmentRecord)


environmentRecord : Can.Type String
environmentRecord =
    Can.TRecord Dict.empty Nothing


userAlias : String -> Can.Type String -> Can.Type String
userAlias name aliased =
    Can.TAlias (ModuleName.Canonical ( "author", "project" ) "Main") name [] (Can.Filled aliased)
