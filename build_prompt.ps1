# build_prompt.ps1
# Enterprise AI Review Platform - Prompt Builder

param(
    [Parameter(Mandatory = $true)]
    [string]$ContextJson,

    [Parameter(Mandatory = $true)]
    [string]$RootDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$RootDir\config\platform.yaml",

    [Parameter(Mandatory = $false)]
    [string]$Timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AI_REVIEW_DIR = Join-Path $RootDir "ai-review"
$PLATFORM_DIR  = Join-Path $AI_REVIEW_DIR "platform"
$AGENTS_DIR    = Join-Path $AI_REVIEW_DIR "agents"
$SKILLS_DIR    = Join-Path $AI_REVIEW_DIR "skills"
$PROMPTS_DIR   = Join-Path $AI_REVIEW_DIR "prompts"
$TEMPLATES_DIR = Join-Path $AI_REVIEW_DIR "templates"
$OUTPUT_DIR    = Split-Path $OutputFile

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "INFO"  { "Cyan" }
            "OK"    { "Green" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            default { "White" }
        }
    )
}

function Read-MdFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-Log "WARN" "Not found: $Label"
        return ""
    }
    return Get-Content $Path -Raw -Encoding UTF8
}

function Add-Section {
    param([System.Text.StringBuilder]$Builder, [string]$Header, [string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return }
    $null = $Builder.AppendLine("")
    $null = $Builder.AppendLine("=" * 60)
    $null = $Builder.AppendLine("# $Header")
    $null = $Builder.AppendLine("=" * 60)
    $null = $Builder.AppendLine($Content.Trim())
}

function Get-PlatformSection {
    $agent = Read-MdFile (Join-Path $PLATFORM_DIR "ai_review_platform_agent.md") "platform_agent"
    $skill = Read-MdFile (Join-Path $PLATFORM_DIR "ai_review_platform_skill.md")  "platform_skill"
    return "$agent`n`n$skill"
}

function Get-AgentsSection {
    param([string[]]$AgentNames, [string]$Language)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($agentName in $AgentNames) {
        $candidates = @(
            (Join-Path $AGENTS_DIR "shared\$agentName.md"),
            (Join-Path $AGENTS_DIR "$Language\$agentName.md"),
            (Join-Path $AGENTS_DIR "sql\$agentName.md")
        )
        $found = $false
        foreach ($path in $candidates) {
            if (Test-Path $path) {
                $null = $builder.AppendLine("")
                $null = $builder.AppendLine("## Agent: $agentName")
                $null = $builder.AppendLine((Get-Content $path -Raw -Encoding UTF8).Trim())
                Write-Log "INFO" "  Agent: $agentName"
                $found = $true; break
            }
        }
        if (-not $found) { Write-Log "WARN" "  Agent not found: $agentName" }
    }
    return $builder.ToString()
}

function Get-SkillsSection {
    param([string[]]$SkillNames, [string]$Language)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($skillName in $SkillNames) {
        $candidates = @(
            (Join-Path $SKILLS_DIR "shared\$skillName.md"),
            (Join-Path $SKILLS_DIR "$Language\$skillName.md"),
            (Join-Path $SKILLS_DIR "sql\$skillName.md")
        )
        $found = $false
        foreach ($path in $candidates) {
            if (Test-Path $path) {
                $null = $builder.AppendLine("")
                $null = $builder.AppendLine("## Skill: $skillName")
                $null = $builder.AppendLine((Get-Content $path -Raw -Encoding UTF8).Trim())
                Write-Log "INFO" "  Skill: $skillName"
                $found = $true; break
            }
        }
        if (-not $found) { Write-Log "WARN" "  Skill not found: $skillName" }
    }
    return $builder.ToString()
}

function Get-PromptSection {
    param([string]$Mode)
    $file = switch ($Mode) {
        "new-review"  { "new_review_prompt.md" }
        "diff-review" { "diff_review_prompt.md" }
        "new-test"    { "new_test_prompt.md" }
        "diff-test"   { "diff_test_prompt.md" }
        default       { "new_review_prompt.md" }
    }
    return Read-MdFile (Join-Path $PROMPTS_DIR $file) "prompt/$file"
}

function Get-TemplatesSection {
    param([string]$Mode, [string]$Language)
    $files = switch ($Mode) {
        "new-review"  { @("review_output_template.md","risk_matrix_template.md") }
        "diff-review" { @("review_output_template.md","risk_matrix_template.md","rollback_plan_template.md") }
        "new-test"    { @("test_case_template.md") }
        "diff-test"   { @("regression_test_template.md","test_case_template.md") }
        default       { @("review_output_template.md") }
    }
    if ($Language -eq "sql") { $files += "sql_risk_analysis_template.md" }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($f in $files) {
        $content = Read-MdFile (Join-Path $TEMPLATES_DIR $f) "template/$f"
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $null = $builder.AppendLine("")
            $null = $builder.AppendLine("## Template: $f")
            $null = $builder.AppendLine($content.Trim())
            Write-Log "INFO" "  Template: $f"
        }
    }
    return $builder.ToString()
}

function Save-Manifest {
    param($Json)
    $agentOutputDir = Join-Path $OUTPUT_DIR "agent_outputs"
    if (-not (Test-Path $agentOutputDir)) { New-Item -ItemType Directory -Path $agentOutputDir | Out-Null }
    $manifestPath = Join-Path $agentOutputDir "_manifest.md"
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# Agent/Skill Manifest")
    $null = $sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Loaded Agents")
    foreach ($a in $Json.Agents)       { $null = $sb.AppendLine("- $a") }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Loaded Skills")
    foreach ($s in $Json.Skills)       { $null = $sb.AppendLine("- $s") }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Matched Rules")
    foreach ($r in $Json.MatchedRules) { $null = $sb.AppendLine("- $r") }
    $sb.ToString() | Out-File -FilePath $manifestPath -Encoding UTF8
    Write-Log "INFO" "Manifest: $manifestPath"
}

function Save-FinalReport {
    param($Json, [string]$PromptFile)
    $reportPath = Join-Path $OUTPUT_DIR "final_report_$Timestamp.md"
    $ts         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $sizeKB     = [math]::Round((Get-Item $PromptFile).Length / 1KB, 1)
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# Review Report")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("| Item | Value |")
    $null = $sb.AppendLine("|---|---|")
    $null = $sb.AppendLine("| Generated | $ts |")
    $null = $sb.AppendLine("| Language  | $($Json.Language) |")
    $null = $sb.AppendLine("| Mode      | $($Json.Mode) |")
    $null = $sb.AppendLine("| Tier      | $($Json.Tier) |")
    $null = $sb.AppendLine("| Prompt    | $sizeKB KB |")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Loaded Agents ($(@($Json.Agents).Count))")
    $null = $sb.AppendLine("")
    foreach ($a in $Json.Agents) { $null = $sb.AppendLine("- $a") }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Loaded Skills ($(@($Json.Skills).Count))")
    $null = $sb.AppendLine("")
    foreach ($s in $Json.Skills) { $null = $sb.AppendLine("- $s") }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Matched Risk Rules")
    $null = $sb.AppendLine("")
    if (@($Json.MatchedRules).Count -eq 0) {
        $null = $sb.AppendLine("- (none: base context used)")
    } else {
        foreach ($r in $Json.MatchedRules) { $null = $sb.AppendLine("- $r") }
    }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("## Next Step")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("Paste output\final_review_prompt_$Timestamp.txt into Claude or ChatGPT.")
    $sb.ToString() | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Log "INFO" "Report: $reportPath"
}

try {
    Write-Log "INFO" "build_prompt.ps1 started"

    if (-not (Test-Path $ContextJson)) {
        Write-Log "ERROR" "Context JSON not found: $ContextJson"
        exit 1
    }
    $json     = Get-Content $ContextJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $language = $json.Language
    $mode     = $json.Mode
    $agents   = @($json.Agents)
    $skills   = @($json.Skills)
    $source   = $json.SourceContent

    $prompt = [System.Text.StringBuilder]::new()
    $null   = $prompt.AppendLine("# Enterprise AI Review Platform")
    $null   = $prompt.AppendLine("# Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null   = $prompt.AppendLine("# Language  : $language")
    $null   = $prompt.AppendLine("# Mode      : $mode")
    $null   = $prompt.AppendLine("# Tier      : $($json.Tier)")
    $null   = $prompt.AppendLine("# Agents    : $($agents -join ', ')")
    $null   = $prompt.AppendLine("# Skills    : $($skills -join ', ')")

    Write-Log "INFO" "Loading platform ..."
    Add-Section -Builder $prompt -Header "PLATFORM DEFINITION" -Content (Get-PlatformSection)

    Write-Log "INFO" "Loading $($agents.Count) agents ..."
    Add-Section -Builder $prompt -Header "AGENTS ($($agents.Count))" -Content (Get-AgentsSection -AgentNames $agents -Language $language)

    Write-Log "INFO" "Loading $($skills.Count) skills ..."
    Add-Section -Builder $prompt -Header "SKILLS ($($skills.Count))" -Content (Get-SkillsSection -SkillNames $skills -Language $language)

    Write-Log "INFO" "Loading prompt ..."
    Add-Section -Builder $prompt -Header "TASK PROMPT [$mode]" -Content (Get-PromptSection -Mode $mode)

    Write-Log "INFO" "Loading templates ..."
    Add-Section -Builder $prompt -Header "OUTPUT TEMPLATES" -Content (Get-TemplatesSection -Mode $mode -Language $language)

    Write-Log "INFO" "Adding source code ..."
    Add-Section -Builder $prompt -Header "SOURCE CODE" -Content $source

    $prompt.ToString() | Out-File -FilePath $OutputFile -Encoding UTF8
    Save-Manifest -Json $json
    Save-FinalReport -Json $json -PromptFile $OutputFile

    $sizeKB = [math]::Round((Get-Item $OutputFile).Length / 1KB, 1)
    Write-Log "OK" "Done: $OutputFile ($sizeKB KB)"
    exit 0
}
catch {
    Write-Log "ERROR" "build_prompt.ps1 error: $_"
    Write-Log "ERROR" $_.ScriptStackTrace
    exit 1
}
