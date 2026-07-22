# Loops.jl — the two-loop × three-rate cognitive cycle over the braid (§3.1, §3.4, §6.1.4).
#
# PRIMUS runs two interleaved meta-dynamics (§3.1): a GOAL-directed loop (maintain motives, bind a focused
# subnetwork, act + check progress) and an AMBIENT loop (mine / tighten / consolidate in the background),
# at three timescales (§3.4): FAST (ms — Sdyn reflex, NO full Atomspace query per tick), MID (10s–100s ms
# — the goal cycle: ground → encode → lift → summarize → condition), SLOW (s–h — the ambient cycle:
# re-validate stale beliefs → consolidate memory). Every step drives the REAL braid operators on the real
# substrate. The decision PROCESSES (PLN action-selection in mid, WILLIAM mining in slow) are explicit
# hooks, bound when those per-Space algorithm processes land — absent here rather than mocked.

module Loops

using ..Registry: SpaceRegistry, dense_store, hmh_index, has_space
using ..Braid:
    store_evidence!, ground!, encode_hmh!, lift!, kernel_summary!, predict_dynamics
using ..Beliefs: stale_beliefs, revalidate_belief!
using ..Dense: has_predictor, get_vec
using ..HMHStore: consolidate!
using ..PLNCore: select_action          # canonical multi-hop action-selection (delegates to lib/pln)
using ..MetaMoCore: govern              # canonical MetaMo goal governance (delegates to lib/metamo)
using ..Mining: mine!
using ..SubRepCore: admit_proposed!     # ambient SubRep option certification (delegates to lib/subrep)
using ..MOSES: geo_synthesize!, geo_synthesize_geometric!   # Julia GA | canonical geometric geo_step! engine
using Random: default_rng

export CognitiveLoop, Observation, fast_step!, mid_step!, slow_step!, run_cycle!

"""
    Observation(payload, modality, entity_key, entity_atom, episode_key, slots)

One environment observation to feed the goal loop: a raw `payload` (modality `modality`) plus the symbolic
hypotheses Γ should ground (entity id `entity_key`, atom `entity_atom`) and the role-filler `slots`
(`role => (type, filler)`) to encode as an HMH episode `episode_key`.
"""
struct Observation
    payload::String
    modality::String
    entity_key::String
    entity_atom::String
    episode_key::Symbol
    slots::Dict{Symbol, Tuple{Symbol, Symbol}}
end

"The live cognitive loop over a Space registry: the tick counter + the current Sctx context-vector key."
mutable struct CognitiveLoop
    reg::SpaceRegistry
    tick::Int
    context::Union{Symbol, Nothing}
end
CognitiveLoop(reg::SpaceRegistry) = CognitiveLoop(reg, 0, nothing)

"""
    fast_step!(loop; rng) -> Vector{Float64} | nothing

FAST path (§3.4, ms): the Sdyn reflex — run the predictive-coding controller forward on the current Sctx
context vector, with NO Atomspace query. Returns the prediction, or `nothing` if no context/predictor is
in place yet. Always advances the tick.
"""
function fast_step!(loop::CognitiveLoop; kwargs...)
    loop.tick += 1
    loop.context === nothing && return nothing
    has_space(loop.reg, :Sdyn) && has_predictor(dense_store(loop.reg, :Sdyn)) ||
        return nothing
    x = get_vec(dense_store(loop.reg, :Sctx), loop.context)
    return predict_dynamics(loop.reg, x; kwargs...)
end

"""
    mid_step!(loop, obs; ctx_key=:ctx) -> NamedTuple

MID path (§3.4 / §6.1.4): the GOAL-directed cycle — store evidence (Sevid), ground the entity (Γ → Sent,
evidence-anchored), encode the trial as an HMH episode (𝓔ₕₘₕ → Shmh), and lift the densified retrieval into
a context vector (Λ → Sctx) that becomes the loop's current context for the fast reflex. The goal is
MOTIVE-GOVERNED: when a `governor` `(; goals, mods, stimulus, candidates)` is supplied and no explicit
`goal`, canonical MetaMo (`metamoGovern`: Ψ appraise → 𝔻 decide → safe-project) SELECTS the goal from the
OpenPsi motive state (§A.9 / infrastructure: S_motive → MetaMo → action selection). PLN then backward-chains
over Srule to select an action for it. Returns `(; cid, context, context_vector, action, goal, governance)`.
"""
function mid_step!(
    loop::CognitiveLoop, obs::Observation; ctx_key::Symbol=:ctx, goal=nothing, governor=nothing
)
    reg = loop.reg
    cid = store_evidence!(reg, obs.payload; modality=obs.modality)
    ground!(reg, obs.entity_key, obs.entity_atom, cid)
    encode_hmh!(reg, obs.episode_key, obs.slots; pointers=["Sent:$(obs.entity_key)"])
    v = lift!(reg, ctx_key, obs.slots)
    loop.context = ctx_key
    loop.tick += 1
    governance = governor === nothing ? nothing :              # MetaMo governs WHICH goal to pursue
        govern(governor.goals, governor.mods, governor.stimulus, governor.candidates)
    goal === nothing && governance !== nothing && (goal = governance.chosen)
    acts = goal === nothing ? [] : select_action(reg, goal)    # PLN action-selection over Srule
    return (;
        cid=cid,
        context=ctx_key,
        context_vector=v,
        action=(isempty(acts) ? nothing : first(acts)),
        goal=goal,
        governance=governance
    )
end

"""
    slow_step!(loop; t, threshold=0.3, lambda=0.1, template_key=:template) -> NamedTuple

SLOW path (§3.4 / §6.1.4): the AMBIENT cycle — re-validate stale beliefs (R10: confidence decayed below
`threshold` at time `t`), consolidate Shmh episodes into a template (schema formation), MINE recurring
patterns (WILLIAM over `mine_from` → Smine), CERTIFY proposed option-candidates through canonical SubRep
(lib/subrep CDS+PDS) into Sopt, and — when a `synthesis` task is supplied — SYNTHESIZE a program into
Sprog via the unified `geo_synthesize!` entry. The synthesis MODE follows the spec's two-ends principle:
no backward subgoals ⇒ MOSES (`Score = F − γW`); backward subgoals + `μ>0` ⇒ GEO-EVO
(`Score = F − γW + μ·align`). `synthesis` is a NamedTuple `(; fitness, weakness, primitives[, gamma, mu,
subgoals, rng])`. Returns `(; stale, revalidated, consolidated, mined, admitted, synthesized)`.
Advances the tick.

`stale` are the beliefs whose confidence decayed below `threshold`; `revalidated` are the ones actually
REFRESHED from surviving evidence this step (≤ `revalidate`, the ambient budget). A stale key with no
evidence left is deliberately absent from `revalidated` — it keeps decaying rather than being propped up.
"""
function slow_step!(loop::CognitiveLoop; t::Real, threshold::Real=0.3, lambda::Real=0.1,
    template_key::Symbol=:template, mine_from::Symbol=:Sent, k::Int=5, eps_pds::Real=0.1,
    revalidate::Int=16, synthesis=nothing)
    reg = loop.reg
    stale = stale_beliefs(reg, t; threshold=threshold, lambda=lambda)
    # R10 CLOSES THE LOOP: re-validate the decayed beliefs instead of only reporting them. Until now
    # `stale` was computed and returned and NOTHING consumed it (the only reference to `.stale` in the
    # whole codebase was the return below), so §7's "factor-graph PLN tightens beliefs" was
    # detection-only. Budgeted (`revalidate`) because this is ambient background work, not a barrier:
    # each key costs an evidence lookup, and a symbol with no surviving evidence is deliberately left
    # to keep decaying (revalidate_belief! returns nothing) rather than propped up.
    revalidated = String[]
    for key in Iterators.take(stale, max(revalidate, 0))
        revalidate_belief!(reg, key, t; into=:Srule) === nothing || push!(revalidated, key)
    end
    consolidated = consolidate!(hmh_index(reg, :Shmh), template_key)
    mined = mine!(reg; from=mine_from, k=k)            # WILLIAM mining → Smine
    admitted = admit_proposed!(reg; eps_pds=eps_pds)   # canonical SubRep CDS+PDS → Sopt
    synthesized = synthesis === nothing ? nothing :    # engine=:geometric ⇒ canonical geo_step!; else Julia GA
        (get(synthesis, :engine, :julia) === :geometric ?
            geo_synthesize_geometric!(reg, synthesis.fitness, synthesis.primitives;
                subgoals=get(synthesis, :subgoals, Any[]), goal=get(synthesis, :goal, :G),
                recombine=get(synthesis, :recombine, false), rng=get(synthesis, :rng, default_rng())) :
            geo_synthesize!(reg, synthesis.fitness, synthesis.weakness, synthesis.primitives;
                gamma=get(synthesis, :gamma, 0.3), mu=get(synthesis, :mu, 0.0),
                subgoals=get(synthesis, :subgoals, Any[]), rng=get(synthesis, :rng, default_rng())))
    loop.tick += 1
    return (; stale=stale, revalidated=revalidated, consolidated=consolidated, mined=mined,
        admitted=admitted, synthesized=synthesized)
end

"""
    run_cycle!(loop; observation=nothing, t=0.0, fast=2, kwargs...) -> NamedTuple

One full multi-rate cycle (§3.1 × §3.4): `fast` Sdyn reflex steps, then one goal-directed mid-step (if an
`observation` is supplied), then one ambient slow-step at time `t`. Returns `(; mid, slow, tick)`.
"""
function run_cycle!(loop::CognitiveLoop; observation::Union{Observation, Nothing}=nothing,
    goal=nothing, t::Real=0.0, fast::Int=2, kwargs...)
    for _ in 1:fast
        fast_step!(loop; kwargs...)
    end
    mid = observation === nothing ? nothing : mid_step!(loop, observation; goal=goal)
    slow = slow_step!(loop; t=t)
    return (; mid=mid, slow=slow, tick=loop.tick)
end

end # module Loops
