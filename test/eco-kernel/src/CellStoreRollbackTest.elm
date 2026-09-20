module CellStoreRollbackTest exposing (main)

{-| The undo trail on the NATIVE kernel, where rollback really has to restore
mutated memory rather than hand back an older persistent value.

The cases are the ones the union-find scratch scopes depend on: a rollback
restores both the cells and the cell COUNT; a write to a cell that was pushed
inside the scope disappears with the cell; scopes nest; and an outer rollback
undoes an inner COMMIT.
-}

-- CHECK: CellStoreRollbackTest: True

import Eco.CellStore as CS
import Platform


type alias Cell =
    { v : Int }


seeded : () -> CS.Store Cell
seeded () =
    CS.new 4
        |> CS.push { v = 10 }
        |> CS.push { v = 20 }
        |> CS.push { v = 30 }


toList : CS.Store Cell -> List Int
toList st =
    List.map (\i -> (CS.get i st).v) (List.range 0 (CS.size st - 1))


{-| Writes inside a scope are undone.
-}
caseWrites : Bool
caseWrites =
    seeded ()
        |> CS.pushMark
        |> CS.set 0 { v = 111 }
        |> CS.set 2 { v = 333 }
        |> CS.rollback
        |> toList
        |> (==) [ 10, 20, 30 ]


{-| Pushes inside a scope are undone, count included; and a write to a cell
that only existed inside the scope goes with it.
-}
casePushes : Bool
casePushes =
    let
        rolled =
            seeded ()
                |> CS.pushMark
                |> CS.push { v = 40 }
                |> CS.set 3 { v = 44 }
                |> CS.set 0 { v = 111 }
                |> CS.rollback
    in
    CS.size rolled == 3 && toList rolled == [ 10, 20, 30 ]


caseCommit : Bool
caseCommit =
    seeded ()
        |> CS.pushMark
        |> CS.set 0 { v = 111 }
        |> CS.push { v = 40 }
        |> CS.commit
        |> toList
        |> (==) [ 111, 20, 30, 40 ]


caseInnerRollback : Bool
caseInnerRollback =
    seeded ()
        |> CS.pushMark
        |> CS.set 0 { v = 111 }
        |> CS.pushMark
        |> CS.set 1 { v = 222 }
        |> CS.rollback
        |> CS.commit
        |> toList
        |> (==) [ 111, 20, 30 ]


{-| The scratch-scope property: an inner commit does not survive an outer
rollback.
-}
caseOuterUndoesInnerCommit : Bool
caseOuterUndoesInnerCommit =
    seeded ()
        |> CS.pushMark
        |> CS.set 0 { v = 111 }
        |> CS.pushMark
        |> CS.set 1 { v = 222 }
        |> CS.commit
        |> CS.rollback
        |> toList
        |> (==) [ 10, 20, 30 ]


{-| Untrailed writes (no mark open) must not be undone by a LATER scope.
-}
caseUntrailedSurvives : Bool
caseUntrailedSurvives =
    seeded ()
        |> CS.set 0 { v = 999 }
        |> CS.pushMark
        |> CS.set 1 { v = 222 }
        |> CS.rollback
        |> toList
        |> (==) [ 999, 20, 30 ]


result : Bool
result =
    caseWrites
        && casePushes
        && caseCommit
        && caseInnerRollback
        && caseOuterUndoesInnerCommit
        && caseUntrailedSurvives


init : () -> ( (), Cmd () )
init _ =
    let
        _ =
            Debug.log "CellStoreRollbackTest" result
    in
    ( (), Cmd.none )


main : Program () () ()
main =
    Platform.worker
        { init = init
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
