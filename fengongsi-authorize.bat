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
$expectedClientBytes = 39398
$expectedClientSha256 = 'A146F4EA3EA9FC48F4A6615897A1865BAA909EB69A8FDB43F7C9378E803AA993'
$expectedManifestSha256 = '3E0AFE95207B8F7A4419EB9716CB3A6A3A7F2328FEB584CA56139CE1F8CA83D6'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V13'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v13'
    Write-Host 'TOKEN_STORED=WINDOWS_DPAPI_CURRENT_USER'

    if ($serverIsBlank) {
        Write-Host ''
        Write-Host 'AVAILABLE COMMANDS'
        Write-Host ('  1 - fengongsi quanxin ' + $role)
        if ($role -ceq 'A') { Write-Host '  2 - fengongsi qianyi A [SNAPSHOT_ZIP]' }
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        $blankChoices = if($role-ceq'A'){@('0','1','2','9')}else{@('0','1','9')}
        do { $choice = ([string](Read-Host 'Enter command number')).Trim() } while ($choice -notin $blankChoices)
        if ($choice -ceq '1') { $arguments = @('quanxin',$role) }
        elseif ($choice -ceq '2') {
            $snapshotPath=([string](Read-Host 'Enter A snapshot ZIP path, or press Enter to auto-detect C:\hotfix\incoming_A')).Trim().Trim('"')
            $arguments=if([string]::IsNullOrWhiteSpace($snapshotPath)){@('qianyi','A')}else{@('qianyi','A',$snapshotPath)}
        }
        elseif ($choice -ceq '9') { $arguments = @('bangzhu') }
        else { $arguments = @() }
    }
    else {
        Write-Host ''
        Write-Host 'AVAILABLE COMMANDS'
        Write-Host ('  1 - fengongsi xiufu ' + $role)
        Write-Host ('  2 - fengongsi caiji ' + $role)
        Write-Host ('  5 - fengongsi baohu ' + $role)
        if ($role -ceq 'A') {
            Write-Host '  3 - fengongsi shengji VERSION'
            Write-Host '  4 - fengongsi huanyu A NEW_DOMAIN'
        }
        if ($role -ceq 'C') { Write-Host '  3 - fengongsi jixu C [NEW_DOMAIN]' }
        Write-Host '  9 - fengongsi bangzhu'
        Write-Host '  0 - finish authorization only'
        $allowedChoices = if($role-ceq'A'){@('0','1','2','3','4','5','9')}else{@('0','1','2','3','5','9')}
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
        elseif ($choice -ceq '5') { $arguments = @('baohu',$role) }
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
AJQDAAA8lgAAAAA=
:__CLIENT_END__
