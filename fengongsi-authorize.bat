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
$expectedClientBytes = 33094
$expectedClientSha256 = '4C69D5A70C75683573CFC49EA87CE89AA6080D8CE4ECBFE280E00F4A1422143F'
$expectedManifestSha256 = '5789AA765C185F5181C404144B4843679B3949CE100019DCD8A8641BFE1B6AEC'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V10'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v10'
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
:__CLIENT_END__
