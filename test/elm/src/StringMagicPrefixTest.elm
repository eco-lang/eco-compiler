module StringMagicPrefixTest exposing (main)

{-| Test that string literals matching internal bytecode magic prefixes
are encoded and decoded correctly as actual strings, not as MLIR locations.

Regression test for: bytecode encoder conflating StringAttr values
containing "__mlir_unknown_loc__" or "__mlir_loc__:" with location attrs.

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
