module Compiler.Monomorphize.Solver.StoreHelpers exposing (loadCtx, groundNoArrow)

{-| Fixture builders for tests that drive `Compiler.Monomorphize.Solver.Store`
directly, without an engine state.

@docs loadCtx, groundNoArrow

-}

import Array
import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Canonical as Can
import Compiler.IR.Typed.TypeVars as Vars
import Compiler.Monomorphize.Solver.Store as Store
import Compiler.Type.State.IO as IO
import Data.HashMap as HashMap
import Dict


{-| Builds a `Store.LoadCtx` over `store` with empty memos and
`sharedArrowMemo` as the arrow memo, for tests that call `Store.loadTypeC`
directly. Passing an item's arrow memo models a shared load, and `Dict.empty`
an isolated one. `lssOn` makes arrows `FunL` with set slots. The census is off
and the alias tables are empty.
-}
loadCtx : Bool -> Dict.Dict Int Vars.Variable -> IO.State -> Store.LoadCtx
loadCtx lssOn sharedArrowMemo store =
    { store = store
    , memo = Dict.empty
    , revMemo = Array.empty
    , lssOn = lssOn
    , arrowSlots = []
    , slotsMinted = 0
    , arrowMemo = sharedArrowMemo
    , censusOn = False
    , arrowOfSlot = Dict.empty
    , groundLoads = HashMap.empty
    , aliasMemo = HashMap.empty
    }


{-| Tells whether a type is ground and arrow-free in the sense of
`Store.groundHash`, which gives a negative hash for any other type.
-}
groundNoArrow : Can.Type TypeIds.MVarId -> Bool
groundNoArrow t =
    Store.groundHash t >= 0
