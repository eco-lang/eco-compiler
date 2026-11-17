module FNV exposing (hash)

import Elm.Kernel.FNV


hash : a -> Int
hash =
    Elm.Kernel.FNV.hash
