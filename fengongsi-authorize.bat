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
$expectedClientBytes = 32843
$expectedClientSha256 = '175C48B3915F94FB3A1F91B70FB7D8A7D45927E82FB9279345C2188E9540FC2E'
$expectedManifestSha256 = 'ACFAFCE7B94A0301FC5A9B97661828D08BFA3AC1636D85B249F38C545EB3846B'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V9'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v9'
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
AEIDAADzfAAAAAA=
:__CLIENT_END__
