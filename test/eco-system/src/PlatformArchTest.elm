module PlatformArchTest exposing (main)

{-| Platform and CPU architecture (plans/eco-system-library.md Phase 3 step 3.6,
§3.8): on the CI machines the environment's values are known ones. (The
`getPlatform` / `getCpuArchitecture` tasks were removed,
plans/eco-system-api-refactor.md D15.)
-}

-- CHECK: platform known: True
-- CHECK: arch known: True
-- EXIT: 0

import Stream
import System exposing (CpuArchitecture(..), Platform(..))


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


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            Stream.logLine
                (String.join "\n"
                    [ "platform known: " ++ boolString (platformKnown env.platform)
                    , "arch known: " ++ boolString (archKnown env.cpuArchitecture)
                    ]
                )
                env.stdout
        )
