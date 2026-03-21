# Post Dev Plan

Date: 2026-03-14

## Purpose

This document captures advanced Rust concepts and baseline research tracks worth exploring after the main development plan milestones are in motion.

## A) Advanced Rust Concepts to Explore

1. Typestate + `PhantomData`
- Encode pipeline stage correctness at compile time (parse -> analyze -> bundle -> runtime).

2. Arena Allocation + Generational IDs
- Use arena-backed storage and stable IDs (`slotmap` style) for graph-heavy subsystems.

3. Concurrency Model Checking with `loom`
- Validate atomic and lock-free correctness in hot-set and scheduler paths under all interleavings.

4. Lock-Free + Bounded Backpressure Patterns
- Favor bounded queues and explicit pressure semantics over unbounded buffering.

5. Intrusive / Pinned Data Structures
- Apply where pointer stability and low allocation overhead are critical.

6. Zero-Copy Data Paths
- Reduce copies via borrowed forms and minimal `String` allocation in hot runtime paths.

7. Unsafe Boundary Discipline
- Keep unsafe blocks small and auditable; validate with Miri and sanitizers.

8. Const Generics for Runtime Topology
- Parameterize lane count and topology constants at compile time for specialization.

## B) Baseline Research Ideas (Non-ML)

1. Abstract Interpretation + Effect Lattice
- Sound tiering and hydration decisions from semantics (pure/hooks/async/io/side-effects).

2. Incremental Computation Graph
- Delta-only recomputation (Salsa-style concepts) instead of coarse invalidation.

3. Formal Verification of Runtime Invariants
- Model hot-set and scheduler invariants with TLA+ / PlusCal.

4. Information-Theoretic Vendor Chunking
- Co-import mutual information for better chunk boundaries than raw thresholds.

5. Optimization-Based Scheduling
- Phase/lane scheduling as constrained optimization (instead of hand-tuned weights).

6. Persistent Graph Versions
- Structural sharing (HAMT-style) for rollback, diffing, and history-aware analysis.

7. Causal Profiling
- Prioritize optimization by true critical-path impact, not only local component time.

8. Zero-Allocation Streaming Experiments
- Investigate `io_uring` + scatter-gather paths for high-throughput runtime delivery.

## C) Suggested Post-Plan Order

1. `loom` model tests for hot-set/scheduler correctness.
2. Effect lattice + abstract interpretation for semantic tiering.
3. Incremental computation graph for minimal recomputation.
4. Causal profiling and optimization-based scheduling.
5. Advanced chunking and streaming experiments.

## D) Exit Criteria for Exploration

- Each concept/research track must produce at least one of:
  - measurable p50/p95 improvement,
  - measurable reduction in recomputation scope,
  - stronger correctness guarantees with failing-case coverage,
  - lower memory churn/allocation count in hot paths.

