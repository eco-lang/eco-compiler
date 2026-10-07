module ProcessRunEnvCwdTest exposing (main)

{-| Environment variables (inherit, merge, replace) and the working directory
of `run` (plans/eco-system-library.md Phase 5 step 5.4).
-}

-- CHECK: merge: ok stdout=merged|home-set| stderr=
-- CHECK: override: ok stdout=overridden| stderr=
-- CHECK: replace: ok stdout=ECO_P5_A=replaced|ECO_P5_B=b| stderr=
-- CHECK: inherit: ok stdout=unset| stderr=
-- CHECK: cwd: ok stdout=/| stderr=
-- CHECK: cwd-shell: ok stdout=/tmp| stderr=
-- EXIT: 0

import Dict
import ProcessTestHelp exposing (describeRun, noShell, simpleRun)
import System.Process as P


main =
    simpleRun
        [ ( "merge"
          , describeRun
                (P.run "sh"
                    [ "-c", "echo \"$ECO_P5_A\"; if [ -n \"$HOME$PATH\" ]; then echo home-set; fi" ]
                    { noShell | environmentVariables = P.MergeWithEnvironmentVariables (Dict.fromList [ ( "ECO_P5_A", "merged" ) ]) }
                )
          )
        , ( "override"
          , describeRun
                (P.run "sh"
                    [ "-c", "echo \"$PATH\"" ]
                    { noShell | environmentVariables = P.MergeWithEnvironmentVariables (Dict.fromList [ ( "PATH", "overridden" ) ]) }
                )
          )
        , ( "replace"
          , describeRun
                (P.run "env"
                    []
                    { noShell
                        | environmentVariables =
                            P.ReplaceEnvironmentVariables (Dict.fromList [ ( "ECO_P5_A", "replaced" ), ( "ECO_P5_B", "b" ) ])
                    }
                )
          )
        , ( "inherit", describeRun (P.run "sh" [ "-c", "echo \"${ECO_P5_A:-unset}\"" ] noShell) )
        , ( "cwd", describeRun (P.run "pwd" [ "-P" ] { noShell | workingDirectory = P.SetWorkingDirectory "/" }) )
        , ( "cwd-shell"
          , describeRun
                (P.run "pwd" [] { noShell | shell = P.DefaultShell, workingDirectory = P.SetWorkingDirectory "/tmp" })
          )
        ]
