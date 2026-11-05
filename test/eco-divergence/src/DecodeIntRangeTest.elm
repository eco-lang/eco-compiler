module DecodeIntRangeTest exposing (main)

{-| JSON-05 (plans/kernel-lib-bug-fixes.md), eco-only part: the range of `Json.Decode.int`.
eco's Int is 64-bit, so `Decode.int` accepts exactly the integers of the i64 range and fails on
any other number (decision D24, a documented divergence: Elm answers `Ok` with a JS double).
Before the fix nlohmann parsed 2^63 and 2^64-1 as `number_unsigned` and `jsonToHeap` cast them
to i64, so they decoded as `Just -9223372036854775808` and `Just -1`. The `1e300` row (from
JSON-06) checks that accepting integral floats stops at the i64 range.

-}

-- DIVERGENCE: Int is 64-bit in eco, so Json.Decode.int keeps 2^63-1 exactly; Elm rounds it to a double
-- CHECK: int max: Ok 9223372036854775807
-- CHECK: int min: Ok -9223372036854775808
-- CHECK: 2^63: Nothing
-- CHECK: 2^64-1: Nothing
-- CHECK: 1e300: Nothing

import Html exposing (text)
import Json.Decode as Decode


main =
    let
        _ =
            Debug.log "int max" (Decode.decodeString Decode.int "9223372036854775807")

        _ =
            Debug.log "int min" (Decode.decodeString Decode.int "-9223372036854775808")

        _ =
            Debug.log "2^63" (Decode.decodeString Decode.int "9223372036854775808" |> Result.toMaybe)

        _ =
            Debug.log "2^64-1" (Decode.decodeString Decode.int "18446744073709551615" |> Result.toMaybe)

        _ =
            Debug.log "1e300" (Decode.decodeString Decode.int "1e300" |> Result.toMaybe)
    in
    text "done"
