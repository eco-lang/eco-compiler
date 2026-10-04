module Compiler.GlobalOpt.KernelFacts exposing
    ( KernelFacts, CallTimeEffect(..), GcAlloc(..), Totality(..), ParamMode(..)
    , DevirtPolicy(..), ShapeGuard(..), devirtOf
    , HofAxis(..), mayCallBackIntoElm
    , lookup, lookupSymbol, splitSymbol, rows
    , canTriggerGC, gcLeafEligible, droppable, hoistable
    , gcLeafEligibleFor, droppableFor, hoistableFor
    , CostClass(..), costClass
    , validationErrors
    )

{-| A kernel is a function implemented in C++ in the runtime rather than in Elm,
and the compiler cannot see its body. Several optimisations want to delete,
merge, price or call a kernel directly, and each needs to know something about
what that body does. This module is the one table of those facts, each read by
hand from the C++ source, so that every optimisation gets the same answer.

**The key.** A row is keyed by a _Mono key_: the `( home, name )` pair of a
kernel reference after monomorphization, such as `( "Utils", "equal" )`. It
carries neither the `Elm`/`Eco` prefix of the kernel module, so `Elm.Kernel.X.f`
and `Eco.Kernel.X.f` share a row, nor the `_Int`, `_Float` or `_Char` suffix
that names a typed variant of the emitted C symbol. `lookup` takes a Mono key.
`splitSymbol` turns an emitted symbol into one, and `lookupSymbol` looks a
symbol's row up through it.

**Whitelist discipline.** A kernel with no row licenses nothing: whoever asks
must behave as it would if this table did not exist. `lookup` answers `Nothing`
for such a kernel, the key forms of the derived facts answer `False`, and
`devirtOf` answers `DevirtNo`. A `Nothing` is never a default to be filled
with a guess.

**A row.** Most stored fields of `KernelFacts` answer one question about the
C++ body, and each axis has a value that means "do not know":
`EffObservableIO`, `GcUnbounded`, `cppAlloc = True`, `HofUnknown`,
`MayDiverge`, `cseSafe = False`, and `params = []` for the borrow axis.

Rows are built from one of two private bases. An _audited_ row starts from a
body that has been read for effects and found pure. An _unaudited_ row starts
from every axis at "do not know"; no such row in the table changes `cseSafe` or
`gcAlloc`, so none licenses deleting, merging or gc-leaf marking a call. It is
there to carry what is known, such as the borrow axis, a higher-order flag, an
effect, a divergence note or a devirtualization registration.

**Derived facts.** What the consumers ask is computed from the stored fields,
never stored: `canTriggerGC`, `gcLeafEligible`, `droppable`, `hoistable`,
`mayCallBackIntoElm` and `costClass`. Three of them, `gcLeafEligible`,
`droppable` and `hoistable`, also come in a form that takes a key instead of a
row (the name ending in `For`), which folds in the whitelist default.

**Checking.** The rules a row must obey, such as "`cseSafe` needs no effect,
no call-back and a totality other than `MayDiverge`", are checked by
`validationErrors`, which is empty exactly when every row passes and no key is
repeated. Nothing in this module evaluates it, so the table is only as
consistent as whatever asserts that list is empty.

Some kernels are deliberately not listed. `File.fileExists`, `File.dirExists`,
`Env.lookup` and `Scheduler.spawn` each return a task that holds on to its
argument. They have no row, rather than a row that marks the argument owned.

@docs KernelFacts, CallTimeEffect, GcAlloc, Totality, ParamMode
@docs DevirtPolicy, ShapeGuard, devirtOf
@docs HofAxis, mayCallBackIntoElm
@docs lookup, lookupSymbol, splitSymbol, rows
@docs canTriggerGC, gcLeafEligible, droppable, hoistable
@docs gcLeafEligibleFor, droppableFor, hoistableFor
@docs CostClass, costClass
@docs validationErrors

-}

import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


{-| What a call to the kernel does that can be observed, at the moment it is
called.

`EffNone` means nothing observable happens. The kernels in the table that build
a task are `EffNone`: the work the task describes happens when the scheduler
runs it, not when the kernel returns it.

`EffObservableIO` covers input and output of any kind. It is also the "do not
know" value, so the unaudited base has it.

`EffRuntimeState` is a change to state held inside the runtime itself.

`EffNoreturn` means the call ends the process instead of returning.
`validationErrors` rejects it on a row whose totality is `Total`.

-}
type CallTimeEffect
    = EffNone
    | EffObservableIO
    | EffRuntimeState
    | EffNoreturn


{-| How much a call allocates on the Eco heap, the heap the garbage collector
manages. Memory the C++ code takes for itself is recorded separately, by the
`cppAlloc` field of `KernelFacts`.

`GcNone` means no allocation on any path through the call.

`GcFixed n` means at most `n` objects per call, each of a size known in
advance. `validationErrors` requires `n` to be positive; zero is written
`GcNone`.

`GcUnbounded` means the number or size of the objects depends on the
arguments. It is also the "do not know" value.

-}
type GcAlloc
    = GcNone
    | GcFixed Int
    | GcUnbounded


{-| Whether a call always returns normally.

`Total` calls always return. A `Throws` call can fail instead of returning,
and `validationErrors` requires its row to carry a divergence note.
`MayDiverge` is for a call that may never return, and is also the "do not know"
value.

-}
type Totality
    = Total
    | Throws
    | MayDiverge


{-| Whether the kernel applies an Elm function value passed to it, and so runs
Elm code before it returns. This is the _HOF axis_, for higher-order function.
It is answered from the C++ body, not from the kernel's Elm type: a kernel that
takes a function and stores it without applying it, as `Scheduler.andThen`
does, is `HofNo`.

`HofNo` and `HofYes` are audited answers. `HofUnknown` means nobody has looked.

The two kinds of question read `HofUnknown` differently. A question about
safety reads it as "may call back", through `mayCallBackIntoElm`: it makes
`canTriggerGC` true, and `validationErrors` rejects a row that has it and is
`cseSafe`. A question about cost reads it as not knowing: `costClass` answers
`CUnknown`, not `CHof`, so a row that has not been audited on this axis asserts
no price. Only `HofYes` gives `CHof`, which is why every higher-order row states
it.

-}
type HofAxis
    = HofUnknown
    | HofNo
    | HofYes


{-| Returns whether the kernel may run Elm code during the call: true unless its
HOF axis is audited as `HofNo`.
-}
mayCallBackIntoElm : KernelFacts -> Bool
mayCallBackIntoElm f =
    f.callsBack /= HofNo


{-| How a kernel treats one of its arguments, for the borrow analysis.

`PBorrowed` means the call does not take ownership of the argument. Whether
the result may be or contain the argument is recorded separately, in
`resultAliases`.

`POwned` means it may store the argument, return it, or pass it to code it does
not know.

-}
type ParamMode
    = PBorrowed
    | POwned


{-| Whether a call site may call the kernel directly instead of through a
function value, which is what _devirtualization_ means here.

`DevirtNo` means the kernel is not registered, and a call keeps its indirect
form. This is the answer for every row that does not say otherwise, and
`devirtOf` gives it for an unlisted kernel.

`DevirtAt arity guard` registers the kernel. `arity` is the number of arguments
a call in Elm passes, which a site's argument count is compared against. It is
not the number of parameters of the C++ export, which can differ: an export may
take an operand the compiler adds, as `Debug.toString` takes a type id, or a
kernel with no parameters may be applied to `()`. `guard` restricts the types a
site may have, as `ShapeGuard` describes. `validationErrors` requires `arity` to
be non-negative and equal to the length of `params` when `params` is not
empty, the row to carry evidence, and every guard position to be `-1` or an
argument index from 0 to `arity - 1`.

Registering a kernel matters beyond removing the indirection. A direct call
names the kernel, so anything that reads this row's `cseSafe` and `totality` to
merge or delete calls can now act at that site. Those fields should therefore
be audited before a kernel is registered. A row left on the unaudited base is
safe to register, since its `cseSafe` is `False`, but it gains only the direct
call.

-}
type DevirtPolicy
    = DevirtNo
    | DevirtAt Int ShapeGuard


{-| A condition on the types at a call site, which must hold before the site
calls a registered kernel directly. The emitted symbol and the declared
argument and result types of a direct kernel call follow from the types at the
site, and an `Int`, `Float` or `Char` there is passed as an unboxed scalar, a
raw machine value rather than a pointer. An unresolved `number` type variable
counts as one too, since it can be fixed to `Int` before code is emitted.

`ShapeAny` accepts every site. It suits a kernel with typed variants for the
unboxed cases, such as `Basics.add`, or one whose only export takes and returns
unboxed scalars, such as `Basics.round`.

`ShapeNoUnboxedScalarAt positions` declines a site where any listed position
is an unboxed scalar. A position is a 0-based argument index, or `-1` for the
result. It is for positions where the kernel has only a boxed export: a site
that derived a scalar there would declare the kernel with a signature that
conflicts with its real one. For `List.cons`, an `Int` tail would read the
tail list's pointer as an integer. A declined site keeps its indirect call.

-}
type ShapeGuard
    = ShapeAny
    | ShapeNoUnboxedScalarAt (List Int)


{-| One row of the table: what the C++ body of one kernel was found to do.

`params` holds the borrow mode of each argument, and an empty list means the
borrow axis has not been audited, not that the kernel takes no arguments.
`cppAlloc` records memory the C++ code takes for itself, which does not stop a
call being a gc-leaf but does keep it out of `CGcLeaf` in `costClass`.

-}
type alias KernelFacts =
    { params : List ParamMode
    , resultAliases : List Int -- indexes into params of arguments the result may be or contain
    , callTimeEffect : CallTimeEffect
    , gcAlloc : GcAlloc
    , cppAlloc : Bool
    , callsBack : HofAxis
    , cseSafe : Bool -- no effect, no call-back, and the result depends only on the arguments
    , totality : Totality
    , divergence : Maybe String -- how the C++ departs from the Elm meaning or the inline version
    , devirt : DevirtPolicy
    , evidence : String -- where in the C++ source the row was read from; needs a .cpp: or .hpp: anchor
    }


{-| The base of every unaudited row: each axis at its "do not know" value,
`params` empty, no evidence, and no devirtualization registration. A row built
from it answers `False` for `gcLeafEligible`, `droppable` and `hoistable`, and
`True` for `canTriggerGC`, unless it overrides the fields those read. With
`evidence` still empty it fails `validationErrors`.
-}
unaudited : KernelFacts
unaudited =
    { params = []
    , resultAliases = []
    , callTimeEffect = EffObservableIO
    , gcAlloc = GcUnbounded
    , cppAlloc = True
    , callsBack = HofUnknown
    , cseSafe = False
    , totality = MayDiverge
    , divergence = Nothing
    , devirt = DevirtNo
    , evidence = ""
    }


{-| The base of every audited row, for a kernel whose C++ body was read and found
to have no call-time effect, no call back into Elm, and no path that fails to
return. It is `cseSafe`. It has `cppAlloc = False` and still `GcUnbounded`; a
row sets either allocation field as its kernel's body requires.
-}
auditedPure : KernelFacts
auditedPure =
    { unaudited
        | callTimeEffect = EffNone
        , cppAlloc = False
        , callsBack = HofNo
        , cseSafe = True
        , totality = Total
    }



-- DERIVED FACTS


{-| Returns whether a garbage collection can happen during a call: true if the
kernel may allocate on the Eco heap, or may run Elm code, which can allocate.
`cppAlloc` does not count.
-}
canTriggerGC : KernelFacts -> Bool
canTriggerGC f =
    f.gcAlloc /= GcNone || mayCallBackIntoElm f


{-| Returns whether a call is a _gc-leaf_: one during which no garbage
collection can happen, because it neither allocates on the Eco heap nor runs
Elm code.
-}
gcLeafEligible : KernelFacts -> Bool
gcLeafEligible f =
    not (canTriggerGC f)


{-| Returns whether the row licenses deleting a call whose result is unused:
it is `cseSafe` and `Total`.
-}
droppable : KernelFacts -> Bool
droppable f =
    f.cseSafe && f.totality == Total


{-| Returns whether the row licenses merging two calls with the same arguments
into one. This is `cseSafe` alone, so it can hold for a `Throws` row, where
`droppable` cannot. It says nothing about allocation: a merged call that
allocates leaves one value where there would have been two.
-}
hoistable : KernelFacts -> Bool
hoistable f =
    f.cseSafe


{-| A rough price for a kernel call, for an inliner's cost model, derived from
the row by `costClass`. It says only what the audit knows, whether the call
allocates and whether it runs Elm code.

`CGcLeaf` is a call that allocates nothing, on the Eco heap or in C++, and
never runs Elm code.

`CAlloc` is a call that may allocate, on either heap, and never runs Elm code.

`CHof` is a call audited as applying an Elm function value.

`CUnknown` is a call whose HOF axis has not been audited, which says nothing
about its price.

-}
type CostClass
    = CGcLeaf
    | CAlloc
    | CHof
    | CUnknown


{-| Returns the cost class of a call. The HOF axis decides first: `HofUnknown`
gives `CUnknown` and `HofYes` gives `CHof`. Only for `HofNo` does allocation
matter, giving `CAlloc` when `gcAlloc` is not `GcNone` or `cppAlloc` is set,
and `CGcLeaf` otherwise.

So `CGcLeaf` is narrower than `gcLeafEligible`: a gc-leaf call that uses C++
memory, such as `Utils.equal`, is `CAlloc`.

-}
costClass : KernelFacts -> CostClass
costClass f =
    case f.callsBack of
        HofUnknown ->
            CUnknown

        HofYes ->
            CHof

        HofNo ->
            if f.gcAlloc /= GcNone || f.cppAlloc then
                CAlloc

            else
                CGcLeaf



-- KEY FORMS
--
-- The same facts asked of a Mono key, with the whitelist default folded in: an
-- unlisted key answers False, so no caller has to choose the default itself.


{-| Returns `gcLeafEligible` of the key's row, or `False` for an unlisted key.
-}
gcLeafEligibleFor : ( Name, Name ) -> Bool
gcLeafEligibleFor key =
    lookup key |> Maybe.map gcLeafEligible |> Maybe.withDefault False


{-| Returns `droppable` of the key's row, or `False` for an unlisted key.
-}
droppableFor : ( Name, Name ) -> Bool
droppableFor key =
    lookup key |> Maybe.map droppable |> Maybe.withDefault False


{-| Returns `hoistable` of the key's row, or `False` for an unlisted key.
-}
hoistableFor : ( Name, Name ) -> Bool
hoistableFor key =
    lookup key |> Maybe.map hoistable |> Maybe.withDefault False



-- LOOKUP


{-| Looks up the row for a Mono key, `( home, name )` with no `Elm`/`Eco`
prefix and no ABI suffix. `Nothing` means the kernel is unlisted and licenses
nothing.
-}
lookup : ( Name, Name ) -> Maybe KernelFacts
lookup key =
    Dict.get key table


{-| Looks up the row for an emitted C symbol, such as
`Elm_Kernel_Utils_compare_Float`, by turning it into a Mono key with
`splitSymbol`. Anything that is not a kernel symbol, or names an unlisted
kernel, gives `Nothing`.

A typed variant shares its base kernel's row.

-}
lookupSymbol : String -> Maybe KernelFacts
lookupSymbol sym =
    splitSymbol sym |> Maybe.andThen lookup


{-| Turns an emitted kernel symbol into a Mono key:
`Elm_Kernel_Utils_compare_Float` gives `Just ( "Utils", "compare" )`.

It strips the `Elm_Kernel_` or `Eco_Kernel_` prefix, takes the text up to the
next `_` as the home and the rest as the name, and removes any `_Int`,
`_Float` or `_Char` ending from the name. A symbol without either prefix
(`eco_gc_alloc_region_fast`, `Eco_Runtime_getOrderLT`), or with no `_` after
it, gives `Nothing`. A home containing `_` would be split in the wrong place.

-}
splitSymbol : String -> Maybe ( Name, Name )
splitSymbol sym =
    let
        afterPrefix : Maybe String
        afterPrefix =
            -- Both prefixes are 11 characters long.
            if String.startsWith "Elm_Kernel_" sym || String.startsWith "Eco_Kernel_" sym then
                Just (String.dropLeft 11 sym)

            else
                Nothing

        dropAbiSuffix : String -> String
        dropAbiSuffix s =
            List.foldl
                (\suf acc ->
                    if String.endsWith suf acc then
                        String.dropRight (String.length suf) acc

                    else
                        acc
                )
                s
                [ "_Int", "_Float", "_Char" ]
    in
    afterPrefix
        |> Maybe.andThen
            (\rest ->
                case String.indexes "_" rest of
                    i :: _ ->
                        Just ( String.left i rest, dropAbiSuffix (String.dropLeft (i + 1) rest) )

                    [] ->
                        Nothing
            )


{-| The rows indexed by Mono key, for `lookup`. If two rows had the same key the
later would win here; `validationErrors` reports that.
-}
table : Dict ( Name, Name ) KernelFacts
table =
    Dict.fromList rows



-- THE TABLE


{-| Returns the devirtualization registration for a Mono key. An unlisted kernel
is not registered: it gives `DevirtNo`.
-}
devirtOf : ( Name, Name ) -> DevirtPolicy
devirtOf key =
    lookup key
        |> Maybe.map .devirt
        |> Maybe.withDefault DevirtNo


{-| Every row of the table, in the order written, unaudited rows included.

The rows fall into groups. The audited rows come first, ending with the
kernels that build tasks. The unaudited rows follow: most of the higher-order
kernels, which state `HofYes`; rows that carry the borrow axis, some with a
devirtualization registration or an effect as well; and rows that exist to
record a divergence note.

-}
rows : List ( ( Name, Name ), KernelFacts )
rows =
    -- Audited pure rows that allocate nothing on the Eco heap.
    [ ( ( "Utils", "equal" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True -- dictEq uses std::vector working stacks
            , divergence = Just "depth > 100 returns true (elm-kernel-cpp/src/core/Utils.cpp:560-563): deep unequal values compare equal; cmp has no such cap"

            -- `(==)` takes two arguments. Typed variants serve unboxed
            -- arguments, and every variant returns a boxed value, so only the
            -- result is guarded.
            , devirt = DevirtAt 2 (ShapeNoUnboxedScalarAt [ -1 ])
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:107-109 (equalRespectingConstants :94-105); elm-kernel-cpp/src/core/Utils.cpp:470-472 (eqHelp :521-734, dictEq :747-797); runtime/src/allocator/StringOps.hpp:1486-1533; runtime/src/allocator/HeapHelpers.hpp:822"
        }
      )
    , ( ( "Utils", "notEqual" )
        -- The export is the negation of `equal`'s, so the audited fields of
        -- this row must match the `equal` row's.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , divergence = Just "inherits equal's depth > 100 cap (elm-kernel-cpp/src/core/Utils.cpp:560-563)"
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:111-113 (= !equalRespectingConstants :94-105; NOT Utils::notEqual at elm-kernel-cpp/src/core/Utils.cpp:799-801, which has no callers)"
        }
      )
    , ( ( "Utils", "compare" )
        -- GcNone because each Order result is an embedded constant, so a call
        -- returns one without allocating.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:13-16; elm-kernel-cpp/src/core/Utils.cpp:451-457 (cmp :302-445, NDEBUG-UB note :214-217); Order singletons initOrderSingletons :33-45 (roots :41-43) called only from elm-kernel-cpp/src/core/UtilsExports.cpp:186-188; runtime/src/allocator/StringOps.hpp:1544-1608"
        }
      )
    , ( ( "Utils", "lt" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:115-117; elm-kernel-cpp/src/core/Utils.cpp:803-805 (cmp :302)"
        }
      )
    , ( ( "Utils", "le" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:119-121; elm-kernel-cpp/src/core/Utils.cpp:807-809"
        }
      )
    , ( ( "Utils", "gt" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:123-125; elm-kernel-cpp/src/core/Utils.cpp:811-813"
        }
      )
    , ( ( "Utils", "ge" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True
            , evidence = "elm-kernel-cpp/src/core/UtilsExports.cpp:127-129; elm-kernel-cpp/src/core/Utils.cpp:815-817"
        }
      )
    , ( ( "String", "length" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone

            -- The only export takes a boxed string and returns an unboxed Int,
            -- so only the argument is guarded; guarding the result would
            -- decline every site.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0 ])
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:18-27; runtime/src/allocator/StringOps.hpp:239-243"
        }
      )
    , ( ( "String", "startsWith" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:106-108; runtime/src/allocator/StringOps.hpp:688-714 (memcmp tiers)"
        }
      )
    , ( ( "String", "endsWith" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:110-112; runtime/src/allocator/StringOps.hpp:719-748"
        }
      )
    , ( ( "String", "contains" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:114-116; runtime/src/allocator/StringOps.hpp:645-683 (charAt :410-463 alloc-free)"
        }
      )
    , ( ( "Bytes", "getStringWidth" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = True -- u16string snapshot
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:309-366 (u16string snapshot :330-338)"
        }
      )
    , ( ( "Bytes", "width" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:299-301 (raw scalar via elm_bytebuffer_len)"
        }
      )
    , ( ( "Bytes", "decodeFailure" )
      , { auditedPure
            | gcAlloc = GcNone
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:469-471; runtime/src/allocator/HeapHelpers.hpp:196 (alloc::nothing() = embedded constant)"
        }
      )

    -- Audited pure rows that allocate, except `Basics.not` and `Basics.round`.
    , ( ( "Basics", "not" )
        -- Returns one of the embedded True and False constants, so nothing is
        -- allocated.
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = False

            -- The only export is boxed at both ends, with no typed variants. A
            -- Bool is never an unboxed scalar, so the guard should never decline
            -- a site; it is there in case that changes.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/BasicsExports.cpp:Elm_Kernel_Basics_not; elm-kernel-cpp/src/core/Basics.cpp:165-167 (return !a); ExportHelpers.hpp:80-82 (elmTrue/elmFalse are EMBEDDED HPointer constants, so nothing is allocated)"
        }
      )
    , ( ( "Basics", "add" )
        -- `lookupSymbol` maps the boxed export and its `_Int` and `_Float`
        -- variants all to this row, so its facts are the boxed export's, which
        -- allocates one box for the result.
      , { auditedPure
            | params = [ PBorrowed, PBorrowed ]
            , gcAlloc = GcFixed 1
            , cppAlloc = False

            -- No guard: an unboxed site calls one of the typed variants.
            , devirt = DevirtAt 2 ShapeAny
            , evidence = "elm-kernel-cpp/src/core/BasicsExports.cpp:Elm_Kernel_Basics_add (boxed root: tag test then boxInt(add_Int ..) / boxFloat(add_Float ..) -- ONE box allocated, no C++ heap, no callback); KernelExports.h declares add_Int/add_Float/add"
        }
      )
    , ( ( "Basics", "round" )
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcNone
            , cppAlloc = False

            -- The only export takes and returns unboxed scalars, and the type
            -- has no variables, so a guard would decline every site.
            , devirt = DevirtAt 1 ShapeAny
            , evidence = "elm-kernel-cpp/src/core/BasicsExports.cpp:Elm_Kernel_Basics_round (return Basics::round(x)); KernelExports.h: int64_t Elm_Kernel_Basics_round(double) is the ONLY export -- no Elm heap value is touched"
        }
      )
    , ( ( "String", "fromList" )
        -- Counts the list, allocates one string of that length and fills it,
        -- hence GcUnbounded. cppAlloc is set True because only the all-ASCII
        -- path was read in full.
      , { auditedPure
            | params = [ PBorrowed ]
            , gcAlloc = GcUnbounded
            , cppAlloc = True
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:Elm_Kernel_String_fromList; elm-kernel-cpp/src/core/String.cpp:63-81+ (ListCursor count pass, then one exact-size allocation and an allocation-free write walk); sole export (HPtr) -> HPtr"
        }
      )
    , ( ( "Json", "wrap" )
        -- POwned with resultAliases = [ 0 ]: some branches store the argument
        -- in the new value, and the last returns the argument itself.
      , { auditedPure
            | params = [ POwned ]
            , resultAliases = [ 0 ]
            , gcAlloc = GcFixed 1
            , cppAlloc = False

            -- Typed variants serve unboxed arguments, and every variant returns
            -- a boxed value, so only the result is guarded.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ -1 ])
            , evidence = "elm-kernel-cpp/src/json/JsonExports.cpp:Elm_Kernel_Json_wrap (ENC_BOOL/ENC_STRING/ENC_FLOAT branches each allocate ONE Tag_Custom; string branch stores the arg at values[0].p; final branch returns the arg unchanged). Grep over the whole body: zero eco_apply, zero statics, zero globals"
        }
      )
    , ( ( "List", "cons" )
      , { auditedPure
            | gcAlloc = GcFixed 1

            -- The tail and the result must stay boxed: a site that derived an
            -- Int there would call `Elm_Kernel_List_cons_Int` with the tail
            -- list's pointer read as an integer.
            , devirt = DevirtAt 2 (ShapeNoUnboxedScalarAt [ 1, -1 ])
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:276-283; runtime/src/allocator/HeapHelpers.hpp:630"
        }
      )
    , ( ( "Utils", "append" )
        -- Both arguments owned. Appending strings may keep both operands inside
        -- a rope, and appending lists shares the second list as the result's
        -- tail. Whether a rope is built depends on the lengths at run time,
        -- which one row per kernel cannot express.
      , { auditedPure
            | params = [ POwned, POwned ]
            , resultAliases = [ 0, 1 ]
            , gcAlloc = GcUnbounded
            , cppAlloc = True
            , divergence = Just "unsupported tag pair silently returns the first argument (elm-kernel-cpp/src/core/Utils.cpp:845-846) instead of failing"

            -- The only export is boxed everywhere, with no typed variants, so
            -- both arguments and the result are guarded.
            , devirt = DevirtAt 2 (ShapeNoUnboxedScalarAt [ 0, 1, -1 ])
            , evidence = "elm-kernel-cpp/src/core/Utils.cpp:823-847; runtime/src/allocator/StringOps.hpp:477-537; runtime/src/allocator/ListOps.cpp:262"
        }
      )
    , ( ( "List", "reverse" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:651-654; runtime/src/allocator/ListOps.cpp:530"
        }
      )
    , ( ( "Bytes", "read_u32" )
      , { auditedPure
            | gcAlloc = GcFixed 1 -- Tuple2
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:539-547"
        }
      )
    , ( ( "String", "slice" )
      , { auditedPure
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 2 ]
            , gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:56-59; runtime/src/allocator/StringOps.cpp:307-473 (interior views :337/:415, whole-string identity :321)"
        }
      )
    , ( ( "String", "cons" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:40-44; runtime/src/allocator/StringOps.hpp:1241-1270"
        }
      )
    , ( ( "JsArray", "empty" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:192-195"
        }
      )
    , ( ( "JsArray", "initializeFromList" )
      , { auditedPure
            | gcAlloc = GcUnbounded
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:457-461 (base export; the ABI variant _Int is :982, same Mono key)"
        }
      )

    -- Audited pure rows for kernels that build a task. Building the task does
    -- nothing observable; its work happens when the scheduler runs it.
    , ( ( "Scheduler", "succeed" )
      , { auditedPure
            | gcAlloc = GcFixed 1

            -- Only allocates the task: it touches no scheduler state and
            -- registers nothing. The only export is boxed at both ends, with no
            -- typed variants, so both are guarded.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:16-21; runtime/src/platform/Scheduler.cpp:123-126"
        }
      )
    , ( ( "Scheduler", "fail" )
      , { auditedPure
            | gcAlloc = GcFixed 1

            -- As for `succeed`.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:23-28; runtime/src/platform/Scheduler.cpp:139-142"
        }
      )
    , ( ( "Scheduler", "andThen" )
        -- HofNo: it stores the callback in the task and never applies it.
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:30-37; runtime/src/platform/Scheduler.cpp:149-152"
        }
      )
    , ( ( "Scheduler", "onError" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "elm-kernel-cpp/src/core/SchedulerExports.cpp:39-46; runtime/src/platform/Scheduler.cpp:154-157"
        }
      )
    , ( ( "MVar", "put" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "eco-kernel-cpp/src/eco/MVarExports.cpp:38-46; eco-kernel-cpp/src/eco/MVar.cpp:290"
        }
      )
    , ( ( "MVar", "read" )
      , { auditedPure
            | gcAlloc = GcFixed 1
            , evidence = "eco-kernel-cpp/src/eco/MVarExports.cpp:30-32; eco-kernel-cpp/src/eco/MVar.cpp:264"
        }
      )

    -- Higher-order kernels. Whatever the function value does becomes part of
    -- the call's effect, allocation and totality, so effect and allocation
    -- stay unaudited and totality is never Total.
    -- Each row states HofYes; left as HofUnknown, costClass would answer
    -- CUnknown instead of CHof.
    , ( ( "JsArray", "foldl" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]

            -- Applies the folding function to each element.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:651-653; foldImpl :576 (final accumulator returned by identity when it stayed boxed, :636-640)"
        }
      )
    , ( ( "JsArray", "foldr" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]

            -- Applies the folding function to each element.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:655-657; foldImpl :576"
        }
      )
    , ( ( "JsArray", "map" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]

            -- Applies the mapping function to each element.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:463"
        }
      )
    , ( ( "JsArray", "initialize" )
      , { unaudited
          -- Applies the generating function to each index.
            | callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:422 (base export; the ABI variant _Int is :948, same Mono key)"
        }
      )
    , ( ( "List", "map2" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed, PBorrowed ]
            , resultAliases = [ 1, 2 ]

            -- Applies the mapping function to each pair of elements.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:592-600; kernelListMapN :432"
        }
      )
    , ( ( "List", "sortBy" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , totality = Throws
            , divergence = Just "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and relies on Utils::cmp's early returns"

            -- Applies the key function to each element.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:759 (Elm_Kernel_List_sortBy; comparator :805-825); elm-kernel-cpp/src/core/Utils.cpp:305-306 -- anchors refreshed 2026-08-20 (LSS_021 audit)"
        }
      )
    , ( ( "List", "sortWith" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , totality = Throws
            , divergence = Just "strict-weak-ordering UB on embedded-constant keys (report 03 #8): the comparator resolves constants to nullptr and relies on Utils::cmp's early returns"

            -- Applies the comparison function in each comparison.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/ListExports.cpp:832 (Elm_Kernel_List_sortWith; comparator :862-878); elm-kernel-cpp/src/core/Utils.cpp:305-306 -- anchors refreshed 2026-08-20 (LSS_021 audit)"
        }
      )
    , ( ( "String", "all" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]

            -- Applies the predicate to each character.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:305 (snapshotChars copies; fn args are unboxed Chars)"
        }
      )

    -- Unaudited rows that carry the borrow axis. Their C++ bodies have not been
    -- read for effects, so none of them licenses deleting, merging or gc-leaf
    -- marking a call.
    , ( ( "JsArray", "length" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:204-208"
        }
      )
    , ( ( "JsArray", "unsafeGet" )
        -- The C signature is `unsafeGet index array`, so the array is argument
        -- 1. The result is one of its elements only when elements are boxed.
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , evidence = "elm-kernel-cpp/src/core/JsArrayExports.cpp:210-223"
        }
      )
    , ( ( "Debug", "toString" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/DebugExports.cpp:56"
        }
      )
    , ( ( "Bytes", "encode" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:395 (writeEncoder :144)"
        }
      )
    , ( ( "Bytes", "decode" )
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 0, 1 ]

            -- Applies the decoder, which is an Elm function value.
            , callsBack = HofYes
            , evidence = "elm-kernel-cpp/src/bytes/BytesExports.cpp:418"
        }
      )
    , ( ( "String", "uncons" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:46-49; runtime/src/allocator/StringOps.cpp:1009"
        }
      )
    , ( ( "String", "words" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:71; elm-kernel-cpp/src/core/String.cpp:286"
        }
      )
    , ( ( "String", "trim" )
      , { unaudited
            | params = [ PBorrowed ]
            , resultAliases = [ 0 ]

            -- Registered on an unaudited row, so only the direct call is gained.
            -- The only export is boxed at both ends.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:91; runtime/src/allocator/StringOps.hpp:878"
        }
      )
    , ( ( "String", "toLower" )
      , { unaudited
            | params = [ PBorrowed ]

            -- As for `trim`.
            , devirt = DevirtAt 1 (ShapeNoUnboxedScalarAt [ 0, -1 ])
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:86; runtime/src/allocator/StringOps.hpp:801"
        }
      )
    , ( ( "String", "toUpper" )
      , { unaudited
            | params = [ PBorrowed ]
            , evidence = "elm-kernel-cpp/src/core/StringExports.cpp:81; runtime/src/allocator/StringOps.hpp:762"
        }
      )
    , ( ( "Debug", "log" )
        -- It prints, so the effect is stated, though the base has it already.
      , { unaudited
            | params = [ PBorrowed, PBorrowed ]
            , resultAliases = [ 1 ]
            , callTimeEffect = EffObservableIO
            , evidence = "elm-kernel-cpp/src/core/DebugExports.cpp:26"
        }
      )
    , ( ( "Crash", "crash" )
        -- gcAlloc stays GcUnbounded: the body converts the message to a
        -- string, and that code has not been read. A call that never returns
        -- gains nothing from being a gc-leaf.
      , { unaudited
            | params = [ PBorrowed ]
            , callTimeEffect = EffNoreturn
            , totality = MayDiverge
            , divergence = Just "prints to stderr + backtrace then ::exit(1) - never returns"
            , evidence = "eco-kernel-cpp/src/eco/CrashExports.cpp:9-11; eco-kernel-cpp/src/eco/Crash.cpp:20-33 (toString :21, fprintf :22/:26, ::exit(1) :30)"
        }
      )

    -- Unaudited rows that exist to record a divergence note: how the C++
    -- kernel differs from the compiler's inline version of the same
    -- operation. They leave params empty, so they carry no borrow modes.
    , ( ( "Basics", "modBy" )
      , { unaudited
            | totality = Throws
            , divergence = Just "C++ THROWS std::runtime_error on modulus 0 (elm-kernel-cpp/src/core/Basics.cpp:92-103, throw at :96); the intrinsic returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131). A PAP-captured modBy 0 terminates through statepointed frames; an inlined one returns 0."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:92-103; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:83-131"
        }
      )
    , ( ( "Basics", "idiv" )
      , { unaudited
            | divergence = Just "C++ is bare a / b: UB / SIGFPE on 0 (elm-kernel-cpp/src/core/Basics.cpp:88-90); the intrinsic is guarded and returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:57-81)."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:88-90; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:57-81"
        }
      )
    , ( ( "Basics", "remainderBy" )
      , { unaudited
            | divergence = Just "C++ UB on divisor 0 (elm-kernel-cpp/src/core/Basics.cpp:105-107); the intrinsic is guarded and returns 0 (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:133-157)."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:105-107; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:133-157"
        }
      )
    , ( ( "Basics", "tan" )
      , { unaudited
            | divergence = Just "C++ is std::tan (elm-kernel-cpp/src/core/Basics.cpp:40-42); the intrinsic composes sin(x)/cos(x) (runtime/src/codegen/Passes/EcoToLLVMArith.cpp:324-337) - differs in the last ulp and at poles."
            , evidence = "elm-kernel-cpp/src/core/Basics.cpp:40-42; runtime/src/codegen/Passes/EcoToLLVMArith.cpp:324-337"
        }
      )
    ]



-- VALIDATION


{-| Messages for the ways the table breaks its own rules; an empty list means
the table is consistent.

Repeated keys give a single message stating how many rows repeat an earlier
key.

Each row must obey these rules, and a row that breaks one gets a message naming
it. Evidence must contain `.cpp:` or `.hpp:`. A `cseSafe` row must have no
call-time effect, an audited `HofNo`, and a totality other than
`MayDiverge`. An `EffNoreturn` row must not be `Total`. `GcFixed` must be
positive. A `HofYes` row must be `GcUnbounded` and not `Total`. A `Throws` row
must carry a divergence note. Every `resultAliases` index must point into
`params`. The key must look like a Mono key: home and name non-empty, a home
not starting with `Elm_Kernel_` or `Eco_Kernel_`, and a name not ending in
`_Int`, `_Float` or `_Char`.

A row registered with `DevirtAt arity guard` must also have a non-negative
`arity`, equal to the length of `params` when `params` is not empty, carry
evidence, and give guard positions that are `-1` or an argument index from 0 to
`arity - 1`.

-}
validationErrors : List String
validationErrors =
    dupKeyErrors
        ++ List.concatMap rowErrors rows
        ++ List.concatMap (\( key, facts ) -> devirtErrors key facts) rows


{-| Returns a message for each way a row's devirtualization registration is
wrong, or nothing for a row that is not registered. A registration must have a
non-negative arity, evidence, and guard positions that are `-1` or a valid
argument index for that arity.

A row can state its arity twice, in `DevirtAt` and as the length of `params`,
and the two must agree. Since `params = []` means the borrow axis was not
audited rather than that the kernel takes no arguments, they are compared only
when `params` is not empty; that is why `DevirtAt` carries its own arity.

-}
devirtErrors : ( Name, Name ) -> KernelFacts -> List String
devirtErrors ( home, name ) facts =
    let
        key =
            home ++ "." ++ name
    in
    case facts.devirt of
        DevirtNo ->
            []

        DevirtAt arity guard ->
            (if arity < 0 then
                [ key ++ ": DevirtAt arity is negative" ]

             else
                []
            )
                ++ (if not (List.isEmpty facts.params) && List.length facts.params /= arity then
                        [ key
                            ++ ": DevirtAt "
                            ++ String.fromInt arity
                            ++ " disagrees with params ("
                            ++ String.fromInt (List.length facts.params)
                            ++ ")"
                        ]

                    else
                        []
                   )
                ++ (if String.isEmpty facts.evidence then
                        [ key ++ ": DevirtAt row carries no evidence" ]

                    else
                        []
                   )
                ++ (case guard of
                        ShapeAny ->
                            []

                        ShapeNoUnboxedScalarAt positions ->
                            if List.all (\pos -> pos == -1 || (pos >= 0 && pos < arity)) positions then
                                []

                            else
                                [ key ++ ": ShapeNoUnboxedScalarAt position out of range for arity " ++ String.fromInt arity ]
                   )


{-| A message giving how many rows repeat an earlier row's key, or nothing
when every key is distinct. `table` would keep only the last such row, with no
other sign of the others.
-}
dupKeyErrors : List String
dupKeyErrors =
    if List.length rows == Dict.size table then
        []

    else
        [ "duplicate key(s): " ++ String.fromInt (List.length rows - Dict.size table) ]


{-| Returns a message, naming the row, for each rule the row breaks. Evidence
must contain `.cpp:` or `.hpp:`. A `cseSafe` row must have no
call-time effect, an audited `HofNo`, and a totality other than `MayDiverge`.
An `EffNoreturn` row must not be `Total`. `GcFixed` must be positive. A `HofYes`
row must be `GcUnbounded` and not `Total`. A `Throws` row must carry a
divergence note. Every `resultAliases` index must point into `params`. The key
must look like a Mono key: home and name non-empty, a home not starting with
`Elm_Kernel_` or `Eco_Kernel_`, and a name not ending in `_Int`, `_Float` or
`_Char`.
-}
rowErrors : ( ( Name, Name ), KernelFacts ) -> List String
rowErrors ( ( home, name ), f ) =
    let
        tag msg =
            home ++ "." ++ name ++ ": " ++ msg

        check cond msg =
            if cond then
                []

            else
                [ tag msg ]
    in
    List.concat
        [ check (String.contains ".cpp:" f.evidence || String.contains ".hpp:" f.evidence)
            "evidence must carry at least one <file>.cpp:<line> / .hpp:<line> anchor"
        , check (not f.cseSafe || (f.callTimeEffect == EffNone && not (mayCallBackIntoElm f) && f.totality /= MayDiverge))
            "cseSafe requires EffNone AND callsBack == HofNo AND totality /= MayDiverge"
        , check (f.callTimeEffect /= EffNoreturn || f.totality /= Total)
            "EffNoreturn requires totality /= Total"
        , check (gcBudgetOk f.gcAlloc)
            "GcFixed n requires n > 0 (use GcNone for zero)"
        , -- Elm code run by a call can allocate any amount, and need not return.
          check (f.callsBack /= HofYes || (f.gcAlloc == GcUnbounded && f.totality /= Total))
            "callsBack == HofYes requires GcUnbounded AND totality /= Total"
        , check (f.totality /= Throws || f.divergence /= Nothing)
            "totality = Throws requires a divergence note"
        , -- So a row with no borrow modes cannot list aliases either.
          check (List.all (\i -> i >= 0 && i < List.length f.params) f.resultAliases)
            "resultAliases index out of range for params"
        , check (home /= "" && name /= "")
            "empty home/name"
        , check (not (String.startsWith "Elm_Kernel_" home || String.startsWith "Eco_Kernel_" home))
            "home must be the Mono home, not the C symbol prefix"
        , check (not (List.any (\s -> String.endsWith s name) [ "_Int", "_Float", "_Char" ]))
            "name must be the base Mono name, not an ABI-suffixed symbol"
        ]


{-| Returns whether an allocation bound is acceptable: `GcFixed` must be
positive, and the other values always are.
-}
gcBudgetOk : GcAlloc -> Bool
gcBudgetOk ga =
    case ga of
        GcFixed n ->
            n > 0

        _ ->
            True
