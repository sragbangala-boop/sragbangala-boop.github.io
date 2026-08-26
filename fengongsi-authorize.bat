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
$expectedClientBytes = 33518
$expectedClientSha256 = '10B17DBAF083822A506A7A4232E7066D78E2C682E4F39A63B3A20C92FF0BA17E'
$expectedManifestSha256 = 'C285AF10BE132BC9047B87CC2191D0A9A537CC179FBA0E95FE9955CFC3EA66AA'
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
        Write-Host 'CLIENT=INSTALLING_VERIFIED_V11'
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
    Write-Host 'CLIENT_RELEASE=branch-client-v11'
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
AAAAAAAAAAAAAAAAShkAAGZlbmdvbmdzaS5jbWRQSwECFAAUAAAACABnDhpddyykrj4HAADjGAAA
DQAAAAAAAAAAAAAAAAD8GQAAZmVuZ29uZ3NpLnBzMVBLAQIUABQAAAAIAHOmGV2HuDd78QUAAJwP
AAAYAAAAAAAAAAAAAAAAAGUhAABJbnN0YWxsLUJyYW5jaENsaWVudC5wczFQSwECFAAUAAAACABk
rhpdJxj4lpoIAACUFAAAFwAAAAAAAAAAAAAAAACMJwAASW52b2tlLUJyYW5jaEhvdGZpeC5wczFQ
SwECFAAUAAAACAB0rhpdzPivthcQAAA9OAAAFwAAAAAAAAAAAAAAAABbMAAASW52b2tlLUJyYW5j
aE1hc3Rlci5wczFQSwECFAAUAAAACABzphldg7lrNDAVAADZSQAAGQAAAAAAAAAAAAAAAACnQAAA
UHVibGlzaC1FbGVVcGdyYWRlT25BLnBzMVBLAQIUABQAAAAIAIYDGF1x2Pj/CAQAABIIAAAZAAAA
AAAAAAAAAAAAAA5WAABTYXZlLUdpdEh1YkNyZWRlbnRpYWwucHMxUEsBAhQAFAAAAAgAwKQaXX4m
6PzJGQAAxVgAAB4AAAAAAAAAAAAAAAAATVoAAFN3aXRjaC1CcmFuY2hDb250cm9sRG9tYWluLnBz
MVBLAQIUABQAAAAIAHOmGV2hTR26YQgAAM8ZAAAYAAAAAAAAAAAAAAAAAFJ0AABUZXN0LUVsZVVw
Z3JhZGVTdWl0ZS5wczFQSwECFAAUAAAACAAbehldr6cmG20CAADsBAAAIgAAAAAAAAAAAAAAAADp
fAAAdmVyaWZ5X2NfY3V0b3Zlcl9wcmVyZXF1aXNpdGVzLnBocFBLBQYAAAAADAAMAEIDAACWfwAA
AAA=
:__CLIENT_END__
