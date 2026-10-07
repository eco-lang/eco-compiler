module ProcessRunInitErrorTest exposing (main)

{-| A program that cannot be started is an `InitError` carrying the errno name
and the program and arguments as given (plans/eco-system-library.md Phase 5
step 5.4, E.4).
-}

-- CHECK: missing: InitError ENOENT program=eco-no-such-program-p5 args=x,y
-- CHECK: badcwd: InitError ENOENT program=pwd args=
-- CHECK: notexec: InitError EACCES program=/dev/null args=
-- EXIT: 0

import ProcessTestHelp exposing (describeRun, noShell, simpleRun)
import System.Process as P


main =
    simpleRun
        [ ( "missing", describeRun (P.run "eco-no-such-program-p5" [ "x", "y" ] noShell) )
        , ( "badcwd"
          , describeRun
                (P.run "pwd" [] { noShell | workingDirectory = P.SetWorkingDirectory "/eco-no-such-dir-p5" })
          )
        , ( "notexec", describeRun (P.run "/dev/null" [] noShell) )
        ]
