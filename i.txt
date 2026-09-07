Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$source = 'https://raw.githubusercontent.com/sragbangala-boop/sragbangala-boop.github.io/4f2c23e6aeef03b2c03f952dbd6ade51595af933/fengongsi-authorize.bat'
$expectedBytes = 65721
$expectedSha256 = '6D818CF626F0C461C0AAC05E5A911AA73115CA7605F811E7309979FC2A2EAA2B'
$destinationDirectory = 'C:\hotfix'
$destination = Join-Path $destinationDirectory 'fengongsi-authorize.bat'
$temporary = Join-Path $env:TEMP ('fengongsi-authorize-' + [guid]::NewGuid().ToString('N') + '.bat')

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

try {
    Invoke-WebRequest -Uri $source -UseBasicParsing -TimeoutSec 60 -OutFile $temporary
    if ((Get-Item -LiteralPath $temporary).Length -ne $expectedBytes -or (Get-Sha256 $temporary) -cne $expectedSha256) {
        throw 'Downloaded authorization BAT identity mismatch.'
    }

    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    if ((Get-Item -LiteralPath $destination).Length -ne $expectedBytes -or (Get-Sha256 $destination) -cne $expectedSha256) {
        throw 'Installed authorization BAT identity mismatch.'
    }

    Write-Host ('AUTHORIZATION_BAT=' + $destination)
    Write-Host ('SHA256=' + $expectedSha256)
    if ([string]$env:YH_PUBLIC_BOOTSTRAP_DOWNLOAD_ONLY -ceq '1') {
        Write-Host 'STATUS=VERIFIED_DOWNLOAD_ONLY'
        return
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $arguments = @('/d','/c','call',$destination)
    if ($isAdministrator) {
        & $env:ComSpec @arguments
        $exitCode = $LASTEXITCODE
    }
    else {
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        $exitCode = $process.ExitCode
    }

    if ($exitCode -ne 0) { throw "Authorization BAT failed: $exitCode" }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
