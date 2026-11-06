module KernelIntrinsicKBasicsXorTest exposing (..)

{-| `Basics.xor True False` evaluates to `True`.

The program logs the value as `testValue`. It imports elm/bytes and several
core modules with `exposing (..)` but uses only `Basics.xor`.

## eco

This is the end-to-end form of the case "K Basics.xor" in compiler/tests/SourceIR/KernelIntrinsicCases.elm. That catalogue calls `Elm.Kernel.Basics.xor` directly; here the call goes through the elm/core `Basics.xor` wrapper. The MLIR back end may emit such a kernel call as an inline intrinsic rather than a call into the kernel, chosen by argument and result types (compiler/src/Compiler/IR/Kernel/Intrinsics.elm).

-}

-- CHECK: testValue: True

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue =
    Basics.xor Basics.True Basics.False


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
