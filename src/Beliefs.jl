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

"""
    beliefs(reg; into=:Srule) -> Vector{Tuple{String,Float64,Float64,Float64}}

The CURRENT belief per key in space `into`, as `(key, s, c, t)` tuples, sorted by key.

**Latest-wins resolution.** The substrate is append-only — `assert_belief!` `add!`s a new
`(belief key s c t)` atom and `Registry` has no remove — so re-asserting a key (which
`reinforce!` does on EVERY outcome) leaves every prior version in the space. Returning them all
made re-assertion a no-op for every consumer: `node_stv`/`impl_stv` returned whichever version the
trie yielded first, `PLNCore.select_action` bumps with `max` so an action kept its BEST-EVER score,
and `stale_beliefs` flagged superseded versions as stale. Measured before this fix: 1 success then
4 failures drove strength 1.0 → 0.2 while the selection score never moved off its first value —
i.e. `reinforce!`'s documented demotion could not happen and the reward channel was write-only.

So a later assertion SUPERSEDES an earlier one for the same key: keep max `t`, tie-broken by higher
`c` (within one tick the assertion carrying more evidence wins) — deterministic, and independent of
trie iteration order. All four consumers (`node_stv`, `PLN.select_action`, `PLNCore.select_action`,
`stale_beliefs`) want exactly this; none needs the history. Superseded atoms still occupy the space
— bounding that needs a write-side replace via `MORK.space_remove_sexpr!`, which `Registry` does not
yet expose (follow-up); reading is correct regardless, including for duplicates already persisted
in `.act` state.
"""
function beliefs(reg::SpaceRegistry; into::Symbol=:Srule)
    latest = Dict{String, Tuple{Float64, Float64, Float64}}()   # key => (s, c, t)
    for a in query_head(reg, into, "belief")
        toks = split(strip(a)[2:(end - 1)])               # ["belief", key, s, c, t]
        length(toks) == 5 || continue
        s = tryparse(Float64, toks[3]);
        c = tryparse(Float64, toks[4]);
        t = tryparse(Float64, toks[5])
        (s === nothing || c === nothing || t === nothing) && continue
        key = String(toks[2])
        prev = get(latest, key, nothing)
        (prev === nothing || (t, c) > (prev[3], prev[2])) && (latest[key] = (s, c, t))
    end
    return Tuple{String, Float64, Float64, Float64}[
        (k, v[1], v[2], v[3]) for (k, v) in sort!(collect(latest); by = first)]
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
