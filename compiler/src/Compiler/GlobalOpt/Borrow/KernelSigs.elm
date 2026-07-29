module Compiler.GlobalOpt.Borrow.KernelSigs exposing
    ( ParamMode(..), KernelSig, lookup )

{-| Audited kernel borrow signatures (design §12; seeded from the Phase-0 U0.3
audit in `design_docs/borrow-inf-census.md` §3a). Keyed by plain `(home, name)` exactly
like `KernelTypeEnv` — the `MonoVarKernel` prefix field and `_Int/_Float/_Char`
MLIR suffixes never appear in Mono names, so no normalization is needed.

`lookup` returns `Nothing` for un-audited keys; the caller defaults those to
all-owned (already sound) and counts them (`kernelDefaultedHeapCalls`).

-}

import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- default; may store, return, or hand to unknown code


type alias KernelSig =
    { params : List ParamMode
    , resultAliases : Maybe Int -- Just i: result may alias param i
    }


lookup : ( Name, Name ) -> Maybe KernelSig
lookup key =
    Dict.get key table


table : Dict ( Name, Name ) KernelSig
table =
    Dict.fromList
        [ ( ( "Utils", "compare" ), bb2 )
        , ( ( "Utils", "equal" ), bb2 )
        , ( ( "Utils", "notEqual" ), bb2 )
        , ( ( "Utils", "lt" ), bb2 )
        , ( ( "Utils", "le" ), bb2 )
        , ( ( "Utils", "gt" ), bb2 )
        , ( ( "Utils", "ge" ), bb2 )
        , ( ( "String", "length" ), bb1 )
        , ( ( "String", "startsWith" ), bb2 )
        , ( ( "String", "endsWith" ), bb2 )
        , ( ( "String", "contains" ), bb2 )
        , ( ( "JsArray", "length" ), bb1 )
        , ( ( "JsArray", "unsafeGet" )
            -- C signature is `unsafeGet index array`: array is param 1 (D0.1/U0.3)
          , { params = [ PBorrowed, PBorrowed ], resultAliases = Just 1 }
          )
        , ( ( "Debug", "log" )
            -- returns its value arg by identity (D0.3): value is param 1
          , { params = [ PBorrowed, PBorrowed ], resultAliases = Just 1 }
          )
        , ( ( "Debug", "toString" ), bb1 )
        ]


bb1 : KernelSig
bb1 =
    { params = [ PBorrowed ], resultAliases = Nothing }


bb2 : KernelSig
bb2 =
    { params = [ PBorrowed, PBorrowed ], resultAliases = Nothing }
