# Beliefs.jl — truth values + staleness on the symbolic core (R10; §4.4, §4.7, §6.1.3).
#
# The symbolic core (Sent/Smap/Srule) holds "atoms + truth values" (the diagram). Γ proposes each candidate
# atom with a truth value TV=(s,c) (§4.4); PLN beliefs/rules are TV-annotated atoms (§4.7). In dynamic
# worlds confidence is not static: it DECAYS with age, c(t) = c₀·exp(−λ(t−t₀)) (§6.1.3), and when it falls
# below a threshold the world model schedules re-validation (R10). Pure symbolic, on the real substrate.

module Beliefs

using ..Registry: SpaceRegistry, add!, query_head

export assert_belief!, beliefs, decayed_confidence, stale_beliefs

"""
    assert_belief!(reg, key, s, c, t; into=:Srule)

Record a belief about entity/hypothesis `key` with truth value `(s, c)` (strength, confidence) last
observed/validated at time `t`: the atom `(belief key s c t)` (§4.7). `key` is a single id symbol — the
full structure it refers to lives elsewhere in the space (cf. `EvidenceOf`).
"""
function assert_belief!(reg::SpaceRegistry, key::AbstractString, s::Real, c::Real, t::Real;
    into::Symbol=:Srule)
    add!(reg, into, "(belief $key $s $c $t)")
    return nothing
end

"All beliefs in space `into` as `(key, s, c, t)` tuples."
function beliefs(reg::SpaceRegistry; into::Symbol=:Srule)
    out = Tuple{String, Float64, Float64, Float64}[]
    for a in query_head(reg, into, "belief")
        toks = split(strip(a)[2:(end - 1)])               # ["belief", key, s, c, t]
        length(toks) == 5 || continue
        s = tryparse(Float64, toks[3]);
        c = tryparse(Float64, toks[4]);
        t = tryparse(Float64, toks[5])
        (s === nothing || c === nothing || t === nothing) && continue
        push!(out, (String(toks[2]), s, c, t))
    end
    return out
end

"""
    decayed_confidence(c0, t0, t; lambda=0.1) -> Float64

Effective confidence at time `t` under exponential staleness decay: `c₀·exp(−λ(t−t₀))` (§6.1.3, R10).
"""
decayed_confidence(c0::Real, t0::Real, t::Real; lambda::Real=0.1) =
    c0 * exp(-lambda * (t - t0))

"""
    stale_beliefs(reg, t; threshold=0.5, lambda=0.1, into=:Srule) -> Vector{String}

The keys of beliefs whose decayed confidence at time `t` has fallen below `threshold` — the re-validation
candidates a dynamic world must re-check (R10). Confidence decay is a first-class operation, not a patch.
"""
function stale_beliefs(reg::SpaceRegistry, t::Real; threshold::Real=0.5, lambda::Real=0.1,
    into::Symbol=:Srule)
    return String[
        key for (key, _s, c, t0) in beliefs(reg; into=into)
        if decayed_confidence(c, t0, t; lambda=lambda) < threshold
    ]
end

end # module Beliefs
