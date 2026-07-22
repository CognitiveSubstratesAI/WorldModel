# TransWeave.jl — transfer / composition over Sxfer (R9; §4.9, Appendix A.11, Appendix D).
#
# Sxfer holds transfer maps with bounded order effects: skills/beliefs reused across tasks/environments
# WITHOUT brittle reuse. A transfer is a TASK MORPHISM T: V_M0 → V_M1 (Appendix D) — a pullback induced by
# a symbol correspondence (objects / predicates / rule schemas / affordances). The TransWeave guarantee is
# the "infer-then-map ≈ map-then-infer" intertwining T∘B ≈ B∘T; the BELLMAN-DARBOUX RESIDUAL
# R_BD(T) = T∘B_M0 − B_M1∘T measures the bounded ORDER EFFECT. A transfer is admitted (R9) only if its BD
# residual is small. Composes with PLN (the backup operator B is inference; here the valuation is the
# belief STV). A per-Space PROCESS over Sxfer + Srule via the registry.

module TransWeave

using ..Registry: SpaceRegistry, add!, query_head
using ..PLN: node_stv

export add_correspondence!,
    correspondence, transfer, bd_residual, admit_transfer!, transfers

"Register a symbol correspondence `src ↦ tgt` under transfer map `name` in Sxfer (an Appendix-D task morphism)."
add_correspondence!(reg::SpaceRegistry, name::AbstractString, src::AbstractString,
    tgt::AbstractString;
    into::Symbol=:Sxfer) = add!(reg, into, "(xfer $name $src $tgt)")

"The correspondence `src ↦ tgt` of transfer map `name`."
function correspondence(reg::SpaceRegistry, name::AbstractString; into::Symbol=:Sxfer)
    d = Dict{String, String}()
    for a in query_head(reg, into, "xfer")
        toks = split(strip(a)[2:(end - 1)])               # ["xfer", name, src, tgt]
        length(toks) == 4 && toks[2] == name && (d[String(toks[3])] = String(toks[4]))
    end
    return d
end

"Apply the transfer map (pullback T): the target correspondent of `sym`, or `sym` itself if unmapped."
transfer(corr::AbstractDict, sym::AbstractString) = String(get(corr, sym, sym))

"""
    bd_residual(reg, name, src_key; into_xfer=:Sxfer, into_rule=:Srule) -> Float64

The Bellman-Darboux residual of transfer map `name` at `src_key` (Appendix D): the strength gap between
the SOURCE valuation mapped through T and the TARGET domain's own valuation — `|T·v_src − v_target|`, the
bounded ORDER EFFECT. Small ⇒ "infer-then-map ≈ map-then-infer" ⇒ the transfer reuses safely.
"""
function bd_residual(reg::SpaceRegistry, name::AbstractString, src_key::AbstractString;
    into_xfer::Symbol=:Sxfer, into_rule::Symbol=:Srule)
    corr = correspondence(reg, name; into=into_xfer)
    tgt_key = transfer(corr, src_key)
    # `node_stv` returns `nothing` for an unbelieved key (absence is not a truth value). This is a
    # NUMERIC residual, not a deduction, so an absent side is deliberately read as strength 0.0 — the
    # default is stated HERE, at the call site, rather than fabricated inside the accessor where it
    # silently poisoned PLN deduction.
    _strength(key) = (v = node_stv(reg, key; into=into_rule); v === nothing ? 0.0 : v.s)
    return abs(_strength(src_key) - _strength(tgt_key))
end

"""
    admit_transfer!(reg, name, src_key; eps=0.1, …) -> Bool

Admit transfer map `name` for `src_key` iff its BD residual ≤ `eps` (bounded order effect, R9): store a
certificate `(xfer-cert name src_key residual eps)` in Sxfer. Returns whether it was admitted — brittle
transfers (large residual) are rejected, not silently applied.
"""
function admit_transfer!(reg::SpaceRegistry, name::AbstractString, src_key::AbstractString;
    eps::Real=0.1, into_xfer::Symbol=:Sxfer, into_rule::Symbol=:Srule)
    r = bd_residual(reg, name, src_key; into_xfer=into_xfer, into_rule=into_rule)
    r <= eps || return false
    add!(reg, into_xfer, "(xfer-cert $name $src_key $r $eps)")
    return true
end

"The admitted transfer certificates in Sxfer."
transfers(reg::SpaceRegistry; into::Symbol=:Sxfer) = query_head(reg, into, "xfer-cert")

end # module TransWeave
