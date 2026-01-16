module Compiler.Generate.DebugPolymorphism exposing
    ( expectDebugPolymorphismResolved
    )

{-| Test logic for invariant MONO_009: Debug.* kernel functions handle polymorphism.

For Debug.log, Debug.toString, and other kernel functions that operate
on polymorphic values:

  - Verify type information is correctly passed at runtime.
  - Verify string representations are type-appropriate.
  - Verify no runtime type errors occur.

This module reuses the existing typed optimization pipeline to verify
debug kernel polymorphism is correctly handled.

-}

import Compiler.AST.Source as Src
import Expect


{-| Verify that Debug kernel calls remain polymorphic with CEcoValue.
-}
expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
expectDebugPolymorphismResolved srcModule =
    -- TODO_TEST_LOGIC
    -- Identify polymorphic Debug kernel calls:
    --   * Check that monomorphization applies an empty substitution to keep type variables as MVar.
    --   * Assert those MVars always carry CEcoValue constraint and do not show up in
    --     layout-influencing positions.
    -- Oracle: Debug calls retain polymorphic MonoTypes; only CEcoValue constraints appear.
    Debug.todo "Debug kernel calls remain polymorphic with CEcoValue"
