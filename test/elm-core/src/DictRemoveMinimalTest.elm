module DictRemoveMinimalTest exposing (main)

{-| `Dict.remove` deletes the smaller of two keys from a two-entry `Dict Int Int`, leaving a dictionary of size 1.

The dictionary is built with `Dict.singleton 1 10` followed by `Dict.insert 2 20`, and key 1 is removed.
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
