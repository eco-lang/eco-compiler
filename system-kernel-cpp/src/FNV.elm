module FNV exposing (hash)

import Eco.Kernel.FNV


hash : a -> Int
hash =
    Eco.Kernel.FNV.hash
