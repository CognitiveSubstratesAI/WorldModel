# SubRepCore.jl — SubRep that DELEGATES to Core's canonical lib/subrep (the WorldModel→lib remediation).
#
# WorldModel's SubRep.jl shipped only the CDS simplex gate — 1 of lib/subrep's ~9 mechanisms. This routes
# the gate to the REAL `Core/lib/subrep/{cds,pds}.metta` AND adds **PDS** (`pds-eps-admit`) — the permissive
# admission of a complementary option whose margin sits within −ε, which CDS rejects and the Julia stand-in
# never had. Evaluated through Core's faithful interpreter (engine-per-workload meta-kernel). Deliberately
# NOT exporting names that mirror SubRep's (would collide with `using .SubRep`); call `SubRepCore.x`.

module SubRepCore

using MeTTaCore
using MeTTaCore.Interpreter
using MeTTaCore.Interpreter.StandardMeTTa
using ..Registry: SpaceRegistry, add!, query_head

const _SPACE = Ref{Any}(nothing)
function _space()
    if _SPACE[] === nothing
        sp = Space()
        load_core_stdlib!(sp)
        libsr = joinpath(dirname(pathof(MeTTaCore)), "..", "lib", "subrep")
        load_metta!(sp, read(joinpath(libsr, "cds.metta"), String))
        load_metta!(sp, read(joinpath(libsr, "pds.metta"), String))
        _SPACE[] = sp
    end
    _SPACE[]::Space
end

_vec(dn) = "(" * join(string.(dn), " ") * ")"
_eval1(expr) = (r = metta_run(parse_program(expr)[1][2], _space()); isempty(r) ? nothing : string(r[1]))
_num(expr) = (s = _eval1(expr); s === nothing ? nothing : tryparse(Float64, s))
_bool(expr) = (s = _eval1(expr); s === nothing ? nothing : s == "True")

"CDS simplex margin via canonical lib/subrep (`cds-margin-simplex`): Δr + min_i(Δn_i)."
cds_margin(dr::Real, dn::AbstractVector{<:Real}) = _num("(cds-margin-simplex $dr $(_vec(dn)))")

"CDS admission via lib/subrep (`cds-admit`): margin ≥ ε."
cds_admit(dr::Real, dn::AbstractVector{<:Real}, eps::Real = 0.0) =
    _bool("(cds-admit (cds-margin-simplex $dr $(_vec(dn))) $eps)")

"""
    pds_admit(dr, dn, eps) -> Bool

PDS-ε admission via lib/subrep (`pds-eps-admit`) — the NEW capability WorldModel's SubRep.jl lacked: admit
a *complementary* option whose CDS margin lies within −ε (`margin ≥ −ε`), i.e. an option CDS would reject.
"""
pds_admit(dr::Real, dn::AbstractVector{<:Real}, eps::Real) =
    _bool("(pds-eps-admit $dr $(_vec(dn)) $eps)")

# ── Ambient-loop option admission (the live slow_step! SubRep process) ───────────────────────────────
# The environment / goal loop PROPOSES option-candidates with their backed-up improvement (Δr, Δn); the
# ambient loop CERTIFIES them via canonical lib/subrep — admitting dominating options (CDS) and, as the
# capability SubRep.jl lacks, complementary options whose margin is within −ε (PDS).

"Propose an option candidate `(Δr, Δn)` for ambient SubRep certification (staged in Sopt)."
propose_option!(reg::SpaceRegistry, id::AbstractString, dr::Real, dn::AbstractVector{<:Real};
    into::Symbol = :Sopt) = add!(reg, into, "(option-candidate $id $dr $(join(string.(dn), " ")))")

_admitted_ids(reg, into) =
    Set(String[t[2] for t in (split(strip(a)[2:(end - 1)]) for a in query_head(reg, into, "option"))
               if length(t) >= 2 && t[1] == "option"])

function _store_option!(reg, id, dr, dn, gate, into)
    add!(reg, into, "(option $id $dr $(join(string.(dn), " ")))")
    add!(reg, into, "(subrep-cert $id $(cds_margin(dr, dn)) $gate)")
end

"""
    admit_proposed!(reg; eps_pds=0.1, into=:Sopt) -> (; cds, pds, rejected)

The ambient SubRep stage: screen every staged `(option-candidate id Δr Δn…)` through canonical lib/subrep.
Admit via CDS (margin ≥ 0, dominates the baseline) — else via PDS-ε (margin ≥ −ε, a complementary option
CDS rejects, the NEW capability) — else reject. Admitted options + their certificate (gate = CDS|PDS) are
stored in Sopt. Idempotent: candidates already admitted are skipped. Returns the admitted/rejected ids.
"""
function admit_proposed!(reg::SpaceRegistry; eps_pds::Real = 0.1, into::Symbol = :Sopt)
    done = _admitted_ids(reg, into)
    cds = String[]; pds = String[]; rej = String[]
    for a in query_head(reg, into, "option-candidate")
        toks = split(strip(a)[2:(end - 1)])                 # ["option-candidate", id, dr, dn…]
        length(toks) >= 3 || continue
        id = String(toks[2])
        id in done && continue
        dr = tryparse(Float64, toks[3])
        dn = [tryparse(Float64, t) for t in toks[4:end]]
        (dr === nothing || any(isnothing, dn)) && continue
        if cds_admit(dr, dn, 0.0)
            _store_option!(reg, id, dr, dn, "CDS", into); push!(cds, id)
        elseif pds_admit(dr, dn, eps_pds)
            _store_option!(reg, id, dr, dn, "PDS", into); push!(pds, id)
        else
            push!(rej, id)
        end
        push!(done, id)
    end
    (; cds = cds, pds = pds, rejected = rej)
end

end # module SubRepCore
