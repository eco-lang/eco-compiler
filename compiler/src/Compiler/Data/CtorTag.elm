module Compiler.Data.CtorTag exposing
    ( dictRBNode
    , dictRBEmpty
    , effective
    )

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

@docs dictRBNode, dictRBEmpty, effective

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
