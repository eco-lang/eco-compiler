# Temporary diagnostic for the Windows-only Stage 7a hang: runs a command, and if it is still
# running after $Minutes, dumps every thread's stack with cdb, kills it and fails.
# Usage: pwsh -File diag-hang-dump.ps1 <minutes> <exe> <args...>
param([int]$Minutes, [string]$Exe, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

$out = Join-Path $env:TEMP "diag-hang.out"
$err = Join-Path $env:TEMP "diag-hang.err"
$quoted = $Rest | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
$null = $p.Handle  # keeps ExitCode readable after exit
$deadline = (Get-Date).AddMinutes($Minutes)
$samples = @()
while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep 30
    try { $p.Refresh(); $samples += "$(Get-Date -Format HH:mm:ss) cpu=$($p.TotalProcessorTime) ws=$([int]($p.WorkingSet64/1MB))MB threads=$($p.Threads.Count)" } catch {}
}
$hung = -not $p.HasExited
$samples | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
if ($hung) {
    Write-Host "=== HUNG after $Minutes min: thread stacks ==="
    $cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"
    if (Test-Path $cdb) {
        $symdir = Split-Path $Exe
        & $cdb -p $p.Id -c ".sympath+ $symdir;.reload /f;~*kn 80;q" 2>&1 | Select-Object -Last 3000 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "cdb not found at $cdb"
    }
    Stop-Process -Id $p.Id -Force
}
Write-Host "=== stdout (tail) ==="; Get-Content $out -Tail 200 | ForEach-Object { Write-Host $_ }
Write-Host "=== stderr (tail) ==="; Get-Content $err -Tail 200 | ForEach-Object { Write-Host $_ }
if ($hung) { exit 1 }
$p.WaitForExit()
exit $p.ExitCode
