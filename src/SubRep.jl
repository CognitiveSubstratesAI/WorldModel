# SubRep.jl — option/subgoal admission over Sopt (§4.9, Appendix A.10).
#
# Sopt holds reusable skills/macros admitted via SubRep certification. The CDS gate (Cone-Dominant
# Subtasks, paper §2.2) admits an option iff it beats the baseline over the whole motive slice: on the
# simplex, margin = Δr + min_i(Δn_i) ≥ ε. An admitted option carries an auditable certificate, and can be
# re-scored zero-shot under a new motive weighting without recertifying. Ported faithfully from Core
# `lib/subrep/cds.metta` (this session's gate). A per-Space PROCESS over the real Sopt space via the
# registry — not new substrate.

module SubRep

using ..Registry: SpaceRegistry, add!, query_head

export cds_margin, cds_admit, admit_option!, admitted_options, reuse_options

"CDS simplex margin (§2.2): `Δr + min_i(Δn_i)` — the option's reward improvement plus its worst-case change
across the motive cone. Positive ⇒ it dominates the baseline for every motive weight in the slice."
cds_margin(dr::Real, dn::AbstractVector{<:Real}) = dr + minimum(dn)

"Admit iff the CDS margin clears the threshold `ε` (§2.2 statewise/expectation gate)."
cds_admit(dr::Real, dn::AbstractVector{<:Real}, eps::Real=0.0) = cds_margin(dr, dn) >= eps

"""
    admit_option!(reg, id, Δr, Δn; eps=0.0, into=:Sopt) -> Bool

SubRep admission (§A.10): screen option `id` — its backed-up improvement `(Δr, Δn)` over the admitted
baseline — through the CDS gate. If it passes, store the option (`(option id Δr Δn…)`) and an auditable
certificate (`(subrep-cert id margin ε)`) in Sopt. Returns whether it was admitted.
"""
function admit_option!(reg::SpaceRegistry, id::AbstractString, dr::Real,
    dn::AbstractVector{<:Real};
    eps::Real=0.0, into::Symbol=:Sopt)
    m = cds_margin(dr, dn)
    m >= eps || return false
    add!(reg, into, "(option $id $dr $(join(string.(dn), " ")))")
    add!(reg, into, "(subrep-cert $id $m $eps)")
    return true
end

"The ids of options admitted into Sopt."
admitted_options(reg::SpaceRegistry; into::Symbol=:Sopt) =
    String[split(strip(a)[2:(end - 1)])[2] for a in query_head(reg, into, "option")]

"""
    reuse_options(reg, w; into=:Sopt) -> Vector{Tuple{String,Float64}}

Zero-shot reuse under a motive shift (§A.10): re-score each admitted option under NEW motive weights `w`
— value `Δr + wᵀΔn` — straight from its stored certificate, with NO recertification. Returns `(id, value)`
best first.
"""
function reuse_options(reg::SpaceRegistry, w::AbstractVector{<:Real}; into::Symbol=:Sopt)
    out = Tuple{String, Float64}[]
    for a in query_head(reg, into, "option")
        toks = split(strip(a)[2:(end - 1)])                 # ["option", id, dr, dn1, dn2, …]
        length(toks) >= 3 || continue
        dr = tryparse(Float64, toks[3])
        dn = [tryparse(Float64, t) for t in toks[4:end]]
        (dr === nothing || any(isnothing, dn)) && continue
        push!(out, (String(toks[2]), dr + sum(w .* dn)))
    end
    sort!(out; by=x -> -x[2])
    return out
end

end # module SubRep
