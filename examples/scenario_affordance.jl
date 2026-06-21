# Scenario demo — Minecraft-style affordance discovery via the ambient loop.
#
# Grounded in vibe-eng Appendix A §A.8 (Scenario A: Minecraft affordance discovery): the ambient loop
# mines recurring action→result regularities, blends them into composite AFFORDANCES, and tightens
# beliefs — consolidating successful motifs (Whitepaper §4 ambient: ECAN → mining → blending → factor-PLN).
#
# Run from an environment with WorldModel + MeTTaCore available:
#   julia> using WorldModel, MeTTaCore
#   julia> include(joinpath(pkgdir(WorldModel), "examples", "scenario_affordance.jl"))
#   julia> run_affordance_demo()

using WorldModel
include(joinpath(@__DIR__, "mettacore_backend.jl"))   # defines MeTTaCoreBackend over MeTTaCore

# A small symbolic game-state log: repeated chop→wood and mine→stone episodes (the perceived evidence).
const AFFORDANCE_DATA = join(
    [
        "(chop tree1)", "(yields tree1 wood)",
        "(chop tree2)", "(yields tree2 wood)",
        "(chop tree3)", "(yields tree3 wood)",
        "(mine rock1)", "(yields rock1 stone)",
        "(mine rock2)", "(yields rock2 stone)",
    ],
    "\n",
)

# The action/outcome regularities the agent considers.
const CANDIDATES = [raw"(chop $o)", raw"(mine $o)", raw"(yields $o $r)"]

"Run the affordance-discovery ambient loop for `cycles` cycles; prints what each cycle discovers."
function run_affordance_demo(; cycles::Int=2)
    backend = MeTTaCoreBackend()
    wm_eval(backend, AFFORDANCE_DATA)                      # perceive the episodes into the space
    loop = CognitiveLoop(; backend=backend)
    local result
    for c in 1:cycles
        result = run_ambient!(loop; candidates=CANDIDATES, minsup=2)
        println("── cycle $c ──")
        println("  recurring (mined):    ", result.frequent)
        println("  affordances (blends): ", result.blends)
        println(
            "  beliefs:              ",
            [(p, round(conf; digits=2)) for (p, n, conf) in result.beliefs],
        )
    end
    return result
end
