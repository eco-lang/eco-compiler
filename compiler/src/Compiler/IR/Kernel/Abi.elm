module Compiler.IR.Kernel.Abi exposing
    ( suffixSelectingKernels, boxedAbiKernels, alwaysPolymorphicModules, comparePair
    , hasAnyFreeVar
    )

{-| What decides which kernel references keep a boxed ABI, independent of how
the ABI type is built. A kernel whose canonical type has no type variable has
one signature; a kernel with a type variable, or any kernel of a module in
`alwaysPolymorphicModules`, has one boxed root implementation. The kernels in
`suffixSelectingKernels` are the exception: a caller may keep the concrete
call-site type, so that a C++ variant can be picked.

`Compiler.Monomorphize.KernelAbi` builds the ABI types from these facts; the
passes before monomorphization use them to decide which kernel references can
be forwarded.


# Kernel Tables

@docs suffixSelectingKernels, boxedAbiKernels, alwaysPolymorphicModules, comparePair


# Type Variables

@docs hasAnyFreeVar

-}

import Compiler.Core.TypeIds exposing (MVarId)
import Compiler.IR.Canonical as Can
import Data.Set as EverySet exposing (EverySet)
import Dict
import Maybe.Extra as Maybe



-- ============================================================================
-- CONSTANTS
-- ============================================================================


{-| The kernels, as `( home, name )` pairs, for which a call site may keep its
concrete call-site type instead of the boxed ABI that
`canTypeToMonoType_preserveVars` builds. The exact condition is the callers'. A kernel outside
this set never reaches its `_Int`, `_Float` or `_Char` variant, because by the
time the symbol is chosen the element type is already `CEcoValue`.

Two kinds of kernel are listed. Element-aware container kernels (`List.cons`,
`List.map2` to `map5`, `Json.wrap`, the `JsArray` element kernels, `MVar.put`)
use the concrete element type. `List.mapN` is listed so that a reference that
is not a saturated call (the alias body `map2 = Elm.Kernel.List.map2`, which a
`List.map2` passed as a value reaches) keeps its result element too: the
kernel builds the list in that element's kind, which no callback closure can
supply when its own result is boxed, as a polymorphic-result kernel's is. Primitive-specialized kernels (the `Utils` comparisons, `Basics.add`,
`sub`, `mul` and `pow`, `String.fromNumber`) have per-type C++ variants.

The symbol choice is `Compiler.GenerateMlir.KernelAbi`'s; where no variant
matches the types (e.g. `Utils.compare` at `String`) the boxed root symbol is
used.

-}
suffixSelectingKernels : EverySet (List String) ( String, String )
suffixSelectingKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
        , ( "List", "map2" )
        , ( "List", "map3" )
        , ( "List", "map4" )
        , ( "List", "map5" )
        , ( "Utils", "compare" )
        , ( "Utils", "equal" )
        , ( "Utils", "notEqual" )
        , ( "Utils", "lt" )
        , ( "Utils", "le" )
        , ( "Utils", "gt" )
        , ( "Utils", "ge" )
        , ( "Json", "wrap" )
        , ( "JsArray", "singleton" )
        , ( "JsArray", "push" )
        , ( "JsArray", "unsafeSet" )
        , ( "MVar", "put" )
        , ( "Basics", "add" )
        , ( "Basics", "sub" )
        , ( "Basics", "mul" )
        , ( "Basics", "pow" )
        , ( "String", "fromNumber" )
        ]


{-| The suffix-selecting kernels whose variants share the boxed root's ABI:
the concrete type may only refine what lies inside an argument or result,
never make a top-level argument or the result an `Int`, `Float` or `Char`.
`List.map2` to `map5` are the members; their variants differ only in the
element kind of the list they build. A caller keeps the concrete type of such
a kernel only where its top-level ABI is the boxed one
(`Compiler.Monomorphize.KernelAbi.sameTopLevelAbi`). A raw kernel reference
in a kernel module has no signature, so its type comes from the use alone and
can make an argument an `Int`, which would give the kernel a second ABI.
-}
boxedAbiKernels : EverySet (List String) ( String, String )
boxedAbiKernels =
    EverySet.fromList comparePair
        [ ( "List", "map2" )
        , ( "List", "map3" )
        , ( "List", "map4" )
        , ( "List", "map5" )
        ]


{-| The modules whose kernels always get `PreserveVars`, even when the kernel's
type has no type variable. The one member is `Debug`.
-}
alwaysPolymorphicModules : EverySet (List String) String
alwaysPolymorphicModules =
    EverySet.fromList List.singleton [ "Debug" ]


{-| Returns the key under which a `( home, name )` pair is stored in an
`EverySet`, the two strings as a list.
-}
comparePair : ( String, String ) -> List String
comparePair ( a, b ) =
    [ a, b ]



-- ============================================================================
-- FREE TYPE VARIABLES
-- ============================================================================


{-| Returns whether `canType` has any type variable, stopping at the first one
found. It counts exactly what
`Compiler.Monomorphize.KernelAbi.freeVarIds` collects, including a record's
extension variable and both the body and the arguments of a holey alias, so
`hasAnyFreeVar t == not (List.isEmpty (freeVarIds t []))`.
-}
hasAnyFreeVar : Can.Type MVarId -> Bool
hasAnyFreeVar canType =
    case canType of
        Can.TVar _ ->
            True

        Can.TLambda _ from to ->
            hasAnyFreeVar from || hasAnyFreeVar to

        Can.TType _ _ args ->
            List.any hasAnyFreeVar args

        Can.TRecord fields maybeExt ->
            case maybeExt of
                Just _ ->
                    True

                Nothing ->
                    List.any (\( _, Can.FieldType _ t ) -> hasAnyFreeVar t) (Dict.toList fields)

        Can.TTuple a b rest ->
            List.any hasAnyFreeVar (a :: b :: Maybe.toList rest)

        Can.TUnit ->
            False

        Can.TAlias _ _ _ (Can.Filled inner) ->
            hasAnyFreeVar inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            hasAnyFreeVar inner || List.any (\( _, t ) -> hasAnyFreeVar t) args
