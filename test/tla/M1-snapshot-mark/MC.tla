------------------------------- MODULE MC -------------------------------
\* The starting heap of plans/threaded-gc-tla-M1-snapshot-mark.md §6, written over
\* the constants Obj and Fields so that the quick and deep configurations share it.
\*   old 1 -> 2, old 4, young 3 -> 4; r1 -> 1, r2 -> 3; c1 empty; 5 is a free YLOS id.
EXTENDS SnapshotMark

MC_Alloc == {1, 2, 3, 4}
MC_Gen   == [o \in Obj |-> IF o \in {1, 2, 4} THEN "old" ELSE "young"]
MC_Age   == [o \in Obj |-> 0]
MC_Fld   == [o \in Obj |-> [i \in Fields |->
                 IF i = 1 /\ o = 1 THEN 2
                 ELSE IF i = 1 /\ o = 3 THEN 4
                 ELSE Nil]]
MC_Root  == [r \in RootSlots |-> IF r = "r1" THEN 1 ELSE 3]
MC_Cell  == [c \in CellSlots |-> Nil]
=============================================================================
