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
$expectedClientBytes = 31717
$expectedClientSha256 = '5905DA1D4A96A5392673B66728FEA1E22D9771063446C2B5B1FF0CEBD7EFF63E'
$expectedManifestSha256 = 'BE9DF577844FFF0EEFFA929F0B0BFFBE798763BD80445D2A32E8A374502DEAEB'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V8'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v8'
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
        if ($role -ceq 'A') {
            Write-Host '  3 - fengongsi shengji VERSION'
            Write-Host '  4 - fengongsi huanyu A NEW_DOMAIN'
        }
        if ($role -ceq 'C') { Write-Host '  3 - fengongsi jixu C [NEW_DOMAIN]' }
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        $allowedChoices = if($role-ceq'A'){@('0','1','2','3','4','9')}else{@('0','1','2','3','9')}
        do { $choice = ([string](Read-Host 'Enter command number')).Trim() } while ($choice -notin $allowedChoices)
        if ($choice -ceq '1') { $arguments = @('xiufu',$role) }
        elseif ($choice -ceq '2') { $arguments = @('caiji',$role) }
        elseif ($choice -ceq '3' -and $role -ceq 'A') {
            do { $version = ([string](Read-Host 'Enter ELE version, for example 1.4.3')).Trim() } while ($version -notmatch '^\d+\.\d+\.\d+$')
            $arguments = @('shengji',$version)
        }
        elseif ($choice -ceq '3') {
            $currentDomain=([string]$config.main_domain).Trim().TrimEnd('.').ToLowerInvariant()
            $newDomain=([string](Read-Host ('Enter new C control domain, or press Enter to continue '+$currentDomain))).Trim().TrimEnd('.').ToLowerInvariant()
            if([string]::IsNullOrWhiteSpace($newDomain)){$newDomain=$currentDomain}
            $arguments = @('jixu','C',$newDomain)
        }
        elseif ($choice -ceq '4') {
            do{$newDomain=([string](Read-Host 'Enter the new C control domain for A')).Trim().TrimEnd('.').ToLowerInvariant()}while([string]::IsNullOrWhiteSpace($newDomain))
            $arguments = @('huanyu','A',$newDomain)
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
cGhwUEsFBgAAAAAMAAwAQgMAAI14AAAAAA==
:__CLIENT_END__
