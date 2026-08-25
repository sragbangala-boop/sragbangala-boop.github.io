@echo off
setlocal
set "YH_SELF=%~f0"
title Branch A-C GitHub Client Install and Authorization

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:YH_SELF,[Text.Encoding]::UTF8);$a=':__PS_'+'BEGIN__';$b=':__PS_'+'END__';$i=$s.IndexOf($a);$j=$s.IndexOf($b,$i+$a.Length);if($i-lt 0-or$j-lt 0){throw 'Embedded installer is missing.'};& ([ScriptBlock]::Create($s.Substring($i+$a.Length,$j-($i+$a.Length))))"
set "YH_EXIT=%ERRORLEVEL%"

echo.
if "%YH_EXIT%"=="0" (
  echo Client installation and authorization completed.
) else (
  echo Client installation or authorization failed. Exit code: %YH_EXIT%
)
echo.
pause
exit /b %YH_EXIT%

:__PS_BEGIN__
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$owner = 'sragbangala-boop'
$repository = 'branch-platform-private'
$expectedClientBytes = 19336
$expectedClientSha256 = '749CD8C3A07236BA00508D099A1F7D30B100D410758E0023E0877E2CDF855BF9'
$expectedManifestSha256 = '676D9593447E281320893C809D430DB41439E05A907E2FB2B0DD3C88F22252B2'
$simulationRoot = ([string]$env:YH_BAT_SIMULATION_ROOT).Trim()
$isSimulation = -not [string]::IsNullOrWhiteSpace($simulationRoot)
if ($isSimulation) { $simulationRoot = [IO.Path]::GetFullPath($simulationRoot) }
$clientRoot = if ($isSimulation) { Join-Path $simulationRoot 'ProgramData\YHBranchPlatform' } else { 'C:\ProgramData\YHBranchPlatform' }
$commandPath = if ($isSimulation) { Join-Path $simulationRoot 'Windows\System32\fengongsi.cmd' } else { 'C:\Windows\System32\fengongsi.cmd' }
$credentialPath = Join-Path $clientRoot 'github_token.dpapi'
$installedManifestPath = Join-Path $clientRoot 'client\client_manifest.json'
$tempRoot = Join-Path $env:TEMP ('YH_Branch_Client_Setup_' + [guid]::NewGuid().ToString('N'))
$exitCode = 0
$serverIsBlank = $false

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Test-StoredAuthorization([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $storedPtr = [IntPtr]::Zero
    $storedPlain = $null
    try {
        $cipherText = ([IO.File]::ReadAllText($Path,(New-Object Text.UTF8Encoding($false,$true)))).Trim()
        if ([string]::IsNullOrWhiteSpace($cipherText)) { return $false }
        $secure = $cipherText | ConvertTo-SecureString
        $storedPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $storedPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($storedPtr)
        $headers = @{
            Authorization = 'Bearer ' + $storedPlain
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'YH-Branch-Authorization-Verify'
        }
        $repo = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repository" -Headers $headers -UseBasicParsing
        return ([bool]$repo.private -and [string]$repo.full_name -ceq "$owner/$repository")
    }
    catch {
        return $false
    }
    finally {
        $storedPlain = $null
        if ($storedPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($storedPtr) }
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $isSimulation -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Right-click this BAT and select Run as administrator.'
    }

    $configPath = if ($isSimulation) { Join-Path $simulationRoot 'inetpub\wwwroot\stats\cf_api.txt' } else { 'C:\inetpub\wwwroot\stats\cf_api.txt' }
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = [IO.File]::ReadAllText($configPath,(New-Object Text.UTF8Encoding($false,$true))) | ConvertFrom-Json
        $role = ([string]$config.console_role).Trim().ToUpperInvariant()
        if ($role -notin @('A','C')) { throw 'Server role is not A or C.' }
        Write-Host ('SERVER_IDENTITY=INSTALLED_' + $role)
    }
    else {
        $serverIsBlank = $true
        do {
            $role = ([string](Read-Host 'Blank server detected. Enter the role to install (A or C)')).Trim().ToUpperInvariant()
        } while ($role -notin @('A','C'))
        Write-Host 'SERVER_IDENTITY=BLANK'
        Write-Host ('SELECTED_ROLE=' + $role)
    }
    Write-Host ('ROLE=' + $role)

    $clientIsCurrent = (
        (Test-Path -LiteralPath $commandPath -PathType Leaf) -and
        (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) -and
        ((Get-Sha256 $installedManifestPath) -ceq $expectedManifestSha256)
    )

    if ($clientIsCurrent) {
        Write-Host 'CLIENT=ALREADY_INSTALLED_CURRENT'
    }
    else {
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V7'
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $selfText = [IO.File]::ReadAllText($env:YH_SELF,[Text.Encoding]::UTF8)
        $beginMarker = ':__CLIENT_' + 'BEGIN__'
        $endMarker = ':__CLIENT_' + 'END__'
        $beginIndex = $selfText.IndexOf($beginMarker)
        $endIndex = $selfText.IndexOf($endMarker,$beginIndex + $beginMarker.Length)
        if ($beginIndex -lt 0 -or $endIndex -lt 0) { throw 'Embedded client archive is missing.' }
        $base64 = $selfText.Substring($beginIndex + $beginMarker.Length,$endIndex - ($beginIndex + $beginMarker.Length)) -replace '\s',''
        $archive = Join-Path $tempRoot 'branch-server-client-v1.zip'
        [IO.File]::WriteAllBytes($archive,[Convert]::FromBase64String($base64))
        if ((Get-Item -LiteralPath $archive).Length -ne $expectedClientBytes -or (Get-Sha256 $archive) -cne $expectedClientSha256) {
            throw 'Embedded client archive identity mismatch.'
        }
        $extract = Join-Path $tempRoot 'client'
        Expand-Archive -LiteralPath $archive -DestinationPath $extract
        $installer = Join-Path $extract 'Install-BranchClient.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Embedded client installer is missing.' }
        if ($isSimulation) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SourceDirectory $extract -SimulationRoot $simulationRoot
        }
        else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SourceDirectory $extract
        }
        if ($LASTEXITCODE -ne 0) { throw ('Client installation failed: ' + $LASTEXITCODE) }
    }

    if (
        -not (Test-Path -LiteralPath $commandPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) -or
        (Get-Sha256 $installedManifestPath) -cne $expectedManifestSha256
    ) {
        throw 'Installed client verification failed.'
    }
    Write-Host 'CLIENT_VERIFY=OK'

    if ($isSimulation -and (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        Write-Host 'AUTHORIZATION=SIMULATED_VALID'
    }
    elseif (Test-StoredAuthorization $credentialPath) {
        Write-Host 'AUTHORIZATION=ALREADY_VALID'
    }
    else {
        Write-Host 'AUTHORIZATION=REQUIRED'
        Write-Host 'Paste the GitHub fine-grained token at the hidden prompt.'
        $authorizationScript = Join-Path $clientRoot 'client\Save-GitHubCredential.ps1'
        if (-not (Test-Path -LiteralPath $authorizationScript -PathType Leaf)) {
            throw 'Authorization component is missing.'
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $authorizationScript -Owner $owner -Repository $repository
        if ($LASTEXITCODE -ne 0) { throw ('Authorization failed: ' + $LASTEXITCODE) }
        if (-not (Test-StoredAuthorization $credentialPath)) {
            throw 'Stored authorization verification failed.'
        }
    }

    Write-Host 'STATUS=AUTHORIZED_AND_CLIENT_READY'
    Write-Host ('ROLE=' + $role)
    Write-Host 'CLIENT_RELEASE=branch-client-v7'
    Write-Host 'TOKEN_STORED=WINDOWS_DPAPI_CURRENT_USER'

    if ($serverIsBlank) {
        Write-Host ''
        Write-Host 'AVAILABLE COMMANDS'
        Write-Host ('  1 - fengongsi quanxin ' + $role)
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        do { $choice = ([string](Read-Host 'Enter command number')).Trim() } while ($choice -notin @('0','1','9'))
        if ($choice -ceq '1') { $arguments = @('quanxin',$role) }
        elseif ($choice -ceq '9') { $arguments = @('bangzhu') }
        else { $arguments = @() }
    }
    else {
        Write-Host ''
        Write-Host 'AVAILABLE COMMANDS'
        Write-Host ('  1 - fengongsi xiufu ' + $role)
        Write-Host ('  2 - fengongsi caiji ' + $role)
        if ($role -ceq 'A') { Write-Host '  3 - fengongsi shengji VERSION' }
        if ($role -ceq 'C') { Write-Host '  3 - fengongsi jixu C' }
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        $allowedChoices = @('0','1','2','3','9')
        do { $choice = ([string](Read-Host 'Enter command number')).Trim() } while ($choice -notin $allowedChoices)
        if ($choice -ceq '1') { $arguments = @('xiufu',$role) }
        elseif ($choice -ceq '2') { $arguments = @('caiji',$role) }
        elseif ($choice -ceq '3' -and $role -ceq 'A') {
            do { $version = ([string](Read-Host 'Enter ELE version, for example 1.4.3')).Trim() } while ($version -notmatch '^\d+\.\d+\.\d+$')
            $arguments = @('shengji',$version)
        }
        elseif ($choice -ceq '3') { $arguments = @('jixu','C') }
        elseif ($choice -ceq '9') { $arguments = @('bangzhu') }
        else { $arguments = @() }
    }

    if ($arguments.Count) {
        $selectedCommand = 'fengongsi ' + ($arguments -join ' ')
        Write-Host ('SELECTED_COMMAND=' + $selectedCommand)
        if ($isSimulation) {
            Write-Host ('SIMULATED_COMMAND=' + $selectedCommand)
        }
        else {
            & $commandPath @arguments
            if ($LASTEXITCODE -ne 0) { throw ('Selected command failed: ' + $LASTEXITCODE) }
        }
    }
    else {
        Write-Host 'SELECTED_COMMAND=NONE'
    }
}
catch {
    $exitCode = 1
    Write-Host ('ERROR=' + $_.Exception.Message) -ForegroundColor Red
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        try { [IO.Directory]::Delete($tempRoot,$true) } catch {}
    }
}

exit $exitCode
:__PS_END__
:__CLIENT_BEGIN__
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
AAkAXAIAABZJAAAAAA==
:__CLIENT_END__
