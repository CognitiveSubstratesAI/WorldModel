using Documenter
using DocumenterMermaid
using WorldModel

DocMeta.setdocmeta!(WorldModel, :DocTestSetup, :(using WorldModel); recursive=true)

makedocs(;
    modules=[WorldModel],
    authors="CognitiveSubstrates AI",
    repo=Remotes.GitHub("CognitiveSubstratesAI", "WorldModel"),
    sitename="WorldModel",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://cognitivesubstratesai.github.io/WorldModel/stable/",
        edit_link="main",
        assets=String[]
    ),
    pages=[
        "Home" => "index.md",
        "Scenario: Affordance Discovery" => "scenarios.md",
        "Architecture Decision" => "decisions.md",
        "API Reference" => "api.md"
    ],
    warnonly=true
)

deploydocs(; repo="github.com/CognitiveSubstratesAI/WorldModel", devbranch="main")
