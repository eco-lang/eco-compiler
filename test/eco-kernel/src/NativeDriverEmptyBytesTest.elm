module NativeDriverEmptyBytesTest exposing (main)

{-| HEAP-02 (plans/kernel-lib-bug-fixes.md, group 10): `Eco.NativeDriver.lowerAndLinkBytes` with
an empty `Bytes`.

A 0-byte file read with `Eco.File.readBytes` is the embedded empty-Bytes constant (HEAP_014).
`lowerAndLinkBytesBody` (eco-kernel-cpp/src/eco-kernel/NativeDriver.cpp) passes it straight to
`Allocator::resolve`, which must never see an embedded constant: an assertion abort (asserts on)
or a wild read. Fixed, the Task fails cleanly (empty MLIR, or the weak stub's rc=-1). The JS
backend always fails this Task ("not available in the JS bootstrap").

Run it with the AOT runner (`TEST_FILTER=NativeDriverEmptyBytesTest cmake --build build --target
run-aot-e2e`): the JIT `test` binary does not link EcoKernel_NativeDriver, so there the program
fails to materialize `Eco_Kernel_NativeDriver_lowerAndLinkBytes` before it runs, an XFAIL for the
wrong reason that stays one after the fix.

-}

-- CHECK: width: 0
-- CHECK: empty mlir: failed
-- CHECK-NOT: empty mlir: ok


import Bytes
import Eco.File as File
import Eco.NativeDriver as NativeDriver
import Platform
import Task exposing (Task)


dir : String
dir =
    "/tmp/eco-kernel-NativeDriverEmptyBytesTest"


type Msg
    = Done (List String)


run : Task Never (List String)
run =
    File.createDir True dir
        |> Task.andThen (\_ -> File.writeString (dir ++ "/empty.mlir") "")
        |> Task.andThen (\_ -> File.readBytes (dir ++ "/empty.mlir"))
        |> Task.mapError (\_ -> "setup failed")
        |> Task.andThen
            (\bytes ->
                let
                    -- printed before the kernel call, so a crash in it still shows the input was read
                    _ =
                        Debug.log ("width: " ++ String.fromInt (Bytes.width bytes)) ()
                in
                NativeDriver.lowerAndLinkBytes bytes (dir ++ "/out")
                    |> Task.map (\_ -> [ "empty mlir: ok" ])
                    |> Task.onError (\_ -> Task.succeed [ "empty mlir: failed" ])
            )
        |> Task.onError (\e -> Task.succeed [ e ])


init : () -> ( (), Cmd Msg )
init _ =
    ( (), Task.perform Done run )


update : Msg -> () -> ( (), Cmd Msg )
update (Done lines) m =
    let
        _ =
            List.map (\l -> Debug.log l ()) lines
    in
    ( m, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
