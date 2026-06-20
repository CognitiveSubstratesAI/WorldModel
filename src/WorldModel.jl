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
program) and [`wm_query`](@ref) (support count of a pattern). Concrete backends live OUTSIDE this package (a
MeTTaCore in-process adapter, a server client, or a test mock), so WorldModel itself never takes a hard
dependency on the substrate and remains usable on its own.
"""
abstract type AbstractBackend end

"`wm_eval(backend, program)` — evaluate a MeTTa/program string on `backend`. Defined by a backend adapter."
function wm_eval end

"""
`wm_query(backend, pattern)` — SUPPORT count: how many atoms match `pattern` on `backend` (Hyperon
Whitepaper 2025 §7.3 `support`/`match-count`, counted without materializing the matches). Returns an
`Integer`. Defined by a backend adapter.
"""
function wm_query end

# ── The two-loop cognitive cycle ─────────────────────────────────────────────────────────────────────

"""
    CognitiveLoop(; backend=nothing)

The PRIMUS two-loop cognitive cycle (Whitepaper §4) over a pluggable `backend::AbstractBackend`. Holds the
live `attention` state (ECAN STI per atom) and a `tick` counter. Advance it with [`attention_step!`](@ref)
→ [`ambient_step!`](@ref) → [`blend_step!`](@ref) → [`pln_step!`](@ref) (the ambient loop), and
[`goal_step!`](@ref) (the goal-directed loop).

Scaffold: substrate Spaces and further component handles are added scenario-driven (`docs/decisions.md`).
"""
Base.@kwdef mutable struct CognitiveLoop{B}
    backend::B = nothing
    tick::Int = 0
    attention::Dict{String, Float64} = Dict{String, Float64}()
end

const _UNWIRED = "not yet wired — WorldModel is a scaffold; see docs/decisions.md for the wiring plan"

"""
    goal_step!(loop)

Advance the goal-directed loop one step: MetaMo motives → PLN explainable chains → MOSES/GEO-EVO program
proposal → PC forecasts → SubRep option certification. Stub until wired scenario-driven.
"""
goal_step!(::CognitiveLoop) = error("WorldModel.goal_step!: ", _UNWIRED)

"""
    attention_step!(loop; boost=Dict(), rent=0.1, focus_threshold=0.0) -> Vector{String}

The ambient loop's first step — ECAN attention diffusion (Hyperon Whitepaper 2025 §4 / §5.5). Updates the
loop's STI (short-term importance) over atoms: decays everything by `rent` (economic forgetting), adds
`boost` (wages for atoms that proved useful), then NORMALIZES so STI sums to unity — the §5.5 constraint
that "STI must sum to unity across the attentional focus" (the conservation / budget law). Returns the
**attentional focus**: atoms with STI strictly above `focus_threshold` — the candidates the rest of the
ambient loop (mining → blending → factor-PLN) should spend effort on.

Minimal slice: rent-decay + wage-boost + normalization → focus. Full Hebbian spreading-activation over a
link graph (§5.5; `Core/lib/ecan` `ecan-spread-step!`, MORKTensorNetworks `ecan_sti_spread!`) is richer.
"""
function attention_step!(
    loop::CognitiveLoop;
    boost::AbstractDict=Dict{String, Float64}(),
    rent::Real=0.1,
    focus_threshold::Real=0.0
)
    sti = loop.attention
    for k in keys(sti)
        sti[k] *= (1 - rent)                              # rent: economic decay (forgetting)
    end
    for (k, v) in boost
        sti[k] = get(sti, k, 0.0) + v                     # wages: boost useful atoms
    end
    total = sum(values(sti); init=0.0)
    if total > 0
        for k in keys(sti)
            sti[k] /= total                               # conservation: STI sums to unity (§5.5)
        end
    end
    loop.tick += 1
    return sort!(String[k for (k, v) in sti if v > focus_threshold])
end

"""
    ambient_step!(loop; candidates=String[], minsup=2) -> Vector{String}

One step of the ambient background loop (Hyperon Whitepaper 2025 §4): pattern mining **"spots recurring
structures"**. For each candidate pattern, read its support via the backend (the §7.3 `support` /
`match-count` op = [`wm_query`](@ref)), keep those with support `≥ minsup`, advance the loop tick, and
return the frequent (recurring) patterns.

This is the minimal mining slice of the ambient loop (ECAN → mining → concept blending → factor-PLN);
attention diffusion (ECAN), concept blending (`expand-conjunction`), and belief tightening (factor-PLN)
are later slices. Runs against any [`AbstractBackend`](@ref).
"""
function ambient_step!(
    loop::CognitiveLoop;
    candidates::AbstractVector{<:AbstractString}=String[],
    minsup::Integer=2
)
    loop.backend === nothing &&
        error("WorldModel.ambient_step!: no backend — inject one (see AbstractBackend)")
    frequent = String[p for p in candidates if wm_query(loop.backend, p) >= minsup]
    loop.tick += 1
    return frequent
end

# the dollar-variables two patterns share — the "generic space" they can blend over
function _shared_vars(p1::AbstractString, p2::AbstractString)
    vars(p) = Set(m.match for m in eachmatch(r"\$[A-Za-z0-9_]+", p))
    return intersect(vars(p1), vars(p2))
end

"""
    blend_step!(loop, patterns; minsup=2) -> Vector{String}

One step of concept blending (Hyperon Whitepaper 2025 §4 — "concept blending invents composites").
Combines pairs of patterns that SHARE A VARIABLE into composite conjunctions: the shared variable is the
"generic space" the two blend over, and the join `(, P1 P2)` is the category-theoretic **pushout** over
it (cf. the conceptBlending upstream's colimit blend; §7.3 `expand-conjunction`). Keeps composites whose
support via the backend ≥ `minsup` — a minimal optimality filter (well-supported, integrated blends).
Returns the composite blends.

Minimal substrate-native slice: the deterministic pushout-on-shared-vars + support filter, *without* the
LLM spec/morphism generation of the full category-theoretic pipeline. Richer blends (full colimit; the
Fauconnier-Turner optimality constraints — integration/topology/unpacking/good-reason) are later slices.
"""
function blend_step!(
    loop::CognitiveLoop, patterns::AbstractVector{<:AbstractString}; minsup::Integer=2
)
    loop.backend === nothing &&
        error("WorldModel.blend_step!: no backend — inject one (see AbstractBackend)")
    blends = String[]
    n = length(patterns)
    for i in 1:n, j in (i + 1):n
        isempty(_shared_vars(patterns[i], patterns[j])) && continue
        body = string(patterns[i], " ", patterns[j])
        wm_query(loop.backend, body) >= minsup && push!(blends, string("(, ", body, ")"))
    end
    loop.tick += 1
    return blends
end

"""
    pln_step!(loop, patterns; k=1) -> Vector{Tuple{String,Int,Float64}}

One step of factor-graph PLN belief tightening (Hyperon Whitepaper 2025 §4 / §1b). For each pattern, read
its evidence count via the backend (support) and derive a count-based **truth value** — the §1b point that
"evidence counts … fall out from the quantale structure": confidence `= n / (n + k)` rises with evidence
`n`. Returns `(pattern, count, confidence)` triples — the tightened beliefs.

Minimal slice: the leaf evidence→TV (count-based confidence). The full factor-graph propagation — quantale
product `⊗` at factor atoms, sum `⊕` at variable atoms over the blends (§1b) — and strength from ±evidence
are richer slices that the substrate's PLN (`Core/lib/pln`) provides; this slice orchestrates the leaf TVs.
"""
function pln_step!(
    loop::CognitiveLoop, patterns::AbstractVector{<:AbstractString}; k::Real=1
)
    loop.backend === nothing &&
        error("WorldModel.pln_step!: no backend — inject one (see AbstractBackend)")
    beliefs = Tuple{String, Int, Float64}[]
    for p in patterns
        n = wm_query(loop.backend, p)
        push!(beliefs, (p, n, n / (n + k)))
    end
    loop.tick += 1
    return beliefs
end

"""
    run_ambient!(loop; candidates, minsup=2, rent=0.1, focus_threshold=0.0, k=1)
        -> (; focus, frequent, blends, beliefs)

Run ONE full ambient cycle (Hyperon Whitepaper 2025 §4): **ECAN attention → mining → blending →
factor-PLN**, threading each step's output into the next and **closing the attention feedback** — the
believed atoms are waged back into the loop's STI, so useful structure keeps attention across cycles.
`candidates` are the patterns to consider this cycle (boosted into attention). Returns the cycle's
attentional `focus`, the `frequent` patterns, the `blends`, and the `beliefs`.

Call it repeatedly (the loop carries its `attention` STI forward) to run the self-feeding ambient loop.
"""
function run_ambient!(
    loop::CognitiveLoop;
    candidates::AbstractVector{<:AbstractString},
    minsup::Integer=2,
    rent::Real=0.1,
    focus_threshold::Real=0.0,
    k::Real=1
)
    boost = Dict{String, Float64}(string(c) => 1.0 for c in candidates)
    focus = attention_step!(loop; boost=boost, rent=rent, focus_threshold=focus_threshold)
    frequent = ambient_step!(loop; candidates=focus, minsup=minsup)
    blends = blend_step!(loop, frequent; minsup=minsup)
    beliefs = pln_step!(loop, frequent; k=k)
    for (p, _n, c) in beliefs
        loop.attention[p] = get(loop.attention, p, 0.0) + c   # wage: believed atoms keep attention
    end
    return (; focus, frequent, blends, beliefs)
end

export AbstractBackend, wm_eval, wm_query, CognitiveLoop, goal_step!
export attention_step!, ambient_step!, blend_step!, pln_step!, run_ambient!

end # module WorldModel
