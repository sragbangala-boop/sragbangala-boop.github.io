Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$source = 'https://raw.githubusercontent.com/sragbangala-boop/sragbangala-boop.github.io/9b916db096a8668e9f3f3c12ada3925fe7bf503c/fengongsi-authorize.bat'
$expectedBytes = 57496
$expectedSha256 = '1FACE0BDE9D78E16D5E42EEC1A70FCC76948B5B594CE9830DC4A0ED0C7A14A7D'
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
