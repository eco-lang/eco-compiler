---------------------------- MODULE TraceInOrder ----------------------------
(***************************************************************************)
(* Trace validation in log order: the events are matched one after the     *)
(* other, in the merger's order (see TraceLog). The spec's invariant is    *)
(* TLUnmatched.                                                            *)
(***************************************************************************)
EXTENDS TraceLog
VARIABLE tl                        \* the index of the next event to match

TLInit == tl = 1
TLEvent == IF tl <= TraceLen THEN TraceLog[tl] ELSE NoEvent
\* The next event of thread u at or after tl (NoEvent if none). The merger
\* stores that index in every event ("pk").
TLPeek(u) == IF tl > TraceLen THEN NoEvent
             ELSE IF TraceLog[tl].pk[u] = 0 THEN NoEvent
             ELSE TraceLog[TraceLog[tl].pk[u]]
\* A step that matches the next event: A(e) holds for the model step of event e.
TLMatch(A(_)) == /\ tl <= TraceLen
                 /\ A(TraceLog[tl])
                 /\ tl' = tl + 1
                 /\ TraceProgress(tl, TraceLog[tl])
TLUnmatched == tl <= TraceLen

=============================================================================
