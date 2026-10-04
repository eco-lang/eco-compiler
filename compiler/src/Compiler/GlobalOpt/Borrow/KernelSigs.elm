module Compiler.GlobalOpt.Borrow.KernelSigs exposing (KernelSig, ParamMode(..), lookup)

{-| The kernel signatures the borrow analysis reads, taken from the kernel table
in `Compiler.GlobalOpt.KernelFacts`.

A kernel is a function implemented in C++ in the runtime, whose body the
compiler cannot see. For the kernels it lists, `KernelFacts` records by hand
facts about what each body does. This module hands the borrow analysis the part
of a row it needs, as a `KernelSig`: the borrow mode of each argument, and which
arguments the result may be or contain.

`lookup` reports a kernel as unknown in two cases: it has no row, or its row's
`params` is empty. An empty `params` means the borrow axis of that row has not
been audited, not that the kernel takes no arguments, so it says no more than a
missing row does. Every argument of an unknown kernel is to be treated as
owned. Treating an argument as borrowed when the kernel in fact keeps it would
let it be freed while the kernel still holds it, so only a row with a non-empty
`params` makes an argument borrowed.

`ParamMode` repeats `KernelFacts.ParamMode` rather than reusing it, because an
Elm module can expose only its own declarations and so cannot pass on another
module's constructors. The conversion between the two names every constructor,
with no catch-all branch, so a constructor added to `KernelFacts.ParamMode` is a
compile error here until this module handles it.

@docs KernelSig, ParamMode, lookup

-}

import Compiler.Data.Name exposing (Name)
import Compiler.GlobalOpt.KernelFacts as KF


{-| How a kernel treats one of its arguments, as `KernelFacts.ParamMode`
describes.

`PBorrowed` means the call does not take ownership of the argument. The result
may still be or contain it; that is recorded in `resultAliases` of `KernelSig`.

`POwned` means the kernel may store the argument, return it, or pass it to code
it does not know.

-}
type ParamMode
    = PBorrowed
    | POwned


{-| The borrow facts of one kernel whose borrow axis is audited: the mode of each
argument, in order, and which arguments the result may be or contain.
-}
type alias KernelSig =
    { params : List ParamMode
    , resultAliases : List Int -- 0-based indexes into params of arguments the result may be or contain
    }


{-| Returns the signature of the kernel with the given Mono key, the
`( home, name )` pair that `KernelFacts.lookup` takes. It gives `Nothing` when
the kernel has no row, or when its row's `params` is empty because the borrow
axis has not been audited; either way every argument is to be treated as owned.
-}
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


{-| Returns this module's `ParamMode` with the same meaning as the given
`KernelFacts.ParamMode`.
-}
toParamMode : KF.ParamMode -> ParamMode
toParamMode pm =
    case pm of
        KF.PBorrowed ->
            PBorrowed

        KF.POwned ->
            POwned
