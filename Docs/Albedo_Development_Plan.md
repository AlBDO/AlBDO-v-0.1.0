# Albedo Development Plan

Date: 2026-03-14

## 1) Product Objective

Albedo should become a production-grade framework that balances:

- High-level code elegance and ease of use for application developers.
- Low-level performance and deterministic behavior in the runtime pipeline.

## 2) Performance Positioning (Reality-Checked)

We should not claim "fastest JS/TS framework" globally.

We should target and prove a narrower, credible claim:

- Fastest deterministic SSR + incremental TSX pipeline in a clearly defined workload envelope.

A "fastest" claim only ships when all conditions are met:

- Scope is explicit (workload, app size, hardware class, traffic shape).
- Benchmarks are reproducible and public.
- p50 and p95 latency/build metrics beat defined baselines.
- Performance regressions are blocked in CI.

## 3) Six Architectural Pillars

### Pillar A: Canonical Albedo IR

Create one typed IR consumed by parser, analyzer, bundler, hydration, and runtime.

Expected outcome:

- Single source of truth for component/module semantics.
- Deterministic outputs keyed by IR hash.
- Removal of duplicated interpretation logic across subsystems.

### Pillar B: Effect System for Tiering and Hydration

Replace heuristic tiering with effect-aware analysis over call graphs.

Core effect classes:

- Pure
- Hooks
- Async
- IO
- SideEffects

Expected outcome:

- Correct tier A/B/C decisions based on semantics, not naming or rough size hints.
- Reduced hydration mismatches and fewer false static classifications.

### Pillar C: Delta-First Incremental Pipeline

Re-architect compile/analyze flow around deltas rather than broad invalidation.

Expected outcome:

- Change propagation only where dependencies actually require it.
- Lower recomputation cost for localized edits.
- Predictable incremental scaling with project size.

### Pillar D: Artifact-First Runtime

Make server runtime execute sealed route artifacts instead of source-dependent logic.

Artifact content should include:

- Static slices
- Precompiled runtime modules
- Module order and dependency closure
- Hydration payload plans
- Integrity checksums

Expected outcome:

- Faster startup and request path.
- Stronger runtime/build contract.
- Better deployment reproducibility.

### Pillar E: Runtime Kernel (Hot Set + Scheduler + Pi-Arch)

Unify runtime coordination into one small kernel with typed messages and bounded queues.

Expected outcome:

- Clear concurrency boundaries and backpressure semantics.
- Easier invariant testing and observability.
- Better control of tail latency under load.

### Pillar F: Persistent Daemon

Run a background Albedo daemon that keeps graph/IR/cache hot and serves CLI/server/node clients.

Expected outcome:

- Near-instant dev feedback after warm-up.
- Shared cache/state across commands and integrations.
- Reduced cold-start penalties during development.

## 4) Delivery Phases

| Phase | Focus | Primary Deliverables | Exit Criteria |
|---|---|---|---|
| Phase 0 | Baseline and gates | Benchmark harness, workload definitions, CI perf gates, golden correctness tests | Reproducible baseline numbers and automated regression blocking |
| Phase 1 | Semantic foundation | Canonical IR + effect system integrated into tier/hydration decisions | Tier/hydration derived from IR/effects with no correctness regressions |
| Phase 2 | Incremental speed | Delta-first propagation and cache/state APIs | Single-file edits trigger minimal recomputation in measured scenarios |
| Phase 3 | Runtime hardening | Artifact-first runtime and unified kernel | Runtime can serve artifact-only path with stable p95 latency |
| Phase 4 | Productization | Daemon, polished CLI flows, docs, migration guides | End-to-end DX flow is stable and benchmark claim is publishable |

## 5) Product Readiness Checklist

- `albedo init`, `albedo dev`, `albedo build`, `albedo start` are stable and documented.
- Config and manifest contracts are versioned and backwards-compatible.
- Error surfaces are actionable (compile/runtime overlays and clear diagnostics).
- Benchmark report is published with methodology and hardware details.
- Release process is repeatable (artifacts, changelog, upgrade notes).

## 6) Metrics That Decide Success

- Build metrics: cold build time, incremental rebuild time, recomputed node count.
- Runtime metrics: p50/p95 TTFB, p50/p95 total render latency, tail behavior under concurrency.
- DX metrics: dev server warm-start time, hot-update round-trip time, error-to-fix loop time.
- Stability metrics: crash-free sessions, deterministic output consistency, regression rate.

## 7) Risks and Mitigations

- Risk: Scope creep from research-heavy work.
  - Mitigation: Phase gates with measurable exit criteria and freeze rules.

- Risk: Performance gains at cost of developer usability.
  - Mitigation: Treat CLI/diagnostics/docs as first-class deliverables in each phase.

- Risk: Claiming "fastest" without sufficient evidence.
  - Mitigation: Only publish bounded, benchmark-backed claims tied to explicit workloads.

## 8) Immediate Next Steps (First 2 Weeks)

- Define benchmark scenarios and baseline competitors.
- Implement Phase 0 performance CI gates.
- Draft Canonical IR schema and migration map from current parser/analyzer outputs.
- Draft effect lattice and tiering decision contract.

