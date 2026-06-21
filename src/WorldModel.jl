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
#   Memory substrate:    14 Spaces (PRIMUS-world-modeling_v2 §4.2) — Senv/Sevid/Sent/Smap/Srule/Shmh/…
#                        a HETEROGENEOUS braid (each Space on its own substrate), wired by the bridging
#                        operators Γ/Λ/𝓔/𝓓/𝓤 + observe/act/summarize. Algorithms = per-Space processes.
#
# STATUS: the INFRASTRUCTURE SKELETON is built — 14-Space registry (wm_space/Spaces/init_spaces!) + the
# braid operators (Γ/Λ/𝓔/𝓓/𝓤 + observe/act/summarize) + the two-loop×three-rate cycle (fast/mid/slow_step!,
# world_cycle!). SubRep→Sopt is the first bound service; the rest (PLN→Srule, MOSES→Sprog, WILLIAM→Smine,
# HMH→Shmh, FabricPC→Sdyn, MetaMo→Smotive, kernel→Skernel) bind the same way. The ambient loop is complete
# + self-feeding; the goal loop has goal_step!/plan_goal!. Wired SCENARIO-DRIVEN (Minecraft affordance
# discovery / social-robot anti-hallucination), building only the slice a concrete scenario needs.

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

# ── The 14 world-model Spaces — the substrate skeleton (PRIMUS-world-modeling_v2 §4.2) ───────────────
#
# The world model is a BRAIDED object, not a monolith (§3.3): a HETEROGENEOUS set of Spaces, each a
# memory+computation regime with distinct invariants / time-scale / query-primitive / failure-mode
# (Appendix A §A.1). They interlock via shared IDs + content addressing + shared truth-value/certificate
# annotations + the bridging operators (Γ grounding, Λ lifting, 𝓔_hmh, 𝓓_hmh, 𝓤_hmh). Each Space's
# PROCESSES are the algorithm services (PLN→Srule, SubRep→Sopt, MOSES→Sprog, WILLIAM→Smine, …) bound later.

"""Representational species / regime of a Space (§3.2, §4.2): symbolic-primary, dense-primary,
HMH-primary, plus the evidence store and the environment I/O boundary."""
@enum SpaceKind SYMBOLIC DENSE HMH EVIDENCE ENVIO

"""The canonical 14 world-model Spaces (PRIMUS-world-modeling_v2 §4.2): `(name, kind, role)`."""
const WM_SPACES = (
    (:Senv, ENVIO, "environment interface — observations o_t / actions a_t"),
    (
        :Sevid,
        EVIDENCE,
        "evidence store — immutable shards (id,modality,t,payload,CID) [R2]"
    ),
    (:Sent, SYMBOLIC, "entities + relations — persistent identity hypotheses [R1,R4]"),
    (:Smap, SYMBOLIC, "spatiotemporal map — layout, time stamps, staleness decay [R6,R10]"),
    (:Srule, SYMBOLIC, "rules + uncertain inference — PLN facts/rules/norms [R4,R7,R10]"),
    (:Shmh, HMH, "HMH associative index — episodes/skills/affordances [R3,R5,R6,R11]"),
    (:Sctx, DENSE, "dense context latents — context vectors + 𝓓_hmh outputs [R3]"),
    (:Sdyn, DENSE, "predictive dynamics + control — fast path, PC nets [R7,R11]"),
    (:Smotive, SYMBOLIC, "motives + certificates — MetaMo objectives (governs both loops)"),
    (:Sopt, SYMBOLIC, "options/subgoals — SubRep-admitted skills + certificates [R5]"),
    (:Sxfer, SYMBOLIC, "transfer/composition — TransWeave artifacts [R9]"),
    (:Sprog, SYMBOLIC, "program space — MOSES/GEO-EVO evolved macros [R5]"),
    (:Smine, SYMBOLIC, "pattern mining/compression — WILLIAM service [R5,R11]"),
    (:Skernel, DENSE, "kernel/MKME — set→vector summaries (cross-cutting service)")
)

"""
    wm_space(backend, name::Symbol, kind::SpaceKind)

Create (or fetch) a handle to a Space of the given `kind` on `backend`. A backend adapter maps each kind
to its substrate: SYMBOLIC/EVIDENCE → a prefix-scoped MORK `CoreSpace` (`new_core_space(shared, prefix)`);
DENSE → a FabricPC dense store; HMH → an HMH index; IO → a scenario channel. A mock backs all kinds for
tests. WorldModel never hard-deps any substrate — it only addresses Spaces through this seam.
"""
function wm_space end

"""The live registry of the 14 Spaces: `name → backend handle` (+ each Space's [`SpaceKind`](@ref))."""
struct Spaces
    handles::Dict{Symbol, Any}
    kinds::Dict{Symbol, SpaceKind}
end

"Create all 14 world-model Spaces on `backend` (each via [`wm_space`](@ref)); returns the [`Spaces`](@ref) registry."
function init_spaces!(backend)
    handles = Dict{Symbol, Any}()
    kinds = Dict{Symbol, SpaceKind}()
    for (name, kind, _role) in WM_SPACES
        handles[name] = wm_space(backend, name, kind)
        kinds[name] = kind
    end
    return Spaces(handles, kinds)
end

"Handle to Space `name` in the registry."
space(s::Spaces, name::Symbol) = s.handles[name]
"The [`SpaceKind`](@ref) of Space `name`."
space_kind(s::Spaces, name::Symbol) = s.kinds[name]

# ── The two-loop cognitive cycle ─────────────────────────────────────────────────────────────────────

"""
    CognitiveLoop(; backend=nothing, spaces=nothing)

The PRIMUS two-loop cognitive cycle (Whitepaper §4) over a pluggable `backend::AbstractBackend` and the
14-Space substrate registry `spaces::Spaces` (build it with [`init_spaces!`](@ref)). Holds the live
`attention` state (ECAN STI per atom) and a `tick` counter. Advance it with [`attention_step!`](@ref)
→ [`ambient_step!`](@ref) → [`blend_step!`](@ref) → [`pln_step!`](@ref) (the ambient loop), and
[`goal_step!`](@ref) / [`plan_goal!`](@ref) (the goal-directed loop).
"""
Base.@kwdef mutable struct CognitiveLoop{B}
    backend::B = nothing
    spaces::Union{Nothing, Spaces} = nothing
    tick::Int = 0
    attention::Dict{String, Float64} = Dict{String, Float64}()
    sopt::Vector{Any} = []   # Sopt contents: SubRep-certified options (id, Δr, Δn)
end

# ── Bridging operators — the EDGES of the inter-space braid (§4.3–4.6, the diagram) ──────────────────
#
# The Spaces are interlocked by a small set of operators (the diagram's arrows). Each is a generic
# function implemented by a backend adapter / bound service; WorldModel defines the CONTRACT + the braid
# that wires the Spaces. Real implementations need the substrate (perception for Γ, HMH for 𝓔/𝓓/𝓤); a
# mock backs them for tests. The braid: Senv→Sevid→(Sent/Smap/Srule)→Shmh→kernel→Sctx→Sdyn→actions.

"`observe!(backend, spaces)` — read the latest observation `o_t` from Senv and store it as immutable
evidence `(id,modality,t,payload,CID)` in Sevid (R2). Returns the evidence id(s)."
function observe! end

"`act!(backend, spaces, action)` — issue action `a_t` to Senv (from Sdyn fast path / planner)."
function act! end

"Γ grounding (§4.4): `ground!(backend, spaces, evidence)` — `(Sevid×Sdyn×Sctx)→P(Atom)`: propose candidate
atoms (TV + evidence pointers) → compete/merge identity hypotheses → audit provenance; consolidate into
Sent/Smap/Srule, evidence-anchored. Returns the grounded atoms."
function ground! end

"𝓔_hmh (§4.4): `encode_hmh!(backend, spaces, atoms)` — `(Atom*×Sevid)→{±1}^D`: compile an evidence-anchored
symbolic subgraph (roles/fillers/constraints/time) into an HMH record in Shmh (key + pointers back)."
function encode_hmh! end

"𝓓_hmh (§4.5, App B): `densify(backend, item)` — map an HMH item to a dense DUAL-CHANNEL vector
`x = [x_A ‖ x_G]` (algebra-preserving ‖ geometry-enhancing) for Sctx."
function densify end

"𝓤_hmh: `unbind(backend, item)` — approximate unbinding of an HMH item to propose candidate symbolic
structure when needed (HMH → Sent/Srule hypotheses)."
function unbind end

"Λ lifting (§4.5): `lift(backend, spaces, atoms)` — `(Atom*×Shmh×Srule×Smotive)→(Sctx×G)`: map the active
symbolic context (+ HMH retrieval + motive state) into a context vector `c∈Sctx` and a gating pattern
`g∈G` that configures which Sdyn neural modules are active/learned."
function lift end

"Kernel/MKME (§4.5, App C): `summarize(backend, items)` — set→vector: kernel-mean / MKME summary `μ_R` of
a set of (HMH/symbolic) items, with relevance weights for gating + re-ranking (the cross-cutting layer)."
function summarize end

# ── Sopt — the certified-options Space: SubRep admission bound in (§A.10, §4.9) ──────────────────────
#
# Sopt holds reusable skills/macros admitted via SubRep certification; its dominant processes are option
# selection + CERTIFICATE CHECKING. This binds the Core SubRep gate (lib/subrep) as the first algorithm
# service in the braid — the session's CDS/PDS work, finally with a home.

"`wm_admit(backend, Δr, Δn, ε)` → Bool: run the SubRep CDS admission gate (Core `lib/subrep`). Admit the
option iff it beats the baseline over the motive cone (margin ≥ −ε). The backend backs this with the gate."
function wm_admit end

"""
    admit_option!(loop, id, Δr, Δn; ε=0.0) -> Bool

Sopt's admission process (§A.10 / §4.9): screen an option — its expectation-model improvement `(Δr, Δn)`
over the baseline — through the SubRep CDS gate ([`wm_admit`](@ref)); if it passes, store the certified
option in Sopt (`loop.sopt`). Returns whether it was admitted. The certificate survives composition (§7.1).
"""
function admit_option!(loop::CognitiveLoop, id, dr, dn; eps::Real=0.0)
    admitted = wm_admit(loop.backend, dr, dn, eps)
    admitted && push!(loop.sopt, (; id=id, dr=Float64(dr), dn=collect(Float64, dn)))
    return admitted
end

"""
    select_options(loop, w; thresh=0.0) -> Vector

Sopt's option-selection process (§A.10): under the CURRENT motive weights `w`, return the certified options
whose backed-up improvement `Δr + wᵀΔn ≥ thresh`, best first — zero-shot reuse of the SAME certificates
under a motive shift, with no recertification (mirrors `Core/lib/subrep/store.metta`)."""
function select_options(loop::CognitiveLoop, w::AbstractVector; thresh::Real=0.0)
    scored = [(o, o.dr + sum(w .* o.dn)) for o in loop.sopt]
    sort!(scored; by=x -> -x[2])
    return [o for (o, v) in scored if v >= thresh]
end

# ── The cognitive cycle — two loops × three timescales over the braid (§3.1, §3.4) ───────────────────
#
# The world model runs two interleaved loops (§3.1) at three rates (§3.4). Each rate-step wires the braid
# operators + the Space services; `world_cycle!` schedules them. Symbolic reasoning is a SUPERVISOR on an
# appropriate timescale while the low-latency substrate maintains stability/safety (the fast path).

"""Fast path (§3.4, ms): the Sdyn reflex/servo loop — observe → low-latency control → act, WITHOUT a full
Atomspace query on each tick. Returns the action issued."""
function fast_step!(loop::CognitiveLoop; action=:noop)
    observe!(loop.backend, loop.spaces)              # Senv → Sevid (o_t)
    act!(loop.backend, loop.spaces, action)          # Sdyn → Senv (a_t), low-latency
    loop.tick += 1
    return action
end

"""Mid path (§3.4, tens–hundreds of ms): the GOAL-directed cycle — ground evidence to atoms (Γ), lift to a
context vector + gating (Λ, binding a focused subnetwork, §3.1), and select a certified option (Sopt) under
the current motive weights `w`. Returns `(; atoms, context, gating, options)`."""
function mid_step!(loop::CognitiveLoop, evidence; w::AbstractVector=Float64[])
    atoms = ground!(loop.backend, loop.spaces, evidence)       # Γ: Sevid → Sent/Smap/Srule
    c, g = lift(loop.backend, loop.spaces, atoms)              # Λ: → Sctx context + gating
    options = isempty(w) ? loop.sopt : select_options(loop, w) # Sopt option selection
    loop.tick += 1
    return (; atoms=atoms, context=c, gating=g, options=options)
end

"""Slow path (§3.4, seconds–hours): the AMBIENT loop — mine patterns, blend concepts, tighten beliefs, and
consolidate memory ([`run_ambient!`](@ref): ECAN → mining → blending → factor-PLN), in the background."""
function slow_step!(loop::CognitiveLoop; candidates::AbstractVector=String[], minsup::Int=2)
    return run_ambient!(loop; candidates=candidates, minsup=minsup)
end

"""
    world_cycle!(loop; evidence, w, action, candidates, fast=2, mid=2) -> NamedTuple

One full multi-rate cognitive cycle (§3.1 × §3.4): `fast` fast-steps per mid-step, `mid` goal-directed
mid-steps, then one slow ambient step. This is the world-model's interleaved goal + ambient loops running
over the braided Spaces at the three timescales. Returns the last mid result + the ambient result."""
function world_cycle!(loop::CognitiveLoop; evidence=nothing, w::AbstractVector=Float64[],
    action=:noop, candidates::AbstractVector=String[], fast::Int=2, mid::Int=2)
    local mres
    for _ in 1:mid
        for _ in 1:fast
            fast_step!(loop; action=action)
        end
        mres = mid_step!(loop, evidence; w=w)
    end
    ambient = slow_step!(loop; candidates=candidates)
    return (; mid=mres, ambient=ambient)
end

# split a conjunction "(, P1 P2 …)" into its clause strings (ASCII s-expressions)
function _conj_clauses(s::AbstractString)
    s = strip(s)
    startswith(s, "(,") || return [String(s)]
    inner = s[3:(end - 1)]                              # drop the leading "(," and trailing ")"
    clauses = String[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            print(buf, c)
        elseif c == ')'
            depth -= 1
            print(buf, c)
        elseif c == ' ' && depth == 0
            t = strip(String(take!(buf)))
            isempty(t) || push!(clauses, t)
        else
            print(buf, c)
        end
    end
    t = strip(String(take!(buf)))
    isempty(t) || push!(clauses, t)
    return clauses
end

# the predicate head of a pattern "(pred …)" → "pred"
function _head(p::AbstractString)
    m = match(r"^\(\s*([^\s()]+)", strip(p))
    return m === nothing ? String(strip(p)) : String(m.captures[1])
end

# flat-token structural match: same arity, constants must agree, `$`-tokens are wildcards.
# (Patterns here are flat s-expressions like `(yields $o wood)`; nesting would be flattened.)
_tokens(p::AbstractString) = split(replace(strip(p), '(' => ' ', ')' => ' '))
function _matches(a::AbstractString, b::AbstractString)
    ta, tb = _tokens(a), _tokens(b)
    length(ta) == length(tb) || return false
    for (x, y) in zip(ta, tb)
        (startswith(x, '$') || startswith(y, '$') || x == y) || return false
    end
    return true
end

"""
    goal_step!(loop, goal; affordances, beliefs=Dict()) -> Vector{Tuple{String,Float64}}

One step of the goal-directed loop (Hyperon Whitepaper 2025 §4): given a `goal` — a desired outcome
pattern, the MetaMo *motive* — search the discovered `affordances` (the ambient loop's composites, the
PLN/knowledge) for ones whose OUTCOME clause matches the goal's predicate, and propose their ACTION
clause as a program (the MOSES role). Each proposal is CERTIFIED (the SubRep role) by an affordance
confidence: an explicit override in `beliefs`, else — when a `backend` is wired — the affordance is
checked against the substrate (support `n` of its join body → §1b confidence `n/(n+1)`), else `1`.
Returns the certified `(action, confidence)` options, most-certified first.

Minimal slice: affordance-based backward lookup over the ambient loop's output (goal → action), certified
by substrate support. Full PLN backward chaining, MOSES program search, PC forecasting are richer slices.
"""
function goal_step!(
    loop::CognitiveLoop,
    goal::AbstractString;
    affordances::AbstractVector{<:AbstractString},
    beliefs::AbstractDict=Dict{String, Float64}()
)
    options = Tuple{String, Float64}[]
    for aff in affordances
        clauses = _conj_clauses(aff)
        length(clauses) >= 2 || continue
        action, outcome = clauses[1], clauses[end]
        _matches(outcome, goal) || continue           # the affordance's outcome matches the goal
        conf = if haskey(beliefs, aff)
            Float64(beliefs[aff])                     # explicit belief override
        elseif loop.backend !== nothing
            n = wm_query(loop.backend, join(clauses, " "))  # SubRep: certify against the substrate
            n / (n + 1)                                     # §1b evidence → confidence
        else
            1.0
        end
        push!(options, (action, Float64(conf)))       # propose the action, certified
    end
    sort!(options; by=x -> -x[2])                     # most-certified options first
    loop.tick += 1
    return options
end

# belief of an affordance/rule: explicit override, else the prior (rules need not be ground facts)
_affordance_belief(beliefs, aff, prior) = Float64(get(beliefs, aff, prior))

# recursive backward chaining (no tick mutation — the public plan_goal! ticks once)
function _plan(loop, g, affordances, beliefs, prior, max_depth, seen)
    if loop.backend !== nothing && wm_query(loop.backend, g) > 0
        return (; goal=g, steps=String[], confidence=1.0)          # already true in the substrate
    end
    (max_depth <= 0 || g in seen) && return nothing                # depth / cycle guard
    seen2 = push!(copy(seen), g)
    best = nothing
    for aff in affordances
        clauses = _conj_clauses(aff)
        length(clauses) >= 2 || continue
        _matches(clauses[end], g) || continue          # rule's OUTCOME matches the goal
        action = clauses[end - 1]                      # the action that achieves it
        preconds = clauses[1:(end - 2)]                # remaining clauses = subgoals
        steps = String[]
        conf = _affordance_belief(beliefs, aff, prior)
        reachable = true
        for pc in preconds
            sp = _plan(loop, pc, affordances, beliefs, prior, max_depth - 1, seen2)
            if sp === nothing
                reachable = false
                break
            end
            append!(steps, sp.steps)                   # do the subgoal's actions first…
            conf *= sp.confidence
        end
        reachable || continue
        push!(steps, String(action))                   # …then the action that consumes them
        cand = (; goal=g, steps=steps, confidence=conf)
        if best === nothing || cand.confidence > best.confidence
            best = cand                                # keep the most-certified plan
        end
    end
    return best
end

"""
    plan_goal!(loop, goal; affordances, beliefs=Dict(), prior=0.9, max_depth=8)
        -> Union{Nothing, @NamedTuple{goal::String, steps::Vector{String}, confidence::Float64}}

Multi-hop backward chaining (Hyperon Whitepaper 2025 §4 "PLN supplies explainable chains"; §5.9 Motive
Decomposition Network; §4 motivational compositionality — "goals decompose and recombine"). Plans an
ordered sequence of actions achieving `goal` by recursively decomposing it through `affordances` — rules
of the form `(, PRECOND… ACTION OUTCOME)` (last clause = outcome, second-to-last = action, the rest =
preconditions / subgoals). A goal already true in the substrate (`wm_query > 0`) is a base case (no
action). Returns the ordered `steps` (a subgoal's actions before the action that consumes them) and a
`confidence` = product of the per-rule beliefs along the chain (`beliefs` override, else `prior`); or
`nothing` if the goal is unreachable within `max_depth` (depth- and cycle-guarded).

Builds on the one-hop [`goal_step!`](@ref): where that proposes a single certified action, this chains
them into a plan. A no-precondition rule `(, ACTION OUTCOME)` is exactly an ambient-discovered affordance,
so plans compose the ambient loop's output with richer domain rules. Richer slices (MOSES program
synthesis, PC forecast-guided search, full PLN strength/confidence) come later.
"""
function plan_goal!(
    loop::CognitiveLoop,
    goal::AbstractString;
    affordances::AbstractVector{<:AbstractString},
    beliefs::AbstractDict=Dict{String, Float64}(),
    prior::Real=0.9,
    max_depth::Integer=8
)
    plan = _plan(
        loop, String(strip(goal)), affordances, beliefs, Float64(prior), max_depth,
        Set{String}()
    )
    loop.tick += 1
    return plan
end

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

export AbstractBackend, wm_eval, wm_query, CognitiveLoop, goal_step!, plan_goal!
export attention_step!, ambient_step!, blend_step!, pln_step!, run_ambient!
export SpaceKind, SYMBOLIC, DENSE, HMH, EVIDENCE, ENVIO, WM_SPACES
export wm_space, Spaces, init_spaces!, space, space_kind
export observe!, act!, ground!, encode_hmh!, densify, unbind, lift, summarize
export wm_admit, admit_option!, select_options
export fast_step!, mid_step!, slow_step!, world_cycle!

end # module WorldModel
