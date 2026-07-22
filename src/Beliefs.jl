# Beliefs.jl — truth values + staleness on the symbolic core (R10; §4.4, §4.7, §6.1.3).
#
# The symbolic core (Sent/Smap/Srule) holds "atoms + truth values" (the diagram). Γ proposes each candidate
# atom with a truth value TV=(s,c) (§4.4); PLN beliefs/rules are TV-annotated atoms (§4.7). In dynamic
# worlds confidence is not static: it DECAYS with age, c(t) = c₀·exp(−λ(t−t₀)) (§6.1.3), and when it falls
# below a threshold the world model schedules re-validation (R10). Pure symbolic, on the real substrate.

module Beliefs

using ..Registry: SpaceRegistry, add!, query_head
using ..Braid: evidence_of

export assert_belief!, beliefs, decayed_confidence, stale_beliefs, revalidate_belief!

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
    revalidate_belief!(reg, key, t; into=:Srule, evidence_into=:Sent) -> Union{NamedTuple,Nothing}

R10 RE-VALIDATION: refresh a stale belief's CONFIDENCE from the evidence that currently anchors the
symbol, and reset its decay clock to `t`. Returns the refreshed `(key, s, c, t)`, or `nothing` when
there is no such belief or no evidence.

This is the half of R10 that was missing: `stale_beliefs` detected decay and returned a list that
nothing consumed, so "factor-graph PLN tightens beliefs" (§7 ambient loop) was detection-only.

Confidence is derived from the EVIDENCE COUNT through our canonical count→confidence map — the same
`Truth_w2c(w) = w/(w+1)` that `Core/lib/pln` uses (k = 1; verified live: `w2c(1)=0.5`, `w2c(3)=0.75`,
and `w2c∘c2w` is the identity). Using the canonical map matters: a revalidated confidence lands on the
SAME evidence scale as every other truth value in the system, so revision stays coherent. (This is
exactly why PeTTaChainer's k=800 must not be imported — see
`docs/specs/pln_node_base_rate_spec.md` §2b.)

**Strength is PRESERVED.** Re-validation refreshes *how confident we are given current evidence*; it
does not invent *what we believe*. Deriving a node's base-rate STRENGTH is a separate and
semantically-loaded step (spec §6 — it needs an extension/universe notion, not just a count).

**No evidence ⇒ `nothing`**: the belief is left to keep decaying rather than propped up. That is the
honest outcome for a symbol nothing supports any more, and it keeps decay meaningful — a belief can
only be rescued by evidence that actually exists.
"""
function revalidate_belief!(reg::SpaceRegistry, key::AbstractString, t::Real;
    into::Symbol=:Srule, evidence_into::Symbol=:Sent)
    n = length(evidence_of(reg, key; into=evidence_into))
    n == 0 && return nothing                       # unsupported ⇒ let it decay
    cur = nothing
    for (k, s, _c, _t0) in beliefs(reg; into=into)
        if k == key; cur = s; break; end
    end
    cur === nothing && return nothing              # nothing to revalidate
    c_new = n / (n + 1)                            # canonical Truth_w2c(n), k = 1
    assert_belief!(reg, key, cur, c_new, t; into=into)   # latest-wins ⇒ supersedes the stale row
    return (key=String(key), s=cur, c=c_new, t=float(t))
end

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
