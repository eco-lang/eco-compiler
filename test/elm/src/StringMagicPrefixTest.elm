module StringMagicPrefixTest exposing (main)

{-| String literals whose contents look like internal marker text, such as
`"__mlir_unknown_loc__"`, `"__mlir_loc__:foo:1:2"` and `"loc:unknown"`, are ordinary
strings and are printed exactly as written.

A compiler that uses text of this kind as a marker in its own output must still treat
these literals as plain string data.
-}

-- CHECK: s1: "__mlir_unknown_loc__"
-- CHECK: s2: "__mlir_loc__:foo:1:2"
-- CHECK: s3: "__mlir_loc__:"
-- CHECK: s4: "loc:unknown"

import Html exposing (text)


main =
    let
        _ =
            Debug.log "s1" "__mlir_unknown_loc__"

        _ =
            Debug.log "s2" "__mlir_loc__:foo:1:2"

        _ =
            Debug.log "s3" "__mlir_loc__:"

        _ =
            Debug.log "s4" "loc:unknown"
    in
    text "done"
