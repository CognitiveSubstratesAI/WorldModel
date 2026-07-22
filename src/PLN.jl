# PLN.jl — uncertain inference over Srule (the goal loop's reasoning process, §4.7, §6.1.4).
#
# Srule hosts PLN beliefs/rules as TV-annotated atoms; PLN derives new beliefs (deduction) and selects
# actions for a goal (backward chaining). The deduction truth-value formula is the canonical PLN one
# (PLN book §1.4 p.15 + §5.2.2.2 consistency), ported faithfully from Core `lib/pln/pln_core_logic.metta`
# (itself from trueagi-io/hyperon-pln). This is a per-Space PROCESS that plugs into `mid_step!`'s
# action-selection hook — it reads/writes the real Srule space via the registry; it is NOT new substrate.

module PLN

using ..Registry: SpaceRegistry, add!, query_head
using ..Beliefs: beliefs, assert_belief!

export STV, truth_deduction, node_stv, impl_stv, assert_implication!, deduce, select_action
export base_rate, refresh_base_rates!

"A PLN simple truth value: strength `s` ∈ [0,1] and confidence `c` ∈ [0,1)."
const STV = NamedTuple{(:s, :c), Tuple{Float64, Float64}}

# ── consistency (PLN book §5.2.2.2, p.74) ──────────────────────────────────────────────────────────
_clamp01(x) = clamp(float(x), 0.0, 1.0)
_smallest_intersection(as, bs) = _clamp01((as + bs - 1) / as)   # P(A,B) lower bound, as conditional
_largest_intersection(as, bs) = _clamp01(bs / as)
_consistent(as, bs, abs_) =
    as > 0 && (_smallest_intersection(as, bs) <= abs_ <= _largest_intersection(as, bs))

"""
    truth_deduction(P, Q, R, PQ, QR) -> STV

PLN deduction (book §1.4 p.15): derive the truth value of `P ⇒ R` from the node STVs `P,Q,R` and the link
STVs `PQ = P⇒Q`, `QR = Q⇒R`. Strength `PQs·QRs + (1−PQs)(Rs − Qs·QRs)/(1−Qs)`; confidence `PQs·QRs·PQc·QRc`.
Returns the `(s=1, c=0)` ignorance fallback when the conditional-probability consistency preconditions fail.
"""
function truth_deduction(P::STV, Q::STV, R::STV, PQ::STV, QR::STV)::STV
    (_consistent(P.s, Q.s, PQ.s) && _consistent(Q.s, R.s, QR.s)) || return (s=1.0, c=0.0)
    s = Q.s > 0.9999 ? R.s : PQ.s * QR.s + ((1 - PQ.s) * (R.s - Q.s * QR.s)) / (1 - Q.s)
    c = PQ.s * QR.s * PQ.c * QR.c
    return (s=_clamp01(s), c=_clamp01(c))
end

# ── reading / writing TV-annotated rules in Srule ──────────────────────────────────────────────────
"""
    node_stv(reg, name; into=:Srule) -> Union{STV,Nothing}

The STV of node `name` from `into`'s beliefs, or **`nothing` when the node has no belief**.

**Absence is not a truth value.** Our own MeTTa library already gets this right:
`Core/lib/pln/pln_core_logic.metta:208` declares `(= (STV \$stv) (empty))`, so an undeclared node
yields NO RESULT — verified live: `(STV some-undeclared-node)` evaluates to `[]`. That matches CeTTa
(`lib_pln.metta:127`) and hyperon (absence ⇒ `Empty`, which cuts the branch and removes it from the
result).

This function used to return a fabricated `(0.0, 0.0)`, which made the Julia layer **contradict the
MeTTa it wraps** — and that single divergence is what made 2-hop deduction dead code: `_consistent`
(`:24`) requires `as > 0`, so a fabricated 0 strength always failed the precondition, forcing the
`(s=1, c=0)` ignorance fallback, and every 2-hop candidate scored `1.0 * 0.0 = 0.0`. The guard and the
fallback are byte-for-byte CeTTa's and are CORRECT — they were simply being fed a value our own MeTTa
would never have produced.

Callers doing LOGIC must skip on `nothing`. A caller that genuinely wants a numeric default states it
at the call site (`v === nothing ? 0.0 : v.s`) so the fabrication is visible there, not hidden here.
"""
function node_stv(reg::SpaceRegistry, name::AbstractString; into::Symbol=:Srule)::Union{STV,Nothing}
    for (k, s, c, _t) in beliefs(reg; into=into)
        k == name && return (s=s, c=c)::STV
    end
    return nothing
end

"The STV of the implication `a ⇒ b` (belief key `a=>b`), or `nothing` if there is no such link."
impl_stv(reg::SpaceRegistry, a::AbstractString, b::AbstractString; into::Symbol=:Srule) =
    node_stv(reg, "$a=>$b"; into=into)

"""
    assert_implication!(reg, a, b, s, c, t; into=:Srule)

Assert `a ⇒ b` with truth value `(s,c)` observed at time `t`: the rule atom `(implies a b)` plus its STV
(belief key `a=>b`). The unit the goal loop reasons over.
"""
function assert_implication!(reg::SpaceRegistry, a::AbstractString, b::AbstractString,
    s::Real, c::Real, t::Real; into::Symbol=:Srule)
    add!(reg, into, "(implies $a $b)")
    assert_belief!(reg, "$a=>$b", s, c, t; into=into)
    return nothing
end

"""
    deduce(reg, a, b, c; into=:Srule) -> STV

PLN deduction over Srule: derive the truth value of `a ⇒ c` by chaining `a ⇒ b` and `b ⇒ c`, using the
node STVs of `a,b,c` and the two link STVs.
"""
function deduce(
    reg::SpaceRegistry,
    a::AbstractString,
    b::AbstractString,
    c::AbstractString;
    into::Symbol=:Srule
)
    # ABSENCE SKIPS. An unknown node or missing link means the deduction has NO PREMISES — not that it
    # is false. Feeding a fabricated (0,0) instead is exactly what used to force the (s=1,c=0) fallback.
    P  = node_stv(reg, a; into); Q  = node_stv(reg, b; into); R = node_stv(reg, c; into)
    PQ = impl_stv(reg, a, b; into); QR = impl_stv(reg, b, c; into)
    any(x -> x === nothing, (P, Q, R, PQ, QR)) && return nothing
    return truth_deduction(P, Q, R, PQ, QR)
end

# ── node base rates: the EXTENSIONAL prior a node STV actually denotes ─────────────────────────────
# A PLN node's strength is its BASE RATE — P(C), the chance a random element of the universe is in C —
# not "how true C is". We can compute it directly, because grounding already records an instance
# relation: `ground!` writes `(entity KEY TYPE)` into Sent (Braid.jl:47-53), live on every perception
# (OmegaClaw `_perceive` emits `(entity e<tick> <token>)`). So
#     s(T) = |{k : (entity k T)}| / |{k : (entity k _)}|
# is the textbook extensional base rate over data we already produce — no invented semantics.
#
# Confidence comes from the INSTANCE COUNT through our canonical map `Truth_w2c(n) = n/(n+1)` (k = 1,
# lib/pln pln_core_logic.metta:216), so it lands on the same evidence scale as every other TV.
# PeTTaChainer's k=800 is deliberately NOT used (docs/specs/pln_node_base_rate_spec.md §2b).
#
# ⚠️ Scope: this covers PERCEPTUAL concepts (types that have an extension in Sent). Action/goal symbols
# live in Srule and have no extension, so they get NO base rate here — `node_stv` reports absence and
# callers skip, which is the correct behaviour rather than a fabricated prior. Giving those symbols a
# base rate needs a different notion (episode frequency over Shmh) and is a separate decision (spec §6).

"Parse `(entity KEY TYPE)` → `TYPE`, or `nothing` for any other shape (incl. the 1-arg `(entity k)`)."
function _entity_type(a::AbstractString)
    toks = split(strip(a)[2:(end - 1)])
    (length(toks) == 3 && toks[1] == "entity") ? String(toks[3]) : nothing
end

"""
    base_rate(reg, concept; into=:Sent) -> Union{STV,Nothing}

The extensional base rate of `concept`: strength `|ext(concept)| / |universe|` over the `(entity k T)`
instance atoms in `into`, confidence `n/(n+1)` from the instance count (canonical `Truth_w2c`, k=1).

Returns `nothing` — NOT `(0,0)` — when the concept has no instances or the universe is empty. Absence
is not a truth value: a concept we have never seen an instance of is *unknown*, not *known to be rare*,
and fabricating a 0 strength is exactly what made 2-hop deduction dead (see `node_stv`).
"""
function base_rate(reg::SpaceRegistry, concept::AbstractString; into::Symbol=:Sent)
    universe = 0; ext = 0
    for a in query_head(reg, into, "entity")
        ty = _entity_type(a)
        ty === nothing && continue
        universe += 1
        ty == concept && (ext += 1)
    end
    (universe == 0 || ext == 0) && return nothing
    return (s = ext / universe, c = ext / (ext + 1))::STV
end

"""
    refresh_base_rates!(reg, t; into=:Sent, into_rule=:Srule, limit=64) -> Vector{String}

Recompute the extensional base rate of every concept with an extension in `into` and assert it as that
node's belief in `into_rule`, so `node_stv` resolves it (beliefs are latest-wins, so this supersedes an
earlier snapshot rather than accumulating). Returns the concepts refreshed.

This is what turns `PLNCore.select_action`'s 2-hop transitive branch from structurally-live into
actually-firing: it needs node STVs for its endpoints, and before this nothing in production ever wrote
one. Budgeted by `limit` — it is ambient background work.
"""
function refresh_base_rates!(reg::SpaceRegistry, t::Real;
    into::Symbol=:Sent, into_rule::Symbol=:Srule, limit::Int=64)
    counts = Dict{String, Int}(); universe = 0
    for a in query_head(reg, into, "entity")
        ty = _entity_type(a)
        ty === nothing && continue
        universe += 1
        counts[ty] = get(counts, ty, 0) + 1
    end
    universe == 0 && return String[]
    out = String[]
    for ty in Iterators.take(sort!(collect(keys(counts))), max(limit, 0))   # sorted ⇒ deterministic
        n = counts[ty]
        assert_belief!(reg, ty, n / universe, n / (n + 1), t; into=into_rule)
        push!(out, ty)
    end
    return out
end

"""
    select_action(reg, goal; into=:Srule) -> Vector{Tuple{String,STV}}

The goal loop's action-selection (§6.1.4): backward-chain over Srule — every implication `X ⇒ goal` makes
`X` a candidate action, ranked by the implication's expected payoff `s·c`, best first. The real content of
`mid_step!`'s action-selection hook.
"""
function select_action(reg::SpaceRegistry, goal::AbstractString; into::Symbol=:Srule)
    suffix = "=>$goal"
    cands = Tuple{String, STV}[]
    for (k, s, c, _t) in beliefs(reg; into=into)
        endswith(k, suffix) || continue
        push!(cands, (String(k[1:(end - length(suffix))]), (s=s, c=c)))
    end
    sort!(cands; by=x -> -(x[2].s * x[2].c))
    return cands
end

end # module PLN
