# WorldModel

The live **PRIMUS** world-modeling application over the CognitiveSubstratesAI substrate — a running,
stateful **two-loop cognitive system** (Hyperon Whitepaper 2025, §4).

!!! note "Standalone by design"
    WorldModel has **no hard package dependencies**. It loads on a bare Julia and connects to substrate
    capabilities (MeTTa evaluation, MORK spaces, the algorithm libraries) through a pluggable
    [`AbstractBackend`](@ref) injected at **runtime** — so anyone can clone and use it on its own,
    against any backend (an in-process `MeTTaCore` adapter, a `MorkServer`/`MettaJam` socket client, or a
    mock for tests). It is an *application* that composes the substrate, never a library that depends on it.

## Architecture

The cognitive cycle is two interacting loops over a shared memory substrate (the 13 Spaces of §7):

- **Goal-directed loop** — MetaMo motives → PLN explainable chains → MOSES / GEO-EVO program proposal →
  PC (Active Predictive Coding) forecasts → SubRep option certification.
- **Ambient background loop** — ECAN attention diffusion → pattern mining (WILLIAM) → concept blending →
  factor-graph PLN belief tightening.
- **Shared controls** — geodesic control (forward-reachability × backward-usefulness) and quantale
  weakness (an Occam prior favouring simpler, more transferable structure).

The component algorithms already exist as reusable libraries in the substrate; WorldModel wires them into
the loop **scenario-driven** (e.g. Minecraft affordance discovery, social-robot anti-hallucination) —
building only the slice a concrete scenario needs, never loop-first-blind. See the
[Architecture Decision](decisions.md) for the rationale and the built-vs-spec map.

## Status

The **ambient loop** is complete and self-feeding — [`attention_step!`](@ref) (ECAN) →
[`ambient_step!`](@ref) (mining) → [`blend_step!`](@ref) (blending) → [`pln_step!`](@ref) (factor-PLN),
orchestrated by [`run_ambient!`](@ref), which closes the feedback (believed atoms are waged back as
attention). The **goal-directed loop** has its first slice — [`goal_step!`](@ref) plans toward a goal over
the discovered affordances, certified against the substrate. Both are demonstrated end-to-end on a working
scenario (see [Affordance Discovery](scenarios.md)).

Each step is the *minimal substrate-native slice* of its §4 component; richer slices live in the substrate
libraries and are wired in scenario-driven. The pluggable-backend seam is tested against a mock backend
(WorldModel runs standalone) and every slice is smoke-tested end-to-end through the real `MeTTaCore`
substrate.
