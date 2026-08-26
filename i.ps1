Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$source = 'https://raw.githubusercontent.com/sragbangala-boop/sragbangala-boop.github.io/9068d45f9cc06db1d729e920c0a72e7309d20e32/fengongsi-authorize.bat'
$expectedBytes = 56914
$expectedSha256 = '14B6A8F1D0C2AA4774FB33C456B410C77488B78C93984B799731F81C1B82348E'
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
