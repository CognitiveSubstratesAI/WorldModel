# MOSESCore.jl — MOSES delegated to Core's canonical lib/MOSES (the WorldModel→lib slice).
#
# WorldModel's MOSES.jl is a plain GA over Vector{String} token-lists with an opaque caller fitness (~4.6%
# of lib/MOSES) — it has no program representation, no knob-vectors, no reduce-to-elegance, no truth-table
# semantics, no metapopulation. This exposes the REAL lib/MOSES (32 files: typed program trees + knobs +
# reduce-to-elegance + metapopulation search) through Core, demonstrating capability the GA toy never had:
# truth-table BEHAVIORAL scoring (program semantics vs a target table) and the metapopulation search loop.
# lib/MOSES loaded via the durable Interpreter.load_metta! path (its own test uses the obsolete run_metta).
# The full OR-induction search is ~69s (kept out-of-band, exactly as the lib's own test does). Not exported.

module MOSESCore

using MeTTaCore
using MeTTaCore.Interpreter
using MeTTaCore.Interpreter.StandardMeTTa

const _ORDER = split("utilities instance map multimap tree knob logical_canonize rte_helpers " *
    "propagate_not gather_junctors cut_unnecessary_or cut_unnecessary_and promote_common_constraints " *
    "subsumption complement_subtraction delete_inconsistent_handle reduce_to_elegance lsk logical_probe " *
    "sample_logical_perms add_logical_knobs build_logical build_knobs knob_mapper append_to " *
    "representation get_candidate deme scoring optimization metapopulation run_moses")

const _SPACE = Ref{Any}(nothing)
function _space()
    if _SPACE[] === nothing
        sp = Space()
        load_core_stdlib!(sp)
        libm = joinpath(dirname(pathof(MeTTaCore)), "..", "lib", "MOSES")
        for f in _ORDER
            load_metta!(sp, read(joinpath(libm, "$f.metta"), String))
        end
        _SPACE[] = sp
    end
    _SPACE[]::Space
end
_eval1(e) = (r = metta_run(parse_program(e)[1][2], _space()); isempty(r) ? nothing : string(r[1]))

"""
    score_on_table(program, inputs, table) -> Float64

Truth-table BEHAVIORAL score of a MOSES program tree against `table` over `inputs`, via lib/MOSES
`seedPool` — the REAL fitness (program semantics vs a target truth table). WorldModel's GA scores token
lists with an opaque caller function and has no program/table semantics at all. Lower = more errors.
"""
function score_on_table(program::AbstractString, inputs::AbstractString, table::AbstractString)
    s = _eval1("(seedPool $program $inputs $table)")
    s === nothing && return nothing
    m = match(r"(-?\d+(?:\.\d+)?)\)+\s*$", strip(s))
    m === nothing ? nothing : parse(Float64, m.captures[1])
end

"""
    run_moses(args) -> String

Run the lib/MOSES metapopulation search (`runMoses`) and return the best exemplar. `args` is the
MeTTa argument tail `"maxGen minGen popSize inputs table depth pcMax pool"`. `maxGen=0` is the fast
base case (best of the pool); a positive maxGen runs the full deme-expansion search (~minute for OR).
"""
run_moses(args::AbstractString) = _eval1("(runMoses $args)")

end # module MOSESCore
