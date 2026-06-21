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

"Current motives = the latest `(motive id urgency)` per id in Smotive (append-only, latest wins)."
function motives(reg::SpaceRegistry; into::Symbol=:Smotive)
    latest = Dict{String, Float64}()
    for a in query_head(reg, into, "motive")
        toks = split(strip(a)[2:(end - 1)])               # ["motive", id, urgency]
        length(toks) == 3 || continue
        u = tryparse(Float64, toks[3])
        u === nothing || (latest[String(toks[2])] = u)    # later atoms overwrite → latest wins
    end
    return latest
end

"Set motive `id`'s urgency to `u` (clamped to the safe region [0,1]); appends, latest wins."
set_motive!(reg::SpaceRegistry, id::AbstractString, u::Real; into::Symbol=:Smotive) =
    add!(reg, into, "(motive $id $(clamp(float(u), 0.0, 1.0)))")

"""
    govern!(reg, stimulus; max_drift=0.2, into=:Smotive) -> Union{Tuple{String,Float64}, Nothing}

MetaMo governance step (`metamoGovern`, dynamics.metta): for each motive in `stimulus` (`id => Δurgency`),
apply the change under HOMEOSTATIC DAMPING — clamped to `±max_drift` (the eq #8 contraction safeguard) —
then project into the safe region `[0,1]`, and DECIDE the dominant motive (argmax urgency). Returns the
chosen `(id, urgency)`, or `nothing` if there are no motives.
"""
function govern!(reg::SpaceRegistry, stimulus::AbstractDict{<:AbstractString, <:Real};
    max_drift::Real=0.2, into::Symbol=:Smotive)
    cur = motives(reg; into=into)
    for (id, delta) in stimulus
        u0 = get(cur, String(id), 0.0)
        u1 = clamp(u0 + clamp(float(delta), -max_drift, max_drift), 0.0, 1.0)   # damp + safe-project
        set_motive!(reg, id, u1; into=into)
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
