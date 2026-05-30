param(
  [Parameter(Mandatory = $true)]
  [string]$TenancyId,

  [Parameter(Mandatory = $true)]
  [string]$CompartmentId,

  [Parameter(Mandatory = $true)]
  [string]$SshPublicKey,

  [string[]]$Regions = @(
    "us-ashburn-1",
    "us-chicago-1",
    "ca-montreal-1",
    "ca-toronto-1",
    "uk-london-1",
    "uk-cardiff-1",
    "eu-marseille-1",
    "eu-madrid-1",
    "eu-zurich-1",
    "eu-amsterdam-1",
    "me-jeddah-1",
    "me-dubai-1",
    "ap-osaka-1",
    "ap-seoul-1",
    "ap-melbourne-1",
    "sa-santiago-1"
  ),

  [string]$Shape = "VM.Optimized3.Flex",
  [double]$Ocpus = 10,
  [double]$MemoryGb = 160,
  [int]$NodeCount = 2,
  [int]$CpgReadyDelaySeconds = 90,
  [int]$PerRegionAdLimit = 0,
  [string]$ImageId = "",
  [string]$OperatingSystem = "Canonical Ubuntu",
  [string]$OperatingSystemVersion = "24.04",
  [string]$CidrPrefix = "10.251",
  [string]$ResultsPath = "",
  [switch]$KeepPassingResources,
  [switch]$IncludePhoenixAndFrankfurt
)

$ErrorActionPreference = "Stop"

function Invoke-OciJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [switch]$AllowFailure
  )

  $raw = & oci @Arguments 2>&1 | ForEach-Object { $_.ToString() }
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    if ($AllowFailure) {
      return [pscustomobject]@{
        ok    = $false
        error = ($raw | Out-String).Trim()
      }
    }
    throw [System.Exception]::new(($raw | Out-String).Trim())
  }
  $text = ($raw | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  $jsonStart = $text.IndexOf("{")
  if ($jsonStart -lt 0) {
    $jsonStart = $text.IndexOf("[")
  }
  if ($jsonStart -gt 0) {
    $text = $text.Substring($jsonStart)
  }
  return $text | ConvertFrom-Json
}

function New-ProbeNetwork {
  param(
    [Parameter(Mandatory = $true)][string]$Region,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$CidrBlock,
    [Parameter(Mandatory = $true)][string]$SubnetCidrBlock
  )

  $vcn = Invoke-OciJson @(
    "network", "vcn", "create",
    "--region", $Region,
    "--compartment-id", $CompartmentId,
    "--cidr-block", $CidrBlock,
    "--display-name", "$Name-vcn",
    "--dns-label", ($Name -replace "[^A-Za-z0-9]", "").Substring(0, [Math]::Min(15, ($Name -replace "[^A-Za-z0-9]", "").Length)),
    "--wait-for-state", "AVAILABLE",
    "--max-wait-seconds", "300"
  )

  $subnet = Invoke-OciJson @(
    "network", "subnet", "create",
    "--region", $Region,
    "--compartment-id", $CompartmentId,
    "--vcn-id", $vcn.data.id,
    "--cidr-block", $SubnetCidrBlock,
    "--display-name", "$Name-subnet",
    "--dns-label", "probe",
    "--prohibit-public-ip-on-vnic", "true",
    "--wait-for-state", "AVAILABLE",
    "--max-wait-seconds", "300"
  )

  [pscustomobject]@{
    vcn_id    = $vcn.data.id
    subnet_id = $subnet.data.id
  }
}

function Remove-ProbeNetwork {
  param(
    [Parameter(Mandatory = $true)][string]$Region,
    [string]$SubnetId,
    [string]$VcnId
  )

  if ($SubnetId) {
    Write-Host "Deleting probe subnet $SubnetId"
    & oci network subnet delete --region $Region --subnet-id $SubnetId --force --wait-for-state TERMINATED --max-wait-seconds 300 | Out-Null
  }
  if ($VcnId) {
    Write-Host "Deleting probe VCN $VcnId"
    & oci network vcn delete --region $Region --vcn-id $VcnId --force --wait-for-state TERMINATED --max-wait-seconds 300 | Out-Null
  }
}

function Get-LatestPlatformImageId {
  param([Parameter(Mandatory = $true)][string]$Region)

  if (-not [string]::IsNullOrWhiteSpace($ImageId)) {
    return $ImageId
  }

  $images = Invoke-OciJson @(
    "compute", "image", "list",
    "--region", $Region,
    "--compartment-id", $CompartmentId,
    "--operating-system", $OperatingSystem,
    "--operating-system-version", $OperatingSystemVersion,
    "--shape", $Shape,
    "--sort-by", "TIMECREATED",
    "--sort-order", "DESC",
    "--all"
  )

  $image = @($images.data | Where-Object { $_."lifecycle-state" -eq "AVAILABLE" } | Select-Object -First 1)
  if (-not $image) {
    throw "No AVAILABLE $OperatingSystem $OperatingSystemVersion image found for $Shape in $Region"
  }
  return $image[0].id
}

function Get-AvailabilityDomains {
  param([Parameter(Mandatory = $true)][string]$Region)

  $ads = Invoke-OciJson @(
    "iam", "availability-domain", "list",
    "--region", $Region,
    "--compartment-id", $TenancyId
  )

  $names = @($ads.data | ForEach-Object { $_.name })
  if ($PerRegionAdLimit -gt 0) {
    $names = @($names | Select-Object -First $PerRegionAdLimit)
  }
  return $names
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$singleProbeScript = Join-Path $scriptDir "Test-OciCpgCapacity.ps1"
if (-not (Test-Path -LiteralPath $singleProbeScript)) {
  throw "Missing single-region probe script: $singleProbeScript"
}

if ($IncludePhoenixAndFrankfurt) {
  $Regions = @("us-phoenix-1", "eu-frankfurt-1") + $Regions
}
$Regions = @($Regions | Select-Object -Unique)

if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
  $ResultsPath = Join-Path (Get-Location) ("cpg-capacity-results-{0}.jsonl" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$results = New-Object System.Collections.Generic.List[object]
$regionIndex = 20

foreach ($region in $Regions) {
  Write-Host ""
  Write-Host "=== Testing region $region ==="
  $network = $null
  $regionResult = $null

  try {
    $ads = @(Get-AvailabilityDomains -Region $region)
    if ($ads.Count -eq 0) {
      throw "No availability domains returned"
    }

    $image = Get-LatestPlatformImageId -Region $region
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $name = "aeronprobe$stamp$regionIndex"
    $cidrBlock = "$CidrPrefix.$regionIndex.0/24"
    $subnetCidrBlock = "$CidrPrefix.$regionIndex.0/25"
    $network = New-ProbeNetwork -Region $region -Name $name -CidrBlock $cidrBlock -SubnetCidrBlock $subnetCidrBlock

    foreach ($ad in $ads) {
      Write-Host ""
      Write-Host "--- Probe $region / $ad ---"
      $probeOutput = & $singleProbeScript `
        -Region $region `
        -AvailabilityDomain $ad `
        -CompartmentId $CompartmentId `
        -SubnetId $network.subnet_id `
        -ImageId $image `
        -SshPublicKey $SshPublicKey `
        -Shape $Shape `
        -Ocpus $Ocpus `
        -MemoryGb $MemoryGb `
        -NodeCount $NodeCount `
        -CpgReadyDelaySeconds $CpgReadyDelaySeconds `
        -KeepResources:$KeepPassingResources

      $jsonLine = @($probeOutput | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
      if ($jsonLine) {
        $regionResult = $jsonLine | ConvertFrom-Json
      } else {
        $regionResult = [pscustomobject]@{
          result              = "FAIL"
          region              = $region
          availability_domain = $ad
          error               = ($probeOutput | Out-String).Trim()
        }
      }

      $regionResult | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $ResultsPath -Encoding ascii
      $results.Add($regionResult)

      if ($regionResult.result -eq "PASS") {
        Write-Host "PASS: $region / $ad"
        if ($KeepPassingResources) {
          Write-Host "Kept passing CPG/instances for benchmark follow-up."
        }
        break
      }
    }
  }
  catch {
    $regionResult = [pscustomobject]@{
      result              = "FAIL"
      region              = $region
      availability_domain = ""
      error               = $_.Exception.ToString()
    }
    $regionResult | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $ResultsPath -Encoding ascii
    $results.Add($regionResult)
    Write-Host "FAIL: $region - $($_.Exception.Message)"
  }
  finally {
    if ($network -and -not ($KeepPassingResources -and $regionResult -and $regionResult.result -eq "PASS")) {
      Remove-ProbeNetwork -Region $region -SubnetId $network.subnet_id -VcnId $network.vcn_id
    }
  }

  $regionIndex++
}

Write-Host ""
Write-Host "Results written to $ResultsPath"
$results | Sort-Object result, region, availability_domain | Format-Table result, region, availability_domain, shape, ocpus, memory_gb -AutoSize
