module CharToCodeFromStringTest exposing (main)

{-| Regression test for an x86-64 SysV ABI bug in the kernel boundary.

When a Char came from `String.uncons` (passed in a register from a kernel
return), the upper bits of the register held leftover garbage. The MLIR
caller did not zero-extend the i16 Char before calling `Elm_Kernel_Char_toCode`
and the C++ kernel returned the garbage in bits 16..47 of an int64_t.

A character literal like `Char.toCode 'A'` did NOT trigger the bug — it
compiles to an immediate `mov $0x41, %edi` which already clears the upper
bits. The bug needs a *dynamically derived* Char.

-}

-- CHECK: code: 116


import Char
import Html exposing (text)


main =
    let
        src =
            "type"

        code =
            case String.uncons src of
                Just ( c, _ ) ->
                    Char.toCode c

                Nothing ->
                    -1

        _ =
            Debug.log "code" code
    in
    text "done"
