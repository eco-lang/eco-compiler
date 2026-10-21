module ProcessRunInitErrorTest exposing (main)

{-| A program that cannot be started is an `InitError` carrying its `StartError`
and the program and arguments as given (plans/eco-system-library.md Phase 5
step 5.4, E.4).
-}

-- CHECK: missing: InitError ProgramNotFound program=eco-no-such-program-p5 args=x,y
-- CHECK: badcwd: InitError ProgramNotFound program=pwd args=
-- CHECK: notexec: InitError PermissionDenied program=/dev/null args=
-- EXIT: 0

import ChildProcess as P
import ProcessTestHelp exposing (describeRun, noShell, simpleRun)


main =
    simpleRun
        [ ( "missing", describeRun (P.run "eco-no-such-program-p5" [ "x", "y" ] noShell) )
        , ( "badcwd"
          , describeRun
                (P.run "pwd" [] { noShell | workingDirectory = P.SetWorkingDirectory "/eco-no-such-dir-p5" })
          )
        , ( "notexec", describeRun (P.run "/dev/null" [] noShell) )
        ]
