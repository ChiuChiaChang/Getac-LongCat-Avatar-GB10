# GetacPPTAIStudio v1.3.1.50 — fix SlideVideoTransitions.cs CS0019
# Apply to a v1.3.1.49 source folder. Preserves assets/portraits locally.
param([string]$StudioRoot = (Get-Location).Path)
$ErrorActionPreference = 'Stop'
$file = Join-Path $StudioRoot "SlideVideoTransitions.cs"
if (-not (Test-Path $file)) { throw "Missing: $file" }
$old = '(i % 3 switch { 0 => "fade", 1 => "smoothleft", _ => "wipeleft" })'
$new = '((i % 3) switch { 0 => "fade", 1 => "smoothleft", _ => "wipeleft" })'
$raw = [System.IO.File]::ReadAllText($file)
if ($raw.Contains($new)) {
    Write-Host "CS0019 fix is already applied."
    exit 0
}
if (-not $raw.Contains($old)) { throw "Expected v1.3.1.49 expression not found; no changes made." }
$backup = "$file.before_v1.3.1.50"
Copy-Item -LiteralPath $file -Destination $backup -Force
[System.IO.File]::WriteAllText($file, $raw.Replace($old,$new), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Fixed: $file"
Write-Host "Backup: $backup"
Write-Host "Now run build.bat in your Studio source directory."
