module Compiler.GlobalOpt.Borrow.KernelSigs exposing
    ( ParamMode(..), KernelSig, lookup )

{-| Audited kernel borrow signatures (design §12; seeded from the Phase-0 U0.3
audit in `design_docs/borrow-inf-census.md` §3a, extended by the U-T1.2 audit
2026-07-31 — the tier-1 reader-list rows). Keyed by plain `(home, name)`
exactly like `KernelTypeEnv` — the `MonoVarKernel` prefix field and
`_Int/_Float/_Char` MLIR suffixes never appear in Mono names, so no
normalization is needed.

`lookup` returns `Nothing` for un-audited keys; the caller defaults those to
all-owned (already sound) and counts them (`kernelDefaultedHeapCalls`).

**Whitelist discipline (census §15.2): unknown ⇒ owned.** A blacklist would be
unsound — a forgotten retaining kernel means premature free under a future B4.

**`resultAliases` is a LIST of 0-based param indices** (U-T1.2): the result may
share identity with any listed param, wholly or through an interior pointer
(views/slices) — including *closure-mediated* aliasing in HOF kernels, where
the result is built from user-closure outputs that can be the input's elements
(`foldl (\x _ -> x)` returns an element). Sound over-approximation, exactly
like `unsafeGet`'s boxed-branch-only alias.

Audited-REJECTED (POwned, do NOT add — Console.write precedent, the result is
a `Task_Binding` capturing the arg): `File.fileExists`/`dirExists`
(`File.cpp:679/684`), `Env.lookup` (`Env.cpp:52`), `Scheduler.spawn`
(`Scheduler.cpp:467`).

-}

import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- default; may store, return, or hand to unknown code


type alias KernelSig =
    { params : List ParamMode
    , resultAliases : List Int -- result may alias these params (0-based)
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
            -- C signature is `unsafeGet index array`: array is param 1 (D0.1/U0.3);
            -- aliases an element only in the boxed branch (JsArrayExports.cpp:221).
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 1 ] }
          )
        , ( ( "Debug", "log" )
            -- returns its value arg by identity (D0.3): value is param 1
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 1 ] }
          )
        , ( ( "Debug", "toString" ), bb1 )

        -- ── U-T1.2 rows (audited 2026-07-31; evidence anchors per row) ──
        , ( ( "Bytes", "getStringWidth" )
            -- BytesExports.cpp:311; reads, returns scalar width.
          , bb1
          )
        , ( ( "Bytes", "width" )
            -- BytesExports.cpp:301; reads, scalar.
          , bb1
          )
        , ( ( "Bytes", "encode" )
            -- BytesExports.cpp:397; writeEncoder memcpys into a FRESH flat
            -- ByteBuffer (:245-275) — pointer-free result, no alias.
          , bb1
          )
        , ( ( "Bytes", "decode" )
            -- BytesExports.cpp:420 (decoder=0, bytes=1); Decode.string/bytes
            -- yield zero-copy views over bytes (:583/:633) and Decode.succeed
            -- can embed decoder payloads — result may alias both.
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 0, 1 ] }
          )
        , ( ( "Crash", "crash" )
            -- CrashExports.cpp:9 → Crash.cpp:20; reads, prints, exit(1) — diverges.
          , bb1
          )
        , ( ( "JsArray", "foldl" )
            -- JsArrayExports.cpp:651 → foldImpl:576 (fn=0, acc=1, array=2);
            -- fn called (never stored), array read-only; empty array returns
            -- acc by identity (:638) and closure outputs can be elements.
          , { params = [ PBorrowed, PBorrowed, PBorrowed ], resultAliases = [ 1, 2 ] }
          )
        , ( ( "JsArray", "foldr" )
            -- JsArrayExports.cpp:655 → foldImpl:576; same as foldl.
          , { params = [ PBorrowed, PBorrowed, PBorrowed ], resultAliases = [ 1, 2 ] }
          )
        , ( ( "JsArray", "map" )
            -- JsArrayExports.cpp:463 (fn=0, array=1); fresh array of fn
            -- outputs — which can be the input's elements (identity fn).
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 1 ] }
          )
        , ( ( "List", "map2" )
            -- ListExports.cpp:557 → kernelListMapN:402 (fn=0, xs=1, ys=2);
            -- fresh spine of fn outputs — outputs can alias either list's
            -- elements.
          , { params = [ PBorrowed, PBorrowed, PBorrowed ], resultAliases = [ 1, 2 ] }
          )
        , ( ( "List", "sortBy" )
            -- ListExports.cpp:604 (fn=0, list=1); index-sort (:648), fresh
            -- spine holding the SAME element pointers (:671-674); keys local.
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 1 ] }
          )
        , ( ( "List", "sortWith" )
            -- ListExports.cpp:678; same shape (:705,:730).
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [ 1 ] }
          )
        , ( ( "String", "slice" )
            -- StringExports.cpp:56 → StringOps.cpp:307 (start=0, end=1, str=2);
            -- emits Tag_StringSlice/Utf8View interior views (:337/:415) or
            -- whole-string identity (:321); tiny ranges copy.
          , { params = [ PBorrowed, PBorrowed, PBorrowed ], resultAliases = [ 2 ] }
          )
        , ( ( "String", "uncons" )
            -- StringExports.cpp:46 → StringOps.cpp:1055; tail is a
            -- slice/view of the input (:1075/:1084).
          , { params = [ PBorrowed ], resultAliases = [ 0 ] }
          )
        , ( ( "String", "words" )
            -- StringExports.cpp:71 → String.cpp:293; UTF-8 fast path emits
            -- interior slices (:337); UTF-16 path copies.
          , { params = [ PBorrowed ], resultAliases = [ 0 ] }
          )
        , ( ( "String", "trim" )
            -- StringExports.cpp:91 → StringOps.hpp:878; slice (:899) or
            -- identity wrap (:897).
          , { params = [ PBorrowed ], resultAliases = [ 0 ] }
          )
        , ( ( "String", "toLower" )
            -- StringExports.cpp:86 → StringOps.hpp:801; fresh leaf always
            -- (empty → global constant, aliases a global not the param).
          , bb1
          )
        , ( ( "String", "toUpper" )
            -- StringExports.cpp:81 → StringOps.hpp:762; fresh leaf.
          , bb1
          )
        , ( ( "String", "all" )
            -- StringExports.cpp:305 (fn=0, str=1); snapshotChars copies before
            -- iterating; result is an embedded boxed-bool constant; fn args
            -- are unboxed Chars (no heap alias through the closure).
          , { params = [ PBorrowed, PBorrowed ], resultAliases = [] }
          )
        ]


bb1 : KernelSig
bb1 =
    { params = [ PBorrowed ], resultAliases = [] }


bb2 : KernelSig
bb2 =
    { params = [ PBorrowed, PBorrowed ], resultAliases = [] }
