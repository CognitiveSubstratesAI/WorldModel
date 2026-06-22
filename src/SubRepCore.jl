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

end # module SubRepCore
