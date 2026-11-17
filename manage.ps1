#requires -Version 5.1
<#
    VPN Manager — добавление и удаление клиентов, статус, backup.
    Запускается из папки vpn-result-... через "Управление VPN.cmd"
    или напрямую: powershell -ExecutionPolicy Bypass -File manage.ps1
#>
[CmdletBinding()]
param(
    [string]$ResultDir,
    [string]$Server,
    [int]$SshPort = 0,
    [ValidateSet('auto', 'key', 'password')]
    [string]$Auth = 'auto',
    [string]$SshKey,
    [string]$SshPassword,
    [string]$PanelPassword,
    [switch]$QuickAdd,
    [switch]$QuickAwg,
    [switch]$SelfTest,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Root = $PSScriptRoot
$script:ManageScript = Join-Path $script:Root 'server-manage.sh'
$script:TempDir = Join-Path $env:TEMP ('vpn-manage-' + [guid]::NewGuid().ToString('N'))
$script:PlinkSha256 = '969f36879d5716aa1a9811f43a6a6510e8f08372dbeb9695b810b9c776f39c75'
$script:Plink = $null
$script:SshExe = $null
$script:AuthMode = $null
$script:SshKeyPath = $null
$script:PwFile = $null
$script:PlinkHostKey = $null
$script:ResultFolder = $null
$script:Conn = $null
$script:Result = $null
$script:PanelPass = $null
$script:InboundId = $null
$script:Sni = 'www.otto.de'
$script:Pbk = ''
$script:Sid = ''
$script:XhttpPath = ''
$script:XhttpMode = 'auto'
$script:AwgPort = 0

New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null

try { & chcp.com 65001 > $null } catch { }
try {
    [Console]::OutputEncoding = $script:Utf8
    [Console]::InputEncoding = $script:Utf8
    $global:OutputEncoding = $script:Utf8
} catch { }
try { $Host.UI.RawUI.WindowTitle = 'VPN Manager' } catch { }

# =============================================================================
#  UI
# =============================================================================
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
        Write-Host "  $Prompt [$hint]: " -ForegroundColor White -NoNewline
        $answer = ([string](Read-Host)).Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('y', 'yes', 'д', 'да', '1')) { return $true }
        if ($answer -in @('n', 'no', 'н', 'нет', '0')) { return $false }
        Write-Warn 'Ответьте да или нет.'
    }
}

function Read-Number {
    param([string]$Prompt, [int]$Default = 0, [int]$Min = 0, [int]$Max = 1000000)
    while ($true) {
        $raw = Read-Input $Prompt ([string]$Default)
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Min -and $value -le $Max) {
            return $value
        }
        Write-Warn "Нужно число от $Min до $Max."
    }
}

function ConvertTo-PlainText {
    param([Security.SecureString]$Secure)
    if ($null -eq $Secure) { return '' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function HtmlEncode([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Test-IsName([string]$Name) {
    return ($Name -match '^[A-Za-z0-9_-]{1,24}$')
}

# =============================================================================
#  FILES / CONNECTION
# =============================================================================
function Find-ResultFolder {
    if ($ResultDir) {
        $p = $ResultDir
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).Path $p }
        if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
        throw "Папка не найдена: $ResultDir"
    }

    $dirs = @()
    foreach ($base in @($script:Root, (Split-Path $script:Root -Parent), (Get-Location).Path)) {
        if ([string]::IsNullOrWhiteSpace($base) -or -not (Test-Path -LiteralPath $base)) { continue }
        $dirs += @(Get-ChildItem -LiteralPath $base -Directory -Filter 'vpn-result-*' -ErrorAction SilentlyContinue)
    }
    $found = $dirs |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'result.json') } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($found) { return $found.FullName }

    Write-Title 'Папка с результатами'
    Write-Info 'Нужна папка vpn-result-..., которую создал установщик.'
    while ($true) {
        $p = Read-Input 'Путь к папке' '' -Required
        if (Test-Path -LiteralPath (Join-Path $p 'result.json')) {
            return (Resolve-Path -LiteralPath $p).Path
        }
        Write-Warn 'В этой папке нет result.json. Укажите папку vpn-result-...'
    }
}

function Import-Connection {
    $folder = Find-ResultFolder
    $resultPath = Join-Path $folder 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) {
        throw "В папке нет result.json: $folder"
    }
    $script:ResultFolder = $folder
    $script:Result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $connPath = Join-Path $folder 'connection.json'
    if (Test-Path -LiteralPath $connPath) {
        $script:Conn = Get-Content -LiteralPath $connPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $script:Conn = [pscustomobject]@{
            host         = [string]$script:Result.host
            ssh_port     = [int]$script:Result.ssh_port
            panel_port   = [int]$script:Result.panel.port
            panel_path   = [string]$script:Result.panel.path
            panel_url    = [string]$script:Result.panel.url
            auth_mode    = ''
            ssh_key      = ''
            plink_hostkey = ''
            inbound_id   = [int]$script:Result.inbound.id
            awg_port     = 0
            created_at   = [string]$script:Result.created_at
        }
    }

    if ($Server) { $script:Conn.host = $Server }
    if ($SshPort -gt 0) { $script:Conn.ssh_port = $SshPort }

    $script:Server = [string]$script:Conn.host
    $script:SshPort = [int]$script:Conn.ssh_port
    $script:PanelPass = [string]$script:Result.panel.password
    $script:InboundId = [int]$script:Result.inbound.id
    if ($null -ne $script:Result.inbound.sni) { $script:Sni = [string]$script:Result.inbound.sni }
    if ($null -ne $script:Result.inbound.pbk) { $script:Pbk = [string]$script:Result.inbound.pbk }
    if ($null -ne $script:Result.inbound.sid) { $script:Sid = [string]$script:Result.inbound.sid }
    if ($null -ne $script:Result.inbound.path) { $script:XhttpPath = [string]$script:Result.inbound.path }
    if ($null -ne $script:Result.inbound.mode -and [string]$script:Result.inbound.mode -ne '') {
        $script:XhttpMode = [string]$script:Result.inbound.mode
    }
    if ($script:Result.amneziawg -and $script:Result.amneziawg.enabled) {
        $script:AwgPort = [int]$script:Result.amneziawg.port
    }
    if (-not $PanelPassword -and [string]::IsNullOrWhiteSpace($script:PanelPass)) {
        $sec = Read-Host "  Пароль панели 3x-ui" -AsSecureString
        $script:PanelPass = ConvertTo-PlainText $sec
    } elseif ($PanelPassword) {
        $script:PanelPass = $PanelPassword
    }
    if ([string]::IsNullOrEmpty($script:PanelPass)) { throw 'Не указан пароль панели.' }

    Write-Info "Сервер: $script:Server`:$script:SshPort"
    Write-Info "Папка:  $script:ResultFolder"
}

# =============================================================================
#  SSH
# =============================================================================
function Get-PlinkPath {
    $candidates = @(
        (Join-Path $script:Root 'plink.exe'),
        (Join-Path $script:Root 'tools\plink.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Test-Plink {
    $path = Get-PlinkPath
    if (-not $path) { throw 'Не найден plink.exe. Он нужен для входа по паролю.' }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($hash -ne $script:PlinkSha256) {
        throw "plink.exe повреждён или подменён (SHA-256 $hash)."
    }
    $script:Plink = $path
    return $path
}

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'Не найден ssh.exe. Нужен Windows 10/11.' }
    return $cmd.Source
}

function Initialize-Auth {
    $mode = $Auth
    if ($mode -eq 'auto') {
        if ($SshKey) { $mode = 'key' }
        elseif ($SshPassword) { $mode = 'password' }
        elseif ($script:Conn.auth_mode -eq 'key') { $mode = 'key' }
        elseif ($script:Conn.auth_mode -eq 'password') { $mode = 'password' }
        else {
            Write-Title 'Доступ к серверу'
            Write-Host '   1) SSH-ключ' -ForegroundColor Gray
            Write-Host '   2) Пароль root' -ForegroundColor Gray
            $choice = Read-Input 'Способ входа (1/2)' '2'
            if ($choice -eq '1') { $mode = 'key' } else { $mode = 'password' }
        }
    }
    $script:AuthMode = $mode

    if ($mode -eq 'key') {
        $script:SshExe = Get-SshExe
        if (-not $SshKey) { $SshKey = [string]$script:Conn.ssh_key }
        if ([string]::IsNullOrWhiteSpace($SshKey)) {
            $SshKey = Read-Input 'Путь к SSH-ключу' (Join-Path $env:USERPROFILE '.ssh\id_ed25519') -Required
        }
        if ($SshKey -match '^~') { $SshKey = $SshKey -replace '^~', $env:USERPROFILE }
        if (-not (Test-Path -LiteralPath $SshKey)) { throw "Файл ключа не найден: $SshKey" }
        if ($SshKey -match '\.ppk$') { throw 'Это PuTTY .ppk. Нужен ключ OpenSSH или вход по паролю.' }
        $script:SshKeyPath = (Resolve-Path -LiteralPath $SshKey).Path
        $script:PlinkHostKey = [string]$script:Conn.plink_hostkey
    } else {
        Test-Plink | Out-Null
        if (-not $SshPassword) {
            $sec = Read-Host "  Пароль root@$script:Server" -AsSecureString
            $SshPassword = ConvertTo-PlainText $sec
        }
        if ([string]::IsNullOrEmpty($SshPassword)) { throw 'Пароль не введён.' }
        if ($SshPassword -match '[\r\n]') { throw 'Пароль не должен содержать перевод строки.' }
        $script:PwFile = Join-Path $script:TempDir 'ssh-password.txt'
        [IO.File]::WriteAllText($script:PwFile, $SshPassword + "`n", $script:Utf8)
        try {
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $script:PwFile -AclObject $acl
        } catch { }
        if ([string]::IsNullOrWhiteSpace($script:PlinkHostKey)) {
            Resolve-PlinkHostKey
        }
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$InputText,
        [switch]$Quiet
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $oldEap = $ErrorActionPreference
    $exit = 1
    $ErrorActionPreference = 'Continue'
    try {
        $emit = {
            param($item)
            $line = [string]$item
            $lines.Add($line)
            if (-not $Quiet) { Write-Host $line }
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
    $baseArgs = @('-ssh', '-P', "$script:SshPort", '-batch', '-l', 'root', '-pwfile', $script:PwFile, $script:Server, 'echo __VPN_HOSTKEY_OK__')
    $first = Invoke-Native -Exe $script:Plink -Arguments $baseArgs -Quiet
    if ($first.ExitCode -eq 0 -and $first.Text -match '__VPN_HOSTKEY_OK__') {
        return
    }
    $m = [regex]::Match($first.Text, 'SHA256:[A-Za-z0-9+/=]+')
    if (-not $m.Success) {
        throw "Не удалось подключиться по SSH. Проверьте адрес и пароль.`n$($first.Text.Trim())"
    }
    $script:PlinkHostKey = $m.Value
    $second = Invoke-Native -Exe $script:Plink -Arguments @(
        '-ssh', '-P', "$script:SshPort", '-batch', '-hostkey', $script:PlinkHostKey,
        '-l', 'root', '-pwfile', $script:PwFile, $script:Server, 'echo __VPN_HOSTKEY_OK__') -Quiet
    if ($second.ExitCode -ne 0 -or $second.Text -notmatch '__VPN_HOSTKEY_OK__') {
        throw "Сервер ответил, но вход не удался. Проверьте пароль root.`n$($second.Text.Trim())"
    }
}

function Invoke-RemoteManage {
    param(
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )
    if (-not (Test-Path -LiteralPath $script:ManageScript)) {
        throw "Не найден server-manage.sh: $($script:ManageScript)"
    }
    $text = [IO.File]::ReadAllText($script:ManageScript, [Text.Encoding]::UTF8)
    $passValue = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:PanelPass))
    $map = @{
        '@@PANEL_PORT@@'     = [string]$script:Conn.panel_port
        '@@PANEL_PATH@@'     = [string]$script:Conn.panel_path
        '@@PANEL_USER@@'     = [string]$script:Result.panel.username
        '@@PANEL_PASS_B64@@' = $passValue
        '@@INBOUND_ID@@'     = [string]$script:InboundId
        '@@PUBLIC_HOST@@'    = $script:Server
        '@@SNI@@'            = $script:Sni
        '@@PBK@@'            = $script:Pbk
        '@@SID@@'            = $script:Sid
        '@@XHTTP_PATH@@'     = $script:XhttpPath
        '@@XHTTP_MODE@@'     = $script:XhttpMode
        '@@AWG_PORT@@'       = [string]$script:AwgPort
    }
    foreach ($key in $map.Keys) { $text = $text.Replace($key, [string]$map[$key]) }
    if ($text -match '@@[A-Z0-9_]+@@') {
        $left = [regex]::Matches($text, '@@[A-Z0-9_]+@@') | ForEach-Object { $_.Value } | Select-Object -Unique
        throw "В server-manage.sh остались плейсхолдеры: $($left -join ', ')"
    }

    $quoted = @()
    foreach ($a in @($Arguments)) {
        $quoted += "'" + ([string]$a).Replace("'", "''") + "'"
    }
    $argLine = ($quoted -join ' ')
    $delim = "__VPN_MANAGE_$([guid]::NewGuid().ToString('N'))__"
    # PowerShell appends CRLF to native stdin; keep it on a harmless comment
    # line so bash does not try to execute a lone carriage return.
    $wrapper = "bash -s -- $argLine <<'$delim'`n" + $text.TrimEnd() + "`n$delim`n# __vpn_manage_end__"

    if ($script:AuthMode -eq 'key') {
        $sshArgs = @(
            '-i', $script:SshKeyPath,
            '-p', "$script:SshPort",
            '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=30',
            "root@$script:Server",
            'bash -s'
        )
        return Invoke-Native -Exe $script:SshExe -Arguments $sshArgs -InputText $wrapper -Quiet:$Quiet
    }

    $wrapperPath = Join-Path $script:TempDir 'manage-command.sh'
    [IO.File]::WriteAllText($wrapperPath, $wrapper, $script:Utf8)
    $plinkArgs = @('-ssh', '-P', "$script:SshPort", '-batch', '-l', 'root', '-pwfile', $script:PwFile)
    if ($script:PlinkHostKey) { $plinkArgs += @('-hostkey', $script:PlinkHostKey) }
    $plinkArgs += @('-m', $wrapperPath, $script:Server)
    return Invoke-Native -Exe $script:Plink -Arguments $plinkArgs -Quiet:$Quiet
}

# =============================================================================
#  CLIENT OUTPUT
# =============================================================================
function Get-ClientJson {
    param([string]$Text)
    $m = [regex]::Match($Text, '=== VPN_CLIENT_JSON_BEGIN ===\s*([A-Za-z0-9+/=\s]+?)\s*=== VPN_CLIENT_JSON_END ===')
    if (-not $m.Success) { return $null }
    $b64 = $m.Groups[1].Value -replace '\s', ''
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    return ($json | ConvertFrom-Json)
}

function Show-HumanOutput {
    param([string]$Text)
    $clean = [regex]::Replace($Text, '=== VPN_CLIENT_JSON_BEGIN ===[\s\S]*?=== VPN_CLIENT_JSON_END ===', '')
    foreach ($line in ($clean -split "`r?`n")) {
        if ($line.Trim() -ne '') { Write-Host "  $line" }
    }
}

function New-SharePage {
    param([string]$Name, [string]$Link, [string]$Qr, [string]$Title = 'VPN')
    $qrHtml = if ($Qr) {
        '<img src="data:image/png;base64,' + $Qr + '" alt="QR">'
    } else {
        '<div class="empty">QR не сгенерирован</div>'
    }
    $template = @'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#0b1020;color:#e8ecff;font:16px/1.5 system-ui,Segoe UI,Arial,sans-serif}
main{max-width:680px;margin:0 auto;padding:32px 18px 64px}h1{font-size:30px;margin:0 0 6px}.muted{color:#9aa4c7}
.card{background:#121a33;border:1px solid #26325a;border-radius:18px;padding:22px;margin-top:18px}
.qr{background:#fff;border-radius:14px;padding:12px;display:flex;justify-content:center;margin:18px 0}
.qr img{width:100%;max-width:260px;height:auto}.empty{color:#334155;padding:40px 0}
code,pre{font-family:ui-monospace,Consolas,monospace}pre{white-space:pre-wrap;word-break:break-all;background:#0a0f1f;border:1px solid #26325a;border-radius:12px;padding:14px;font-size:12px}
.btn{display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;border:0;border-radius:10px;padding:10px 14px;font-weight:600;cursor:pointer}
</style></head><body><main>
<h1>{{TITLE}}</h1>
<p class="muted">Персональный доступ. Не передавайте ссылку посторонним.</p>
<div class="card">
<div class="qr">{{QR}}</div>
<pre id="link">{{LINK}}</pre>
<button class="btn" onclick="copyLink()">Скопировать ссылку</button>
</div>
<script>
function copyLink(){var t=document.getElementById('link').textContent;if(navigator.clipboard){navigator.clipboard.writeText(t).then(function(){alert('Скопировано')},function(){fallback()})}else{fallback()}}
function fallback(){var a=document.createElement('textarea');a.value=document.getElementById('link').textContent;document.body.appendChild(a);a.select();document.execCommand('copy');document.body.removeChild(a);alert('Скопировано')}
</script>
</main></body></html>
'@
    return $template.Replace('{{TITLE}}', (HtmlEncode $Title)).
        Replace('{{QR}}', $qrHtml).
        Replace('{{LINK}}', (HtmlEncode $Link))
}

function Append-LinksFile {
    param([string]$Header, [string]$Body)
    $path = Join-Path $script:ResultFolder 'links.txt'
    $text = "`r`n$Header`r`n$Body`r`n"
    [IO.File]::AppendAllText($path, $text, $script:Utf8)
}

function Save-VlessClient {
    param($Client, [string]$Open = $true)
    $name = [string]$Client.name
    if (-not (Test-IsName $name)) { throw "Некорректное имя клиента: $name" }
    $safe = $name -replace '[^A-Za-z0-9_-]', '_'
    $qr = [string]$Client.qr_png_base64
    if ($qr) {
        [IO.File]::WriteAllBytes((Join-Path $script:ResultFolder "qr-$safe.png"), [Convert]::FromBase64String($qr))
    }
    [IO.File]::WriteAllText((Join-Path $script:ResultFolder "link-$safe.txt"), [string]$Client.link, $script:Utf8)
    $page = New-SharePage -Name $name -Link ([string]$Client.link) -Qr $qr -Title "VPN для $name"
    $pagePath = Join-Path $script:ResultFolder "share-$safe.html"
    [IO.File]::WriteAllText($pagePath, $page, $script:Utf8Bom)
    Append-LinksFile -Header "[$name] добавлен $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body ([string]$Client.link)
    Write-Ok "Ссылка сохранена: link-$safe.txt"
    if ($Open) { Start-Process -FilePath $pagePath | Out-Null }
}

function Save-AwgClient {
    param($Client, [bool]$Open = $true)
    $name = [string]$Client.name
    if (-not (Test-IsName $name)) { throw "Некорректное имя клиента: $name" }
    $safe = $name -replace '[^A-Za-z0-9_-]', '_'
    $conf = [string]$Client.config
    if (-not $conf) { throw 'Сервер не вернул конфиг AmneziaWG.' }
    [IO.File]::WriteAllText((Join-Path $script:ResultFolder "amnezia-$safe.conf"), $conf, $script:Utf8)
    $qr = [string]$Client.qr_png_base64
    if ($qr) {
        [IO.File]::WriteAllBytes((Join-Path $script:ResultFolder "qr-$safe-awg.png"), [Convert]::FromBase64String($qr))
    }
    $page = New-SharePage -Name $name -Link $conf -Qr $qr -Title "AmneziaWG для $name"
    $pagePath = Join-Path $script:ResultFolder "amnezia-$safe.html"
    [IO.File]::WriteAllText($pagePath, $page, $script:Utf8Bom)
    Append-LinksFile -Header "[$name] AmneziaWG добавлен $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Body "IP: $($Client.ip)"
    Write-Ok "Конфиг сохранён: amnezia-$safe.conf"
    if ($Open) { Start-Process -FilePath $pagePath | Out-Null }
}

# =============================================================================
#  ACTIONS
# =============================================================================
function Invoke-ListVless {
    Write-Title 'Клиенты VLESS'
    $run = Invoke-RemoteManage -Arguments @('list-vless')
    if ($run.ExitCode -ne 0) { Write-Err 'Не удалось получить список.' }
}

function Invoke-AddVless {
    Write-Title 'Новый клиент VLESS'
    $name = Read-Input 'Имя клиента (латиница, цифры, _ и -)' '' -Required
    while (-not (Test-IsName $name)) {
        Write-Warn '1-24 символа: A-Z a-z 0-9 _ -'
        $name = Read-Input 'Имя клиента' '' -Required
    }
    $days = Read-Number 'Срок действия, дней (0 = бессрочно)' 0 0 3650
    $gb = Read-Number 'Лимит трафика, ГБ (0 = без лимита)' 0 0 100000

    Write-Info 'Создаю клиента на сервере...'
    $run = Invoke-RemoteManage -Arguments @('add-vless', $name, [string]$days, [string]$gb) -Quiet
    Show-HumanOutput $run.Text
    if ($run.ExitCode -ne 0) { Write-Err 'Клиент не добавлен.'; return }
    $client = Get-ClientJson $run.Text
    if (-not $client) { Write-Warn 'Клиент создан, но ссылку получить не удалось. Откройте панель.'; return }
    Save-VlessClient -Client $client
    Write-Host ''
    Write-Host "  $($client.link)" -ForegroundColor DarkGray
}

function Invoke-ShowVless {
    Write-Title 'Ссылка и QR клиента'
    $name = Read-Input 'Имя клиента' '' -Required
    $run = Invoke-RemoteManage -Arguments @('show-vless', $name) -Quiet
    Show-HumanOutput $run.Text
    if ($run.ExitCode -ne 0) { return }
    $client = Get-ClientJson $run.Text
    if ($client) { Save-VlessClient -Client $client }
}

function Invoke-DelVless {
    Write-Title 'Удалить клиента VLESS'
    Invoke-ListVless
    $name = Read-Input 'Имя клиента для удаления (Enter = отмена)' ''
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if (-not (Read-YesNo "Точно удалить '$name'?" $false)) { Write-Info 'Отменено.'; return }
    $run = Invoke-RemoteManage -Arguments @('del-vless', $name)
    if ($run.ExitCode -eq 0) { Write-Ok "Клиент $name удалён." } else { Write-Err 'Не удалось удалить.' }
}

function Invoke-ListAwg {
    Write-Title 'Клиенты AmneziaWG'
    $run = Invoke-RemoteManage -Arguments @('list-awg')
    if ($run.ExitCode -ne 0) { Write-Err 'AmneziaWG недоступен.' }
}

function Invoke-AddAwg {
    Write-Title 'Новый клиент AmneziaWG'
    $name = Read-Input 'Имя клиента (латиница, цифры, _ и -)' '' -Required
    while (-not (Test-IsName $name)) {
        Write-Warn '1-24 символа: A-Z a-z 0-9 _ -'
        $name = Read-Input 'Имя клиента' '' -Required
    }
    $run = Invoke-RemoteManage -Arguments @('add-awg', $name) -Quiet
    Show-HumanOutput $run.Text
    if ($run.ExitCode -ne 0) { Write-Err 'Клиент AmneziaWG не добавлен.'; return }
    $client = Get-ClientJson $run.Text
    if (-not $client) { Write-Warn 'Клиент создан, но конфиг не получен.'; return }
    Save-AwgClient -Client $client
}

function Invoke-DelAwg {
    Write-Title 'Удалить клиента AmneziaWG'
    Invoke-ListAwg
    $name = Read-Input 'Имя клиента для удаления (Enter = отмена)' ''
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if (-not (Read-YesNo "Точно удалить '$name'?" $false)) { Write-Info 'Отменено.'; return }
    $run = Invoke-RemoteManage -Arguments @('del-awg', $name)
    if ($run.ExitCode -eq 0) { Write-Ok "Клиент AmneziaWG $name удалён." } else { Write-Err 'Не удалось удалить.' }
}

function Invoke-Status {
    Write-Title 'Состояние сервера'
    $run = Invoke-RemoteManage -Arguments @('status')
    if ($run.ExitCode -ne 0) { Write-Err 'Не удалось получить статус.' }
}

function Invoke-Backup {
    Write-Title 'Backup'
    Write-Info 'Сохраняю базу панели и конфиги на сервере...'
    $run = Invoke-RemoteManage -Arguments @('backup')
    if ($run.ExitCode -eq 0) { Write-Ok 'Backup готов. Файл лежит в /root/vpn-backups на сервере.' }
    else { Write-Err 'Backup не создан.' }
}

function Invoke-OpenPanel {
    $script = Join-Path $script:ResultFolder 'open-panel.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Warn 'Нет open-panel.ps1 в папке результата. Откройте панель через установщик.'
        return
    }
    Write-Info 'Запускаю SSH-туннель к панели...'
    & $script
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  VPN MANAGER' -ForegroundColor White
        Write-Host "  $($script:Server) · панель $($script:Conn.panel_port)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1) Добавить клиента VLESS' -ForegroundColor Gray
        Write-Host '   2) Список клиентов VLESS' -ForegroundColor Gray
        Write-Host '   3) Ссылка и QR клиента' -ForegroundColor Gray
        Write-Host '   4) Удалить клиента VLESS' -ForegroundColor Gray
        Write-Host '   5) Добавить клиента AmneziaWG' -ForegroundColor Gray
        Write-Host '   6) Список клиентов AmneziaWG' -ForegroundColor Gray
        Write-Host '   7) Удалить клиента AmneziaWG' -ForegroundColor Gray
        Write-Host '   8) Состояние сервера' -ForegroundColor Gray
        Write-Host '   9) Backup базы и конфигов' -ForegroundColor Gray
        Write-Host '  10) Открыть панель 3x-ui' -ForegroundColor Gray
        Write-Host '   0) Выход' -ForegroundColor Gray
        Write-Host ''
        $choice = Read-Input 'Выбор' '0'
        switch ($choice) {
            '1' { Invoke-AddVless }
            '2' { Invoke-ListVless }
            '3' { Invoke-ShowVless }
            '4' { Invoke-DelVless }
            '5' { Invoke-AddAwg }
            '6' { Invoke-ListAwg }
            '7' { Invoke-DelAwg }
            '8' { Invoke-Status }
            '9' { Invoke-Backup }
            '10' { Invoke-OpenPanel }
            '0' { return }
            default { Write-Warn 'Нет такого пункта.' }
        }
        Write-Host ''
        Read-Host '  Нажмите Enter, чтобы продолжить' | Out-Null
    }
}

# =============================================================================
#  SELF-TEST / MAIN
# =============================================================================
function Invoke-SelfTest {
    $fail = 0
    Write-Host ''
    Write-Host '  SELF-TEST' -ForegroundColor Cyan
    Write-Host '  =========' -ForegroundColor DarkCyan

    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
    try { $null = Get-SshExe; Write-Ok 'ssh.exe найден' } catch { Write-Err $_.Exception.Message; $fail++ }
    try {
        $plink = Get-PlinkPath
        if ($plink) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $plink).Hash.ToLowerInvariant()
            if ($hash -eq $script:PlinkSha256) { Write-Ok 'plink.exe: SHA-256 в порядке' }
            else { Write-Err 'plink.exe: SHA-256 не совпал'; $fail++ }
        } else {
            Write-Warn 'plink.exe не найден (нужен только для входа по паролю)'
        }
    } catch { Write-Err $_.Exception.Message; $fail++ }

    if (Test-Path -LiteralPath $script:ManageScript) {
        $text = [IO.File]::ReadAllText($script:ManageScript, [Text.Encoding]::UTF8)
        if ($text.Contains("`r`n")) { Write-Err 'server-manage.sh: CRLF, нужен LF'; $fail++ }
        else { Write-Ok 'server-manage.sh: LF' }
        $required = @(
            '@@PANEL_PORT@@', '@@PANEL_PATH@@', '@@PANEL_USER@@', '@@PANEL_PASS_B64@@',
            '@@INBOUND_ID@@', '@@PUBLIC_HOST@@', '@@SNI@@', '@@PBK@@', '@@SID@@',
            '@@XHTTP_PATH@@', '@@XHTTP_MODE@@', '@@AWG_PORT@@'
        )
        $missing = @($required | Where-Object { -not $text.Contains($_) })
        if ($missing.Count -gt 0) { Write-Err "Нет плейсхолдеров: $($missing -join ', ')"; $fail++ }
        else { Write-Ok 'server-manage.sh: все плейсхолдеры на месте' }
    } else {
        Write-Err "Не найден $script:ManageScript"
        $fail++
    }

    try {
        $html = New-SharePage -Name 'test' -Link 'vless://test' -Qr '' -Title 'Тест'
        if ($html -match '<!doctype html>' -and $html -match 'vless://test') { Write-Ok 'HTML-шаблон: OK' }
        else { Write-Err 'HTML-шаблон: ошибка'; $fail++ }
    } catch { Write-Err $_.Exception.Message; $fail++ }

    Write-Host ''
    if ($fail -eq 0) {
        Write-Host '  ✓ SELF-TEST OK' -ForegroundColor Green
        return $true
    }
    Write-Host "  × Ошибок: $fail" -ForegroundColor Red
    return $false
}

function Main {
    if ($SelfTest) {
        $ok = Invoke-SelfTest
        if (-not $NoPause) { Read-Host '  Нажмите Enter' | Out-Null }
        if (-not $ok) { exit 1 }
        return
    }

    Import-Connection
    Initialize-Auth

    if ($QuickAdd) { Invoke-AddVless; return }
    if ($QuickAwg) { Invoke-AddAwg; return }
    Show-Menu
}

try {
    Main
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if (-not $NoPause) { Read-Host '  Нажмите Enter' | Out-Null }
    if ($env:VPN_IN_MENU -ne '1') { exit 1 }
} finally {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
