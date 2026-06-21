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
        "(mine rock2)", "(yields rock2 stone)"
    ],
    "\n"
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
            [(p, round(conf; digits=2)) for (p, n, conf) in result.beliefs]
        )
    end
    return result
end

"""
Discover affordances (the AMBIENT loop), then plan toward a `goal` outcome (the GOAL-directed loop).
Shows the two loops composing: mining → blending invents the affordances, then `goal_step!` (§4
MetaMo→…→SubRep) backward-looks them up by the goal's outcome and certifies each action against the
substrate. Default goal = "get wood".
"""
function run_goal_demo(goal::AbstractString=raw"(yields $o wood)")
    backend = MeTTaCoreBackend()
    wm_eval(backend, AFFORDANCE_DATA)
    loop = CognitiveLoop(; backend=backend)
    r = run_ambient!(loop; candidates=CANDIDATES, minsup=2)       # ambient: discover affordances
    opts = goal_step!(loop, goal; affordances=r.blends)           # goal: plan + certify toward the goal
    println("goal:        ", goal)
    println("affordances: ", r.blends)
    println("plan:        ", [(a, round(c; digits=2)) for (a, c) in opts])
    return opts
end

# A small crafting hierarchy (domain rules WITH preconditions): planks need wood, wood needs chopping.
# Rule form `(, PRECOND… ACTION OUTCOME)`: last clause = outcome, second-to-last = action, rest = subgoals.
const CRAFT_RULES = [
    raw"(, (chop $o) (yields $o wood))",                            # chop yields wood (a leaf affordance)
    raw"(, (yields $o wood) (craft $o plank) (yields $o plank))"   # wood + craft yields plank
]

"""
Plan a multi-step goal by backward chaining (the goal loop's deeper slice — §4 "PLN supplies explainable
chains"). From an empty world the planner derives the full chain; with wood already perceived it SKIPS the
chop (that subgoal is already true in the substrate).
"""
function run_plan_demo()
    fresh = MeTTaCoreBackend()
    p1 = plan_goal!(
        CognitiveLoop(; backend=fresh), raw"(yields $o plank)"; affordances=CRAFT_RULES
    )
    println(
        "plan plank (empty world):  ", p1.steps, "  conf=", round(p1.confidence; digits=3)
    )
    haswood = MeTTaCoreBackend()
    wm_eval(haswood, "(yields log wood)")                          # wood already observed
    p2 = plan_goal!(
        CognitiveLoop(; backend=haswood), raw"(yields $o plank)"; affordances=CRAFT_RULES
    )
    println(
        "plan plank (wood present): ", p2.steps, "  conf=", round(p2.confidence; digits=3)
    )
    return (p1, p2)
end
