# PLN.jl — uncertain inference over Srule (the goal loop's reasoning process, §4.7, §6.1.4).
#
# Srule hosts PLN beliefs/rules as TV-annotated atoms; PLN derives new beliefs (deduction) and selects
# actions for a goal (backward chaining). The deduction truth-value formula is the canonical PLN one
# (PLN book §1.4 p.15 + §5.2.2.2 consistency), ported faithfully from Core `lib/pln/pln_core_logic.metta`
# (itself from trueagi-io/hyperon-pln). This is a per-Space PROCESS that plugs into `mid_step!`'s
# action-selection hook — it reads/writes the real Srule space via the registry; it is NOT new substrate.

module PLN

using ..Registry: SpaceRegistry, add!
using ..Beliefs: beliefs, assert_belief!

export STV, truth_deduction, node_stv, impl_stv, assert_implication!, deduce, select_action

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
"The STV of node `name` from Srule beliefs; `(0,0)` (total ignorance) if unknown."
function node_stv(reg::SpaceRegistry, name::AbstractString; into::Symbol=:Srule)
    for (k, s, c, _t) in beliefs(reg; into=into)
        k == name && return (s=s, c=c)::STV
    end
    return (s=0.0, c=0.0)
end

"The STV of the implication `a ⇒ b` (stored under belief key `a=>b`)."
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
deduce(
    reg::SpaceRegistry,
    a::AbstractString,
    b::AbstractString,
    c::AbstractString;
    into::Symbol=:Srule
) =
    truth_deduction(node_stv(reg, a; into), node_stv(reg, b; into), node_stv(reg, c; into),
        impl_stv(reg, a, b; into), impl_stv(reg, b, c; into))

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
