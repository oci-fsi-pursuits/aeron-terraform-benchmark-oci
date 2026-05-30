param(
  [Parameter(Mandatory = $true)]
  [string]$Region,

  [Parameter(Mandatory = $true)]
  [string]$AvailabilityDomain,

  [Parameter(Mandatory = $true)]
  [string]$CompartmentId,

  [Parameter(Mandatory = $true)]
  [string]$SubnetId,

  [Parameter(Mandatory = $true)]
  [string]$ImageId,

  [Parameter(Mandatory = $true)]
  [string]$SshPublicKey,

  [string]$Shape = "VM.Optimized3.Flex",
  [double]$Ocpus = 10,
  [double]$MemoryGb = 256,
  [int]$NodeCount = 2,
  [int]$CpgReadyDelaySeconds = 90,
  [switch]$KeepResources
)

$ErrorActionPreference = "Stop"

function New-TempJsonFile {
  param([Parameter(Mandatory = $true)]$Value)

  $path = [System.IO.Path]::GetTempFileName()
  $Value | ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $path -NoNewline -Encoding ascii
  return $path
}

function Invoke-OciJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

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

$stamp = Get-Date -Format "yyyyMMddHHmmss"
$name = "aeron-cpg-probe-$stamp"
$createdInstanceIds = New-Object System.Collections.Generic.List[string]
$cpgId = $null
$tempFiles = New-Object System.Collections.Generic.List[string]
$sshPublicKeyFile = $null

try {
  if (Test-Path -LiteralPath $SshPublicKey) {
    $sshPublicKeyFile = (Resolve-Path -LiteralPath $SshPublicKey).Path
  } else {
    $sshPublicKeyFile = [System.IO.Path]::GetTempFileName()
    $SshPublicKey | Set-Content -LiteralPath $sshPublicKeyFile -NoNewline -Encoding ascii
    $tempFiles.Add($sshPublicKeyFile)
  }

  $capabilitiesPath = New-TempJsonFile @{
    items = @(
      @{
        service = "compute"
        name    = "general"
      }
    )
  }
  $tempFiles.Add($capabilitiesPath)

  Write-Host "Creating temporary CPG $name in $Region / $AvailabilityDomain"
  $cpg = Invoke-OciJson @(
    "cpg", "cluster-placement-group", "create",
    "--region", $Region,
    "--compartment-id", $CompartmentId,
    "--availability-domain", $AvailabilityDomain,
    "--name", $name,
    "--description", "Temporary Aeron benchmark CPG capacity probe",
    "--type", "STANDARD",
    "--capabilities", "file://$capabilitiesPath"
  )
  $cpgId = $cpg.data.id
  Write-Host "CPG: $cpgId"

  Write-Host "Waiting $CpgReadyDelaySeconds seconds for CPG propagation"
  Start-Sleep -Seconds $CpgReadyDelaySeconds

  $shapeConfigPath = New-TempJsonFile @{
    ocpus       = $Ocpus
    memoryInGBs = $MemoryGb
  }
  $tempFiles.Add($shapeConfigPath)

  $platformConfigPath = New-TempJsonFile @{
    type                                 = "INTEL_VM"
    isSymmetricMultiThreadingEnabled     = $false
    areVirtualInstructionsEnabled        = $false
    isAccessControlServiceEnabled        = $false
    isInputOutputMemoryManagementUnitEnabled = $false
  }
  $tempFiles.Add($platformConfigPath)

  $launchOptionsPath = New-TempJsonFile @{
    networkType = "VFIO"
  }
  $tempFiles.Add($launchOptionsPath)

  for ($i = 1; $i -le $NodeCount; $i++) {
    $displayName = "$name-node-$i"
    Write-Host "Launching $displayName ($Shape, $Ocpus OCPU, $MemoryGb GB) in CPG"
    $instance = Invoke-OciJson @(
      "compute", "instance", "launch",
      "--region", $Region,
      "--compartment-id", $CompartmentId,
      "--availability-domain", $AvailabilityDomain,
      "--shape", $Shape,
      "--shape-config", "file://$shapeConfigPath",
      "--platform-config", "file://$platformConfigPath",
      "--launch-options", "file://$launchOptionsPath",
      "--cluster-placement-group-id", $cpgId,
      "--subnet-id", $SubnetId,
      "--assign-public-ip", "false",
      "--image-id", $ImageId,
      "--ssh-authorized-keys-file", $sshPublicKeyFile,
      "--display-name", $displayName,
      "--wait-for-state", "RUNNING",
      "--max-wait-seconds", "900"
    )
    $createdInstanceIds.Add($instance.data.id)
    Write-Host "RUNNING: $($instance.data.id)"
  }

  [pscustomobject]@{
    result              = "PASS"
    region              = $Region
    availability_domain = $AvailabilityDomain
    cpg_id              = $cpgId
    shape               = $Shape
    ocpus               = $Ocpus
    memory_gb           = $MemoryGb
    node_count          = $NodeCount
    instance_ids        = ($createdInstanceIds -join ",")
  } | ConvertTo-Json -Depth 5
}
catch {
  [pscustomobject]@{
    result              = "FAIL"
    region              = $Region
    availability_domain = $AvailabilityDomain
    cpg_id              = $cpgId
    shape               = $Shape
    ocpus               = $Ocpus
    memory_gb           = $MemoryGb
    node_count          = $NodeCount
    instance_ids        = ($createdInstanceIds -join ",")
    error               = $_.Exception.ToString()
  } | ConvertTo-Json -Depth 5
}
finally {
  if (-not $KeepResources) {
    foreach ($instanceId in $createdInstanceIds) {
      Write-Host "Terminating probe instance $instanceId"
      & oci compute instance terminate --region $Region --instance-id $instanceId --force --wait-for-state TERMINATED --max-wait-seconds 900 | Out-Null
    }
    if ($cpgId) {
      Write-Host "Deleting probe CPG $cpgId"
      & oci cpg cluster-placement-group delete --region $Region --cluster-placement-group-id $cpgId --force | Out-Null
    }
  }

  foreach ($path in $tempFiles) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }
}
