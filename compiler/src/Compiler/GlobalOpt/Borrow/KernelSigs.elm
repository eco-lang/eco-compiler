module Compiler.GlobalOpt.Borrow.KernelSigs exposing (KernelSig, ParamMode(..), lookup)

{-| **SHIM (kernel-opt-07 R1).** The audited kernel table now lives in
`Compiler.GlobalOpt.KernelFacts`; this module survives only so
`Borrow/Constrain.elm` and `Borrow/LssFacts.elm` compile untouched.

`ParamMode` is DEFINED here rather than re-exported because Elm has no
re-export: an `exposing` list may only name declarations of the module itself
(`Canonicalize.ExportNotFound`, Reporting/Error/Canonicalize.elm:88), and a
custom type's constructors cannot be aliased into pattern position. The
`toParamMode` case below is exhaustive, so any future constructor added to
`KernelFacts.ParamMode` is a COMPILE ERROR here rather than silent drift.

`params = []` in a `KernelFacts` row means "the borrow axis of this row has not
been audited". Such a row is reported as a MISS so `Constrain`/`LssFacts` take
exactly today's poison path — _including_ the census counters
(`poisonedByKernel`, `kernelDefaultedHeapCalls`, `kernelDefaultedNames`), which
would otherwise silently re-baseline design\_docs/borrow-inf-census.md. A
genuinely arity-0 kernel is borrow-vacuous, so the sentinel is safe there too
(`poisonArgs [] == identity`, and both paths then `ownEverything` the result).

**Whitelist discipline (census §15.2): unknown ⇒ owned.** A blacklist would be
unsound — a forgotten retaining kernel means premature free under a future B4.

-}

import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.KernelFacts as KF


type ParamMode
    = PBorrowed -- reads only; never stores or returns-by-identity
    | POwned -- default; may store, return, or hand to unknown code


type alias KernelSig =
    { params : List ParamMode
    , resultAliases : List Int -- result may alias these params (0-based)
    }


lookup : ( Name, Name ) -> Maybe KernelSig
lookup key =
    case KF.lookup key of
        Nothing ->
            Nothing

        Just facts ->
            case facts.params of
                [] ->
                    Nothing

                ps ->
                    Just
                        { params = List.map toParamMode ps
                        , resultAliases = facts.resultAliases
                        }


toParamMode : KF.ParamMode -> ParamMode
toParamMode pm =
    case pm of
        KF.PBorrowed ->
            PBorrowed

        KF.POwned ->
            POwned
