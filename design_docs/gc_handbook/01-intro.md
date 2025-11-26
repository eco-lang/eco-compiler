# 1. Introduction (GC Goals & Terms)

- Motivation: avoid manual free errors; GC trades mutator overhead and pauses for safety and productivity.
- Metrics: safety, throughput, completeness/promptness, pause time (latency), space overhead, scalability/portability, language-specific needs.
- Experimental method: measure live set, pause distributions, throughput; use realistic workloads and report configs.
- Terminology: heap, mutator vs collector, roots (globals, stack, regs, statics), references/addresses, liveness/reachability, allocator, atomic ops, sets/sequences.

