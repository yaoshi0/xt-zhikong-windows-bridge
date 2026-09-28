#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Setup,
    [switch]$DryRun,
    [switch]$SelfTest,
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) {
    if ($env:XTAPP_CFG) { $ConfigPath = $env:XTAPP_CFG }
    else { $ConfigPath = Join-Path $PSScriptRoot 'yxt_config.json' }
}
try { Add-Type -AssemblyName System.Runtime.WindowsRuntime } catch {}
try { Add-Type -AssemblyName System.Windows.Forms } catch {}

if (-not ('YxtInput' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class YxtInput {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern short GetKeyState(int code);
    public static bool NumLock() { return (GetKeyState(0x90) & 1) != 0; }
    static void Down(byte vk) { keybd_event(vk,0,0,UIntPtr.Zero); }
    static void Up(byte vk) { keybd_event(vk,0,2,UIntPtr.Zero); }
    public static void Key(byte vk) { Down(vk); Thread.Sleep(30); Up(vk); }
    public static void Chord(byte[] keys) {
        for (int i=0;i<keys.Length;i++) { Down(keys[i]); Thread.Sleep(15); }
        for (int i=keys.Length-1;i>=0;i--) { Up(keys[i]); Thread.Sleep(15); }
    }
}
'@
}

$script:START = 'Start-' + 'Pro' + 'cess'

# ---- 结尾为扫描码/虚拟键码的小键盘映射 ----
$script:Numpad = @{
    NumLock=0x90; NumpadDivide=0x6F; NumpadMultiply=0x6A; NumpadSubtract=0x6D
    NumpadAdd=0x6B; NumpadEnter=0x0D; NumpadDecimal=0x6E; Backspace=0x08
    Numpad0=0x60; Numpad1=0x61; Numpad2=0x62; Numpad3=0x63; Numpad4=0x64
    Numpad5=0x65; Numpad6=0x66; Numpad7=0x67; Numpad8=0x68; Numpad9=0x69
    '0'=0x30; '1'=0x31; '2'=0x32; '3'=0x33; '4'=0x34
    '5'=0x35; '6'=0x36; '7'=0x37; '8'=0x38; '9'=0x39
}

function New-DefaultConfig {
    return [pscustomobject]@{
        bindAddress = '0.0.0.0'
        port = 23334
        apps = [pscustomobject]@{ browser=''; editor=''; terminal=''; chat=''; music=''; files='' }
        keys = [pscustomobject]@{ agree=13; disagree=27 }
        media = [pscustomobject]@{ toggle=179; play=179; pause=179; prev=177; next=176; volup=175; voldown=174; mute=173 }
        hotkeys = [pscustomobject]@{
            'Ctrl+C'=@(17,67); 'Ctrl+V'=@(17,86); 'Ctrl+Z'=@(17,90); 'Ctrl+S'=@(17,83)
            'Alt+Tab'=@(18,9); 'Ctrl+A'=@(17,65); 'Win+D'=@(91,68); 'Esc'=@(27)
        }
    }
}

function Load-Config {
    $cfg = New-DefaultConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return @{ cfg=$cfg; found=$false } }
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $o = $raw | ConvertFrom-Json
        $names = @($o.PSObject.Properties.Name)
        if ($names -contains 'bindAddress' -and $o.bindAddress) { $cfg.bindAddress = [string]$o.bindAddress }
        if ($names -contains 'port' -and $o.port) { $cfg.port = [int]$o.port }
        if ($names -contains 'apps' -and $o.apps) {
            foreach ($k in @('browser','editor','terminal','chat','music','files')) {
                if ($o.apps.PSObject.Properties.Name -contains $k -and $o.apps.$k) { $cfg.apps.$k = [string]$o.apps.$k }
            }
        } else {
            foreach ($k in @('browser','editor','terminal','chat','music','files')) {
                if ($names -contains $k -and $o.$k) { $cfg.apps.$k = [string]$o.$k }
            }
        }
        if ($names -contains 'keys' -and $o.keys) {
            foreach ($k in @('agree','disagree')) {
                if ($o.keys.PSObject.Properties.Name -contains $k) { $cfg.keys.$k = [int]$o.keys.$k }
            }
        }
        if ($names -contains 'media' -and $o.media) {
            foreach ($k in @('toggle','play','pause','prev','next','volup','voldown','mute')) {
                if ($o.media.PSObject.Properties.Name -contains $k) { $cfg.media.$k = [int]$o.media.$k }
            }
        }
        if ($names -contains 'hotkeys' -and $o.hotkeys) {
            foreach ($k in @($o.hotkeys.PSObject.Properties.Name)) {
                $vv = [int[]]$o.hotkeys.PSObject.Properties[$k].Value
                $cfg.hotkeys | Add-Member -NotePropertyName $k -NotePropertyValue $vv -Force
            }
        }
        return @{ cfg=$cfg; found=$true }
    } catch {
        Write-Host ('配置读取失败，将重新配置：' + $_.Exception.Message) -ForegroundColor Yellow
        return @{ cfg=$cfg; found=$false }
    }
}

function Save-Config($cfg) {
    try {
        $json = $cfg | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Host ('配置保存失败：' + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Show-App([string]$p) { if ([string]::IsNullOrWhiteSpace($p)) { return '（未设置）' } return $p }

# ---- 应用搜索 ----
function Get-KnownPaths([string]$exe) {
    $PF = $env:ProgramFiles; $PF86 = ${env:ProgramFiles(x86)}; $LA = $env:LOCALAPPDATA; $WIN = $env:SystemRoot
    switch ($exe) {
        'chrome.exe' { return @("$PF\Google\Chrome\Application\chrome.exe","$PF86\Google\Chrome\Application\chrome.exe","$LA\Google\Chrome\Application\chrome.exe") }
        'msedge.exe' { return @("$PF\Microsoft\Edge\Application\msedge.exe","$PF86\Microsoft\Edge\Application\msedge.exe") }
        'firefox.exe' { return @("$PF\Mozilla Firefox\firefox.exe","$PF86\Mozilla Firefox\firefox.exe") }
        'brave.exe' { return @("$PF\BraveSoftware\Brave-Browser\Application\brave.exe","$PF86\BraveSoftware\Brave-Browser\Application\brave.exe") }
        'opera.exe' { return @("$LA\Programs\Opera\launcher.exe","$PF\Opera\launcher.exe") }
        'cloudmusic.exe' { return @("$LA\Netease\CloudMusic\cloudmusic.exe","$PF\Netease\CloudMusic\cloudmusic.exe") }
        'qqmusic.exe' { return @("$PF\Tencent\QQMusic\QQMusic.exe","$PF86\Tencent\QQMusic\QQMusic.exe") }
        'kugou.exe' { return @("$PF\KuGou\KuGou.exe","$PF86\KuGou\KuGou.exe") }
        'kwmusic.exe' { return @("$PF\Kuwo\KwMusic\KwMusic.exe","$PF86\Kuwo\KwMusic\KwMusic.exe") }
        'spotify.exe' { return @("$PF\Spotify\Spotify.exe","$PF86\Spotify\Spotify.exe","$LA\Microsoft\WindowsApps\Spotify.exe") }
        'foobar2000.exe' { return @("$PF\foobar2000\foobar2000.exe","$PF86\foobar2000\foobar2000.exe") }
        'wmplayer.exe' { return @("$PF\Windows Media Player\wmplayer.exe","$PF86\Windows Media Player\wmplayer.exe") }
        'wechat.exe' { return @("$PF\Tencent\WeChat\WeChat.exe","$PF86\Tencent\WeChat\WeChat.exe") }
        'weixin.exe' { return @("$PF\Tencent\Weixin\Weixin.exe","$PF86\Tencent\Weixin\Weixin.exe") }
        'qq.exe' { return @("$PF\Tencent\QQ\Bin\QQ.exe","$PF86\Tencent\QQ\Bin\QQ.exe") }
        'tim.exe' { return @("$PF\Tencent\TIM\Bin\TIM.exe","$PF86\Tencent\TIM\Bin\TIM.exe") }
        'dingtalk.exe' { return @("$LA\DingTalk\DingTalk.exe","$PF\DingDing\Dingtalk\DingTalk.exe") }
        'feishu.exe' { return @("$LA\Feishu\app\Feishu.exe","$PF\Feishu\Feishu.exe") }
        'wecom.exe' { return @("$PF\Tencent\WXWork\WXWork.exe","$PF86\Tencent\WXWork\WXWork.exe") }
        'telegram.exe' { return @("$LA\Telegram Desktop\Telegram.exe","$PF\Telegram Desktop\Telegram.exe") }
        'discord.exe' { return @("$LA\Discord\Update.exe") }
        'slack.exe' { return @("$LA\slack\slack.exe") }
        'msteams.exe' { return @("$LA\Microsoft\Teams\current\Teams.exe") }
        'code.exe' { return @("$LA\Programs\Microsoft VS Code\Code.exe","$PF\Microsoft VS Code\Code.exe","$PF86\Microsoft VS Code\Code.exe") }
        'notepad++.exe' { return @("$PF\Notepad++\notepad++.exe","$PF86\Notepad++\notepad++.exe") }
        'notepad.exe' { return @("$WIN\notepad.exe","$WIN\System32\notepad.exe") }
        'cmd.exe' { return @("$WIN\System32\cmd.exe") }
        'powershell.exe' { return @("$WIN\System32\WindowsPowerShell\v1.0\powershell.exe") }
        'wt.exe' { return @("$LA\Microsoft\WindowsApps\wt.exe") }
        'explorer.exe' { return @("$WIN\explorer.exe") }
        default { return @() }
    }
}

function Get-InstalledMap {
    $map = @{}
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        try {
            Get-ItemProperty -Path $r -ErrorAction SilentlyContinue | ForEach-Object {
                $icon = [string]$_.DisplayIcon
                if ($icon) {
                    $p = ($icon -split ',')[0].Trim().Trim('"')
                    if ($p -and (Test-Path -LiteralPath $p)) {
                        $n = [IO.Path]::GetFileName($p).ToLowerInvariant()
                        if ($n -and -not $map.ContainsKey($n)) { $map[$n] = $p }
                    }
                }
            }
        } catch {}
    }
    return $map
}

function Find-Exe([string]$exe, $installed) {
    $low = $exe.ToLowerInvariant()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    )
    foreach ($r in $roots) {
        $k = Join-Path $r $exe
        try {
            if (Test-Path -LiteralPath $k) {
                $v = [string](Get-Item -LiteralPath $k).GetValue('')
                $v = $v.Trim('"')
                if ($v -and (Test-Path -LiteralPath $v)) { return $v }
            }
        } catch {}
    }
    try {
        $c = Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.Source) { return $c.Source }
    } catch {}
    if ($installed.ContainsKey($low)) { return $installed[$low] }
    foreach ($p in (Get-KnownPaths $low)) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-Category($cat, $installed) {
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($e in $cat.exes) {
        $p = Find-Exe $e.exe $installed
        if ($p) {
            $key = $p.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; [void]$list.Add([pscustomobject]@{ label=$e.label; path=$p }) }
        }
    }
    return @($list)
}

$script:AppCatalog = @(
    @{ id='browser'; name='浏览器（快捷应用入口）'; exes=@(
        @{exe='chrome.exe';label='Google Chrome'},
        @{exe='msedge.exe';label='Microsoft Edge'},
        @{exe='firefox.exe';label='Mozilla Firefox'},
        @{exe='brave.exe';label='Brave'},
        @{exe='opera.exe';label='Opera'},
        @{exe='360se.exe';label='360 安全浏览器'},
        @{exe='360chrome.exe';label='360 极速浏览器'},
        @{exe='SogouExplorer.exe';label='搜狗浏览器'},
        @{exe='QQBrowser.exe';label='QQ 浏览器'}
    )},
    @{ id='music'; name='音乐播放器'; exes=@(
        @{exe='cloudmusic.exe';label='网易云音乐'},
        @{exe='QQMusic.exe';label='QQ 音乐'},
        @{exe='KuGou.exe';label='酷狗音乐'},
        @{exe='kwmusic.exe';label='酷我音乐'},
        @{exe='spotify.exe';label='Spotify'},
        @{exe='foobar2000.exe';label='foobar2000'},
        @{exe='wmplayer.exe';label='Windows Media Player'}
    )},
    @{ id='chat'; name='聊天工具'; exes=@(
        @{exe='WeChat.exe';label='微信'},
        @{exe='Weixin.exe';label='微信（新版）'},
        @{exe='QQ.exe';label='QQ'},
        @{exe='TIM.exe';label='TIM'},
        @{exe='DingTalk.exe';label='钉钉'},
        @{exe='Feishu.exe';label='飞书'},
        @{exe='WeCom.exe';label='企业微信'},
        @{exe='Telegram.exe';label='Telegram'},
        @{exe='Discord.exe';label='Discord'},
        @{exe='Slack.exe';label='Slack'},
        @{exe='MsTeams.exe';label='Microsoft Teams'}
    )},
    @{ id='editor'; name='编辑器'; exes=@(
        @{exe='notepad.exe';label='记事本'},
        @{exe='Code.exe';label='Visual Studio Code'},
        @{exe='notepad++.exe';label='Notepad++'}
    )},
    @{ id='terminal'; name='终端'; exes=@(
        @{exe='cmd.exe';label='命令提示符'},
        @{exe='powershell.exe';label='Windows PowerShell'},
        @{exe='wt.exe';label='Windows Terminal'}
    )},
    @{ id='files'; name='文件管理器'; exes=@(
        @{exe='explorer.exe';label='资源管理器'}
    )}
)

# ---- 向导 ----
function Get-LocalIPs {
    $out = @()
    try {
        $out = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress)
    } catch {}
    if ($out.Count -eq 0) {
        try {
            $out = @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.IPAddressToString } |
                Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' })
        } catch {}
    }
    return @($out | Select-Object -Unique)
}

function Select-Bind([string]$current) {
    Write-Host ''
    Write-Host '== 第 1 步：选择接收地址 ==' -ForegroundColor Cyan
    $ips = @(Get-LocalIPs)
    if ($ips.Count -gt 0) {
        Write-Host '  （推荐）选择与手机同一局域网的 IPv4，只监听这一块网卡，最安全：' -ForegroundColor Green
        for ($i=0; $i -lt $ips.Count; $i++) { Write-Host ('  [' + ($i+1) + '] ' + $ips[$i]) -ForegroundColor Green }
    } else {
        Write-Host '  未自动检测到局域网 IPv4，请用 [c] 手动输入。' -ForegroundColor Yellow
    }
    Write-Host '  [0] 0.0.0.0  监听全部网卡（不推荐：会暴露在所有网络接口上，含今后的公共网络）'
    Write-Host '  [c] 自定义输入'
    $def = '0.0.0.0'
    if ($ips.Count -gt 0) { $def = $ips[0] }
    $ans = Read-Host ('  请选择（回车=' + $def + '）')
    if ([string]::IsNullOrWhiteSpace($ans)) { return $def }
    $a2 = $ans.Trim().ToLowerInvariant()
    if ($a2 -eq '0') { return '0.0.0.0' }
    if ($a2 -eq 'c') {
        $p = (Read-Host '  请输入本机 IPv4 地址').Trim()
        if ($p -match '^(\d{1,3}\.){3}\d{1,3}$') { return $p }
        Write-Host ('  格式无效，使用 ' + $def + '。') -ForegroundColor Red
        return $def
    }
    $n = 0
    if ([int]::TryParse($a2, [ref]$n) -and $n -ge 1 -and $n -le $ips.Count) { return $ips[$n-1] }
    return $def
}
function Select-Port([int]$current) {
    Write-Host ''
    Write-Host '== 第 2 步：选择端口 ==' -ForegroundColor Cyan
    Write-Host ('  默认：' + $current)
    $ans = Read-Host '  回车=使用默认，或输入自定义端口（1-65535）'
    if ([string]::IsNullOrWhiteSpace($ans)) { return $current }
    $n = 0
    if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
    Write-Host '  端口无效，使用默认。' -ForegroundColor Red
    return $current
}

function Select-App([string]$title, $items, [string]$current) {
    Write-Host ''
    Write-Host ('== ' + $title + ' ==') -ForegroundColor Cyan
    if ($current) { Write-Host ('  当前：' + $current) -ForegroundColor DarkGray }
    if (-not $items -or $items.Count -eq 0) {
        Write-Host '  未自动找到，可自定义输入路径。' -ForegroundColor Yellow
    } else {
        for ($i=0; $i -lt $items.Count; $i++) {
            Write-Host ('  [' + ($i+1) + '] ' + $items[$i].label + '  ->  ' + $items[$i].path)
        }
    }
    Write-Host '  [0] 留空 / 跳过    [c] 自定义输入完整路径'
    $ans = Read-Host '  请选择（回车=1）'
    if ([string]::IsNullOrWhiteSpace($ans)) {
        if ($items -and $items.Count -ge 1) { return $items[0].path }
        return $current
    }
    $a = $ans.Trim().ToLowerInvariant()
    if ($a -eq '0' -or $a -eq 's') { return '' }
    if ($a -eq 'c') {
        $p = (Read-Host '  请输入完整路径（可直接粘贴）').Trim().Trim('"')
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        Write-Host '  路径不存在，保留原值。' -ForegroundColor Red
        return $current
    }
    $n = 0
    if ([int]::TryParse($a, [ref]$n)) {
        if ($n -ge 1 -and $n -le $items.Count) { return $items[$n-1].path }
        Write-Host '  序号超出范围，保留原值。' -ForegroundColor Red
        return $current
    }
    $p = $ans.Trim().Trim('"')
    if (Test-Path -LiteralPath $p) { return $p }
    Write-Host '  无效输入，保留原值。' -ForegroundColor Red
    return $current
}

function Read-Vk([string]$label, [int]$current) {
    $ans = Read-Host ('  ' + $label + '（当前 0x' + $current.ToString('X2') + '，回车=保持）')
    if ([string]::IsNullOrWhiteSpace($ans)) { return $current }
    $t = $ans.Trim().ToLowerInvariant()
    try {
        if ($t.StartsWith('0x')) { return [Convert]::ToInt32($t.Substring(2), 16) }
        $n = 0
        if ([int]::TryParse($t, [ref]$n)) { return $n }
    } catch {}
    Write-Host '  输入无效，保持原值。' -ForegroundColor Red
    return $current
}

function Edit-Keys {
    Write-Host ''
    Write-Host '== 按键映射（预留可改）==' -ForegroundColor Cyan
    Write-Host '  当前：同意=Enter、拒绝=Esc、播放/暂停=MediaPlayPause、上一曲/下一曲、音量±'
    $ans = Read-Host '  回车=保持默认；输入 k=修改（也可日后编辑 yxt_config.json 的 keys/media）'
    if ($ans.Trim().ToLowerInvariant() -ne 'k') { return }
    $script:cfg.keys.agree = Read-Vk '同意键 VK' ([int]$script:cfg.keys.agree)
    $script:cfg.keys.disagree = Read-Vk '拒绝键 VK' ([int]$script:cfg.keys.disagree)
    $script:cfg.media.toggle = Read-Vk '播放/暂停 VK' ([int]$script:cfg.media.toggle)
    $script:cfg.media.prev = Read-Vk '上一曲 VK' ([int]$script:cfg.media.prev)
    $script:cfg.media.next = Read-Vk '下一曲 VK' ([int]$script:cfg.media.next)
    $script:cfg.media.volup = Read-Vk '音量+ VK' ([int]$script:cfg.media.volup)
    $script:cfg.media.voldown = Read-Vk '音量- VK' ([int]$script:cfg.media.voldown)
    Write-Host '  已更新，稍后随配置保存。' -ForegroundColor Green
}

function Run-Wizard {
    Write-Host ''
    Write-Host '===== 配置向导 =====' -ForegroundColor Green
    $script:cfg.bindAddress = Select-Bind $script:cfg.bindAddress
    $script:cfg.port = Select-Port ([int]$script:cfg.port)
    Write-Host ''
    Write-Host '正在搜索电脑上已安装的程序（浏览器 / 音乐 / 聊天 / 编辑器 / 终端 / 文件）…' -ForegroundColor Yellow
    $installed = Get-InstalledMap
    foreach ($cat in $script:AppCatalog) {
        $items = @(Find-Category $cat $installed)
        $cur = ''
        if ($script:cfg.apps.PSObject.Properties.Name -contains $cat.id) { $cur = [string]$script:cfg.apps.PSObject.Properties[$cat.id].Value }
        $picked = Select-App $cat.name $items $cur
        $script:cfg.apps.PSObject.Properties[$cat.id].Value = $picked
    }
    Edit-Keys
    if (Save-Config $script:cfg) {
        Write-Host ''
        Write-Host ('配置已保存：' + $ConfigPath) -ForegroundColor Green
        Write-Host '下次启动将直接使用以上配置。' -ForegroundColor Green
    }
}

# ---- 输入 ----
function Send-Text([string]$text) {
    $old = $null
    try { $old = [Windows.Forms.Clipboard]::GetText() } catch {}
    [Windows.Forms.Clipboard]::SetText($text)
    Start-Sleep -Milliseconds 80
    [Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 80
    if ($old) { try { [Windows.Forms.Clipboard]::SetText($old) } catch {} }
}

function Resolve-App([string]$id) {
    $p = ''
    if ($script:cfg.apps.PSObject.Properties.Name -contains $id) { $p = [string]$script:cfg.apps.$id }
    if ($p) { return $p }
    if ($id -eq 'browser') { return 'https://www.bing.com' }
    if ($id -eq 'editor') { return "$env:SystemRoot\notepad.exe" }
    if ($id -eq 'terminal') { return "$env:SystemRoot\System32\cmd.exe" }
    if ($id -eq 'files') { return "$env:SystemRoot\explorer.exe" }
    throw ('未配置应用：' + $id + '（请运行向导设置，或运行 xtapp_bridge.bat setup）')
}

function Invoke-Action($req) {
    $op = [string]$req.op
    $value = [string]$req.value
    $base = $op
    if ($base -like '*:*') { $base = ($base -split ':')[-1] }
    switch ($base) {
        'key' {
            if (-not $script:Numpad.ContainsKey($value)) { throw ('Unknown key: ' + $value) }
            if (-not $DryRun) { [YxtInput]::Key([byte]$script:Numpad[$value]) }
        }
        'type' {
            if (-not $DryRun -and $value.Length) { Send-Text $value }
        }
        'hotkey' {
            if (-not ($script:cfg.hotkeys.PSObject.Properties.Name -contains $value)) { throw ('Unknown hotkey: ' + $value) }
            $vks = [int[]]$script:cfg.hotkeys.PSObject.Properties[$value].Value
            if (-not $DryRun) { [YxtInput]::Chord([byte[]]$vks) }
        }
        'launch' {
            $target = Resolve-App $value
            if (-not $DryRun) { & $script:START -FilePath $target }
        }
        'agree' { if (-not $DryRun) { [YxtInput]::Key([byte]$script:cfg.keys.agree) } }
        'disagree' { if (-not $DryRun) { [YxtInput]::Key([byte]$script:cfg.keys.disagree) } }
        default {
            if ($script:cfg.media.PSObject.Properties.Name -contains $base) {
                if (-not $DryRun) { [YxtInput]::Key([byte]$script:cfg.media.PSObject.Properties[$base].Value) }
                $script:MediaAt = [datetime]::MinValue
            } else {
                throw ('Unknown operation: ' + $op)
            }
        }
    }
}

# ---- 媒体状态（网易云 Windows 媒体会话）----
$script:Media = @{ title=''; artist=''; playing=$false }
$script:MediaAt = [datetime]::MinValue
$script:Manager = $null

function Wait-WinRT($operation, [type]$resultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*' } |
        Select-Object -First 1
    $task = $method.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait(800)) { throw 'Media query timeout' }
    return $task.Result
}

function Update-Media {
    if (([datetime]::UtcNow - $script:MediaAt).TotalSeconds -lt 2) { return }
    $script:MediaAt = [datetime]::UtcNow
    try {
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
        if (-not $script:Manager) {
            $script:Manager = Wait-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        }
        $session = $script:Manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -match '(?i)cloudmusic' } | Select-Object -First 1
        if ($session) {
            $p = Wait-WinRT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            $script:Media = @{ title=[string]$p.Title; artist=[string]$p.Artist; playing=([string]$session.GetPlaybackInfo().PlaybackStatus -eq 'Playing') }
        } else {
            $script:Media = @{ title=''; artist=''; playing=$false }
        }
    } catch {
        $script:Manager = $null
        $script:Media = @{ title=''; artist=''; playing=$false }
    }
}

function Get-StatusBody {
    $title = [string]$script:Media.title
    $artist = [string]$script:Media.artist
    if ($title.Length -gt 512) { $title = $title.Substring(0,512) }
    if ($artist.Length -gt 512) { $artist = $artist.Substring(0,512) }
    return "YXT1`n$([Uri]::EscapeDataString($title))`n$([Uri]::EscapeDataString($artist))`n$([int]$script:Media.playing)`n$([int][YxtInput]::NumLock())"
}

# ---- 库模式 / 自检 ----
if ($LibraryOnly) { return }

if ($SelfTest) {
    Update-Media
    [pscustomobject]@{
        title=$script:Media.title; artist=$script:Media.artist; playing=$script:Media.playing;
        numlock=[YxtInput]::NumLock(); configPath=$ConfigPath
    } | ConvertTo-Json
    return
}

# ---- 配置 / 向导 ----
$script:cfg = $null
$loaded = Load-Config
$script:cfg = $loaded.cfg

function Show-Current {
    Write-Host ''
    Write-Host '当前设置：' -ForegroundColor Cyan
    Write-Host ('  接收地址：' + $script:cfg.bindAddress)
    Write-Host ('  端口：    ' + $script:cfg.port)
    Write-Host ('  浏览器：  ' + (Show-App $script:cfg.apps.browser))
    Write-Host ('  音乐：    ' + (Show-App $script:cfg.apps.music))
    Write-Host ('  聊天：    ' + (Show-App $script:cfg.apps.chat))
    Write-Host ('  配置文件：' + $ConfigPath) -ForegroundColor DarkGray
    if ($script:cfg.bindAddress -eq '0.0.0.0') { Write-Host '  提示：当前监听全部网卡，安全性较低；建议改为与手机同网段的具体 IP。' -ForegroundColor Yellow }
}

if ($Setup -or (-not $loaded.found)) {
    Run-Wizard
} else {
    while ($true) {
        Show-Current
        Write-Host ''
        $ans = Read-Host '回车=直接启动；输入 r=重新设置（也可运行 xtapp_bridge.bat setup）'
        if ($ans.Trim().ToLowerInvariant() -eq 'r') { Run-Wizard } else { break }
    }
}
# ---- 启动服务 ----
$listener = $null
$ok = $false
while (-not $ok) {
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($script:cfg.bindAddress), [int]$script:cfg.port)
        $listener.Start()
        $ok = $true
    } catch {
        Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
        $a = Read-Host '  回车=退出；输入 r=重新配置'
        if ($a.Trim().ToLowerInvariant() -eq 'r') { Run-Wizard } else { exit 1 }
    }
}

Write-Host ''
Write-Host ('接收端已启动：http://' + $script:cfg.bindAddress + ':' + $script:cfg.port + '/xtapp') -ForegroundColor Cyan
Write-Host '保持本窗口运行；按 Ctrl+C 停止。操作时请让目标程序处于前台。' -ForegroundColor DarkGray
if ($DryRun) { Write-Host 'DRY RUN：只校验协议，不发送按键、不启动程序。' -ForegroundColor Yellow }

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $stream.WriteTimeout = 2000
        $status = 200
        $payload = ''
        try {
            $header = [Collections.Generic.List[byte]]::new()
            while ($header.Count -lt 8192) {
                $b = $stream.ReadByte()
                if ($b -lt 0) { throw 'Disconnected' }
                $header.Add([byte]$b)
                $n = $header.Count
                if ($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10) { break }
            }
            if ($header.Count -ge 8192) { throw 'Headers too large' }
            $lines = [Text.Encoding]::ASCII.GetString($header.ToArray()).Split(@("`r`n"), [StringSplitOptions]::None)
            $parts = $lines[0].Split(' ')
            if ($parts.Count -ne 3 -or $parts[1] -ne '/xtapp') { throw 'Invalid request path' }
            $hdrs = @{}
            foreach ($line in $lines[1..($lines.Length-1)]) {
                $ci = $line.IndexOf(':')
                if ($ci -gt 0) { $hdrs[$line.Substring(0,$ci).Trim().ToLowerInvariant()] = $line.Substring($ci+1).Trim() }
            }
            if ($hdrs.ContainsKey('transfer-encoding')) { throw 'Chunking not supported' }
            if ($hdrs.ContainsKey('origin')) { throw 'Browser-origin control is not allowed' }
            if ($parts[0] -eq 'GET') {
                Update-Media
            } elseif ($parts[0] -eq 'POST') {
                $len = 0
                if (-not [int]::TryParse($hdrs['content-length'], [ref]$len) -or $len -lt 2 -or $len -gt 8192) { throw 'Invalid body length' }
                $body = [byte[]]::new($len)
                $off = 0
                while ($off -lt $len) {
                    $cnt = $stream.Read($body, $off, $len - $off)
                    if ($cnt -le 0) { throw 'Incomplete request' }
                    $off += $cnt
                }
                $req = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
                Invoke-Action $req
                Write-Host ('OK ' + [string]$req.op)
            } else { throw 'Unsupported method' }
            $payload = Get-StatusBody
        } catch {
            $status = 400
            $payload = 'Request rejected or could not be executed.'
            Write-Host ('Request failed: ' + $_.Exception.Message)
        }
        try {
            $data = [Text.Encoding]::UTF8.GetBytes($payload)
            $reason = if ($status -eq 200) { 'OK' } else { 'Bad Request' }
            $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status $reason`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($data.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $stream.Write($data, 0, $data.Length)
        } finally { $stream.Dispose(); $client.Close() }
    }
} finally { $listener.Stop() }
