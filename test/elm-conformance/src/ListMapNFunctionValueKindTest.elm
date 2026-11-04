module ListMapNFunctionValueKindTest exposing (main)

{-| kernelListMapN, the function-value route (plans/kernel-lib-bug-fixes.md, Phase 2 open items):
`List.map2` .. `List.map5` used as a value rather than called saturated, with a point-free kernel
callback whose result type is polymorphic (`Debug.log`).

`List.mapN` is the kernel itself (`map2 = Elm.Kernel.List.map2`). At a saturated call the
compiler picks `Elm_Kernel_List_map2_Int` (or `_Float`/`_Char`) from the result's element type,
and that variant asks for the result unboxed (ListMapNKernelClosureKindTest). A value use reaches
the kernel through the alias body, a reference that is not a call. Before the fix that reference
got the boxed kernel ABI type, so one erased `List.map2` specialization served every element type
and called the untyped form, which stores each callback result in the callback closure's own kind.
`Debug.log`'s closure returns kind 0 (boxed), so the `List Int` got boxed heads, which code
compiled for a `List Int` reads as raw Ints (HEAP_046). `List.map2` to `map5` are now
suffix-selecting kernels (`Compiler.IR.Kernel.Abi.suffixSelectingKernels`), so the alias body
keeps the concrete type and names the typed variant. An ordinary Elm lambda returns unboxed and
was never affected.

The `List Int` and direct-Float cases each reach `List.map2` a different way: from a record
field, from a list, through a pass-through function, and partially applied. 66108864 is below
2^26, so a head read as a pointer shows up as a sum or a bound check that is off (before the fix
the native sums came out near 2.2e12). `==` is kind-tolerant, so `recordEq` holds either way.

Controls, which passed natively before the fix: the `map3`..`map5` cases wrap `Debug.log` in
an Elm lambda, whose closure returns unboxed, and the `List Char` case. Expected output recorded
from Elm on node (run-js-e2e.js --record).

-}

-- CHECK-DAG: recordSum: 66108866
-- CHECK-DAG: recordLt: True
-- CHECK-DAG: recordEq: True
-- CHECK-DAG: listSum: 66108866
-- CHECK-DAG: listLt: True
-- CHECK-DAG: passSum: 66108866
-- CHECK-DAG: passLt: True
-- CHECK-DAG: partialSum: 66108866
-- CHECK-DAG: partialLt: True
-- CHECK-DAG: directFloatSum: 4
-- CHECK-DAG: directFloatLt: True
-- CHECK-DAG: floatSum: 4
-- CHECK-DAG: floatLt: True
-- CHECK-DAG: chars: "xy"
-- CHECK-DAG: map4Sum: 66108866
-- CHECK-DAG: map5Sum: 66108866

import Platform


type alias Zips =
    { zip2 : (String -> Int -> Int) -> List String -> List Int -> List Int
    , zip2c : (String -> Char -> Char) -> List String -> List Char -> List Char
    }


zips : Zips
zips =
    { zip2 = List.map2, zip2c = List.map2 }


{-| Hands its argument back; keeps `List.map2` an argument, not a callee.
-}
passThrough : a -> a
passThrough f =
    f


{-| Applies a partially applied `List.mapN` to its last list.
-}
applyTo : List b -> (List b -> List c) -> List c
applyTo ys f =
    f ys


keys : List String
keys =
    [ "a", "b" ]


ints : List Int
ints =
    [ 66108864, 2 ]


report : ()
report =
    let
        fromRecord : List Int
        fromRecord =
            zips.zip2 Debug.log keys ints

        fromList : List Int
        fromList =
            case [ List.map2 ] of
                zip :: _ ->
                    zip Debug.log keys ints

                [] ->
                    []

        passed : List Int
        passed =
            passThrough List.map2 Debug.log keys ints

        partial : List Int
        partial =
            applyTo ints (List.map2 Debug.log keys)

        directFloats : List Float
        directFloats =
            applyTo [ 1.5, 2.5 ] (List.map2 Debug.log [ "p", "q" ])

        floats : List Float
        floats =
            applyTo [ 1.5, 2.5 ] (List.map3 (\_ -> Debug.log) [ (), () ] [ "f", "g" ])

        chars : List Char
        chars =
            zips.zip2c Debug.log [ "c", "d" ] [ 'x', 'y' ]

        m4 : List Int
        m4 =
            applyTo ints (List.map4 (\_ _ -> Debug.log) [ (), () ] [ (), () ] keys)

        m5 : List Int
        m5 =
            applyTo ints (List.map5 (\_ _ _ -> Debug.log) [ (), () ] [ (), () ] [ (), () ] keys)

        _ =
            Debug.log "recordSum" (List.sum fromRecord)

        _ =
            Debug.log "recordLt" (List.all (\h -> h < 67108864) fromRecord)

        _ =
            Debug.log "recordEq" (fromRecord == [ 66108864, 2 ])

        _ =
            Debug.log "listSum" (List.sum fromList)

        _ =
            Debug.log "listLt" (List.all (\h -> h < 67108864) fromList)

        _ =
            Debug.log "passSum" (List.sum passed)

        _ =
            Debug.log "passLt" (List.all (\h -> h < 67108864) passed)

        _ =
            Debug.log "partialSum" (List.sum partial)

        _ =
            Debug.log "partialLt" (List.all (\h -> h < 67108864) partial)

        _ =
            Debug.log "directFloatSum" (List.sum directFloats)

        _ =
            Debug.log "directFloatLt" (List.all (\h -> h < 3.0) directFloats)

        _ =
            Debug.log "floatSum" (List.sum floats)

        _ =
            Debug.log "floatLt" (List.all (\h -> h < 3.0) floats)

        _ =
            Debug.log "chars" (String.fromList chars)

        _ =
            Debug.log "map4Sum" (List.sum m4)

        _ =
            Debug.log "map5Sum" (List.sum m5)
    in
    ()


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
