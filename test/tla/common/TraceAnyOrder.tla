---------------------------- MODULE TraceAnyOrder ---------------------------
(***************************************************************************)
(* Trace validation in any order the log allows: each thread's events are  *)
(* matched in that thread's order, and an event only once everything the   *)
(* log orders before it (its vector clock "vc") is matched (see TraceLog). *)
(* The spec's invariant is TPUnmatched.                                    *)
(***************************************************************************)
EXTENDS TraceLog
VARIABLE tpos                      \* [TraceThreads -> matched events of that thread]

TPInit == tpos = [u \in TraceThreads |-> 0]
TPEvents(u) == TraceHdr.tev[u]     \* the indices of u's events, in order
TPHasNext(u) == tpos[u] < Len(TPEvents(u))
\* The next event of thread u (NoEvent when u is done).
TPPeek(u) == IF TPHasNext(u) THEN TraceLog[TPEvents(u)[tpos[u] + 1]] ELSE NoEvent
\* u's next event may be matched now: everything the log orders before it is.
TPReady(u) == /\ TPHasNext(u)
              /\ \A v \in TraceThreads : tpos[v] >= TPPeek(u).vc[v]
RECURSIVE TPSum(_)
TPSum(S) == IF S = {} THEN 0
            ELSE LET u == CHOOSE x \in S : TRUE IN tpos[u] + TPSum(S \ {u})
TPDone == TPSum(TraceThreads)
\* A step that matches thread u's next event e: A(u, e) holds for its model step.
TPMatch(A(_, _)) == \E u \in TraceThreads :
                      /\ TPReady(u)
                      /\ A(u, TPPeek(u))
                      /\ tpos' = [tpos EXCEPT ![u] = @ + 1]
                      /\ TraceProgress(TPDone + 1, TPPeek(u))
TPUnmatched == \E u \in TraceThreads : TPHasNext(u)
=============================================================================
