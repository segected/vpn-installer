#requires -Version 5.1
<#
    VPN — единое меню.
    Один файл для всего: установка, продолжение, клиенты, проверка, панель.
    Запускается двойным кликом по "Запустить установку VPN.cmd".
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:Installer = Join-Path $script:Root 'installer.ps1'
$script:Manager = Join-Path $script:Root 'manage.ps1'
$script:PowerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $script:PowerShell)) {
    $script:PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
}

try { & chcp.com 65001 > $null } catch { }
try {
    [Console]::OutputEncoding = $script:Utf8
    $global:OutputEncoding = $script:Utf8
} catch { }
try { $Host.UI.RawUI.WindowTitle = 'VPN — установка и управление' } catch { }

# =============================================================================
#  UI
# =============================================================================
function Show-Header {
    Clear-Host
    Write-Host ''
    Write-Host '   ██╗   ██╗██████╗ ███╗   ██╗' -ForegroundColor Cyan
    Write-Host '   ██║   ██║██╔══██╗████╗  ██║' -ForegroundColor Cyan
    Write-Host '   ██║   ██║██████╔╝██╔██╗ ██║' -ForegroundColor DarkCyan
    Write-Host '   ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║' -ForegroundColor DarkCyan
    Write-Host '    ╚████╔╝ ██║     ██║ ╚████║' -ForegroundColor Blue
    Write-Host '     ╚═══╝  ╚═╝     ╚═╝  ╚═══╝' -ForegroundColor Blue
    Write-Host ''
    Write-Host '   VPN  ·  установка и управление' -ForegroundColor White
    Write-Host '   VLESS + XHTTP + Reality  ·  3x-ui  ·  AmneziaWG' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Rule([string]$Text) {
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkCyan
}

function Write-Ok([string]$Text) { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host "  × $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  · $Text" -ForegroundColor Gray }

function Find-LatestResult {
    $bases = @($script:Root, (Split-Path -Parent $script:Root), [Environment]::GetFolderPath('Desktop'))
    $dirs = @()
    foreach ($b in $bases) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if (-not (Test-Path -LiteralPath $b)) { continue }
        $dirs += @(Get-ChildItem -LiteralPath $b -Directory -Filter 'vpn-result*' -ErrorAction SilentlyContinue)
    }
    $dirs = @($dirs | Sort-Object LastWriteTime -Descending)
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'result.json')) { return $d }
    }
    if ($dirs.Count -gt 0) { return $dirs[0] }
    return $null
}

function Get-ResultHost($Folder) {
    try {
        $j = [IO.File]::ReadAllText((Join-Path $Folder.FullName 'result.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        return [string]$j.host
    } catch {
        return ''
    }
}

function Show-Menu {
    $latest = Find-LatestResult
    Write-Host '  ╭──────────────────────────────────────────────────────────╮' -ForegroundColor DarkCyan
    Write-Host ('  │  ВЫБЕРИТЕ ДЕЙСТВИЕ' + (' ' * 39) + '│') -ForegroundColor White
    Write-Host '  ├──────────────────────────────────────────────────────────┤' -ForegroundColor DarkCyan

    $items = @(
        @{ n = '1'; t = 'Установить VPN на сервер'; h = 'новый сервер' },
        @{ n = '2'; t = 'Продолжить установку'; h = 'если прервалась' },
        @{ n = '3'; t = 'Добавить клиентов / управление'; h = 'ключи, статус' },
        @{ n = '4'; t = 'Проверить сервер и оценить'; h = 'диагностика' },
        @{ n = '5'; t = 'Открыть панель 3x-ui'; h = 'через туннель' },
        @{ n = '6'; t = 'Открыть папку с результатом'; h = 'QR и ссылки' },
        @{ n = '7'; t = 'Справка'; h = 'что делает' },
        @{ n = '0'; t = 'Выход'; h = '' }
    )
    foreach ($it in $items) {
        $left = ('  │  {0}  {1}' -f $it.n, $it.t)
        $right = $it.h
        $pad = 58 - ($left.Length - 2) - $right.Length
        if ($pad -lt 1) { $pad = 1 }
        Write-Host ('  │  ') -ForegroundColor DarkCyan -NoNewline
        Write-Host ($it.n) -ForegroundColor Cyan -NoNewline
        Write-Host ('  ' + $it.t) -ForegroundColor White -NoNewline
        Write-Host ((' ' * $pad) + $right) -ForegroundColor DarkGray -NoNewline
        Write-Host (' │') -ForegroundColor DarkCyan
    }
    Write-Host '  ╰──────────────────────────────────────────────────────────╯' -ForegroundColor DarkCyan

    if ($latest) {
        $hostName = Get-ResultHost $latest
        if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = 'сервер' }
        Write-Host "  Последний результат: $hostName  ·  $($latest.Name)" -ForegroundColor DarkGray
    } else {
        Write-Host '  Результатов пока нет — начните с пункта 1.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Наберите номер пункта и нажмите Enter.' -ForegroundColor DarkGray
    $choice = ''
    $empty = 0
    while ($true) {
        Write-Host '  Ваш выбор: ' -ForegroundColor White -NoNewline
        $choice = ([string](Read-Host)).Trim()
        if ($choice -match '^[0-7]$') { return $choice }
        if ([string]::IsNullOrEmpty($choice)) {
            $empty++
            if ($empty -ge 5) {
                throw 'Окно не получает ввод. Закройте его и запустите «Запустить установку VPN.cmd» заново.'
            }
        } else {
            $empty = 0
        }
        Write-Warn 'Нужна одна цифра от 0 до 7. Нажмите её и Enter.'
    }
}

function Wait-Enter {
    if ($NoPause) { return }
    Write-Host ''
    Write-Host '  Нажмите Enter, чтобы вернуться в меню...' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

function Invoke-Inline {
    param([scriptblock]$Action)
    $old = $env:VPN_IN_MENU
    $env:VPN_IN_MENU = '1'
    $global:LASTEXITCODE = 0
    try {
        & $Action
    } catch {
        Write-Host ''
        Write-Err $_.Exception.Message
        $global:LASTEXITCODE = 1
    } finally {
        if ($null -eq $old) {
            Remove-Item Env:\VPN_IN_MENU -ErrorAction SilentlyContinue
        } else {
            $env:VPN_IN_MENU = $old
        }
    }
    $code = $global:LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    $global:LASTEXITCODE = 0
    return [int]$code
}

# =============================================================================
#  ACTIONS
# =============================================================================
function Start-Install {
    Write-Rule 'Установка VPN'
    Write-Info 'Сейчас откроется мастер. Он спросит адрес сервера и несколько опций.'
    Write-Info 'На каждый вопрос набирайте ответ и нажимайте Enter.'
    Write-Host ''
    $code = Invoke-Inline { & $script:Installer -NoPause }
    if ($code -eq 0) { Write-Ok 'Установщик завершил работу.' } else { Write-Warn "Установщик завершился с кодом $code." }
}

function Start-Resume {
    Write-Rule 'Продолжение установки'
    Write-Info 'Если установка прервалась и 3x-ui уже стоит на сервере.'
    Write-Host ''
    $code = Invoke-Inline { & $script:Installer -Resume -NoPause }
    if ($code -eq 0) { Write-Ok 'Продолжение завершено.' } else { Write-Warn "Установщик завершился с кодом $code." }
}

function Start-Manage {
    $latest = Find-LatestResult
    if (-not $latest) {
        Write-Warn 'Сначала установите VPN: нужна папка vpn-result-...'
        return
    }
    if (-not (Test-Path -LiteralPath $script:Manager)) {
        Write-Err "Не найден manage.ps1: $($script:Manager)"
        return
    }
    Write-Rule 'Клиенты и управление'
    Write-Info "Папка: $($latest.FullName)"
    Write-Host ''
    $code = Invoke-Inline { & $script:Manager -ResultDir $latest.FullName -NoPause }
    if ($code -eq 0) { Write-Ok 'Готово.' } else { Write-Warn "Меню управления завершилось с кодом $code." }
}

function Start-Diagnose {
    Write-Rule 'Проверка сервера'
    Write-Info 'Установщик подключится к серверу и проверит, что работает.'
    Write-Host ''
    $code = Invoke-Inline { & $script:Installer -Diagnose -NoPause }
    if ($code -eq 0) { Write-Ok 'Проверка завершена.' } else { Write-Warn "Проверка завершилась с кодом $code." }
}

function Start-OpenPanel {
    $latest = Find-LatestResult
    if (-not $latest) {
        Write-Warn 'Сначала установите VPN: нужна папка vpn-result-...'
        return
    }
    $panel = Join-Path $latest.FullName 'open-panel.ps1'
    if (-not (Test-Path -LiteralPath $panel)) {
        Write-Err "В папке результата нет open-panel.ps1."
        return
    }
    Write-Rule 'Панель 3x-ui'
    Write-Info 'Откроется туннель и браузер. Чтобы закрыть туннель, нажмите Ctrl+C.'
    Write-Host ''
    & $script:PowerShell -NoProfile -ExecutionPolicy Bypass -File $panel
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0) { Write-Warn "Не удалось открыть панель (код $code)." }
}

function Start-OpenFolder {
    $latest = Find-LatestResult
    if (-not $latest) {
        Write-Warn 'Папки с результатом пока нет.'
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $latest.FullName + '"') | Out-Null
    Write-Ok "Открыта папка: $($latest.FullName)"
}

function Show-Help {
    Write-Rule 'Справка'
    Write-Host '  Что делает установщик:' -ForegroundColor Gray
    Write-Host '   • ставит 3x-ui + VLESS XHTTP Reality на TCP 443;' -ForegroundColor DarkGray
    Write-Host '   • по желанию добавляет Hysteria2 (UDP 443) и AmneziaWG;' -ForegroundColor DarkGray
    Write-Host '   • по желанию включает защиту сервера и автообновления;' -ForegroundColor DarkGray
    Write-Host '   • после установки сам проверяет порты, TLS и панель;' -ForegroundColor DarkGray
    Write-Host '   • создаёт папку vpn-result-... с QR, ссылками и конфигами.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Чего он не делает:' -ForegroundColor Gray
    Write-Host '   • не перезагружает сервер;' -ForegroundColor DarkGray
    Write-Host '   • не меняет SSH-порт и sshd_config;' -ForegroundColor DarkGray
    Write-Host '   • не трогает существующую Amnezia и Docker.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Пункты меню:' -ForegroundColor Gray
    Write-Host '   1 — новая установка на чистый сервер;' -ForegroundColor DarkGray
    Write-Host '   2 — закончить прерванную установку (-Resume);' -ForegroundColor DarkGray
    Write-Host '   3 — добавить или удалить клиентов, статус, backup;' -ForegroundColor DarkGray
    Write-Host '   4 — проверить сервер и получить оценку;' -ForegroundColor DarkGray
    Write-Host '   5 — открыть панель 3x-ui;' -ForegroundColor DarkGray
    Write-Host '   6 — открыть папку с QR и ссылками.' -ForegroundColor DarkGray
}

# =============================================================================
#  SELF-TEST / MAIN
# =============================================================================
function Invoke-SelfTest {
    $fail = 0
    Write-Host ''
    Write-Host '  MENU SELF-TEST' -ForegroundColor Cyan
    Write-Host '  ===============' -ForegroundColor DarkCyan

    if (Test-Path -LiteralPath $script:Installer) { Write-Ok 'installer.ps1 найден' } else { Write-Err 'нет installer.ps1'; $fail++ }
    if (Test-Path -LiteralPath $script:Manager) { Write-Ok 'manage.ps1 найден' } else { Write-Err 'нет manage.ps1'; $fail++ }
    if (Test-Path -LiteralPath $script:PowerShell) { Write-Ok "PowerShell: $script:PowerShell" } else { Write-Err 'нет powershell.exe'; $fail++ }

    $self = [IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($self, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { Write-Err "menu.ps1: $($errors[0].Message)"; $fail++ } else { Write-Ok 'menu.ps1: синтаксис OK' }

    Write-Host ''
    if ($fail -eq 0) { Write-Ok 'MENU SELF-TEST OK'; return $true }
    Write-Err "MENU SELF-TEST FAIL: $fail"
    return $false
}

function Main {
    while ($true) {
        Show-Header
        $choice = Show-Menu
        switch ($choice) {
            '1' { Start-Install; Wait-Enter }
            '2' { Start-Resume; Wait-Enter }
            '3' { Start-Manage; Wait-Enter }
            '4' { Start-Diagnose; Wait-Enter }
            '5' { Start-OpenPanel; Wait-Enter }
            '6' { Start-OpenFolder; Wait-Enter }
            '7' { Show-Help; Wait-Enter }
            '0' { return }
        }
    }
}

$exitCode = 0
try {
    if ($SelfTest) {
        if (-not (Invoke-SelfTest)) { $exitCode = 1 }
    } else {
        Main
    }
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if ($env:VPN_INSTALLER_DEBUG -eq '1' -and $_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    $exitCode = 1
}
exit $exitCode
