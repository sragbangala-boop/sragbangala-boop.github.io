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
$expectedClientBytes = 18569
$expectedClientSha256 = '71754A4A6CD4E787CF87E9D440DFCDAA4912EED6BB3E45F54D1175DDB768CFE5'
$expectedManifestSha256 = 'E1061236B79CD515D3F1904E58513337CB76BA505258011C1FE709FF693611BB'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V6'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v6'
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
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        $allowedChoices = if ($role -ceq 'A') { @('0','1','2','3','9') } else { @('0','1','2','9') }
        do { $choice = ([string](Read-Host 'Enter command number')).Trim() } while ($choice -notin $allowedChoices)
        if ($choice -ceq '1') { $arguments = @('xiufu',$role) }
        elseif ($choice -ceq '2') { $arguments = @('caiji',$role) }
        elseif ($choice -ceq '3') {
            do { $version = ([string](Read-Host 'Enter ELE version, for example 1.4.3')).Trim() } while ($version -notmatch '^\d+\.\d+\.\d+$')
            $arguments = @('shengji',$version)
        }
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
:__CLIENT_END__
