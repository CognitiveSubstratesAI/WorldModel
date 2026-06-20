# WorldModel — the live PRIMUS world-modeling application.
#
# STANDALONE BY DESIGN. This package has NO hard package dependencies: clone it and it loads on a bare
# Julia. It is an APPLICATION (a live, stateful cognitive system), not a reusable library — and it stays
# dependency-free by talking to substrate capabilities (MeTTa evaluation, MORK spaces, the algorithm
# libraries) through a PLUGGABLE `AbstractBackend` injected at RUNTIME. So anyone can use it on its own,
# against whatever backend they have (an in-process MeTTaCore adapter, a MorkServer/MettaJam socket
# client, or a mock for tests). Per the architecture decision (docs/decisions.md), it lives in its own
# repo so application glue + live state never pollute — and never depend on — the substrate libraries.
#
# Architecture (Hyperon Whitepaper 2025 §4 two-loop):
#   Goal-directed loop:  MetaMo → PLN → MOSES / GEO-EVO → PC (ActPC) → SubRep
#   Ambient loop:        ECAN → pattern mining (WILLIAM) → concept blending → factor-graph PLN
#   Shared controls:     geodesic control · quantale-weakness (Occam prior)
#   Memory substrate:    13 Spaces (§7 / vibe-eng Appendix A) — Senv/Sevid/Sent/Smap/Srule/Shmh/…
#
# STATUS: scaffold. The loop is wired SCENARIO-DRIVEN (Minecraft affordance discovery / social-robot
# anti-hallucination), building only the slice a concrete scenario needs (measure-first).

module WorldModel

const WORLDMODEL_VERSION = v"0.1.0"

# ── The loose-coupling seam: a pluggable backend (keeps WorldModel dependency-free) ──────────────────

"""
    AbstractBackend

The seam between the standalone WorldModel application and whatever substrate runs underneath. A backend
provides the capabilities the cognitive loop needs — at minimum [`wm_eval`](@ref) (evaluate a MeTTa
program) and [`wm_query`](@ref) (match a pattern). Concrete backends live OUTSIDE this package (a
MeTTaCore in-process adapter, a server client, or a test mock), so WorldModel itself never takes a hard
dependency on the substrate and remains usable on its own.
"""
abstract type AbstractBackend end

"`wm_eval(backend, program)` — evaluate a MeTTa/program string on `backend`. Defined by a backend adapter."
function wm_eval end

"`wm_query(backend, pattern)` — match `pattern` on `backend`. Defined by a backend adapter."
function wm_query end

# ── The two-loop cognitive cycle ─────────────────────────────────────────────────────────────────────

"""
    CognitiveLoop(; backend=nothing)

The PRIMUS two-loop cognitive cycle (Whitepaper §4) over a pluggable `backend::AbstractBackend`. Advance
it with [`goal_step!`](@ref) (goal-directed loop) and [`ambient_step!`](@ref) (ambient background loop).

Scaffold: substrate Spaces, component handles, and loop state are added scenario-driven (`docs/decisions.md`).
"""
Base.@kwdef mutable struct CognitiveLoop{B}
    backend::B = nothing
    tick::Int = 0
end

const _UNWIRED = "not yet wired — WorldModel is a scaffold; see docs/decisions.md for the wiring plan"

"""
    goal_step!(loop)

Advance the goal-directed loop one step: MetaMo motives → PLN explainable chains → MOSES/GEO-EVO program
proposal → PC forecasts → SubRep option certification. Stub until wired scenario-driven.
"""
goal_step!(::CognitiveLoop) = error("WorldModel.goal_step!: ", _UNWIRED)

"""
    ambient_step!(loop)

Advance the ambient background loop one step: ECAN attention diffusion → pattern mining (WILLIAM) →
concept blending → factor-graph PLN belief tightening. Stub until wired scenario-driven.
"""
ambient_step!(::CognitiveLoop) = error("WorldModel.ambient_step!: ", _UNWIRED)

export AbstractBackend, wm_eval, wm_query, CognitiveLoop, goal_step!, ambient_step!

end # module WorldModel
