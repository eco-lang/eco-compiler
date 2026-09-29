---------------------------------- MODULE MC ----------------------------------
\* The example heap of plans/threaded-gc-tla-M3-minor-forwarding.md §5.5, with two
\* changes (AUDIT.md): 4's head is the old leaf 9, not Nil, so that the heads pass
\* runs (spineRunP's needs_heads: a constant head never sets it); and the region
\* heap keeps both of the YLOS's parents.
\*
\* From-space: 1 = Tuple(2, 7)   age 1 (promotes; its children must promote too)
\*             2 = leaf -> old 9 age 1 (promotes; shared by 1 and 5's head)
\*             3 = Cons(7, 4)    age 0 (its head is the YLOS: 7's second parent)
\*             4 = Cons(9, 5)    age 0 (a pointer head: the run's heads pass runs)
\*             5 = Cons(2, Nil)  age 1 (promotes; shared by 4's tail and 7)
\*             6 = garbage
\* YLOS 7 = [5] age 1 (promoted in place); old 9. Roots: <<1, 3>>.
\* Acyclic, and every edge goes to an object at least as old (Elm's allocation order).
EXTENDS MinorForwarding

MC_FromIds == 1..6
MC_ConsIds == {3, 4, 5}
MC_YlosIds == {7}
MC_OldIds == {9}
MC_Fields == (1 :> <<2, 7>>) @@ (2 :> <<9>>) @@ (3 :> <<7, 4>>) @@ (4 :> <<9, 5>>)
             @@ (5 :> <<2, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<5>>)
MC_Roots == <<1, 3>>
MC_Age == (1 :> 1) @@ (2 :> 1) @@ (3 :> 0) @@ (4 :> 0) @@ (5 :> 1) @@ (6 :> 0) @@ (7 :> 1)
MC_PromoAge == 1
MC_Builders == {}
MC_NoIds == {}
MC_NoRetire == [x \in {} |-> 0]

\* Region variant: the same shape, with 2 -> Retire 12 (tenured to old 9) and 4's
\* head -> Hand 11 (recorded by whoever evacuates it: the run's heads pass, or the
\* scanner of a pushed 4'). 7 keeps both parents, 1 and 3. Every eden object has
\* age 0 (TV9, copyClaimedR) and the YLOS is reached with age 0 (reachYoungLargeR
\* sets it to 1); the region minor never promotes.
MC_HandIds == {11}
MC_RetireIds == {12}
MC_RegionFields == (1 :> <<2, 7>>) @@ (2 :> <<12>>) @@ (3 :> <<7, 4>>) @@ (4 :> <<11, 5>>)
                   @@ (5 :> <<2, 0>>) @@ (6 :> <<3>>) @@ (7 :> <<5>>)
MC_RegionAge == [o \in 1..7 |-> 0]
MC_RetireFwd == (12 :> 9)
================================================================================
