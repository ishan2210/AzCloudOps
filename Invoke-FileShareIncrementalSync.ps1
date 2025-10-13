<#
Incremental Azure File Share -> File Share sync (all shares) using AzCopy with SAS-in-URL.
- Copies only new/changed files (azcopy sync --delete-destination=false)
- Creates missing target shares
- CSV header aliases supported (same as blob script)

CSV headers (any case/spacing; any of these aliases work):
  SourceAccount:  sourceaccount, sourceaccountname, srcaccount, srcacct
  SourceKey:      sourcekey, sourceaccountkey, srckey
  TargetAccount:  targetaccount, destaccount, destaccountname, dstaccount, dstacct
  TargetKey:      targetkey, destaccountkey, dstkey
#>

param(
  [Parameter(Mandatory=$true)] [string]$CsvPath,
  [Parameter(Mandatory=$true)] [string]$AzCopyPath = "C:\Users\admini\Downloads\azcopy_windows_amd64_10.30.1\azcopy_windows_amd64_10.30.1\azcopy.exe",
  [string]$LogRoot = "$PSScriptRoot\AzCopy-Logs",
  [int]$Concurrency,
  [int]$SasHours = 24,   # validity for generated SAS tokens
  [switch]$WhatIf
)

function Test-Tool { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" } }
function New-Dir   { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }
function TrimSafe  { param($v) if ($null -eq $v) { "" } else { ([string]$v).Trim() } }

# Normalize row keys (lowercase, trimmed)
function Normalize-Row {
  param($Row)
  $h = @{}
  foreach ($p in $Row.PSObject.Properties) { $k = ([string]$p.Name).Trim().ToLower(); $h[$k] = TrimSafe $p.Value }
  return $h
}

# Resolve a field value by trying aliases
function Resolve-Field { param($Row, [string[]]$Aliases)
  foreach ($a in $Aliases) { if ($Row.ContainsKey($a) -and -not [string]::IsNullOrWhiteSpace($Row[$a])) { return $Row[$a] } }
  return ""
}

function Get-StorageContextFromKey {
  param([string]$AccountName,[string]$AccountKey)
  try {
    New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey -Protocol Https -ErrorAction Stop
  } catch { throw "Failed to create storage context for account '$AccountName'. $($_.Exception.Message)" }
}

function Ensure-ShareExists { param($Context,[string]$ShareName)
  $exists = $false
  try { $null = Get-AzStorageShare -Name $ShareName -Context $Context -ErrorAction Stop; $exists = $true } catch { $exists = $false }
  if (-not $exists) {
    Write-Host "  [+] Creating target share '$ShareName'..."
    New-AzStorageShare -Name $ShareName -Context $Context -ErrorAction Stop | Out-Null
  }
}

# Build SAS URLs for a File Share
# Source needs: rl (read, list)
# Destination needs: rlcw (read, list, create, write) so AzCopy can list and upload
function New-ShareSasUrls {
  param(
    [string]$SrcAccount, $SrcCtx, [string]$DstAccount, $DstCtx, [string]$ShareName, [datetime]$Expiry
  )
  $srcBase = "https://$SrcAccount.file.core.windows.net/$ShareName"
  $dstBase = "https://$DstAccount.file.core.windows.net/$ShareName"

  $srcSas = New-AzStorageShareSASToken -Name $ShareName -Context $SrcCtx -Permission rl   -ExpiryTime $Expiry -ErrorAction Stop
  $dstSas = New-AzStorageShareSASToken -Name $ShareName -Context $DstCtx -Permission rlcw -ExpiryTime $Expiry -ErrorAction Stop

  if ($srcSas[0] -ne '?') { $srcSas = '?' + $srcSas }
  if ($dstSas[0] -ne '?') { $dstSas = '?' + $dstSas }

  return @{
    SrcUrl = $srcBase + $srcSas
    DstUrl = $dstBase + $dstSas
  }
}

# Live-streaming AzCopy sync
function Start-AzCopySync {
  param(
    [string]$AzCopyExe,[string]$SrcUrl,[string]$DstUrl,[string]$JobDir,[int]$Concurrency,[switch]$WhatIf
  )

  if (-not (Test-Path -LiteralPath $JobDir)) { New-Dir -Path $JobDir }

  $env:AZCOPY_LOG_LOCATION = $JobDir
  $env:AZCOPY_JOB_PLAN_LOCATION = $JobDir
  if ($PSBoundParameters.ContainsKey('Concurrency') -and $Concurrency -gt 0) { $env:AZCOPY_CONCURRENCY_VALUE = $Concurrency }
  else { Remove-Item Env:\AZCOPY_CONCURRENCY_VALUE -ErrorAction SilentlyContinue }

  $args = @(
    'sync', $SrcUrl, $DstUrl,
    '--recursive=true',
    '--from-to=FileFile',
    '--log-level=INFO',
    '--delete-destination=false'
  )
  $logFile = Join-Path $JobDir ("azcopy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

  if ($WhatIf) { Write-Host "  [DRY-RUN] $AzCopyExe $($args -join ' ')"; return }

  Write-Host "    [AzCopy] $($args -join ' ')"
  & $AzCopyExe @args 2>&1 | Tee-Object -FilePath $logFile

  if ($LASTEXITCODE -ne 0) { throw "AzCopy failed. ExitCode=$LASTEXITCODE. See log: $logFile" }
  else { Write-Host ("    Synced OK. Log: {0}" -f $logFile) }
}

# ---------------- MAIN ----------------
try {
  Test-Tool -Path $AzCopyPath
  New-Dir -Path $LogRoot

  if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Write-Host "Installing Az.Storage module for the current user..."
    Install-Module Az.Storage -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module Az.Storage -ErrorAction Stop

  if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV not found: $CsvPath" }
  $raw = Import-Csv -Path $CsvPath
  if (-not $raw -or $raw.Count -eq 0) { throw "CSV contains no rows." }

  # Normalize rows
  $rows = @(); foreach ($r in $raw) { $rows += (Normalize-Row $r) }

  # Header aliases
  $aliasSrcAcct = @('sourceaccount','sourceaccountname','srcaccount','srcacct')
  $aliasSrcKey  = @('sourcekey','sourceaccountkey','srckey')
  $aliasDstAcct = @('targetaccount','destaccount','destaccountname','dstaccount','dstacct')
  $aliasDstKey  = @('targetkey','destaccountkey','dstkey')

  $summary = New-Object System.Collections.Generic.List[object]
  $rowIndex = 0
  foreach ($row in $rows) {
    $rowIndex++

    $srcAcct = TrimSafe (Resolve-Field $row $aliasSrcAcct)
    $srcKey  = TrimSafe (Resolve-Field $row $aliasSrcKey)
    $dstAcct = TrimSafe (Resolve-Field $row $aliasDstAcct)
    $dstKey  = TrimSafe (Resolve-Field $row $aliasDstKey)

    if ([string]::IsNullOrWhiteSpace($srcAcct) -or [string]::IsNullOrWhiteSpace($srcKey) -or
        [string]::IsNullOrWhiteSpace($dstAcct) -or [string]::IsNullOrWhiteSpace($dstKey)) {
      Write-Warning ("Skipping row #{0}: one or more required fields are empty. Row data: {1}" -f $rowIndex, ($row | ConvertTo-Json -Compress))
      continue
    }

    Write-Host ""
    Write-Host ("=== {0}  ==>  {1} ===" -f $srcAcct,$dstAcct)

    $srcCtx = Get-StorageContextFromKey -AccountName $srcAcct -AccountKey $srcKey
    $dstCtx = Get-StorageContextFromKey -AccountName $dstAcct -AccountKey $dstKey

    # Enumerate all source shares
    $shares = Get-AzStorageShare -Context $srcCtx -ErrorAction Stop
    if (-not $shares -or $shares.Count -eq 0) {
      Write-Host ("  No shares found in source account '{0}'." -f $srcAcct)
      $summary.Add([pscustomobject]@{ SourceAccount=$srcAcct; TargetAccount=$dstAcct; Shares=0; Status="No source shares" })
      continue
    }

    $syncedCount = 0
    $expiry = (Get-Date).AddHours($SasHours)

    foreach ($s in $shares) {
      $shareName = $s.Name
      Write-Host ("  -> Share: {0}" -f $shareName)

      # Ensure exists on target
      Ensure-ShareExists -Context $dstCtx -ShareName $shareName

      # Create SAS URLs (dest needs rlcw)
      $urls = New-ShareSasUrls -SrcAccount $srcAcct -SrcCtx $srcCtx -DstAccount $dstAcct -DstCtx $dstCtx -ShareName $shareName -Expiry $expiry
      $srcUrl = $urls.SrcUrl
      $dstUrl = $urls.DstUrl

      # Per share log dir
      $jobDir = Join-Path $LogRoot ("{0}-share-{1}" -f $srcAcct,$shareName)
      New-Dir -Path $jobDir

      # Incremental sync
      Start-AzCopySync -AzCopyExe $AzCopyPath -SrcUrl $srcUrl -DstUrl $dstUrl -JobDir $jobDir -Concurrency $Concurrency -WhatIf:$WhatIf
      $syncedCount++
    }

    $status = "Synced"; if ($WhatIf.IsPresent) { $status = "DRY-RUN complete" }
    $summary.Add([pscustomobject]@{ SourceAccount=$srcAcct; TargetAccount=$dstAcct; Shares=$syncedCount; Status=$status })
  }

  Write-Host ""
  Write-Host "==== SUMMARY ===="
  $summary | Format-Table -AutoSize
}
catch { Write-Error $_; exit 1 }
