module DictRemoveMinimalTest exposing (main)

{-| Minimal repro for SIGSEGV in Dict.remove:
    Dict.remove 1 (Dict.insert 2 20 (Dict.singleton 1 10))
-}

-- CHECK: size: 1

import Dict
import Html exposing (text)


main =
    let
        d =
            Dict.insert 2 20 (Dict.singleton 1 10)

        removed =
            Dict.remove 1 d

        _ =
            Debug.log "size" (Dict.size removed)
    in
    text "done"
