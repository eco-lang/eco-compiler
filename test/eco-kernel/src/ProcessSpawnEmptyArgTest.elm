module ProcessSpawnEmptyArgTest exposing (main)

{-| HEAP-01 (plans/kernel-lib-bug-fixes.md, group 10): `Eco.Process.spawn` with an empty-string
argument.

The literal `""` is the embedded empty-String constant (HEAP_014). `listToStringVector`
(eco-kernel-cpp/src/eco-kernel/KernelHelpers.hpp), which `spawnBody` uses for the arguments,
passes each element to `Allocator::resolve`, which must never see an embedded constant: an
assertion abort (asserts on) or a wild read. Fixed, the child gets one empty argument, so
`exit $#` exits 1 (plain POSIX behaviour).

-}

-- CHECK: empty arg: ExitFailure 1


import Eco.Process as P
import Platform
import Task exposing (Task)


type Msg
    = Done String


exitString : P.ExitCode -> String
exitString code =
    case code of
        P.ExitSuccess ->
            "ExitSuccess"

        P.ExitFailure n ->
            "ExitFailure " ++ String.fromInt n


run : Task Never String
run =
    P.spawn "sh" [ "-c", "exit $#", "sh", "" ]
        |> Task.andThen (\h -> P.wait h |> Task.mapError never)
        |> Task.map exitString
        |> Task.onError (\_ -> Task.succeed "spawn failed")


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.perform Done run )


update : Msg -> () -> ( (), Cmd Msg )
update (Done line) m =
    let
        _ =
            Debug.log ("empty arg: " ++ line) ()
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
