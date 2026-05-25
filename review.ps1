# review.ps1
# Enterprise AI Review Platform - Entry Point

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("java", "csharp", "linux", "sql")]
    [string]$Language,

    [Parameter(Mandatory = $true)]
    [ValidateSet("new-review", "diff-review", "new-test", "diff-test")]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "$PSScriptRoot\..\config\platform.yaml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SCRIPT_DIR   = $PSScriptRoot
$ROOT_DIR     = Resolve-Path "$SCRIPT_DIR\.."
$OUTPUT_DIR   = Join-Path $ROOT_DIR "output"
$CONTEXT_FILE = Join-Path $OUTPUT_DIR "_context.json"
$TIMESTAMP    = Get-Date -Format "yyyyMMdd_HHmmss"

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Assert-PathExists {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-Log "ERROR" "Not found - $Label : $Path"
        exit 1
    }
}

function Invoke-PreCheck {
    Write-Log "INFO" "Pre-check started"
    Assert-PathExists $ConfigPath "config/platform.yaml"
    Assert-PathExists (Join-Path $ROOT_DIR "source-code\new") "source-code/new"
    if ($Mode -eq "diff-review" -or $Mode -eq "diff-test") {
        Assert-PathExists (Join-Path $ROOT_DIR "source-code\old") "source-code/old"
    }
    Assert-PathExists (Join-Path $SCRIPT_DIR "detect_context.ps1") "detect_context.ps1"
    Assert-PathExists (Join-Path $SCRIPT_DIR "build_prompt.ps1")   "build_prompt.ps1"
    Write-Log "OK" "Pre-check passed"
}

function Initialize-OutputDir {
    if (-not (Test-Path $OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIR | Out-Null
    }
    $agentOutputDir = Join-Path $OUTPUT_DIR "agent_outputs"
    if (-not (Test-Path $agentOutputDir)) {
        New-Item -ItemType Directory -Path $agentOutputDir | Out-Null
    }
    Write-Log "INFO" "Output dir: $OUTPUT_DIR"
}

function Invoke-DetectContext {
    Write-Log "INFO" "Step1: detect_context (Language=$Language, Mode=$Mode)"

    & "$SCRIPT_DIR\detect_context.ps1" `
        -Language   $Language `
        -Mode       $Mode `
        -RootDir    $ROOT_DIR `
        -ConfigPath $ConfigPath `
        -OutputJson $CONTEXT_FILE

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR" "detect_context.ps1 failed (exit=$LASTEXITCODE)"
        exit 1
    }
    if (-not (Test-Path $CONTEXT_FILE)) {
        Write-Log "ERROR" "Context JSON not found: $CONTEXT_FILE"
        exit 1
    }

    $json    = Get-Content $CONTEXT_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    $context = @{
        Language      = $json.Language
        Mode          = $json.Mode
        Tier          = [int]$json.Tier
        MatchedRules  = @($json.MatchedRules)
        Agents        = @($json.Agents)
        Skills        = @($json.Skills)
        SourceContent = $json.SourceContent
    }
    Write-Log "OK" "Detected: Agents=$($context.Agents.Count), Skills=$($context.Skills.Count), Tier=$($context.Tier)"
    return $context
}

function Invoke-BuildPrompt {
    param([hashtable]$Context)
    Write-Log "INFO" "Step2: build_prompt"
    $outputFile = Join-Path $OUTPUT_DIR "final_review_prompt_$TIMESTAMP.txt"

    & "$SCRIPT_DIR\build_prompt.ps1" `
        -ContextJson $CONTEXT_FILE `
        -RootDir     $ROOT_DIR `
        -OutputFile  $outputFile `
        -ConfigPath  $ConfigPath `
        -Timestamp   $TIMESTAMP

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR" "build_prompt.ps1 failed"
        exit 1
    }
    Assert-PathExists $outputFile "final_review_prompt.txt"
    Write-Log "OK" "Prompt generated: $outputFile"
    return $outputFile
}

function Write-Summary {
    param([hashtable]$Context, [string]$OutputFile)
    $size = (Get-Item $OutputFile).Length
    Write-Host ""
    Write-Host "======================================" -ForegroundColor DarkGray
    Write-Host " Review Prompt Generated" -ForegroundColor White
    Write-Host "======================================" -ForegroundColor DarkGray
    Write-Host " Language : $($Context.Language)"
    Write-Host " Mode     : $($Context.Mode)"
    Write-Host " Tier     : $($Context.Tier)"
    Write-Host " Agents   : $($Context.Agents -join ', ')"
    Write-Host " Skills   : $($Context.Skills.Count) loaded"
    Write-Host " Output   : $OutputFile"
    Write-Host " Size     : $([math]::Round($size/1KB, 1)) KB"
    Write-Host " Time     : $TIMESTAMP"
    Write-Host "======================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Next: Paste output\final_review_prompt.txt into Claude or ChatGPT." -ForegroundColor Cyan
}

try {
    Write-Log "INFO" "Enterprise AI Review Platform started"
    Write-Log "INFO" "Language=$Language / Mode=$Mode"

    Invoke-PreCheck
    Initialize-OutputDir

    $context    = Invoke-DetectContext
    $outputFile = Invoke-BuildPrompt -Context $context

    Write-Summary -Context $context -OutputFile $outputFile

    if (Test-Path $CONTEXT_FILE) {
        Remove-Item $CONTEXT_FILE -Force
        Write-Log "INFO" "Cleaned up: _context.json"
    }
}
catch {
    Write-Log "ERROR" "Unexpected error: $_"
    Write-Log "ERROR" $_.ScriptStackTrace
    exit 1
}
