# MetaMo.jl — the motive governor over Smotive (§4 goal loop, Appendix A.9).
#
# Smotive holds motives/priorities; MetaMo is the policy governor that steers which goal the goal loop
# pursues. Ported from the governance step `metamoGovern` (Core `lib/metamo/dynamics.metta`):
#   Ψ appraise → 𝔻 decide → damp ΔG → apply → project to the safe region.
# The faithful CORE here is: appraise (urgency += stimulus), HOMEOSTATIC DAMPING (the change is clamped to
# ±max_drift — the eq #8 Lipschitz-contraction safeguard that keeps the governance map a contraction),
# safe projection ([0,1]), and DECIDE (argmax). The full OpenPsi appraisal + boundary-caution machinery is
# the deeper Core/lib/metamo system — a documented depth limit, not faked. A per-Space PROCESS over Smotive.

module MetaMo

using ..Registry: SpaceRegistry, add!, query_head

export set_motive!, motives, govern!, dominant_motive

"""
    motives(reg; into=:Smotive) -> Dict{String,Float64}

Current motives = the latest `(motive id urgency t)` per id in Smotive (append-only, latest wins).

**Resolution is by `t`, not by iteration order.** The row carries its own timestamp precisely so that
"latest" is a fact about the data rather than about how the substrate happens to enumerate it. The
previous schema was `(motive id urgency)` with no `t`, and this function resolved duplicates by

    latest[id] = u    # "later atoms overwrite → latest wins"

which was simply false. The atoms arrive from `query_head → atoms → Substrate.dump_atoms`, a zipper walk
over the MORK trie; MORK tags symbols with a leading size byte, so the winner was whichever urgency had
the LONGEST decimal string, then lexicographic order — not the latest, not the maximum, an artifact of
byte layout. Harmless while Smotive had no production writer; load-bearing the moment `mid_step!` began
persisting the appraised modulator vector every tick, at which point `dominant_motive`/`govern!` were
reading an arbitrary historical value as "the agent's current affect".

`Beliefs.beliefs` documents this exact hazard and solves it the same way 40 lines away — see its
`(t, c) > (prev[3], prev[2])`. Ties on `t` break on higher urgency: deterministic, and (like Beliefs'
`c` tie-break) it prefers the stronger appraisal written within a single tick.

LEGACY ROWS: 3-token `(motive id urgency)` atoms already persisted in `.act` state are still read, at
`t = -Inf`, so any timestamped write supersedes them and nothing silently disappears on upgrade.
"""
function motives(reg::SpaceRegistry; into::Symbol=:Smotive)
    latest = Dict{String, Tuple{Float64, Float64}}()      # id => (t, urgency)
    for a in query_head(reg, into, "motive")
        toks = split(strip(a)[2:(end - 1)])               # ["motive", id, urgency, t]
        (length(toks) == 4 || length(toks) == 3) || continue
        u = tryparse(Float64, toks[3])
        u === nothing && continue
        t = length(toks) == 4 ? tryparse(Float64, toks[4]) : -Inf    # legacy row ⇒ oldest possible
        t === nothing && continue
        key = String(toks[2])
        prev = get(latest, key, nothing)
        (prev === nothing || (t, u) > prev) && (latest[key] = (t, u))
    end
    return Dict{String, Float64}(k => v[2] for (k, v) in latest)
end

"""
    set_motive!(reg, id, u, t; into=:Smotive)

Set motive `id`'s urgency to `u` (clamped to the safe region [0,1]) as of time `t`; appends, latest wins.

`t` is REQUIRED and positional on purpose. A defaulted timestamp is worse than none: every caller that
forgot it would write the same value, `motives`' ordering would degrade back to a tie on every row, and
the trie-order bug above would return silently — with the schema now *claiming* to be time-ordered.
Pass the loop tick (`loop.tick`) or the wall clock, whichever the caller's other writes use.
"""
set_motive!(reg::SpaceRegistry, id::AbstractString, u::Real, t::Real; into::Symbol=:Smotive) =
    add!(reg, into, "(motive $id $(clamp(float(u), 0.0, 1.0)) $(float(t)))")

"""
    govern!(reg, stimulus, t; max_drift=0.2, into=:Smotive) -> Union{Tuple{String,Float64}, Nothing}

MetaMo governance step (`metamoGovern`, dynamics.metta): for each motive in `stimulus` (`id => Δurgency`),
apply the change under HOMEOSTATIC DAMPING — clamped to `±max_drift` (the eq #8 contraction safeguard) —
then project into the safe region `[0,1]`, and DECIDE the dominant motive (argmax urgency). Returns the
chosen `(id, urgency)`, or `nothing` if there are no motives.

`t` stamps this governance step — see `set_motive!` for why it is required rather than defaulted. One
step writes one row per stimulated motive, all at the same `t`; the read side breaks that tie on urgency.
"""
function govern!(reg::SpaceRegistry, stimulus::AbstractDict{<:AbstractString, <:Real}, t::Real;
    max_drift::Real=0.2, into::Symbol=:Smotive)
    cur = motives(reg; into=into)
    for (id, delta) in stimulus
        u0 = get(cur, String(id), 0.0)
        u1 = clamp(u0 + clamp(float(delta), -max_drift, max_drift), 0.0, 1.0)   # damp + safe-project
        set_motive!(reg, id, u1, t; into=into)
    end
    return dominant_motive(reg; into=into)
end

"""
    dominant_motive(reg; into=:Smotive) -> Union{Tuple{String,Float64}, Nothing}

The dominant motive (argmax urgency) the goal loop should pursue — the governor's action selection (𝔻).
"""
function dominant_motive(reg::SpaceRegistry; into::Symbol=:Smotive)
    cur = motives(reg; into=into)
    isempty(cur) && return nothing
    u, id = findmax(cur)
    return (id, u)
end

end # module MetaMo
