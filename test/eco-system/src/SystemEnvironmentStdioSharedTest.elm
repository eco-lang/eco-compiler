module SystemEnvironmentStdioSharedTest exposing (main)

{-| The standard streams `System.environment` gives are the flags' streams: writes through
either, each awaited, come out in the order they were made (plans/compiler-io-on-eco-system.md
P1.1).
-}

-- CHECK: one
-- CHECK-NEXT: two
-- CHECK-NEXT: three
-- CHECK-NEXT: four
-- EXIT: 0

import Stream
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\flags ->
            System.environment
                |> Task.andThen
                    (\env ->
                        Stream.writeLine "one" flags.stdout
                            |> Task.andThen (\_ -> Stream.writeLine "two" env.stdout)
                            |> Task.andThen (\_ -> Stream.writeLine "three" flags.stdout)
                            |> Task.andThen (\_ -> Stream.writeLine "four" env.stdout)
                    )
        )
