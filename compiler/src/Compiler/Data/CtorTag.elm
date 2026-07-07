module Compiler.Data.CtorTag exposing (constantTag, effective, isEmbeddedConstantCtor)

{-| Runtime ctor-tag conventions shared between monomorphization (which sets
`CtorShape.tag` used at construction time) and code generation (which emits the
ctor-tag constants used by pattern matching).

Most constructors use their zero-based declaration index as the runtime tag.
Some types, however, need the runtime to recognise them as "special" so that
structural operations like `==` can implement type-specific semantics instead
of the default tree-shape walk. We reserve the top of the 16-bit ctor range
for those markers; the values must stay in sync with
`elm-kernel-cpp/src/core/Utils.cpp`.

The current reservations cover `Dict`/`Set` so that `Dict` equality compares
by content (in-order key/value traversal) instead of by tree shape.

@docs effective

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== RESERVED CTOR TAGS ======
-- ============================================================================


{-| Ctor tag for `Dict.RBNode_elm_builtin`. Must match `Utils.cpp`.
-}
dictRBNode : Int
dictRBNode =
    0xFFFF


{-| Ctor tag for `Dict.RBEmpty_elm_builtin`. Must match `Utils.cpp`.
-}
dictRBEmpty : Int
dictRBEmpty =
    0xFFFE


{-| Ctor tag emitted for embedded "empty" constant constructor branches
(`Nil`, `Nothing`, and any other nullary constant that shares the merged empty
bit pattern). Because those constants can no longer be told apart by value, the
runtime returns this single reserved tag for all of them (`eco_get_tag` / the
`eco.case` lowering), and the compiler tags the matching branch the same. Sits
just below the `Dict` reservations. Must match `CONSTANT_TAG` in
`runtime/src/allocator/Heap.hpp` and `value_enc::ConstantTag`. See plan D9.
-}
constantTag : Int
constantTag =
    0xFFFD


{-| True for a constructor whose runtime representation is an embedded HPointer
constant (Nothing / True / False). Mirrors the nullary-constant selection in
`Compiler.Generate.MLIR.Functions.generateNullaryConstructor`. Such
constructors dispatch by the merged constant tag (`constantTag`) rather than a
per-declaration index, since their bit pattern is shared with the other empties.
(True / False normally reach pattern matching via `Test.IsBool`, not
`Test.IsCtor`; they are included here for completeness.)
-}
isEmbeddedConstantCtor : Name -> Bool
isEmbeddedConstantCtor name =
    name == "Nothing" || name == "True" || name == "False"



-- ============================================================================
-- ====== TAG COMPUTATION ======
-- ============================================================================


{-| Compute the runtime ctor tag for a constructor.

Normal constructors use `Index.toMachine` (their zero-based declaration index).
Constructors in runtime-recognised types (currently `Dict`) use reserved tag
values so the runtime can dispatch to a type-specific implementation.

-}
effective : IO.Canonical -> Name -> Index.ZeroBased -> Int
effective home name index =
    if home == ModuleName.dict then
        if name == "RBNode_elm_builtin" then
            dictRBNode

        else if name == "RBEmpty_elm_builtin" then
            dictRBEmpty

        else
            Index.toMachine index

    else
        Index.toMachine index
