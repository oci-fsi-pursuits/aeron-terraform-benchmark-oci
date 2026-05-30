param(
  [string]$TfvarsPath = "local-test-opt3-phx-vm10-pool.tfvars",
  [string]$Region = "sa-saopaulo-1",
  [string]$AvailabilityDomain = "pILZ:SA-SAOPAULO-1-AD-1",
  [string]$ImageId = "ocid1.image.oc1.sa-saopaulo-1.aaaaaaaakoj2pbsggofw6sejgzfbyhv7ityl2cwomcslu47t3ncmmkwsp6ca",
  [string]$Shape = "VM.Optimized3.Flex",
  [double]$Ocpus = 10,
  [double]$MemoryGb = 160,
  [int]$NodeCount = 2,
  [int]$CpgReadyDelaySeconds = 90,
  [switch]$KeepPassingResources
)

$ErrorActionPreference = "Stop"

function Get-TfvarString {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $match = [regex]::Match($Content, "$Name\s*=\s*`"([^`"]+)`"")
  if (-not $match.Success) {
    throw "Could not find $Name in $TfvarsPath"
  }
  return $match.Groups[1].Value
}

function Invoke-OciJson {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $raw = & oci @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $exit = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exit -ne 0) {
    throw [System.Exception]::new(($raw | Out-String).Trim())
  }
  $text = ($raw | Out-String).Trim()
  $jsonStart = $text.IndexOf("{")
  if ($jsonStart -lt 0) {
    $jsonStart = $text.IndexOf("[")
  }
  if ($jsonStart -gt 0) {
    $text = $text.Substring($jsonStart)
  }
  return $text | ConvertFrom-Json
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tfvarsFullPath = Join-Path $repoRoot $TfvarsPath
$tfvars = Get-Content -Raw -LiteralPath $tfvarsFullPath
$compartmentId = Get-TfvarString -Content $tfvars -Name "compartment_ocid"
$sshPublicKey = Get-TfvarString -Content $tfvars -Name "ssh_public_key"

$stamp = Get-Date -Format "yyyyMMddHHmmss"
$name = "aeronsp$stamp"
$vcnId = $null
$subnetId = $null

try {
  Write-Host "Creating temporary Sao Paulo VCN/subnet for CPG probe"
  $vcn = Invoke-OciJson @(
    "network", "vcn", "create",
    "--region", $Region,
    "--compartment-id", $compartmentId,
    "--cidr-block", "10.252.20.0/24",
    "--display-name", "$name-vcn",
    "--dns-label", "aeronsp",
    "--wait-for-state", "AVAILABLE",
    "--max-wait-seconds", "300"
  )
  $vcnId = $vcn.data.id

  $subnet = Invoke-OciJson @(
    "network", "subnet", "create",
    "--region", $Region,
    "--compartment-id", $compartmentId,
    "--vcn-id", $vcnId,
    "--cidr-block", "10.252.20.0/25",
    "--display-name", "$name-subnet",
    "--dns-label", "probe",
    "--prohibit-public-ip-on-vnic", "true",
    "--wait-for-state", "AVAILABLE",
    "--max-wait-seconds", "300"
  )
  $subnetId = $subnet.data.id

  Write-Host "Running CPG launch probe in $Region / $AvailabilityDomain"
  & (Join-Path $repoRoot "scripts\Test-OciCpgCapacity.ps1") `
    -Region $Region `
    -AvailabilityDomain $AvailabilityDomain `
    -CompartmentId $compartmentId `
    -SubnetId $subnetId `
    -ImageId $ImageId `
    -SshPublicKey $sshPublicKey `
    -Shape $Shape `
    -Ocpus $Ocpus `
    -MemoryGb $MemoryGb `
    -NodeCount $NodeCount `
    -CpgReadyDelaySeconds $CpgReadyDelaySeconds `
    -KeepResources:$KeepPassingResources
}
finally {
  if (-not $KeepPassingResources) {
    if ($subnetId) {
      Write-Host "Deleting temporary subnet $subnetId"
      & oci network subnet delete --region $Region --subnet-id $subnetId --force --wait-for-state TERMINATED --max-wait-seconds 300 | Out-Null
    }
    if ($vcnId) {
      Write-Host "Deleting temporary VCN $vcnId"
      & oci network vcn delete --region $Region --vcn-id $vcnId --force --wait-for-state TERMINATED --max-wait-seconds 300 | Out-Null
    }
  }
}
