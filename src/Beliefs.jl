# Beliefs.jl — truth values + staleness on the symbolic core (R10; §4.4, §4.7, §6.1.3).
#
# The symbolic core (Sent/Smap/Srule) holds "atoms + truth values" (the diagram). Γ proposes each candidate
# atom with a truth value TV=(s,c) (§4.4); PLN beliefs/rules are TV-annotated atoms (§4.7). In dynamic
# worlds confidence is not static: it DECAYS with age, c(t) = c₀·exp(−λ(t−t₀)) (§6.1.3), and when it falls
# below a threshold the world model schedules re-validation (R10). Pure symbolic, on the real substrate.

module Beliefs

using ..Registry: SpaceRegistry, add!, query_head

export assert_belief!, beliefs

# WHAT IS NOT HERE, AND WHY.
#
# `decayed_confidence`, `stale_beliefs` and `revalidate_belief!` used to live in this file. They were the
# three places the R10 belief DYNAMICS were written in Julia: the decay law `c0*exp(-lambda*(t-t0))` with
# `lambda = 0.1`, a `threshold = 0.5` staleness cut (which disagreed with `slow_step!`'s 0.3 for the same
# concept), and `c_new = n / (n + 1)` — under a comment naming the canonical `Truth_w2c` it was
# transcribing, while `EvidenceConfidence` sat in `Core/lib/pln` with zero callers.
#
# They moved to `PLNCore.jl`, which evaluates `Core/lib/pln/decay.metta` +
# `WorldModel/lib/ambient_policy.metta`. The move was structural, not cosmetic: this file is `include`d
# BEFORE `PLNCore` and `PLNCore` does `using ..Beliefs`, so a call from here into the interpreter would
# close a dependency cycle. Being unable to reach the canonical formula from here is precisely why it got
# written out again — so the code went to where the library is reachable, rather than the library being
# copied to where the code was.
#
# What remains is substrate: append a belief atom, and resolve the current one per key.

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

end # module Beliefs
