module PlatformArchTest exposing (main)

{-| Platform and CPU architecture (plans/eco-system-library.md Phase 3 step 3.6,
§3.8): the environment and the tasks agree, and on the CI machines the values
are known ones.
-}

-- CHECK: platform known: True
-- CHECK: arch known: True
-- CHECK: env agrees: True
-- EXIT: 0

import Stream.Log
import System exposing (CpuArchitecture(..), Platform(..))
import Task


platformKnown : Platform -> Bool
platformKnown p =
    case p of
        Linux ->
            True

        Darwin ->
            True

        Win32 ->
            True

        _ ->
            False


archKnown : CpuArchitecture -> Bool
archKnown a =
    case a of
        X64 ->
            True

        Arm64 ->
            True

        _ ->
            False


boolString : Bool -> String
boolString b =
    if b then
        "True"

    else
        "False"


main : System.SimpleProgram ()
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (Task.map2 Tuple.pair System.getPlatform System.getCpuArchitecture
                    |> Task.andThen
                        (\( platform, arch ) ->
                            Stream.Log.line env.stdout
                                (String.join "\n"
                                    [ "platform known: " ++ boolString (platformKnown platform)
                                    , "arch known: " ++ boolString (archKnown arch)
                                    , "env agrees: " ++ boolString (platform == env.platform && arch == env.cpuArchitecture)
                                    ]
                                )
                        )
                )
        )
