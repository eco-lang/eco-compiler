------------------------------- MODULE MC -------------------------------
\* The graphs and initial work distributions of plans/threaded-gc-tla-M2-slice-control.md §6,
\* written over the model's constants so that every configuration shares them.
\*   quick graph: the diamond 1 -> {2, 3} -> 4, root 1;
\*   deep graph:  the diamond plus 4 -> 5, roots 1 and 3.
EXTENDS SliceControl

MC_Edges     == {<<1, 2>>, <<1, 3>>, <<2, 4>>, <<3, 4>>}
MC_DeepEdges == MC_Edges \cup {<<4, 5>>}

MC_NoWork == [x \in Slots |-> <<>>]

\* 5b slice: the t0 greys on slot 0's private stack (markHPointer -> pushGrey);
\* slot 0 of the code is the model's slot 1.
MC_RootOnStack1 == [x \in Slots |-> IF x = 1 THEN <<1>> ELSE <<>>]

\* Round-robin into the deques before the launch (minorGCParallel step 4,
\* launchBackground, tenureParDistribute): one root lands in one deque.
MC_RootInDeque1 == [x \in Slots |-> IF x = 1 THEN <<1>> ELSE <<>>]
MC_RootInDeque2 == [x \in Slots |-> IF x = 2 THEN <<1>> ELSE <<>>]
MC_RootInDeque3 == [x \in Slots |-> IF x = 3 THEN <<1>> ELSE <<>>]

\* Deep episode: roots 1 and 3 round-robin into the background deques 2 and 3.
MC_DeepDeques == [x \in Slots |-> IF x = 2 THEN <<1>> ELSE IF x = 3 THEN <<3>> ELSE <<>>]
\* The negative control of BudgetOK (mutants/budget_premise.cfg): a drain whose
\* budget can run out, with the budget loads folded as if it could not.
MC_Always == TRUE
=============================================================================
