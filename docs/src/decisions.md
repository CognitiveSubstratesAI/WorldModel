# Architecture Decisions

## ADR-001 — WorldModel is a standalone application, not a substrate library (2026-06-20)

**Decision.** The PRIMUS world-model lives in its own repo as a **standalone application**, separate from
the MORK/Core kernel and the algorithm packages — and with **no hard dependency** on them.

**Context.** The CognitiveSubstratesAI stack splits cleanly into two kinds of code:

- **Reusable libraries** — the kernel and algorithm packages (`MeTTaCore`/`MORK`/`PathMap`,
  `MorkSupercompiler`, `MORKTensorNetworks`, `FabricPC`, `MetaMo`, `HMH`/`FactorVSA`, `WILLIAM`, …).
  These are versioned, stateless, dependency-clean — *reusable software*.
- **The world-model** — a running, stateful, ever-evolving cognitive system that *composes* those
  libraries into the two-loop architecture. It is an *application* (a live codebase / server), not a
  reusable component.

Merging the application's glue, live state, and scenario code into the kernel would pollute a clean
reusable substrate with application concerns (cf. the algorithm-library governance rule: split heavy +
app-level code to its own repo). The prior `PRIMUS_WorldModeling` was already a separate package.

**Consequence — standalone with a pluggable backend.** WorldModel takes **no hard package
dependencies**: it loads on a bare Julia, and reaches substrate capabilities (MeTTa eval, MORK spaces,
the algorithm libraries) through a pluggable [`AbstractBackend`](@ref) injected at **runtime**. A
concrete backend (an in-process `MeTTaCore` adapter, a `MorkServer`/`MettaJam` socket client, or a test
mock) lives *outside* this package. So anyone can clone and use WorldModel on its own, against whatever
backend they have — the substrate is a runtime connection, not a build dependency.

**How the loop gets wired.** Scenario-driven (measure-first): pick a concrete scenario (Minecraft
affordance discovery / social-robot anti-hallucination) and build only the loop slice it needs, against
a backend — never loop-first-blind.

## Built-vs-spec map (2026-06-20)

Where each Whitepaper §4 / Appendix-A component lives. The application **composes** these via a backend;
it does **not** absorb them.

| Component | Status |
|---|---|
| MetaMo, PLN, MOSES, ECAN, factor-PLN | ✅ libraries (`Core/lib/{metamo,pln,MOSES,ecan}`) |
| PC (predictive coding) | ✅ `Core/lib/ActPC-*`, `FabricPC` |
| geodesic, quantale-weakness | ✅ `ActPC-Geom`, `Core/lib/quantale` |
| HMH / Symbolic-Heads, Tensor Logic | ✅ `HMH`/`FactorVSA`, `MORKTensorNetworks` |
| pattern mining | ✅ `WILLIAM` + Core miners |
| GEO-EVO, SubRep, concept-blending, TransWeave | ❌ not in the new stack (orphaned / old only) |
| Concept/Dynamics spaces, ontology guard, crystallization, sensory encoder, causal-do, bridges | ❌ only in the old `PRIMUS_WorldModeling` (reference) |
| **The two-loop wiring** | ❌ **this repo** (to build, scenario-driven) |
