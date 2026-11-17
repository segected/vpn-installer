#requires -Version 5.1
<#
    VPN Installer — установка VLESS + XHTTP + Reality на чистый сервер.
    Запускается через "Запустить установку VPN.cmd" или напрямую:
        powershell -ExecutionPolicy Bypass -File installer.ps1
#>
[CmdletBinding()]
param(
    [string]$Server,
    [int]$SshPort = 22,
    [ValidateSet('auto', 'key', 'password')]
    [string]$Auth = 'auto',
    [string]$SshKey,
    [string]$SshPassword,
    [string]$PanelPort = 'auto',
    [string]$PanelPath = 'auto',
    [string]$PanelUser = 'auto',
    [string]$PanelPassword = 'auto',
    [string]$Clients = 'phone,pc',
    [string]$Sni = 'www.otto.de',
    [switch]$Hysteria2,
    [switch]$NoAmnezia,
    [string]$AwgPort = 'auto',
    [switch]$PanelPublic,
    [switch]$NoSplitTunnel,
    [switch]$Harden,
    [switch]$NoHarden,
    [switch]$CheckIp,
    [switch]$NoCheckIp,
    [switch]$Diagnose,
    [switch]$CheckOnly,
    [switch]$Resume,
    [switch]$SelfTest,
    [switch]$Unattended,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:ToolsDir = Join-Path $script:Root 'tools'
$script:Plink = Join-Path $script:ToolsDir 'plink.exe'
$script:ServerScript = Join-Path $script:Root 'server-install.sh'
$script:XuiVersion = 'v3.11.0'
$script:XuiSha256 = '9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d'
$script:PlinkSha256 = '969f36879d5716aa1a9811f43a6a6510e8f08372dbeb9695b810b9c776f39c75'
$script:TempDir = Join-Path $env:TEMP ('vpn-installer-' + [guid]::NewGuid().ToString('N'))
$script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$script:LogPath = $null
$script:PwFile = $null
$script:PlinkHostKey = $null
$script:AuthMode = $null
$script:SshKeyPath = $null
$script:SshPasswordPlain = $null
$script:SshExe = $null
$script:Installed = $false
$script:ExitCode = 0
$script:ResultDir = $null
$script:Harden = $false
$script:CheckIp = $true

New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null

try { & chcp.com 65001 > $null } catch { }
try {
    [Console]::OutputEncoding = $script:Utf8
    [Console]::InputEncoding = $script:Utf8
    $global:OutputEncoding = $script:Utf8
} catch { }
try { $Host.UI.RawUI.WindowTitle = 'VPN Installer — VLESS + Reality' } catch { }

# =============================================================================
#  UI
# =============================================================================
function Show-Banner {
    Clear-Host
    $art = @'
   ██╗   ██╗██████╗ ███╗   ██╗
   ██║   ██║██╔══██╗████╗  ██║
   ██║   ██║██████╔╝██╔██╗ ██║
   ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║
    ╚████╔╝ ██║     ██║ ╚████║
     ╚═══╝  ╚═╝     ╚═╝  ╚═══╝
     open source
'@
    $colors = @('Cyan', 'Cyan', 'DarkCyan', 'DarkCyan', 'Blue', 'Blue')
    $lines = $art -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $c = $colors[[Math]::Min($i, $colors.Count - 1)]
        Write-Host $lines[$i] -ForegroundColor $c
    }
    Write-Host ''
    Write-Host '  VPN INSTALLER' -ForegroundColor White -NoNewline
    Write-Host '  ·  VLESS + XHTTP + Reality  ·  3x-ui' -ForegroundColor DarkGray
    Write-Host '  Чистый сервер → рабочий VPN за несколько минут.' -ForegroundColor Gray
    Write-Host '  Без перезагрузки. Без Docker. Без изменения SSH.' -ForegroundColor DarkGray
    Write-Host '  На каждый вопрос наберите ответ и нажмите Enter.' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 64)) -ForegroundColor DarkCyan
}

function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host "  × $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  · $Text" -ForegroundColor Gray }

function Read-Input {
    param([string]$Prompt, [string]$Default = '', [switch]$Required)
    while ($true) {
        Write-Host "  $Prompt" -ForegroundColor White -NoNewline
        if ($Default -ne '') { Write-Host " [$Default]" -ForegroundColor DarkGray -NoNewline }
        Write-Host ': ' -ForegroundColor DarkGray -NoNewline
        $value = [string](Read-Host)
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        $value = $value.Trim()
        if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
            Write-Warn 'Это поле обязательно.'
            continue
        }
        return $value
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $v = Read-Input "$Prompt ($hint)" ''
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        switch -Regex ($v.ToLowerInvariant()) {
            '^(y|yes|д|да)$' { return $true }
            '^(n|no|н|нет)$' { return $false }
            default { Write-Warn 'Ответьте y или n.' }
        }
    }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [int]$Default = 1)
    Write-Host "  $Prompt" -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $num = $i + 1
        $mark = if ($num -eq $Default) { '  ←' } else { '' }
        Write-Host ("   {0}) {1}{2}" -f $num, $Options[$i], $mark) -ForegroundColor Gray
    }
    while ($true) {
        $v = Read-Input 'Выбор' "$Default"
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
        Write-Warn "Введите число от 1 до $($Options.Count)."
    }
}

# =============================================================================
#  VALIDATION / HELPERS
# =============================================================================
function Test-IsHost([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -gt 253) { return $false }
    if ($Value -match '\.\.' -or $Value.StartsWith('.') -or $Value.EndsWith('.')) { return $false }
    return $Value -match '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

function Test-IsDomain([string]$Value) {
    if (-not (Test-IsHost $Value)) { return $false }
    return $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

function Test-IsPort([string]$Value, [int]$Min = 1, [int]$Max = 65535) {
    $n = 0
    if (-not [int]::TryParse($Value, [ref]$n)) { return $false }
    return ($n -ge $Min -and $n -le $Max)
}

function New-RandomString {
    param(
        [int]$Length = 24,
        [string]$Alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    )
    $bytes = New-Object byte[] $Length
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($Alphabet[$b % $Alphabet.Length]) }
    return $sb.ToString()
}

function Set-PrivateFileAcl([string]$Path) {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = Get-Acl -Path $Path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
    } catch { }
}

function Expand-LocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = $Path.Trim()
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Get-DefaultSshKey {
    foreach ($name in @('id_ed25519', 'id_rsa', 'id_ecdsa')) {
        $p = Join-Path $env:USERPROFILE ".ssh\$name"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'Не найден ssh.exe. Включите компонент Windows «OpenSSH Client».' }
    return $cmd.Source
}

function Test-Plink {
    if (-not (Test-Path -LiteralPath $script:Plink)) {
        throw "Не найден plink.exe: $($script:Plink)"
    }
    try { Unblock-File -LiteralPath $script:Plink -ErrorAction SilentlyContinue } catch { }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $script:Plink).Hash.ToLowerInvariant()
    if ($hash -ne $script:PlinkSha256) {
        throw "SHA-256 plink.exe не совпал. Файл повреждён или подменён.`nОжидался: $($script:PlinkSha256)`nПолучен:  $hash"
    }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $script:Plink
        if ($sig.SignerCertificate.Subject -notmatch 'Simon Tatham') {
            throw 'plink.exe подписан не Simon Tatham.'
        }
        if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'UnknownError') {
            throw "Подпись plink.exe недействительна: $($sig.Status)"
        }
    } catch {
        throw "Не удалось проверить подпись plink.exe: $($_.Exception.Message)"
    }
    return $true
}

function ConvertTo-PlainText([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Initialize-Auth {
    if ($Auth -eq 'auto') {
        if ($SshKey) { $script:AuthMode = 'key' }
        elseif ($SshPassword) { $script:AuthMode = 'password' }
        elseif ($Unattended) {
            $defaultKey = Get-DefaultSshKey
            if ($defaultKey) { $script:AuthMode = 'key'; $SshKey = $defaultKey }
            else { throw 'В unattended-режиме укажите -SshKey или -SshPassword.' }
        } else {
            Write-Title 'Доступ к серверу'
            Write-Host '  Как подключаться?' -ForegroundColor Gray
            Write-Host '   1) SSH-ключ — безопаснее, удобно для своего сервера' -ForegroundColor Gray
            Write-Host '   2) Пароль root — проще для нового сервера' -ForegroundColor Gray
            $choice = Read-Choice 'Способ входа' @('SSH-ключ', 'Пароль root') 2
            if ($choice -eq 1) { $script:AuthMode = 'key' } else { $script:AuthMode = 'password' }
        }
    } else {
        $script:AuthMode = $Auth
    }

    if ($script:AuthMode -eq 'key') {
        $script:SshExe = Get-SshExe
        if (-not $SshKey) {
            $defaultKey = Get-DefaultSshKey
            if ($Unattended) {
                if (-not $defaultKey) { throw 'Не найден SSH-ключ. Укажите -SshKey.' }
                $SshKey = $defaultKey
            } else {
                $SshKey = Read-Input 'Путь к SSH-ключу' $defaultKey -Required
            }
        }
        $SshKey = Expand-LocalPath $SshKey
        if (-not (Test-Path -LiteralPath $SshKey)) { throw "Файл ключа не найден: $SshKey" }
        if ($SshKey -match '\.ppk$') {
            throw 'Это PuTTY .ppk. OpenSSH не умеет его читать. Укажите ключ OpenSSH или выберите вход по паролю.'
        }
        $script:SshKeyPath = (Resolve-Path -LiteralPath $SshKey).Path
    } else {
        if (-not $SshPassword) {
            if ($Unattended) { throw 'В unattended-режиме укажите -SshPassword.' }
            Write-Host '  Пароль при вводе не показывается — так и должно быть.' -ForegroundColor DarkGray
            Write-Host '  Наберите пароль вслепую и нажмите Enter.' -ForegroundColor DarkGray
            $secure = Read-Host "  Пароль root@$Server" -AsSecureString
            $SshPassword = ConvertTo-PlainText $secure
        }
        if ([string]::IsNullOrEmpty($SshPassword)) { throw 'Пароль не введён.' }
        if ($SshPassword -match '[\r\n]') { throw 'Пароль не должен содержать перевод строки.' }
        $script:SshPasswordPlain = $SshPassword
        Test-Plink | Out-Null
        $script:PwFile = Join-Path $script:TempDir 'ssh-password.txt'
        [IO.File]::WriteAllText($script:PwFile, $SshPassword + "`n", $script:Utf8)
        Set-PrivateFileAcl $script:PwFile
    }
}

# =============================================================================
#  SSH / REMOTE
# =============================================================================
function Invoke-NativeStream {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$LogPath,
        [string]$InputText,
        [switch]$Quiet
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $oldEap = $ErrorActionPreference
    $exit = 1
    # Native tools write warnings to stderr; with ErrorActionPreference=Stop
    # PowerShell turns those into terminating errors. Soften it for this call.
    $ErrorActionPreference = 'Continue'
    try {
        $emit = {
            param($item)
            $line = [string]$item
            $lines.Add($line)
            if ($LogPath) { [IO.File]::AppendAllText($LogPath, $line + "`r`n", $script:Utf8) }
            # Service markers (__VPN_...__) are for parsing, not for people.
            if (-not $Quiet -and $line -notmatch '^\s*__VPN_[A-Z0-9_]+__\s*$') { Write-Host $line }
        }
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & $Exe @Arguments 2>&1 | ForEach-Object { & $emit $_ }
        } else {
            & $Exe @Arguments 2>&1 | ForEach-Object { & $emit $_ }
        }
        $exit = $LASTEXITCODE
        if ($null -eq $exit) { $exit = 0 }
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return [pscustomobject]@{
        Output   = $lines
        ExitCode = $exit
        Text     = ($lines -join "`n")
    }
}

function Resolve-PlinkHostKey {
    $baseArgs = @('-ssh', '-P', "$SshPort", '-batch', '-l', 'root', '-pwfile', $script:PwFile, $Server, 'echo __VPN_HOSTKEY_OK__')
    $first = Invoke-NativeStream -Exe $script:Plink -Arguments $baseArgs -Quiet
    if ($first.ExitCode -eq 0 -and $first.Text -match '__VPN_HOSTKEY_OK__') {
        $script:PlinkHostKey = $null
        return
    }
    $m = [regex]::Match($first.Text, 'SHA256:[A-Za-z0-9+/=]+')
    if (-not $m.Success) {
        throw "Не удалось подключиться по SSH. Проверьте адрес и пароль.`n$($first.Text.Trim())"
    }
    $script:PlinkHostKey = $m.Value
    $second = Invoke-NativeStream -Exe $script:Plink -Arguments @('-ssh', '-P', "$SshPort", '-batch', '-hostkey', $script:PlinkHostKey, '-l', 'root', '-pwfile', $script:PwFile, $Server, 'echo __VPN_HOSTKEY_OK__') -Quiet
    if ($second.ExitCode -ne 0 -or $second.Text -notmatch '__VPN_HOSTKEY_OK__') {
        throw "Сервер ответил, но вход не удался. Проверьте пароль root.`n$($second.Text.Trim())"
    }
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Quiet
    )
    if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue }
    $oldOut = $null
    $oldIn = $null
    try {
        $oldOut = [Console]::OutputEncoding
        $oldIn = $global:OutputEncoding
        [Console]::OutputEncoding = $script:Utf8
        # $OutputEncoding must be global: a function-local copy makes PowerShell
        # fall back to ASCII and Russian text turns into "?" on the server.
        $global:OutputEncoding = $script:Utf8

        # PowerShell appends CRLF to native stdin; keep it on a harmless comment line.
        $payload = $ScriptText.TrimEnd() + "`n# __vpn_payload_end__"

        if ($script:AuthMode -eq 'key') {
            $sshArgs = @(
                '-i', $script:SshKeyPath,
                '-p', "$SshPort",
                '-o', 'BatchMode=yes',
                '-o', 'StrictHostKeyChecking=accept-new',
                '-o', 'ConnectTimeout=15',
                '-o', 'ServerAliveInterval=30',
                "root@$Server",
                'bash -s'
            )
            return Invoke-NativeStream -Exe $script:SshExe -Arguments $sshArgs -LogPath $LogPath -InputText $payload -Quiet:$Quiet
        }

        $delim = "__VPN_INSTALL_$($script:RunId)__"
        $wrapper = "bash -s <<'$delim'`n" + $payload + "`n$delim`n"
        $wrapperPath = Join-Path $script:TempDir 'remote-command.sh'
        [IO.File]::WriteAllText($wrapperPath, $wrapper, $script:Utf8)
        $plinkArgs = @('-ssh', '-P', "$SshPort", '-batch', '-l', 'root', '-pwfile', $script:PwFile)
        if ($script:PlinkHostKey) { $plinkArgs += @('-hostkey', $script:PlinkHostKey) }
        $plinkArgs += @('-m', $wrapperPath, $Server)
        return Invoke-NativeStream -Exe $script:Plink -Arguments $plinkArgs -LogPath $LogPath -Quiet:$Quiet
    } finally {
        if ($null -ne $oldOut) { [Console]::OutputEncoding = $oldOut }
        if ($null -ne $oldIn) { $global:OutputEncoding = $oldIn }
    }
}

function Test-ServerConnection {
    $test = @'
. /etc/os-release 2>/dev/null || true
printf '__VPN_TEST_BEGIN__\n'
printf 'ID=%s\n' "${ID:-unknown}"
printf 'VERSION=%s\n' "${VERSION_ID:-unknown}"
printf 'PRETTY=%s\n' "${PRETTY_NAME:-unknown}"
printf 'ARCH=%s\n' "$(uname -m)"
printf 'MEM_KB=%s\n' "$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
printf 'MEM_AVAIL_KB=%s\n' "$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)"
printf 'DISK_KB=%s\n' "$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')"
if command -v systemctl >/dev/null 2>&1; then echo SYSTEMD=1; else echo SYSTEMD=0; fi
if command -v apt-get >/dev/null 2>&1; then echo APT=1; else echo APT=0; fi
if [ -d /usr/local/x-ui ] || [ -f /etc/systemd/system/x-ui.service ]; then echo XUI=1; else echo XUI=0; fi
if command -v ss >/dev/null 2>&1; then
  if ss -H -ltn 2>/dev/null | grep -q ':443 '; then echo PORT443=1; else echo PORT443=0; fi
else
  echo PORT443=?
fi
printf 'SSH_CONN=%s\n' "${SSH_CONNECTION:-}"
printf '__VPN_TEST_END__\n'
'@
    Write-Info "Проверяю, что это за сервер и подходит ли он..."
    $run = Invoke-RemoteScript -ScriptText $test -LogPath (Join-Path $script:TempDir 'connect.log') -Quiet
    if ($run.ExitCode -ne 0 -or $run.Text -notmatch '__VPN_TEST_END__') {
        throw "Не удалось выполнить команды на сервере.`n$($run.Text.Trim())"
    }
    $info = @{}
    foreach ($line in $run.Output) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $info[$Matches[1]] = $Matches[2] }
    }
    return $info
}

function Write-Fact([string]$Label, [string]$Value, [string]$Color = 'White') {
    Write-Host ('  ' + $Label.PadRight(15)) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Format-Size([double]$Megabytes) {
    if ($Megabytes -ge 1024) { return ('{0:0.#} ГБ' -f ($Megabytes / 1024)) }
    return ('{0:0} МБ' -f $Megabytes)
}

function Show-ServerInfo($Info) {
    Write-Title 'Сервер'
    Write-Ok "Связь с $Server есть, вход выполнен."

    Write-Host ''
    Write-Fact 'Система' $Info.PRETTY
    $arch = [string]$Info.ARCH
    if ($arch -eq 'x86_64') { $arch = 'x86_64, 64-бит' }
    elseif ($arch -eq 'aarch64') { $arch = 'ARM64, 64-бит' }
    Write-Fact 'Процессор' $arch

    if ($Info.MEM_KB) {
        $memMb = [double]$Info.MEM_KB / 1024
        $memText = 'всего ' + (Format-Size $memMb)
        if ($Info.MEM_AVAIL_KB) { $memText += ', свободно ' + (Format-Size ([double]$Info.MEM_AVAIL_KB / 1024)) }
        Write-Fact 'Память' $memText
    }
    if ($Info.DISK_KB) {
        $diskMb = [double]$Info.DISK_KB / 1024
        Write-Fact 'Диск' ('свободно ' + (Format-Size $diskMb))
    }

    if ($Info.XUI -eq '1') {
        Write-Fact '3x-ui' 'уже установлен — продолжим настройку' 'Yellow'
    } else {
        Write-Fact '3x-ui' 'ещё нет — поставим сейчас' 'Green'
    }
    if ($Info.PORT443 -eq '1') {
        if ($Info.XUI -eq '1' -and $Resume) {
            Write-Fact 'Порт 443' 'занят нашей панелью — так и должно быть' 'Green'
        } else {
            Write-Fact 'Порт 443' 'занят другой программой' 'Yellow'
        }
    } elseif ($Info.PORT443 -eq '0') {
        Write-Fact 'Порт 443' 'свободен — это то, что нужно' 'Green'
    }

    $problems = @()
    if ($Info.ID -notin @('ubuntu', 'debian')) {
        $problems += "Нужны Ubuntu или Debian, а на сервере $($Info.PRETTY)."
    }
    if ($Info.SYSTEMD -ne '1') { $problems += 'На сервере нет systemd — установщик не подходит.' }
    if ($Info.APT -ne '1') { $problems += 'На сервере нет apt — установщик не подходит.' }
    if ($Info.ARCH -notin @('x86_64', 'aarch64')) { $problems += "Процессор $($Info.ARCH) не поддерживается." }
    if ($Info.MEM_KB -and ([double]$Info.MEM_KB / 1024) -lt 400) {
        $problems += 'Мало памяти: лучше 512 МБ и больше.'
    }
    if ($Info.DISK_KB -and ([double]$Info.DISK_KB / 1048576) -lt 1.5) {
        $problems += 'Мало места на диске: нужно хотя бы 1,5 ГБ.'
    }
    if ($Info.XUI -eq '1' -and -not $Resume) {
        $problems += '3x-ui уже стоит. Если установка прерывалась — выберите пункт «Продолжить установку».'
    }
    if ($Info.PORT443 -eq '1' -and -not $Resume) {
        $problems += 'Порт 443 занят. Освободите его или возьмите другой сервер.'
    }

    Write-Host ''
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Err $p }
        throw ($problems -join ' ')
    }
    Write-Ok 'Сервер подходит для установки.'

    if ($Info.SSH_CONN) {
        $parts = $Info.SSH_CONN -split '\s+'
        if ($parts.Count -ge 4 -and $parts[3] -ne "$SshPort") {
            Write-Info "Сейчас SSH идёт через порт $($parts[3]); firewall разрешит оба порта."
        }
    }
}

# =============================================================================
#  OPTIONS
# =============================================================================
function Initialize-Options {
    if ($CheckOnly) {
        if ($PanelPort -ne 'auto' -and -not (Test-IsPort $PanelPort 1024 65535)) {
            throw 'Порт панели должен быть auto или числом 1024-65535.'
        }
        if ($PanelPort -eq '443') { throw 'Порт 443 занят VLESS. Выберите другой.' }
        $script:PanelPort = $PanelPort
        $script:PanelPath = 'auto'
        $script:PanelUser = 'auto'
        $script:PanelPassword = 'auto'
        $script:Clients = 'phone,pc'
        $script:Sni = 'www.otto.de'
        $script:EnableHy2 = $false
        $script:EnableAwg = $false
        $script:AwgPort = 'auto'
        $script:SplitTunnel = $false
        $script:Harden = $false
        $script:CheckIp = $false
        return
    }

    if (-not $Resume) {
    $panelProvided = $script:Bound.ContainsKey('PanelPort') -or $script:Bound.ContainsKey('PanelPath') -or
        $script:Bound.ContainsKey('PanelUser') -or $script:Bound.ContainsKey('PanelPassword')
    $panelManual = $false
    if (-not $Unattended -and -not $panelProvided) {
        Write-Title 'Панель 3x-ui'
        Write-Host '  Панель будет доступна только через SSH-туннель.' -ForegroundColor Gray
        $panelManual = Read-YesNo 'Настроить порт, путь, логин и пароль вручную?' $false
    }
    if ($panelManual) {
        while ($true) {
            $PanelPort = Read-Input 'Порт панели (auto или 1024-65535)' 'auto'
            if ($PanelPort -eq 'auto' -or (Test-IsPort $PanelPort 1024 65535)) { break }
            Write-Warn 'Нужно auto или число 1024-65535.'
        }
        if ($PanelPort -eq '443') { throw 'Порт 443 занят VLESS. Выберите другой.' }
        while ($true) {
            $PanelPath = Read-Input 'Путь панели (auto или 8-64 символа A-Z a-z 0-9 _ -)' 'auto'
            if ($PanelPath -eq 'auto' -or $PanelPath -match '^[A-Za-z0-9_-]{8,64}$') { break }
            Write-Warn 'Путь: 8-64 символа, только A-Z a-z 0-9 _ - (без слэшей).'
        }
        while ($true) {
            $PanelUser = Read-Input 'Логин панели (auto или 8-64 символа A-Z a-z 0-9 . _ -)' 'auto'
            if ($PanelUser -eq 'auto' -or $PanelUser -match '^[A-Za-z0-9._-]{8,64}$') { break }
            Write-Warn 'Логин: 8-64 символа, только A-Z a-z 0-9 . _ -'
        }
        if ($PanelPassword -eq 'auto') {
            $sec = Read-Host '  Пароль панели (Enter = авто)' -AsSecureString
            $plain = ConvertTo-PlainText $sec
            if (-not [string]::IsNullOrEmpty($plain)) {
                if ($plain.Length -lt 12) { throw 'Пароль панели должен быть не короче 12 символов.' }
                if ($plain -match '[\r\n]') { throw 'Пароль не должен содержать перевод строки.' }
                $PanelPassword = $plain
            }
        }
    } else {
        if (-not $script:Bound.ContainsKey('PanelPort')) { $PanelPort = 'auto' }
        if (-not $script:Bound.ContainsKey('PanelPath')) { $PanelPath = 'auto' }
        if (-not $script:Bound.ContainsKey('PanelUser')) { $PanelUser = 'auto' }
        if (-not $script:Bound.ContainsKey('PanelPassword')) { $PanelPassword = 'auto' }
    }
    if ($PanelPort -ne 'auto' -and -not (Test-IsPort $PanelPort 1024 65535)) { throw 'Порт панели должен быть auto или 1024-65535.' }
    if ($PanelPort -eq '443') { throw 'Порт 443 занят VLESS. Выберите другой.' }
    if ($PanelPath -ne 'auto' -and $PanelPath -notmatch '^[A-Za-z0-9_-]{8,64}$') { throw 'Некорректный путь панели.' }
    if ($PanelUser -ne 'auto' -and $PanelUser -notmatch '^[A-Za-z0-9._-]{8,64}$') { throw 'Некорректный логин панели.' }
    if ($PanelPassword -ne 'auto' -and $PanelPassword.Length -lt 12) { throw 'Пароль панели короче 12 символов.' }
    $script:PanelPort = $PanelPort
    $script:PanelPath = $PanelPath
    $script:PanelUser = $PanelUser
    $script:PanelPassword = $PanelPassword
    } else {
        $script:PanelPort = 'auto'
        $script:PanelPath = 'auto'
        $script:PanelUser = 'auto'
        $script:PanelPassword = 'auto'
    }

    if (-not $Unattended -and -not $script:Bound.ContainsKey('Clients')) {
        Write-Title 'Клиенты'
        Write-Host '  Для каждого устройства — отдельное имя и отдельный ключ.' -ForegroundColor Gray
        while ($true) {
            $raw = Read-Input 'Имена клиентов через запятую' 'phone,pc'
            $names = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            $bad = @($names | Where-Object { $_ -notmatch '^[A-Za-z0-9_-]{1,24}$' })
            if ($names.Count -ge 1 -and $names.Count -le 5 -and $bad.Count -eq 0) {
                $Clients = ($names -join ',')
                break
            }
            Write-Warn 'Нужно 1-5 имён, только латиница, цифры, _ и - (до 24 символов).'
        }
    }
    $names = @($Clients -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $bad = @($names | Where-Object { $_ -notmatch '^[A-Za-z0-9_-]{1,24}$' })
    if ($names.Count -lt 1 -or $names.Count -gt 5 -or $bad.Count -gt 0) {
        throw 'Клиенты: 1-5 имён, только A-Z a-z 0-9 _ - (до 24 символов).'
    }
    $script:Clients = ($names -join ',')

    if (-not $Unattended -and -not $script:Bound.ContainsKey('Sni')) {
        Write-Title 'Маскировка Reality'
        Write-Host '  Reality притворяется обычным сайтом. Нужен чужой сайт с TLS 1.3.' -ForegroundColor Gray
        $choice = Read-Choice 'Выберите SNI' @(
            'www.otto.de (проверен)',
            'www.microsoft.com',
            'www.apple.com',
            'www.cloudflare.com',
            'Свой домен'
        ) 1
        switch ($choice) {
            1 { $Sni = 'www.otto.de' }
            2 { $Sni = 'www.microsoft.com' }
            3 { $Sni = 'www.apple.com' }
            4 { $Sni = 'www.cloudflare.com' }
            5 {
                while ($true) {
                    $Sni = Read-Input 'Домен для маскировки' 'www.otto.de' -Required
                    if (Test-IsDomain $Sni) { break }
                    Write-Warn 'Некорректный домен. Пример: www.example.com'
                }
            }
        }
    }
    if (-not (Test-IsDomain $Sni)) { throw "Некорректный SNI: $Sni" }
    $script:Sni = $Sni

    $enableHy2 = $Hysteria2.IsPresent
    if (-not $Unattended -and -not $script:Bound.ContainsKey('Hysteria2')) {
        Write-Title 'Дополнительно'
        Write-Host '  Hysteria2 быстрый, но многие провайдеры режут UDP.' -ForegroundColor Gray
        Write-Host '  Если UDP заблокирован — Hysteria2 не заработает, VLESS продолжит работать.' -ForegroundColor DarkGray
        $enableHy2 = Read-YesNo 'Добавить Hysteria2 (UDP 443)?' $false
    }
    $script:EnableHy2 = $enableHy2

    $enableAwg = -not $NoAmnezia.IsPresent
    if (-not $Unattended -and -not $script:Bound.ContainsKey('NoAmnezia')) {
        Write-Title 'AmneziaWG'
        Write-Host '  Второй протокол для приложения AmneziaVPN. Работает без Docker.' -ForegroundColor Gray
        Write-Host '  Если Amnezia уже стоит на сервере — установщик её не тронет.' -ForegroundColor DarkGray
        Write-Host '  UDP может блокироваться провайдером; VLESS останется основным.' -ForegroundColor DarkGray
        $enableAwg = Read-YesNo 'Добавить AmneziaWG (UDP 51820)?' $true
    }
    if ($enableAwg) {
        if (-not $Unattended -and -not $script:Bound.ContainsKey('AwgPort')) {
            Write-Host '  Просто нажмите Enter — установщик сам выберет свободный порт.' -ForegroundColor DarkGray
            while ($true) {
                $AwgPort = Read-Input 'Порт AmneziaWG (Enter = авто)' 'auto'
                if ($AwgPort -eq 'auto' -or (Test-IsPort $AwgPort 1024 65535)) { break }
                Write-Warn 'Нужно auto или число 1024-65535.'
            }
        }
        if ($AwgPort -ne 'auto' -and -not (Test-IsPort $AwgPort 1024 65535)) {
            throw 'Порт AmneziaWG должен быть auto или числом 1024-65535.'
        }
        if ($AwgPort -eq '443') { throw 'Порт 443 занят VLESS/Hysteria2. Выберите другой.' }
        if ($AwgPort -eq "$script:PanelPort") {
            Write-Warn "Порт $AwgPort занят панелью. Ставлю auto."
            $AwgPort = 'auto'
        }
    }
    $script:EnableAwg = $enableAwg
    $script:AwgPort = $AwgPort

    $panelPublic = $PanelPublic.IsPresent
    if (-not $Unattended -and -not $script:Bound.ContainsKey('PanelPublic')) {
        Write-Title 'Панель 3x-ui'
        Write-Host '  По умолчанию панель видна только через SSH-туннель (безопаснее).' -ForegroundColor Gray
        Write-Host '  Вариант «да»: HTTPS с самоподписанным сертификатом, вход прямо по ссылке.' -ForegroundColor DarkGray
        Write-Host '  Тогда панель видна из интернета — пароль должен быть надёжным.' -ForegroundColor DarkGray
        $panelPublic = Read-YesNo 'Открыть панель из интернета по HTTPS?' $false
    }
    $script:PanelPublic = $panelPublic

    $splitTunnel = -not $NoSplitTunnel.IsPresent
    if (-not $Unattended -and -not $script:Bound.ContainsKey('NoSplitTunnel')) {
        Write-Title 'Белые списки'
        Write-Host '  Раздельное туннелирование: российские сайты — напрямую, остальное — через VPN.' -ForegroundColor Gray
        Write-Host '  Это настройка клиента (NekoBox/Hiddify/v2rayN), сервер не меняется.' -ForegroundColor DarkGray
        $splitTunnel = Read-YesNo 'Включить белые списки (российские сайты напрямую)?' $true
    }
    $script:SplitTunnel = $splitTunnel

    $harden = $Harden.IsPresent
    if (-not $Unattended -and -not $script:Bound.ContainsKey('Harden') -and -not $script:Bound.ContainsKey('NoHarden')) {
        Write-Title 'Защита сервера'
        Write-Host '  Установщик может сам усилить защиту сервера:' -ForegroundColor Gray
        Write-Host '   • SYN-cookies и защита от поддельных пакетов' -ForegroundColor DarkGray
        Write-Host '   • автоматические обновления безопасности (без перезагрузки)' -ForegroundColor DarkGray
        Write-Host '   • fail2ban: 5 ошибок — бан на час, повторно — на неделю' -ForegroundColor DarkGray
        Write-Host '  SSH-порт и sshd_config не меняются.' -ForegroundColor DarkGray
        $harden = Read-YesNo 'Включить защиту сервера?' $true
    }
    if ($NoHarden.IsPresent) { $harden = $false }
    $script:Harden = $harden

    $checkIp = $true
    if ($NoCheckIp.IsPresent) {
        $checkIp = $false
    } elseif (-not $Unattended -and -not $script:Bound.ContainsKey('CheckIp') -and -not $script:Bound.ContainsKey('NoCheckIp')) {
        Write-Title 'Проверка после установки'
        Write-Host '  После установки установщик проверит порты, TLS и панель,' -ForegroundColor Gray
        Write-Host '  поставит оценку и покажет, что именно не работает.' -ForegroundColor DarkGray
        $checkIp = Read-YesNo 'Проверить доступность и оценить?' $true
    }
    $script:CheckIp = $checkIp
}

function Show-Summary {
    Write-Title 'Проверьте настройки'
    Write-Host "  Сервер:        $Server`:$SshPort" -ForegroundColor Gray
    if ($script:AuthMode -eq 'key') {
        Write-Host "  Доступ:        SSH-ключ $($script:SshKeyPath)" -ForegroundColor Gray
    } else {
        Write-Host '  Доступ:        пароль root (не сохраняется)' -ForegroundColor Gray
    }
    if ($Resume) {
        Write-Host '  Панель:        существующая (данные возьмём с сервера)' -ForegroundColor Gray
    } else {
        Write-Host "  Панель:        порт $($script:PanelPort), путь /$($script:PanelPath)/" -ForegroundColor Gray
    }
    Write-Host "  Клиенты:       $($script:Clients)" -ForegroundColor Gray
    Write-Host "  Маскировка:    SNI $($script:Sni)" -ForegroundColor Gray
    Write-Host "  Hysteria2:     $(if ($script:EnableHy2) { 'да' } else { 'нет' })" -ForegroundColor Gray
    Write-Host "  AmneziaWG:     $(if ($script:EnableAwg) { 'да, UDP ' + $script:AwgPort } else { 'нет' })" -ForegroundColor Gray
    Write-Host "  Панель:        $(if ($script:PanelPublic) { 'HTTPS из интернета' } else { 'только через SSH-туннель' })" -ForegroundColor Gray
    Write-Host "  Белые списки:  $(if ($script:SplitTunnel) { 'да (российские сайты напрямую)' } else { 'нет, весь трафик через VPN' })" -ForegroundColor Gray
    Write-Host "  Защита сервера: $(if ($script:Harden) { 'да (sysctl, автообновления, fail2ban)' } else { 'нет' })" -ForegroundColor Gray
    Write-Host "  Проверка после: $(if ($script:CheckIp) { 'да, с оценкой' } else { 'нет' })" -ForegroundColor Gray
    Write-Host ''
    if (-not $Unattended) {
        if (-not (Read-YesNo 'Всё верно, начинаем установку?' $true)) {
            Write-Info 'Отменено пользователем.'
            return $false
        }
    }
    return $true
}

function Build-ServerScript {
    if (-not (Test-Path -LiteralPath $script:ServerScript)) {
        throw "Не найден server-install.sh: $($script:ServerScript)"
    }
    $text = [IO.File]::ReadAllText($script:ServerScript, [Text.Encoding]::UTF8)
    $passValue = if ($script:PanelPassword -eq 'auto') {
        'auto'
    } else {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:PanelPassword))
    }
    $map = @{
        '@@PUBLIC_HOST@@'          = $Server
        '@@SSH_PORT@@'             = "$SshPort"
        '@@PANEL_PORT@@'           = $script:PanelPort
        '@@PANEL_PATH@@'           = $script:PanelPath
        '@@PANEL_USER@@'           = $script:PanelUser
        '@@PANEL_PASS_B64@@'       = $passValue
        '@@CLIENT_NAMES@@'         = $script:Clients
        '@@ENABLE_HY2@@'           = $(if ($script:EnableHy2) { '1' } else { '0' })
        '@@ENABLE_AWG@@'           = $(if ($script:EnableAwg) { '1' } else { '0' })
        '@@AWG_PORT@@'             = $script:AwgPort
        '@@PANEL_PUBLIC@@'         = $(if ($script:PanelPublic) { '1' } else { '0' })
        '@@SPLIT_TUNNEL@@'         = $(if ($script:SplitTunnel) { '1' } else { '0' })
        '@@HARDEN@@'               = $(if ($script:Harden) { '1' } else { '0' })
        '@@CHECK_ONLY@@'           = $(if ($CheckOnly) { '1' } else { '0' })
        '@@RESUME@@'               = $(if ($Resume) { '1' } else { '0' })
        '@@XUI_VERSION@@'          = $script:XuiVersion
        '@@XUI_INSTALLER_SHA256@@' = $script:XuiSha256
        '@@SNI@@'                  = $script:Sni
    }
    foreach ($key in $map.Keys) { $text = $text.Replace($key, [string]$map[$key]) }
    if ($text -match '@@[A-Z0-9_]+@@') {
        $left = [regex]::Matches($text, '@@[A-Z0-9_]+@@') | ForEach-Object { $_.Value } | Select-Object -Unique
        throw "В server-install.sh остались незаменённые плейсхолдеры: $($left -join ', ')"
    }
    return $text
}

function Invoke-SyntaxCheck {
    param([string]$ScriptText, [string]$LogPath)
    $delim = "__VPN_SYNTAX_$($script:RunId)__"
    if ($ScriptText.Contains($delim)) { throw 'Случайный конфликт маркера. Запустите установщик ещё раз.' }
    $check = "bash -n <<'$delim'`n" + $ScriptText.TrimEnd() + "`n$delim`necho __VPN_SYNTAX_OK__`n# __vpn_syntax_end__"
    $run = Invoke-RemoteScript -ScriptText $check -LogPath $LogPath
    if ($run.ExitCode -ne 0 -or $run.Text -notmatch '__VPN_SYNTAX_OK__') {
        throw "Синтаксическая ошибка в серверном скрипте. Установка не начата.`n$($run.Text.Trim())"
    }
}

# =============================================================================
#  HTML RESULT PAGE
# =============================================================================
function HtmlEncode([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-HtmlPage {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][object[]]$Clients,
        [bool]$IncludePanel = $true,
        [string]$Title = 'VPN готов',
        [string]$Subtitle = '',
        [bool]$IncludeShareLinks = $true
    )

    $cards = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($c in @($Clients)) {
        $name = [string]$c.name
        $safe = $name -replace '[^A-Za-z0-9_-]', '_'
        $id = "link-$i"
        $link = HtmlEncode ([string]$c.link)
        $qr = [string]$c.qr_png_base64
        if ($qr) {
            $qrHtml = '<img src="data:image/png;base64,' + $qr + '" alt="QR ' + (HtmlEncode $name) + '">'
        } else {
            $qrHtml = '<div class="qr-empty">QR не сгенерирован</div>'
        }
        $share = ''
        if ($IncludeShareLinks) {
            $share = '<a class="btn ghost" href="share-' + $safe + '.html">Страница для получателя</a>'
        }
        $card = @'
<article class="card client">
  <div class="client-head">
    <div>
      <div class="eyebrow">КЛИЕНТ</div>
      <h2>{{NAME}}</h2>
    </div>
    <span class="pill">VLESS</span>
  </div>
  <div class="qr">{{QR_HTML}}</div>
  <div class="linkbox"><code id="{{ID}}">{{LINK}}</code></div>
  <div class="actions">
    <button class="btn" onclick="copyId('{{ID}}')">Скопировать ссылку</button>
    {{SHARE}}
  </div>
</article>
'@
        $card = $card.Replace('{{NAME}}', (HtmlEncode $name)).
            Replace('{{ID}}', $id).
            Replace('{{QR_HTML}}', $qrHtml).
            Replace('{{LINK}}', $link).
            Replace('{{SHARE}}', $share)
        [void]$cards.AppendLine($card)
        $i++
    }

    $warnings = ''
    if ($Result.hysteria2 -and $Result.hysteria2.enabled) {
        $warnings += '<div class="notice warn"><b>Hysteria2 включён.</b> UDP может блокироваться провайдером. Если Hysteria2 не работает — используйте VLESS: он основной.</div>'
    }
    if ($Result.split_tunnel) {
        $warnings += '<div class="notice"><b>Белые списки:</b> российские сайты — напрямую, остальное — через VPN. Это настройка клиента, инструкция ниже.</div>'
    } else {
        $warnings += '<div class="notice"><b>Режим:</b> весь трафик устройства идёт через VPN.</div>'
    }
    $warnings += '<div class="notice"><b>Ссылка = ключ доступа.</b> Не публикуйте её в открытых чатах и соцсетях.</div>'

    $verifyHtml = ''
    try {
        if ($IncludePanel -and $Result.verify) {
            $score = [int]$Result.verify.score
            $grade = HtmlEncode ([string]$Result.verify.grade)
            $cls = if ($score -ge 90) { 'ok' } elseif ($score -ge 75) { 'mid' } else { 'bad' }
            $rows = New-Object System.Text.StringBuilder
            foreach ($c in @($Result.verify.checks)) {
                if ($null -eq $c) { continue }
                $rowCls = if ($c.ok) { 'ok' } else { 'bad' }
                $mark = if ($c.ok) { '✓' } else { '×' }
                $where = if ([string]$c.where -eq 'pc') { ' · проверено с этого ПК' } else { '' }
                $detail = HtmlEncode ([string]$c.detail)
                if ($detail) { $detail = $detail + $where }
                [void]$rows.AppendLine('<li class="' + $rowCls + '"><span class="mark">' + $mark + '</span><div><b>' + (HtmlEncode ([string]$c.name)) + '</b><em>' + $detail + '</em></div></li>')
            }
            $verifyHtml = @'
<section class="card verify">
  <div class="verify-head">
    <div>
      <div class="eyebrow">САМОПРОВЕРКА</div>
      <h2>Проверка после установки</h2>
    </div>
    <div class="score {{CLS}}"><b>{{SCORE}}</b><span>%</span><em>{{GRADE}}</em></div>
  </div>
  <ul class="checks">{{ROWS}}</ul>
</section>
'@
            $verifyHtml = $verifyHtml.Replace('{{CLS}}', $cls).
                Replace('{{SCORE}}', [string]$score).
                Replace('{{GRADE}}', $grade).
                Replace('{{ROWS}}', $rows.ToString())
        }
    } catch { $verifyHtml = '' }

    $panel = ''
    if ($IncludePanel -and $Result.panel) {
        $panelUrl = [string]$Result.panel.url
        $panelIsPublic = $panelUrl -like 'https://*' -and $panelUrl -notlike 'https://127.0.0.1*' -and $panelUrl -notlike 'https://localhost*'
        if ($panelIsPublic) {
            $panelHowTo = '<p class="muted">Панель открыта из интернета по HTTPS. Сертификат самоподписанный — браузер один раз предупредит: «Дополнительно» → «Перейти на сайт».</p>'
        } else {
            $panelHowTo = '<p class="muted">Панель слушает только 127.0.0.1. Запустите <b>open-panel.cmd</b> из этой папки — туннель откроется сам, браузер запустится после подключения.</p>'
        }
        $panel = @'
<section class="card panel">
  <div class="eyebrow">АДМИНИСТРИРОВАНИЕ</div>
  <h2>Панель 3x-ui</h2>
  <div class="kv"><span>Адрес</span><code>{{PANEL_URL}}</code></div>
  <div class="kv"><span>Логин</span><code>{{PANEL_USER}}</code></div>
  <div class="kv"><span>Пароль</span><code>{{PANEL_PASS}}</code></div>
  <div class="kv"><span>Порт / путь</span><code>{{PANEL_PORT}} / {{PANEL_PATH}}</code></div>
  <div class="notice warn">В этой странице есть пароль панели. Другим людям отправляйте только share-*.html.</div>
  {{PANEL_HOWTO}}
</section>
'@
        $panel = $panel.Replace('{{PANEL_HOWTO}}', $panelHowTo)
        $panel = $panel.Replace('{{PANEL_URL}}', (HtmlEncode ([string]$Result.panel.url))).
            Replace('{{PANEL_USER}}', (HtmlEncode ([string]$Result.panel.username))).
            Replace('{{PANEL_PASS}}', (HtmlEncode ([string]$Result.panel.password))).
            Replace('{{PANEL_PORT}}', (HtmlEncode ([string]$Result.panel.port))).
            Replace('{{PANEL_PATH}}', (HtmlEncode ('/' + [string]$Result.panel.path + '/')))
    }

    $split = ''
    if ($Result.split_tunnel) {
        $splitNotes = [string]$Result.split_tunnel_notes
        if ([string]::IsNullOrWhiteSpace($splitNotes)) {
            $splitNotes = 'Включите в клиенте профиль «Bypass Russia» / «Russia direct»: российские сайты — напрямую, остальное — через VPN.'
        }
        $split = @'
<section class="card split">
  <div class="eyebrow">МАРШРУТИЗАЦИЯ</div>
  <h2>Белые списки</h2>
  <p class="muted">Российские сайты идут напрямую, остальное — через VPN. Настройка делается в клиенте.</p>
  <pre>{{SPLIT}}</pre>
</section>
'@
        $split = $split.Replace('{{SPLIT}}', (HtmlEncode $splitNotes))
    }

    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = 'VPN готов' }
    if ([string]::IsNullOrWhiteSpace($Subtitle)) { $Subtitle = "Сервер $($Result.host) · VLESS + XHTTP + Reality" }
    $date = [string]$Result.created_at
    if ([string]::IsNullOrWhiteSpace($date)) { $date = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $hostName = HtmlEncode ([string]$Result.host)

    $template = @'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root{--bg:#060a12;--panel:#0d1524;--panel2:#111c30;--text:#e9f0ff;--muted:#8ea3c7;--line:#1d2b45;--accent:#38bdf8;--accent2:#818cf8;--ok:#34d399;--warn:#fbbf24;--radius:18px}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%}
body{font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;background:radial-gradient(1100px 560px at 15% -10%,#12305a 0%,transparent 60%),radial-gradient(900px 520px at 100% 0%,#2a1a5e 0%,transparent 55%),var(--bg);color:var(--text);line-height:1.55}
a{color:var(--accent)}
.wrap{max-width:1120px;margin:0 auto;padding:42px 22px 70px}
header{padding:12px 0 26px}
.badge{display:inline-flex;align-items:center;gap:8px;padding:7px 12px;border-radius:999px;background:linear-gradient(90deg,rgba(56,189,248,.18),rgba(129,140,248,.18));border:1px solid rgba(56,189,248,.35);color:#bae6fd;font-size:12px;font-weight:700;letter-spacing:.12em}
h1{font-size:clamp(30px,4vw,52px);line-height:1.05;margin:16px 0 10px;letter-spacing:-.03em}
h2{font-size:24px;margin:4px 0 0;letter-spacing:-.02em}
.sub{color:var(--muted);font-size:17px;max-width:760px;margin:0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:18px;margin:24px 0}
.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:var(--radius);padding:22px;box-shadow:0 20px 60px rgba(0,0,0,.25)}
.client{display:flex;flex-direction:column;gap:16px}
.client-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
.eyebrow{font-size:11px;letter-spacing:.16em;color:var(--muted);text-transform:uppercase}
.pill{font-size:12px;padding:5px 10px;border-radius:999px;background:rgba(52,211,153,.12);border:1px solid rgba(52,211,153,.3);color:#a7f3d0;white-space:nowrap}
.qr{background:#fff;border-radius:14px;padding:12px;display:flex;justify-content:center;align-items:center;min-height:220px}
.qr img{width:100%;max-width:230px;height:auto;display:block}
.qr-empty{color:#334155;font-size:14px}
.linkbox{background:#070d18;border:1px solid var(--line);border-radius:12px;padding:12px;max-height:130px;overflow:auto}
.linkbox code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;word-break:break-all;color:#c7d7f5}
.actions{display:flex;gap:10px;flex-wrap:wrap}
.btn{appearance:none;border:1px solid rgba(56,189,248,.45);background:linear-gradient(180deg,rgba(56,189,248,.22),rgba(56,189,248,.1));color:#e0f2fe;padding:10px 14px;border-radius:11px;font-weight:600;cursor:pointer;text-decoration:none;font-size:14px}
.btn:hover{filter:brightness(1.15)}
.btn.ghost{background:transparent;border-color:var(--line);color:var(--text)}
.notice{border:1px solid var(--line);background:rgba(56,189,248,.06);border-radius:14px;padding:12px 14px;color:var(--muted);margin:14px 0;font-size:14px}
.notice.warn{border-color:rgba(251,191,36,.35);background:rgba(251,191,36,.07);color:#fde68a}
.notice b{color:var(--text)}
.muted{color:var(--muted)}
.panel .kv{display:grid;grid-template-columns:110px 1fr;gap:8px 14px;align-items:center;margin:10px 0;font-size:14px}
.kv span{color:var(--muted)}
.kv code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:13px;color:#c7d7f5;word-break:break-all}
.how .steps{display:grid;gap:10px;color:var(--muted)}
.how .steps b{color:var(--text)}
pre{white-space:pre-wrap;word-break:break-word;background:#070d18;border:1px solid var(--line);border-radius:12px;padding:14px;color:#c7d7f5;font-size:13px;overflow:auto}
.verify{margin:18px 0}
.verify-head{display:flex;justify-content:space-between;gap:16px;align-items:center;flex-wrap:wrap}
.score{display:flex;align-items:baseline;gap:2px;padding:10px 16px;border-radius:14px;border:1px solid var(--line);background:rgba(56,189,248,.08);white-space:nowrap}
.score b{font-size:30px;line-height:1}
.score span{font-size:15px;color:var(--muted)}
.score em{font-style:normal;font-size:13px;color:var(--muted);margin-left:8px}
.score.ok{border-color:rgba(52,211,153,.45);background:rgba(52,211,153,.1);color:#a7f3d0}
.score.mid{border-color:rgba(251,191,36,.45);background:rgba(251,191,36,.1);color:#fde68a}
.score.bad{border-color:rgba(248,113,113,.45);background:rgba(248,113,113,.1);color:#fecaca}
.checks{list-style:none;margin:16px 0 0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:8px 18px}
.checks li{display:flex;gap:10px;align-items:flex-start;font-size:14px;color:var(--muted)}
.checks .mark{width:20px;height:20px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;flex:none;margin-top:1px}
.checks li.ok .mark{background:rgba(52,211,153,.18);color:#6ee7b7}
.checks li.bad .mark{background:rgba(248,113,113,.18);color:#fca5a5}
.checks b{display:block;color:var(--text);font-weight:600}
.checks em{font-style:normal;font-size:12px;color:var(--muted)}
footer{margin-top:34px;color:var(--muted);font-size:13px;border-top:1px solid var(--line);padding-top:18px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%) translateY(20px);background:#0f1726;border:1px solid rgba(56,189,248,.4);color:#e0f2fe;padding:10px 16px;border-radius:12px;opacity:0;pointer-events:none;transition:.2s;box-shadow:0 10px 30px rgba(0,0,0,.4);z-index:99}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
@media(max-width:640px){.wrap{padding:24px 14px 50px}.card{padding:18px}.panel .kv{grid-template-columns:1fr}.qr{min-height:180px}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <div class="badge">VPN READY</div>
  <h1>{{TITLE}}</h1>
  <p class="sub">{{SUBTITLE}}</p>
</header>
{{WARNINGS}}
{{VERIFY}}
<section class="grid">
{{CARDS}}
</section>
{{PANEL}}
<section class="card how">
  <div class="eyebrow">ИНСТРУКЦИЯ</div>
  <h2>Как подключиться</h2>
  <div class="steps">
    <div><b>1.</b> Установите клиент: <b>v2rayNG</b>, <b>NekoBox</b> или <b>Hiddify</b> на телефон; <b>v2rayN</b>, <b>NekoBox</b> или <b>Hiddify</b> на ПК.</div>
    <div><b>2.</b> Отсканируйте QR или скопируйте ссылку и импортируйте её в клиент.</div>
    <div><b>3.</b> Включите VPN и проверьте <a href="https://ifconfig.me" target="_blank" rel="noopener">ifconfig.me</a> — должен показать <b>{{HOST}}</b>.</div>
  </div>
</section>
{{SPLIT}}
<footer>
  Сгенерировано VPN Installer · {{DATE}} · сервер {{HOST}}<br>
  Ссылка = доступ к VPN. Не публикуйте её в открытых местах.
</footer>
</div>
<div id="toast" class="toast"></div>
<script>
function toast(msg){var t=document.getElementById('toast');if(!t)return;t.textContent=msg;t.classList.add('show');clearTimeout(window.__toastTimer);window.__toastTimer=setTimeout(function(){t.classList.remove('show')},1800);}
function copyId(id){var el=document.getElementById(id);if(!el)return;var text=el.textContent;if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(text).then(function(){toast('Скопировано')},function(){fallbackCopy(text)});}else{fallbackCopy(text);}}
function fallbackCopy(text){var ta=document.createElement('textarea');ta.value=text;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.focus();ta.select();try{document.execCommand('copy');toast('Скопировано')}catch(e){toast('Не удалось скопировать')}document.body.removeChild(ta);}
</script>
</body>
</html>
'@

    return $template.Replace('{{TITLE}}', (HtmlEncode $Title)).
        Replace('{{SUBTITLE}}', (HtmlEncode $Subtitle)).
        Replace('{{WARNINGS}}', $warnings).
        Replace('{{VERIFY}}', $verifyHtml).
        Replace('{{CARDS}}', $cards.ToString()).
        Replace('{{PANEL}}', $panel).
        Replace('{{SPLIT}}', $split).
        Replace('{{HOST}}', $hostName).
        Replace('{{DATE}}', (HtmlEncode $date))
}

# =============================================================================
#  RESULT FILES
# =============================================================================
function Write-TextBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8Bom)
}

function Write-TextNoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function PsQuote([string]$Text) {
    if ($null -eq $Text) { return '' }
    return $Text.Replace("'", "''")
}

function New-OpenPanelScript {
    param($Result)
    $auth = $script:AuthMode
    $server = PsQuote ([string]$Result.host)
    $sshPort = [int]$Result.ssh_port
    $panelPort = [int]$Result.panel.port
    $panelPath = PsQuote ([string]$Result.panel.path)
    $url = PsQuote ([string]$Result.panel.url)
    $keyPath = PsQuote ([string]$script:SshKeyPath)

    $template = @'
$ErrorActionPreference = 'Stop'
$server = '{{SERVER}}'
$sshPort = {{SSH_PORT}}
$panelPort = {{PANEL_PORT}}
$panelPath = '{{PANEL_PATH}}'
$url = '{{URL}}'
$auth = '{{AUTH}}'
$keyPath = '{{KEY_PATH}}'
$hostKey = '{{HOSTKEY}}'

function Test-LocalPort {
    param([int]$Port)
    try {
        $client = New-Object Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

Write-Host ''
Write-Host '  VPN Panel Tunnel' -ForegroundColor Cyan
Write-Host '  ================' -ForegroundColor DarkCyan
Write-Host "  Сервер: $server" -ForegroundColor Gray
Write-Host "  Панель: $url" -ForegroundColor Gray
Write-Host ''

if ($url -like 'https://*' -and $url -notlike 'https://127.0.0.1*' -and $url -notlike 'https://localhost*') {
    Write-Host '  Панель открыта из интернета по HTTPS — туннель не нужен.' -ForegroundColor Gray
    Write-Host '  Браузер один раз предупредит о самоподписанном сертификате.' -ForegroundColor DarkGray
    Start-Process $url
    exit 0
}

if ($auth -eq 'key') {
    $exe = (Get-Command ssh.exe -ErrorAction Stop).Source
    $argString = '-i "' + $keyPath + '" -p ' + $sshPort + ' -N -L ' + $panelPort + ':127.0.0.1:' + $panelPort + ' -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes root@' + $server
} else {
    $exe = Join-Path $PSScriptRoot 'plink.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw 'Не найден plink.exe рядом с open-panel.ps1. Скопируйте его в эту папку.'
    }
    $argString = '-ssh -P ' + $sshPort + ' -N -L ' + $panelPort + ':127.0.0.1:' + $panelPort
    if ($hostKey -ne '') { $argString += ' -hostkey ' + $hostKey }
    $argString += ' root@' + $server
    Write-Host '  Сейчас откроется окно plink. Введите пароль SSH.' -ForegroundColor Yellow
}

Write-Host '  Открываю туннель...' -ForegroundColor Cyan
Start-Process -FilePath $exe -ArgumentList $argString | Out-Null

$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    if (Test-LocalPort $panelPort) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}

if ($ready) {
    Write-Host '  Туннель готов. Открываю панель...' -ForegroundColor Green
} else {
    Write-Host '  Туннель не поднялся за 60 секунд. Проверьте пароль/ключ и окно туннеля.' -ForegroundColor Yellow
}
Start-Process $url
Write-Host ''
Write-Host '  Не закрывайте окно туннеля, пока работаете с панелью.' -ForegroundColor DarkGray
Write-Host '  Это окно можно закрыть.' -ForegroundColor DarkGray
'@
    $template = $template.Replace('{{SERVER}}', $server).
        Replace('{{SSH_PORT}}', [string]$sshPort).
        Replace('{{PANEL_PORT}}', [string]$panelPort).
        Replace('{{PANEL_PATH}}', $panelPath).
        Replace('{{URL}}', $url).
        Replace('{{AUTH}}', $auth).
        Replace('{{KEY_PATH}}', $keyPath).
        Replace('{{HOSTKEY}}', (PsQuote ([string]$script:PlinkHostKey)))
    return $template
}

function New-ReadmeText {
    param($Result)
    $panel = $Result.panel
    $hy2 = if ($Result.hysteria2 -and $Result.hysteria2.enabled) {
        'Hysteria2 включён (UDP 443). Если провайдер режет UDP — используйте VLESS.'
    } else {
        'Hysteria2 не устанавливался. Основной протокол — VLESS.'
    }
    $split = if ($Result.split_tunnel) {
        'Включены белые списки: российские сайты — напрямую, остальное — через VPN. Настройка в клиенте, см. split-tunnel.txt.'
    } else {
        'Белые списки не включены: весь трафик идёт через VPN.'
    }
    $awg = if ($Result.amneziawg -and $Result.amneziawg.enabled) {
        "AmneziaWG включён (UDP $($Result.amneziawg.port)). Файлы amnezia-<имя>.conf импортируются в AmneziaVPN."
    } elseif ($Result.amneziawg -and $Result.amneziawg.skipped) {
        'AmneziaWG не ставился: на сервере уже есть Amnezia, установщик её не трогал.'
    } else {
        'AmneziaWG не устанавливался.'
    }
    $plinkNote = if ($script:AuthMode -eq 'password') {
        'Для панели используется plink.exe из этой папки. Пароль SSH вводится при запуске open-panel.cmd.'
    } else {
        'Для панели используется ваш SSH-ключ. Пароль вводить не нужно, если ключ без парольной фразы.'
    }
    $panelAccess = if (([string]$panel.url) -like 'https://*' -and ([string]$panel.url) -notlike 'https://127.0.0.1*' -and ([string]$panel.url) -notlike 'https://localhost*') {
        @'
- Открывается из интернета по HTTPS (самоподписанный сертификат).
- Браузер один раз предупредит: «Дополнительно» → «Перейти на сайт».
- Пароль панели должен быть надёжным: она видна из интернета.
'@
    } else {
        @'
- Панель слушает только 127.0.0.1 и снаружи закрыта.
- Запустите open-panel.cmd — туннель и браузер откроются сами.
'@
    }
    $verifyText = 'Самопроверка не проводилась.'
    try {
        if ($Result.verify) {
            $vlines = @("Оценка: $($Result.verify.score)% — $($Result.verify.grade)")
            foreach ($c in @($Result.verify.checks)) {
                if ($null -eq $c) { continue }
                $mark = if ($c.ok) { '[OK] ' } else { '[!!] ' }
                $detail = if ([string]::IsNullOrWhiteSpace([string]$c.detail)) { '' } else { " — $($c.detail)" }
                $vlines += $mark + [string]$c.name + $detail
            }
            $verifyText = ($vlines -join "`r`n")
        }
    } catch { }
    $hardenText = if ($script:Harden) {
        'Защита сервера включена: SYN-cookies, автообновления безопасности, fail2ban (повторные — бан на неделю).'
    } else {
        'Защита сервера не включалась (можно включить повторной установкой).'
    }
    $template = @'
VPN установлен
==============
Сервер: {{HOST}}
Дата:   {{DATE}}

ЧТО ВНУТРИ
- index.html          — откройте в браузере: QR, ссылки, панель.
- share-<имя>.html    — отправьте получателю (там только его ключ).
- links.txt           — все ссылки.
- split-tunnel.txt    — как включить белые списки в клиенте.
- amnezia-<имя>.conf  — файл для AmneziaVPN (если AmneziaWG включён).
- amnezia.html        — QR и инструкция для AmneziaWG.
- open-panel.cmd      — открыть панель через SSH-туннель.
- install.log         — лог установки.
- result.json         — машинные данные установки (для разбора проблем).
- checksums.txt       — SHA-256 файлов.

КАК ПОДКЛЮЧИТЬСЯ
1. Телефон: v2rayNG / NekoBox / Hiddify → отсканировать QR.
2. ПК: v2rayN / NekoBox / Hiddify → импортировать ссылку.
3. AmneziaWG: AmneziaVPN → + → «Файл настроек» → amnezia-<имя>.conf.
4. Проверка: https://ifconfig.me должен показать {{HOST}}.

ПАНЕЛЬ 3X-UI
{{PANEL_ACCESS}}
- Адрес: {{PANEL_URL}}
- Логин: {{PANEL_USER}}
- Пароль: {{PANEL_PASS}}
- Порт / путь: {{PANEL_PORT}} / {{PANEL_PATH}}
- {{PLINK_NOTE}}

РЕЖИМ
- {{SPLIT}}
- {{HY2}}
- {{AWG}}

ПРОВЕРКА
{{VERIFY_TEXT}}

БЕЗОПАСНОСТЬ
- {{HARDEN}}
- В этой папке ключи и пароль панели. Не публикуйте её.
- Другим людям отправляйте только share-<имя>.html.
- Ссылка = доступ к VPN. Не выкладывайте её в открытый доступ.
- Не отправляйте result.json и install.log посторонним.

ЕСЛИ ЧТО-ТО НЕ РАБОТАЕТ
- Проверьте, что другие VPN выключены.
- Попробуйте другой клиент (v2rayNG/NekoBox/Hiddify/v2rayN).
- Лог установки: install.log.
- На сервере: systemctl status x-ui.
- Не делайте reboot без необходимости.
'@
    return $template.Replace('{{HOST}}', [string]$Result.host).
        Replace('{{DATE}}', [string]$Result.created_at).
        Replace('{{PANEL_URL}}', [string]$panel.url).
        Replace('{{PANEL_USER}}', [string]$panel.username).
        Replace('{{PANEL_PASS}}', [string]$panel.password).
        Replace('{{PANEL_PORT}}', [string]$panel.port).
        Replace('{{PANEL_PATH}}', '/' + [string]$panel.path + '/').
        Replace('{{PANEL_ACCESS}}', $panelAccess).
        Replace('{{PLINK_NOTE}}', $plinkNote).
        Replace('{{SPLIT}}', $split).
        Replace('{{HY2}}', $hy2).
        Replace('{{AWG}}', $awg).
        Replace('{{VERIFY_TEXT}}', $verifyText).
        Replace('{{HARDEN}}', $hardenText)
}

function New-AmneziaPage {
    param(
        [Parameter(Mandatory = $true)]$Result
    )
    $awg = $Result.amneziawg
    $cards = New-Object System.Text.StringBuilder
    foreach ($c in @($awg.clients)) {
        $name = [string]$c.name
        $safe = $name -replace '[^A-Za-z0-9_-]', '_'
        $qr = [string]$c.qr_png_base64
        if ($qr) {
            $qrHtml = '<img src="data:image/png;base64,' + $qr + '" alt="QR ' + (HtmlEncode $name) + '">'
        } else {
            $qrHtml = '<div class="qr-empty">QR не сгенерирован — используйте файл .conf</div>'
        }
        [void]$cards.AppendLine(@"
<article class="card client">
  <div class="client-head">
    <div>
      <div class="eyebrow">AMNEZIAWG</div>
      <h2>$(HtmlEncode $name)</h2>
    </div>
    <span class="pill">UDP $($awg.port)</span>
  </div>
  <p class="muted">IP в VPN: $(HtmlEncode ([string]$c.ip)) · Endpoint: $(HtmlEncode ([string]$Result.host)):$($awg.port)</p>
  <div class="qr">$qrHtml</div>
  <div class="actions">
    <a class="btn" href="amnezia-$safe.conf" download>Скачать .conf</a>
  </div>
  <details>
    <summary>Показать конфиг</summary>
    <pre>$(HtmlEncode ([string]$c.config))</pre>
  </details>
</article>
"@)
    }

    $html = @"
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AmneziaWG — VPN</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#0b1020;color:#e8ecff;font:16px/1.5 system-ui,Segoe UI,Arial,sans-serif}
main{max-width:980px;margin:0 auto;padding:32px 18px 64px}h1{margin:0 0 6px;font-size:32px}
.muted{color:#9aa4c7}.cards{display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));margin-top:22px}
.card{background:#121a33;border:1px solid #26325a;border-radius:18px;padding:20px}
.client-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
.eyebrow{font-size:11px;letter-spacing:.16em;color:#7f8bb5}.pill{background:#1d2a52;border:1px solid #35457a;border-radius:999px;padding:4px 10px;font-size:12px}
.qr{margin:18px 0;text-align:center}.qr img{width:220px;height:220px;background:#fff;border-radius:12px;padding:8px}
.btn{display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;border-radius:10px;padding:10px 14px;font-weight:600}
pre{white-space:pre-wrap;word-break:break-word;background:#0a0f1f;border:1px solid #26325a;border-radius:12px;padding:14px;font-size:12px}
details{margin-top:14px}summary{cursor:pointer;color:#9aa4c7}
.note{background:#15203d;border:1px solid #2b3a6b;border-radius:14px;padding:14px 16px;margin-top:18px}
</style>
</head>
<body><main>
<h1>AmneziaWG</h1>
<p class="muted">Сервер $(HtmlEncode ([string]$Result.host)) · UDP $($awg.port)</p>
<div class="note">
  <b>Как подключить:</b> установите AmneziaVPN → нажмите «+» → «Файл настроек» → выберите
  <code>amnezia-&lt;имя&gt;.conf</code>. QR можно отсканировать в приложении, но файл надёжнее.
  Если AmneziaWG не подключается — используйте VLESS из index.html.
</div>
<div class="cards">
$($cards.ToString())
</div>
</main></body></html>
"@
    return $html
}

function Write-ResultFiles {
    param($Result)
    $base = $script:Root
    try {
        $probe = Join-Path $base ('.vpn-write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
    } catch {
        $base = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    }
    $safeHost = ([string]$Result.host) -replace '[^A-Za-z0-9.-]', '_'
    $outDir = Join-Path $base ("vpn-result-$safeHost-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $clients = @($Result.clients)
    foreach ($c in $clients) {
        $qr = [string]$c.qr_png_base64
        if ($qr) {
            $name = [string]$c.name
            [IO.File]::WriteAllBytes((Join-Path $outDir ("qr-$name.png")), [Convert]::FromBase64String($qr))
        }
    }

    $awgClients = @()
    if ($Result.amneziawg -and $Result.amneziawg.enabled) {
        $awgClients = @($Result.amneziawg.clients)
        foreach ($c in $awgClients) {
            $name = [string]$c.name
            $safe = $name -replace '[^A-Za-z0-9_-]', '_'
            Write-TextNoBom (Join-Path $outDir ("amnezia-$safe.conf")) ([string]$c.config)
            $qr = [string]$c.qr_png_base64
            if ($qr) {
                [IO.File]::WriteAllBytes((Join-Path $outDir ("qr-$safe-awg.png")), [Convert]::FromBase64String($qr))
            }
        }
        Write-TextBom (Join-Path $outDir 'amnezia.html') (New-AmneziaPage -Result $Result)
    }

    $links = New-Object System.Text.StringBuilder
    [void]$links.AppendLine("VPN $($Result.host) — ссылки")
    [void]$links.AppendLine("Дата: $($Result.created_at)")
    [void]$links.AppendLine('')
    [void]$links.AppendLine('=== VLESS + XHTTP + Reality (TCP 443) — ОСНОВНОЙ ===')
    [void]$links.AppendLine('')
    foreach ($c in $clients) {
        [void]$links.AppendLine("[$($c.name)]")
        [void]$links.AppendLine([string]$c.link)
        [void]$links.AppendLine('')
    }
    if ($Result.hysteria2 -and $Result.hysteria2.enabled) {
        [void]$links.AppendLine('=== Hysteria2 (UDP 443) ===')
        [void]$links.AppendLine('Внимание: UDP может блокироваться провайдером. Если не работает — используйте VLESS.')
        [void]$links.AppendLine('')
        foreach ($h in @($Result.hysteria2.clients)) {
            [void]$links.AppendLine("[$($h.name)]")
            [void]$links.AppendLine([string]$h.link)
            [void]$links.AppendLine('')
        }
    }
    if ($Result.amneziawg -and $Result.amneziawg.enabled) {
        [void]$links.AppendLine("=== AmneziaWG (UDP $($Result.amneziawg.port)) ===")
        [void]$links.AppendLine('Файлы: amnezia-<имя>.conf. Импорт: AmneziaVPN → + → Файл настроек.')
        [void]$links.AppendLine("Endpoint: $($Result.host):$($Result.amneziawg.port)")
        [void]$links.AppendLine('')
        foreach ($a in @($Result.amneziawg.clients)) {
            [void]$links.AppendLine("[$($a.name)] $($a.ip) → amnezia-$($a.name).conf")
        }
        [void]$links.AppendLine('')
    }
    Write-TextBom (Join-Path $outDir 'links.txt') $links.ToString()

    $splitText = [string]$Result.split_tunnel_notes
    if ($Result.split_tunnel -and [string]::IsNullOrWhiteSpace($splitText)) {
        $splitText = "Белые списки`r`n============`r`nВключите в клиенте профиль «Bypass Russia» / «Russia direct»: российские сайты — напрямую, остальное — через VPN."
    }
    if (-not [string]::IsNullOrWhiteSpace($splitText)) {
        Write-TextBom (Join-Path $outDir 'split-tunnel.txt') $splitText
    }

    $subtitle = "Сервер $($Result.host) · VLESS + XHTTP + Reality"
    $index = New-HtmlPage -Result $Result -Clients $clients -IncludePanel $true -Title 'VPN готов' -Subtitle $subtitle -IncludeShareLinks $true
    Write-TextBom (Join-Path $outDir 'index.html') $index
    foreach ($c in $clients) {
        $safe = ([string]$c.name) -replace '[^A-Za-z0-9_-]', '_'
        $share = New-HtmlPage -Result $Result -Clients @($c) -IncludePanel $false -Title ("VPN для " + [string]$c.name) -Subtitle 'Персональный доступ. Отсканируйте QR или скопируйте ссылку.' -IncludeShareLinks $false
        Write-TextBom (Join-Path $outDir ("share-$safe.html")) $share
    }

    try {
        $json = $Result | ConvertTo-Json -Depth 10
        Write-TextNoBom (Join-Path $outDir 'result.json') $json
    } catch { }

    try {
        $connection = [ordered]@{
            host          = [string]$Result.host
            ssh_port      = [int]$Result.ssh_port
            panel_port    = [int]$Result.panel.port
            panel_path    = [string]$Result.panel.path
            panel_url     = [string]$Result.panel.url
            auth_mode     = [string]$script:AuthMode
            ssh_key       = $(if ($script:AuthMode -eq 'key') { [string]$script:SshKeyPath } else { '' })
            plink_hostkey = [string]$script:PlinkHostKey
            inbound_id    = [int]$Result.inbound.id
            awg_port      = $(if ($Result.amneziawg -and $Result.amneziawg.enabled) { [int]$Result.amneziawg.port } else { 0 })
            created_at    = [string]$Result.created_at
        }
        Write-TextNoBom (Join-Path $outDir 'connection.json') ($connection | ConvertTo-Json -Depth 4)
    } catch { }

    Write-TextBom (Join-Path $outDir 'README.txt') (New-ReadmeText -Result $Result)
    Write-TextBom (Join-Path $outDir 'open-panel.ps1') (New-OpenPanelScript -Result $Result)
    Write-TextNoBom (Join-Path $outDir 'open-panel.cmd') "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0open-panel.ps1`"`r`nif errorlevel 1 pause`r`n"

    foreach ($name in @('manage.ps1', 'server-manage.sh')) {
        $src = Join-Path $script:Root $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $outDir $name) -Force
        }
    }
    Write-TextNoBom (Join-Path $outDir 'Управление VPN.cmd') "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0manage.ps1`"`r`nif errorlevel 1 pause`r`n"
    Write-TextNoBom (Join-Path $outDir 'Добавить клиента VPN.cmd') "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0manage.ps1`" -QuickAdd`r`nif errorlevel 1 pause`r`n"
    Write-TextNoBom (Join-Path $outDir 'Добавить AmneziaWG клиента.cmd') "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0manage.ps1`" -QuickAwg`r`nif errorlevel 1 pause`r`n"

    if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) {
        Copy-Item -LiteralPath $script:LogPath -Destination (Join-Path $outDir 'install.log') -Force
    }
    if (Test-Path -LiteralPath $script:Plink) {
        Copy-Item -LiteralPath $script:Plink -Destination (Join-Path $outDir 'plink.exe') -Force
    }

    $hashLines = New-Object System.Text.StringBuilder
    foreach ($f in (Get-ChildItem -LiteralPath $outDir -File | Where-Object { $_.Name -ne 'checksums.txt' } | Sort-Object Name)) {
        $h = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash.ToLowerInvariant()
        [void]$hashLines.AppendLine("$h  $($f.Name)")
    }
    Write-TextBom (Join-Path $outDir 'checksums.txt') $hashLines.ToString()

    $script:ResultDir = $outDir
    return $outDir
}

function Show-ResultSummary {
    param($Result)
    Write-Title 'Готово'
    Write-Ok 'VPN установлен и запущен.'
    Write-Host "  Сервер:   $($Result.host):443" -ForegroundColor Gray
    Write-Host "  Папка:    $($script:ResultDir)" -ForegroundColor Gray
    Write-Host "  Панель:   $($Result.panel.url)" -ForegroundColor Gray
    Write-Host "  Логин:    $($Result.panel.username)" -ForegroundColor Gray
    Write-Host "  Пароль:   $($Result.panel.password)" -ForegroundColor Gray
    Write-Host "  Клиенты:  $(@($Result.clients).Count)" -ForegroundColor Gray
    if ($Result.hysteria2 -and $Result.hysteria2.enabled) {
        Write-Warn 'Hysteria2 включён, но UDP может блокироваться. VLESS — основной.'
    }
    if ($Result.amneziawg -and $Result.amneziawg.enabled) {
        Write-Ok "AmneziaWG включён: UDP $($Result.amneziawg.port), файлы amnezia-<имя>.conf в папке."
    } elseif ($Result.amneziawg -and $Result.amneziawg.skipped) {
        Write-Info 'AmneziaWG пропущен: на сервере уже есть Amnezia, установщик её не трогал.'
    }
    Write-Host ''
    Write-Info 'Открываю страницу с QR и ссылками...'
    $index = Join-Path $script:ResultDir 'index.html'
    if (Test-Path -LiteralPath $index) { Start-Process -FilePath $index | Out-Null }
    if (-not $Unattended) {
        Write-Host ''
        $panelUrl = [string]$Result.panel.url
        $panelIsPublic = $panelUrl -like 'https://*' -and $panelUrl -notlike 'https://127.0.0.1*' -and $panelUrl -notlike 'https://localhost*'
        if ($panelIsPublic) {
            if (Read-YesNo 'Открыть панель сейчас в браузере (HTTPS, сертификат самоподписанный)?' $false) {
                Start-Process -FilePath $panelUrl | Out-Null
            }
        } elseif (Read-YesNo 'Открыть панель сейчас через SSH-туннель?' $false) {
            $panelScript = Join-Path $script:ResultDir 'open-panel.ps1'
            if (Test-Path -LiteralPath $panelScript) { & $panelScript }
        } else {
            Write-Info 'Панель позже: запустите open-panel.cmd из папки результата.'
        }
    }
}

# =============================================================================
#  ACCESS CHECK / DIAGNOSE
# =============================================================================
function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 5000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'таймаут' }
        $client.EndConnect($iar)
        $sw.Stop()
        return [pscustomobject]@{ ok = $true; ms = [int]$sw.ElapsedMilliseconds; error = '' }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ ok = $false; ms = [int]$sw.ElapsedMilliseconds; error = $_.Exception.Message }
    } finally {
        try { $client.Close() } catch { }
    }
}

function Test-TlsSni {
    param([string]$Target, [int]$Port, [string]$Sni, [int]$TimeoutMs = 8000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'таймаут подключения' }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs
        $callback = [Net.Security.RemoteCertificateValidationCallback] { param($s, $cert, $chain, $errors) return $true }
        $stream = New-Object Net.Security.SslStream($client.GetStream(), $false, $callback)
        $stream.AuthenticateAsClient($Sni)
        $sw.Stop()
        return [pscustomobject]@{ ok = $true; ms = [int]$sw.ElapsedMilliseconds; error = ''; proto = [string]$stream.SslProtocol }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ ok = $false; ms = [int]$sw.ElapsedMilliseconds; error = $_.Exception.Message; proto = '' }
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        try { $client.Close() } catch { }
    }
}

function Get-LocalAccessChecks {
    param($Result)
    $checks = @()
    $target = [string]$Result.host
    $sni = 'www.otto.de'
    try { if ($Result.inbound.sni) { $sni = [string]$Result.inbound.sni } } catch { }

    if ($target -notmatch '^[0-9.]+$') {
        $dnsOk = $false
        $dnsDetail = ''
        try {
            $addrs = [Net.Dns]::GetHostAddresses($target)
            $dnsOk = @($addrs).Count -gt 0
            $dnsDetail = (@($addrs) | ForEach-Object { $_.IPAddressToString }) -join ', '
        } catch { $dnsDetail = $_.Exception.Message }
        $checks += [pscustomobject]@{ name = 'Домен сервера резолвится'; ok = $dnsOk; detail = $dnsDetail }
    }

    $tcp = Test-TcpPort $target 443 6000
    $checks += [pscustomobject]@{
        name = 'TCP 443 доступен с этого ПК'
        ok = $tcp.ok
        detail = $(if ($tcp.ok) { "$($tcp.ms) мс" } else { $tcp.error })
    }

    if ($tcp.ok) {
        $tls = Test-TlsSni $target 443 $sni 8000
        $checks += [pscustomobject]@{
            name = 'TLS/Reality отвечает с этого ПК'
            ok = $tls.ok
            detail = $(if ($tls.ok) { "$($tls.ms) мс, $($tls.proto)" } else { $tls.error })
        }
    } else {
        $checks += [pscustomobject]@{ name = 'TLS/Reality отвечает с этого ПК'; ok = $false; detail = 'нет соединения' }
    }
    return $checks
}

function Get-VerifyGrade([int]$Score) {
    if ($Score -ge 90) { return 'отлично' }
    if ($Score -ge 75) { return 'хорошо' }
    if ($Score -ge 50) { return 'средне' }
    return 'плохо'
}

function Merge-VerifyResult {
    param($Result, $LocalChecks = @())
    $all = @()
    try {
        foreach ($c in @($Result.verify.checks)) {
            if ($null -eq $c) { continue }
            $all += [pscustomobject]@{ name = [string]$c.name; ok = [bool]$c.ok; detail = [string]$c.detail; where = 'server' }
        }
    } catch { }
    foreach ($c in @($LocalChecks)) {
        if ($null -eq $c) { continue }
        $all += [pscustomobject]@{ name = [string]$c.name; ok = [bool]$c.ok; detail = [string]$c.detail; where = 'pc' }
    }
    $total = $all.Count
    $passed = @($all | Where-Object { $_.ok }).Count
    $score = if ($total -gt 0) { [int][math]::Round($passed * 100 / $total) } else { 0 }
    $verify = [pscustomobject]@{
        score  = $score
        grade  = (Get-VerifyGrade $score)
        passed = $passed
        total  = $total
        checks = $all
    }
    $Result | Add-Member -NotePropertyName verify -NotePropertyValue $verify -Force
    return $verify
}

function Show-Verify {
    param($Verify)
    if (-not $Verify) { return }
    Write-Title 'Проверка результата'
    foreach ($c in @($Verify.checks)) {
        $text = [string]$c.name
        if (-not $c.ok -and -not [string]::IsNullOrWhiteSpace([string]$c.detail)) {
            $text += " — $($c.detail)"
        }
        if ($c.ok) { Write-Ok $text } else { Write-Err $text }
    }
    Write-Host ''
    $color = if ($Verify.score -ge 90) { 'Green' } elseif ($Verify.score -ge 75) { 'Yellow' } else { 'Red' }
    Write-Host ("  Оценка: {0}% — {1}  ({2}/{3})" -f $Verify.score, $Verify.grade, $Verify.passed, $Verify.total) -ForegroundColor $color
}

function Get-KnownResult {
    $bases = @($script:Root, (Split-Path -Parent $script:Root))
    $dirs = @()
    foreach ($b in $bases) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if (-not (Test-Path -LiteralPath $b)) { continue }
        $dirs += @(Get-ChildItem -LiteralPath $b -Directory -Filter 'vpn-result*' -ErrorAction SilentlyContinue)
    }
    foreach ($d in ($dirs | Sort-Object LastWriteTime -Descending)) {
        $f = Join-Path $d.FullName 'result.json'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { return ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Invoke-Diagnose {
    Show-Banner
    Write-Title 'Проверка сервера и оценка'
    Write-Host '  Ничего не меняет: только смотрит, что работает.' -ForegroundColor DarkGray

    if (-not $Server) {
        while ($true) {
            $Server = Read-Input 'IP-адрес или домен сервера' '' -Required
            if (Test-IsHost $Server) { break }
            Write-Warn 'Неверный адрес. Пример: 203.0.113.10'
        }
    } elseif (-not (Test-IsHost $Server)) {
        throw "Некорректный адрес сервера: $Server"
    }
    if (-not $Unattended -and -not $script:Bound.ContainsKey('SshPort')) {
        while ($true) {
            $p = Read-Input 'SSH-порт' '22'
            if (Test-IsPort $p 1 65535) { $SshPort = [int]$p; break }
            Write-Warn 'Порт должен быть числом 1-65535.'
        }
    }

    Initialize-Auth
    if ($script:AuthMode -eq 'password') { Resolve-PlinkHostKey }

    $diag = @'
. /etc/x-ui/install-result.env 2>/dev/null || true
printf '__DIAG_BEGIN__\n'
printf 'XUI=%s\n' "$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
printf 'XRAY=%s\n' "$(pgrep -f xray-linux >/dev/null 2>&1 && echo 1 || echo 0)"
printf 'TCP443=%s\n' "$(ss -H -ltn 2>/dev/null | grep -q ':443 ' && echo 1 || echo 0)"
printf 'UDP443=%s\n' "$(ss -H -lun 2>/dev/null | grep -q ':443 ' && echo 1 || echo 0)"
printf 'AWG=%s\n' "$(awg show awg0 >/dev/null 2>&1 && echo 1 || echo 0)"
printf 'F2B=%s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
printf 'FW=%s\n' "$(iptables -S INPUT 2>/dev/null | grep -q -- '-j VPN-FW' && echo 1 || echo 0)"
printf 'FW_POLICY=%s\n' "$(iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT DROP' && echo 1 || echo 0)"
printf 'UFW=%s\n' "$(ufw status 2>/dev/null | grep -q 'Status: active' && echo 1 || echo 0)"
printf 'EGRESS=%s\n' "$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
printf 'PANEL_PORT=%s\n' "${XUI_PANEL_PORT:-}"
printf 'PANEL_PATH=%s\n' "${XUI_WEB_BASE_PATH:-}"
printf 'PANEL_PASS=%s\n' "${XUI_PASSWORD:-}"
printf 'SNI=%s\n' "$(sqlite3 /etc/x-ui/x-ui.db "select stream_settings from inbounds where port=443 limit 1" 2>/dev/null | grep -o '"serverNames":\["[^"]*"' | head -n1 | sed 's/.*\["//; s/"$//')"
printf 'UPTIME=%s\n' "$(uptime -p 2>/dev/null || true)"
printf 'LOAD=%s\n' "$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
printf 'MEMFREE=%s\n' "$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
printf 'DISKFREE=%s\n' "$(df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
if [[ -n "${XUI_PANEL_PORT:-}" && -n "${XUI_WEB_BASE_PATH:-}" ]]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "https://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/" 2>/dev/null || true)"
  [[ "$code" =~ ^[23] ]] || code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/" 2>/dev/null || true)"
  printf 'PANEL_HTTP=%s\n' "$code"
fi
printf 'TLS_LOCAL=%s\n' "$(timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "${SNI:-www.otto.de}" -brief </dev/null >/dev/null 2>&1 && echo 1 || echo 0)"
printf '__DIAG_END__\n'
'@
    Write-Info 'Опрашиваю сервер: службы, порты, TLS, панель, firewall...'
    $run = Invoke-RemoteScript -ScriptText $diag -LogPath (Join-Path $script:TempDir 'diagnose.log') -Quiet
    if ($run.ExitCode -ne 0 -or $run.Text -notmatch '__DIAG_END__') {
        throw "Не удалось получить состояние сервера.`n$($run.Text.Trim())"
    }
    $info = @{}
    foreach ($line in $run.Output) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $info[$Matches[1]] = $Matches[2] }
    }

    $sni = [string]$info['SNI']
    if ([string]::IsNullOrWhiteSpace($sni)) {
        $known = Get-KnownResult
        if ($known -and [string]$known.host -eq $Server) {
            try { if ($known.inbound.sni) { $sni = [string]$known.inbound.sni } } catch { }
        }
    }
    if ([string]::IsNullOrWhiteSpace($sni)) { $sni = 'www.otto.de' }
    $fakeResult = [pscustomobject]@{ host = $Server; inbound = [pscustomobject]@{ sni = $sni } }

    $checks = @()
    $checks += [pscustomobject]@{ name = 'Служба 3x-ui запущена'; ok = ($info['XUI'] -eq 'active'); detail = [string]$info['XUI'] }
    $checks += [pscustomobject]@{ name = 'Процесс Xray работает'; ok = ($info['XRAY'] -eq '1'); detail = '' }
    $checks += [pscustomobject]@{ name = 'TCP 443 слушается'; ok = ($info['TCP443'] -eq '1'); detail = '' }
    $checks += [pscustomobject]@{ name = 'Панель отвечает'; ok = ([string]$info['PANEL_HTTP'] -match '^[23]'); detail = $(if ($info['PANEL_HTTP']) { "HTTP $($info['PANEL_HTTP'])" } else { 'нет данных' }) }
    $checks += [pscustomobject]@{ name = 'Firewall включён'; ok = (($info['FW'] -eq '1') -or ($info['FW_POLICY'] -eq '1') -or ($info['UFW'] -eq '1')); detail = $(if ($info['UFW'] -eq '1') { 'ufw' } elseif ($info['FW_POLICY'] -eq '1') { 'INPUT DROP' } else { '' }) }
    $checks += [pscustomobject]@{ name = 'Защита SSH (fail2ban)'; ok = ($info['F2B'] -eq 'active'); detail = [string]$info['F2B'] }
    $checks += [pscustomobject]@{ name = 'Reality отвечает по TLS'; ok = ($info['TLS_LOCAL'] -eq '1'); detail = $sni }
    if ($Server -match '^[0-9.]+$' -and $info['EGRESS']) {
        $checks += [pscustomobject]@{ name = 'Выход в интернет с нужного IP'; ok = ($info['EGRESS'] -eq $Server); detail = [string]$info['EGRESS'] }
    }
    if ($info['UDP443'] -eq '1') {
        $checks += [pscustomobject]@{ name = 'Hysteria2 слушает UDP 443'; ok = $true; detail = '' }
    }
    if ($info['AWG'] -eq '1') {
        $checks += [pscustomobject]@{ name = 'AmneziaWG поднят (awg0)'; ok = $true; detail = '' }
    }
    foreach ($c in @(Get-LocalAccessChecks -Result $fakeResult)) { $checks += $c }

    $verify = Merge-VerifyResult -Result $fakeResult -LocalChecks $checks
    Show-Verify $verify

    if ($info['UPTIME'] -or $info['LOAD']) {
        Write-Host ''
        Write-Info "Сервер: uptime $($info['UPTIME']), load $($info['LOAD']), свободно RAM $($info['MEMFREE']) MB, диск $($info['DISKFREE']) MB"
    }
    return $verify
}

# =============================================================================
#  SELF-TEST / MAIN
# =============================================================================
function Get-ResultFromText([string]$Text) {
    $m = [regex]::Match($Text, '=== VPN_RESULT_JSON_BEGIN ===\s*([A-Za-z0-9+/=\s]+?)\s*=== VPN_RESULT_JSON_END ===')
    if (-not $m.Success) {
        throw 'Сервер не вернул result.json. Установка могла прерваться — смотрите лог.'
    }
    $b64 = $m.Groups[1].Value -replace '\s', ''
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    return ($json | ConvertFrom-Json)
}

function Invoke-SelfTest {
    $fail = 0
    Write-Host ''
    Write-Host '  SELF-TEST' -ForegroundColor Cyan
    Write-Host '  =========' -ForegroundColor DarkCyan

    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
        Write-Err "Нужен PowerShell 5.1+. Сейчас: $psv"
        $fail++
    } else {
        Write-Ok "PowerShell $psv"
    }

    try {
        $ssh = Get-SshExe
        Write-Ok "ssh.exe: $ssh"
    } catch {
        Write-Err $_.Exception.Message
        $fail++
    }

    try {
        Test-Plink | Out-Null
        Write-Ok 'plink.exe: SHA-256 и подпись Simon Tatham в порядке'
    } catch {
        Write-Err $_.Exception.Message
        $fail++
    }

    if (-not (Test-Path -LiteralPath $script:ServerScript)) {
        Write-Err "Не найден server-install.sh: $($script:ServerScript)"
        $fail++
    } else {
        $text = [IO.File]::ReadAllText($script:ServerScript, [Text.Encoding]::UTF8)
        if ($text.Contains("`r`n")) {
            Write-Err 'server-install.sh содержит CRLF. Нужны LF.'
            $fail++
        } else {
            Write-Ok 'server-install.sh: LF'
        }
        $required = @(
            '@@PUBLIC_HOST@@', '@@SSH_PORT@@', '@@PANEL_PORT@@', '@@PANEL_PATH@@',
            '@@PANEL_USER@@', '@@PANEL_PASS_B64@@', '@@CLIENT_NAMES@@', '@@ENABLE_HY2@@',
            '@@ENABLE_AWG@@', '@@AWG_PORT@@', '@@PANEL_PUBLIC@@',
            '@@SPLIT_TUNNEL@@', '@@CHECK_ONLY@@', '@@RESUME@@', '@@XUI_VERSION@@',
            '@@XUI_INSTALLER_SHA256@@', '@@SNI@@', '@@HARDEN@@'
        )
        $missing = @($required | Where-Object { -not $text.Contains($_) })
        if ($missing.Count -gt 0) {
            Write-Err "В server-install.sh нет плейсхолдеров: $($missing -join ', ')"
            $fail++
        } else {
            Write-Ok 'server-install.sh: все плейсхолдеры на месте'
        }
        if ($text -notmatch 'set -Eeuo pipefail') {
            Write-Err 'server-install.sh: нет set -Eeuo pipefail'
            $fail++
        }
    }

    try {
        $fake = [pscustomobject]@{
            host = '203.0.113.10'
            created_at = '2026-01-01T00:00:00Z'
            panel = [pscustomobject]@{
                port = 35404
                path = 'TestPath12345'
                username = 'testuser'
                password = 'testpassword'
                url = 'http://127.0.0.1:35404/TestPath12345/'
            }
            clients = @([pscustomobject]@{
                name = 'phone'
                uuid = '00000000-0000-0000-0000-000000000000'
                link = 'vless://test@203.0.113.10:443?type=xhttp#phone'
                qr_png_base64 = ''
            })
            hysteria2 = [pscustomobject]@{ enabled = $false }
            split_tunnel = $true
            split_tunnel_notes = 'test split notes'
            verify = [pscustomobject]@{
                score = 100
                grade = 'отлично'
                checks = @([pscustomobject]@{ name = 'TCP 443 доступен'; ok = $true; detail = '5 мс'; where = 'pc' })
            }
        }
        $html = New-HtmlPage -Result $fake -Clients @($fake.clients) -IncludePanel $true -Title 'Test' -Subtitle 'Test subtitle' -IncludeShareLinks $true
        if ($html -notmatch '<!doctype html>' -or $html -notmatch '203\.0\.113\.10' -or $html -notmatch 'TestPath12345' -or $html -notmatch 'САМОПРОВЕРКА') {
            Write-Err 'HTML-шаблон не собрался.'
            $fail++
        } else {
            Write-Ok 'HTML-шаблон: OK'
        }

        $panelScript = New-OpenPanelScript -Result $fake
        $pTokens = $null
        $pErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($panelScript, [ref]$pTokens, [ref]$pErrors) | Out-Null
        if ($pErrors.Count -gt 0) {
            Write-Err "open-panel.ps1: $($pErrors[0].Message)"
            $fail++
        } else {
            Write-Ok 'open-panel.ps1: OK'
        }

        $readme = New-ReadmeText -Result $fake
        if ($readme -notmatch 'ПАНЕЛЬ 3X-UI' -or $readme -notmatch 'testpassword' -or $readme -notmatch 'ПРОВЕРКА') {
            Write-Err 'README.txt не собрался.'
            $fail++
        } else {
            Write-Ok 'README.txt: OK'
        }
    } catch {
        Write-Err "HTML-шаблон: $($_.Exception.Message)"
        $fail++
    }

    Write-Host ''
    if ($fail -eq 0) {
        Write-Ok 'SELF-TEST OK'
        return $true
    }
    Write-Err "SELF-TEST FAIL: $fail"
    return $false
}

function Invoke-Main {
    Show-Banner

    if (-not $Server) {
        Write-Title 'Сервер'
        while ($true) {
            $Server = Read-Input 'IP-адрес или домен сервера' '' -Required
            if (Test-IsHost $Server) { break }
            Write-Warn 'Неверный адрес. Пример: 203.0.113.10 или vpn.example.com'
        }
    } elseif (-not (Test-IsHost $Server)) {
        throw "Некорректный адрес сервера: $Server"
    }

    if (-not $Unattended -and -not $script:Bound.ContainsKey('SshPort')) {
        while ($true) {
            $p = Read-Input 'SSH-порт' '22'
            if (Test-IsPort $p 1 65535) { $SshPort = [int]$p; break }
            Write-Warn 'Порт должен быть числом 1-65535.'
        }
    } elseif (-not (Test-IsPort "$SshPort" 1 65535)) {
        throw 'SSH-порт должен быть числом 1-65535.'
    }

    Initialize-Auth
    if ($script:AuthMode -eq 'password') { Resolve-PlinkHostKey }

    $info = Test-ServerConnection
    Show-ServerInfo $info

    Initialize-Options

    if ($CheckOnly) {
        Write-Title 'Проверка без установки'
        $scriptText = Build-ServerScript
        Invoke-SyntaxCheck -ScriptText $scriptText -LogPath (Join-Path $script:TempDir 'syntax.log')
        $run = Invoke-RemoteScript -ScriptText $scriptText -LogPath (Join-Path $script:TempDir 'check.log')
        if ($run.ExitCode -ne 0 -or $run.Text -notmatch 'VPN_CHECK_OK') {
            throw "Сервер не прошёл проверку.`n$($run.Text.Trim())"
        }
        Write-Ok 'Сервер подходит для установки. Ничего не изменено.'
        return
    }

    if (-not (Show-Summary)) { return }

    $scriptText = Build-ServerScript
    Invoke-SyntaxCheck -ScriptText $scriptText -LogPath (Join-Path $script:TempDir 'syntax.log')

    Write-Title 'Установка'
    Write-Info 'Это может занять 2-5 минут. Не закрывайте окно.'
    $script:LogPath = Join-Path $script:TempDir 'install.log'
    $run = Invoke-RemoteScript -ScriptText $scriptText -LogPath $script:LogPath
    $result = $null
    try { $result = Get-ResultFromText $run.Text } catch { $result = $null }
    if ($run.ExitCode -ne 0) {
        # A trailing cleanup error must not hide a finished installation: if the
        # server already sent a valid result, the VPN is up and configured.
        if (-not $result -or -not $result.ok) {
            throw "Установка завершилась с ошибкой (код $($run.ExitCode)). Смотрите лог выше. Если 3x-ui уже установился, запустите: Запустить установку VPN.cmd -Resume"
        }
        Write-Warn "Сервер сообщил об ошибке в самом конце (код $($run.ExitCode)), но установка завершена. Продолжаю."
    }

    if (-not $result) { throw 'Сервер не вернул result.json. Установка могла прерваться — смотрите лог.' }
    if (-not $result.ok) { throw 'Сервер не подтвердил успешную установку (ok != true).' }

    $localChecks = @()
    if ($script:CheckIp) {
        Write-Title 'Проверка доступности'
        Write-Info 'Проверяю с этого ПК порт 443 и TLS. Это занимает пару секунд.'
        $localChecks = @(Get-LocalAccessChecks -Result $result)
    }
    $verify = Merge-VerifyResult -Result $result -LocalChecks $localChecks
    Show-Verify $verify

    $outDir = Write-ResultFiles -Result $result
    Show-ResultSummary -Result $result
    $script:Installed = $true
}

# =============================================================================
#  RUN
# =============================================================================
$script:Bound = $PSBoundParameters
$exitCode = 0
try {
    if ($SelfTest) {
        if (-not (Invoke-SelfTest)) { $exitCode = 1 }
    } elseif ($Diagnose) {
        Invoke-Diagnose | Out-Null
    } else {
        Invoke-Main
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if ($env:VPN_INSTALLER_DEBUG -eq '1' -and $_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) {
        try {
            $errLog = Join-Path $script:Root ("vpn-install-error-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
            Copy-Item -LiteralPath $script:LogPath -Destination $errLog -Force
            Write-Info "Лог: $errLog"
        } catch { }
    }
    $exitCode = 1
} finally {
    if ($script:PwFile -and (Test-Path -LiteralPath $script:PwFile)) {
        Remove-Item -LiteralPath $script:PwFile -Force -ErrorAction SilentlyContinue
    }
    $script:SshPasswordPlain = $null
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $NoPause -and -not $Unattended -and -not $SelfTest) {
    Write-Host ''
    Write-Host '  Нажмите Enter, чтобы закрыть окно...' -ForegroundColor DarkGray
    [void](Read-Host)
}
if ($env:VPN_IN_MENU -eq '1') {
    $global:LASTEXITCODE = $exitCode
    return
}
exit $exitCode




