param(
    [string]$WorkDir="",
    [string]$ToolsPath=""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public class WinApi { [DllImport("user32.dll")] public static extern int ShowScrollBar(IntPtr hWnd, int wBar, bool bShow); public const int SB_HORZ=0; }
public class NoHScrollListView : ListView {
    private const int WM_HSCROLL=0x114,WM_VSCROLL=0x115,WM_MOUSEWHEEL=0x20A,WM_SIZE=0x5,WM_PAINT=0xF;
    private void HideH(){try{WinApi.ShowScrollBar(Handle,WinApi.SB_HORZ,false);}catch{}}
    protected override void WndProc(ref Message m){base.WndProc(ref m);if(m.Msg==WM_HSCROLL||m.Msg==WM_VSCROLL||m.Msg==WM_MOUSEWHEEL||m.Msg==WM_SIZE||m.Msg==WM_PAINT)HideH();}
    protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);HideH();}
}
"@ -ReferencedAssemblies "System.Windows.Forms","System.Drawing","System"

try{[Console]::OutputEncoding=[System.Text.Encoding]::UTF8}catch{}
# Hide console window when running as compiled exe
# WinAPI helpers for window management
Add-Type -Name "FgWin32" -Namespace "" -MemberDefinition @"
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    public static void ForceToForeground(IntPtr hWnd){
        // Double Alt press/release to unlock foreground lock and reset Alt state
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 0x0002, UIntPtr.Zero);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 0x0002, UIntPtr.Zero);
        IntPtr hFg=GetForegroundWindow();
        uint fgThread=0; uint myThread=GetCurrentThreadId();
        if(hFg!=IntPtr.Zero){GetWindowThreadProcessId(hFg,out fgThread);}
        if(fgThread!=0&&fgThread!=myThread){AttachThreadInput(myThread,fgThread,true);}
        ShowWindow(hWnd,9);
        SetForegroundWindow(hWnd);
        BringWindowToTop(hWnd);
        if(fgThread!=0&&fgThread!=myThread){AttachThreadInput(myThread,fgThread,false);}
    }
"@ -ErrorAction SilentlyContinue
# Hide console window if running as compiled exe
try{
    $hwnd=[System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle
    if($hwnd -ne [IntPtr]::Zero){[FgWin32]::ShowWindow($hwnd,0)|Out-Null}
}catch{}

# In ps2exe, PSScriptRoot may be null - use multiple fallbacks
$scriptDir=if($PSScriptRoot -and $PSScriptRoot -ne ""){
    $PSScriptRoot
}elseif($MyInvocation.MyCommand.Path -and $MyInvocation.MyCommand.Path -ne ""){
    Split-Path $MyInvocation.MyCommand.Path -Parent
}elseif([System.Reflection.Assembly]::GetExecutingAssembly().Location -and
        [System.Reflection.Assembly]::GetExecutingAssembly().Location -ne ""){
    Split-Path ([System.Reflection.Assembly]::GetExecutingAssembly().Location) -Parent
}else{
    [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
# WorkDir: temp folder for archive operations
$script:WorkDir=if($WorkDir -ne "" -and $null -ne $WorkDir){$WorkDir}elseif($env:TEMP -and $env:TEMP -ne ""){$env:TEMP}elseif($env:TMP -and $env:TMP -ne ""){$env:TMP}else{"C:\Temp"}
# Clean leftover temp dirs older than 1 hour
Get-ChildItem $script:WorkDir -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[0-9a-f]{32}$' -and $_.LastWriteTime -lt (Get-Date).AddHours(-1)}|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
if(-not(Test-Path $script:WorkDir)){New-Item -ItemType Directory -Path $script:WorkDir -Force|Out-Null}
# ToolsPath: folder with adb.exe, aapt2.exe, 7z.exe
$script:ToolsPath=if($ToolsPath -ne "" -and $null -ne $ToolsPath){$ToolsPath}elseif($scriptDir -and $scriptDir -ne ""){$scriptDir}else{""}
function Find-Tool{param([string]$n)
    # 1. ToolsPath param
    if($script:ToolsPath -and $script:ToolsPath -ne ""){
        $l=Join-Path $script:ToolsPath $n;if(Test-Path $l -ErrorAction SilentlyContinue){return $l}}
    # 2. Script / exe directory
    if($scriptDir -and $scriptDir -ne ""){
        $l2=Join-Path $scriptDir $n;if(Test-Path $l2 -ErrorAction SilentlyContinue){return $l2}}
    # 3. Exe location (ps2exe)
    try{
        $exeDir=Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent
        $l3=Join-Path $exeDir $n;if(Test-Path $l3 -ErrorAction SilentlyContinue){return $l3}
    }catch{}
    # 4. myfiles env variable
    $ev=[Environment]::GetEnvironmentVariable("myfiles","Process")
    if($ev){$p=if(Test-Path $ev -PathType Container -ErrorAction SilentlyContinue){Join-Path $ev $n}else{$ev}
        if(Test-Path $p -ErrorAction SilentlyContinue){return $p}}
    return $n}
$envAdb=Find-Tool "adb.exe"
$envAapt2=Find-Tool "aapt2.exe"
$env7z=Find-Tool "7z.exe"
$script:AdbAvailable=Test-Path $envAdb -ErrorAction SilentlyContinue
$currentLocalPath="C:\"; $currentAdbPath="/storage/emulated/0"
$global:SelectedPaths=New-Object "System.Collections.Generic.HashSet[string]"
$global:ClipboardItems=@(); $global:ClipboardIsAdb=$false
$global:SortPC="Name"; $global:SortPCAsc=$true; $global:SortADB="Name"; $global:SortADBAsc=$true
$script:SearchIsPC=$true; $script:SearchStop=$false; $script:SearchSLV=$null; $script:SearchSW=$null
$script:ArchivePath=""; $script:ArchiveIsPC=$true; $script:ArchiveName=""; $script:ArchiveSubDir=""  # empty = not in archive
$script:CtxItem=$null; $script:CtxLVRef=$null; $script:CtxPath=""; $script:CtxIsPC=$true; $script:CtxIsDir=$false; $script:CtxSnap=@()
$script:LogPaused=$false
# Editor state - ALL in $script: so named functions can access them from event handlers
$script:EdTx=$null; $script:EdEncBox=$null; $script:EdStEd=$null; $script:EdForm=$null
$script:EdFilePath=""; $script:EdTitle=""; $script:EdIsAdb=$false; $script:EdAdbPath=""
$script:EdModified=$false; $script:EdClosed=$false; $script:EdFileExt=""; $script:EdHlOn=$false
$script:EdWrapOn=$false; $script:EdBWrap=$null

$extExec=@("exe","bat","cmd","ps1","vbs","wsf","msi","com","scr","pif")
$extText=@("txt","log","cfg","ini","conf","xml","json","yaml","yml","md","csv","nfo","inf","reg","sh","bash", "sql")
$extMedia=@("mp4","mkv","avi","mov","wmv","flv","webm","jpg","jpeg","png","gif","bmp","webp","svg","mp3","wav","flac","aac","ogg")

function Get-FileType{param([string]$n)
    $leaf=($n.TrimEnd("/") -split "[/\\]")[-1];$e="";$dot=$leaf.LastIndexOf(".")
    if($dot -ge 0){$e=$leaf.Substring($dot+1).ToLower()}
    if($e -eq "apk" -or $e -eq "xapk" -or $e -eq "apks"){return "apk"}
    $archExts2=@("zip","7z","rar","gz","tar","bz2","xz","cab","iso","tgz","tbz2","z01","z02","z03","z04","z05")
    if($archExts2-contains $e){return "arch"}
    # Multivolume: .001 .002 ... or .partN.rar pattern
    if($e -match "^[0-9]{2,3}$"){return "arch"}
    if($n -match "\.part[0-9]+\.rar$"){return "arch"}
    if($extExec-contains $e){return "exec"};if($extText-contains $e){return "text"}
    if($extMedia-contains $e){return "media"}
    if($n.EndsWith("/")){return "dir"};return "other"}


function Get-FileColor{param([string]$n,[bool]$isDir=$false)
    $archExts=@("zip","7z","rar","gz","tar","bz2","xz","cab","iso","tgz","tbz2","z01","z02","z03","z04","z05")
    if($n -eq ".. [Go Up]"){return [System.Drawing.Color]::FromArgb(130,128,122)}
    if($isDir -or $n.Contains(":\")){return [System.Drawing.Color]::FromArgb(255,255,255)}
    $ext2="";$d2=$n.LastIndexOf(".");if($d2 -ge 0){$ext2=$n.Substring($d2+1).ToLower()}
    if($archExts -contains $ext2 -and $ext2 -ne "apk"){return [System.Drawing.Color]::FromArgb(0,255,0)}
    if($ext2 -match "^[0-9]{2,3}$" -or $n -match "\.part[0-9]+\.rar$"){return [System.Drawing.Color]::FromArgb(0,255,0)}
    switch(Get-FileType $n){"exec"{return [System.Drawing.Color]::FromArgb(0,255,255)}"text"{return [System.Drawing.Color]::FromArgb(0,140,0)}
        "media"{return [System.Drawing.Color]::FromArgb(80,150,255)}"apk"{return [System.Drawing.Color]::FromArgb(200,115,255)}
        default{return [System.Drawing.Color]::FromArgb(192,192,192)}}}

$bgForm=[System.Drawing.Color]::FromArgb(42,42,46); $bgActive=[System.Drawing.Color]::FromArgb(30,30,34)
$bgInact=[System.Drawing.Color]::FromArgb(22,22,26); $bgHdr=[System.Drawing.Color]::FromArgb(34,34,40)
$curAct=[System.Drawing.Color]::FromArgb(28,98,178); $curInact=[System.Drawing.Color]::FromArgb(58,58,72)
$markClr=[System.Drawing.Color]::FromArgb(255,222,40); $ctxHiClr=[System.Drawing.Color]::FromArgb(48,48,62)
$clrText=[System.Drawing.Color]::FromArgb(210,208,202); $clrDim=[System.Drawing.Color]::FromArgb(150,148,142)
$clrStatus=[System.Drawing.Color]::DeepSkyBlue
$clrGold=[System.Drawing.Color]::FromArgb(212,188,82); $clrLabel=[System.Drawing.Color]::FromArgb(100,180,240)
$ROW_H=22
$fntItem=New-Object System.Drawing.Font("Segoe UI",9.5)
$fntHdr=New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$fntPath=New-Object System.Drawing.Font("Consolas",10,[System.Drawing.FontStyle]::Bold)
$fntEd=New-Object System.Drawing.Font("Consolas",12)
$sfVC=New-Object System.Drawing.StringFormat
$sfVC.LineAlignment=[System.Drawing.StringAlignment]::Center
$sfVC.Alignment=[System.Drawing.StringAlignment]::Near
$sfVC.FormatFlags=[System.Drawing.StringFormatFlags]::NoWrap

function Format-Bytes{param([long]$b)
    if($b -gt 1GB){return "{0:N1} GB"-f($b/1GB)};if($b -gt 1MB){return "{0:N1} MB"-f($b/1MB)}
    if($b -gt 1KB){return "{0:N1} KB"-f($b/1KB)};if($b -ge 0){return "$b B"};return ""}
function Get-LocalSize{param($p)
    if(Test-Path $p -PathType Leaf){return(Get-Item $p -ErrorAction SilentlyContinue).Length}
    if(Test-Path $p -PathType Container){return(Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue|Measure-Object -Property Length -Sum).Sum}
    return 0L}
function Get-AaptPkg{param([string]$apk)
    try{$o=& "$envAapt2" dump badging "`"$apk`"" 2>&1|Select-Object -First 5
        foreach($l in $o){if($l -match "^package:\s+name='([^']+)'"){return $Matches[1]}}}catch{};return $null}
function Detect-Encoding{param([byte[]]$bytes)
    if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){return @{Enc=[System.Text.Encoding]::UTF8;Name="UTF-8 with BOM"}}
    if($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE){return @{Enc=[System.Text.Encoding]::Unicode;Name="UTF-8 with BOM"}}
    $isU8=$true;$i=0;$hasHigh=$false
    while($i -lt $bytes.Length -and $isU8){$b=$bytes[$i];if($b -lt 0x80){$i++;continue};$hasHigh=$true
        if($b -ge 0xC2 -and $b -le 0xDF){$cont=1}elseif($b -ge 0xE0 -and $b -le 0xEF){$cont=2}elseif($b -ge 0xF0 -and $b -le 0xF4){$cont=3}else{$isU8=$false;break}
        for($j=1;$j -le $cont;$j++){if(($i+$j) -ge $bytes.Length -or $bytes[$i+$j] -lt 0x80 -or $bytes[$i+$j] -gt 0xBF){$isU8=$false;break}};$i+=$cont+1}
    if($isU8 -and $hasHigh){return @{Enc=[System.Text.Encoding]::UTF8;Name="UTF-8"}}
    # Heuristic: OEM 866 range 0x80-0xAF vs Win-1251 range 0xC0-0xDF
    $c866=($bytes|Where-Object{$_ -ge 0x80 -and $_ -le 0xAF}).Count
    $c1251=($bytes|Where-Object{$_ -ge 0xC0 -and $_ -le 0xDF}).Count
    if($c866 -gt $c1251 -and $c866 -gt 0){try{return @{Enc=[System.Text.Encoding]::GetEncoding(866);Name="OEM 866"}}catch{}}
    try{return @{Enc=[System.Text.Encoding]::GetEncoding(1251);Name="Windows-1251"}}catch{return @{Enc=[System.Text.Encoding]::ASCII;Name="ASCII"}}
}
function Get-EncFromName{param([string]$n)
    switch($n){"UTF-8"{return New-Object System.Text.UTF8Encoding($false)}"UTF-8 with BOM"{return New-Object System.Text.UTF8Encoding($true)}
        "Windows-1251"{try{return [System.Text.Encoding]::GetEncoding(1251)}catch{return [System.Text.Encoding]::UTF8}}
        "Windows-1252"{try{return [System.Text.Encoding]::GetEncoding(1252)}catch{return [System.Text.Encoding]::UTF8}}
        "OEM 866"{try{return [System.Text.Encoding]::GetEncoding(866)}catch{return [System.Text.Encoding]::UTF8}}
        "ASCII"{return [System.Text.Encoding]::ASCII}default{return New-Object System.Text.UTF8Encoding($false)}}}

# ==============================================================================
# ФУНКЦИЯ ПОДСВЕТКИ СИНТАКСИСА (ИСПРАВЛЕНА)
# ==============================================================================
function Apply-SyntaxHighlight {
    param(
        [System.Windows.Forms.RichTextBox]$tx,
        [string]$ext,
        [int]$maxLines = 3000
    )

    if ($null -eq $tx -or $script:EdHighlighting) { return }

    $ext = $ext.ToLower()
    $supported = @("ps1", "bat", "cmd", "sh", "bash", "ini", "cfg", "conf", "log", "nfo", "json", "sql")
    if ($ext -notin $supported) { return }

    $defaultColor = if ($null -ne $script:clrText) { $script:clrText } else { [System.Drawing.Color]::FromArgb(220, 220, 220) }

    $wasEdModified = $script:EdModified
    $wasTitle = if ($null -ne $script:EdForm) { $script:EdForm.Text } else { "" }
    
    $script:EdHighlighting = $true
    $script:EdSuppressEvents = $true

    try {
        $tx.SuspendLayout()
        $sp = $tx.SelectionStart
        $sl = $tx.SelectionLength

        # Reset selection color
        $tx.SelectAll()
        $tx.SelectionColor = $defaultColor
        $tx.SelectionBackColor = $tx.BackColor

        $full = $tx.Text

        # Palette definition
        $cKw   = [System.Drawing.Color]::FromArgb(86, 156, 214)   # Keywords
        $cStr  = [System.Drawing.Color]::FromArgb(206, 145, 120)  # Strings
        $cCmt  = [System.Drawing.Color]::FromArgb(106, 153, 85)   # Comments
        $cVar  = [System.Drawing.Color]::FromArgb(156, 220, 254)  # Variables
        $cNum  = [System.Drawing.Color]::FromArgb(181, 206, 168)  # Numbers
        $cOp   = [System.Drawing.Color]::FromArgb(212, 143, 215)  # Operators
        $cEcho = [System.Drawing.Color]::FromArgb(220, 220, 170)  # Output
        $cSec  = [System.Drawing.Color]::FromArgb(78, 201, 176)   # INI Sections
        $cKey  = [System.Drawing.Color]::FromArgb(156, 220, 254)  # Keys
        $cVal  = [System.Drawing.Color]::FromArgb(206, 145, 120)  # Values
        $cErr  = [System.Drawing.Color]::FromArgb(244, 71, 71)    # Errors
        $cWrn  = [System.Drawing.Color]::FromArgb(205, 151, 49)   # Warnings
        $cInf  = [System.Drawing.Color]::FromArgb(78, 201, 176)   # Info
        $cDbg  = [System.Drawing.Color]::FromArgb(130, 130, 150)  # Debug
        $cVarB = [System.Drawing.Color]::FromArgb(180, 220, 100)  # BAT Variables %var%

        if ($ext -eq "ps1") {
            $kwList = @("function","param","if","else","elseif","foreach","for","while","do","switch","return","break","continue","try","catch","finally","throw","class","end","begin","process","filter","trap","exit","in","using","namespace")
            $opList = @("-eq","-ne","-lt","-gt","-le","-ge","-like","-notlike","-match","-notmatch","-contains","-notcontains","-in","-notin","-and","-or","-not","-xor","-band","-bor","-bnot")
        } elseif ($ext -in @("bat", "cmd")) {
            $kwList = @("if","else","for","do","goto","call","set","pause","not","exist","defined","shift","pushd","popd","move","copy","del","mkdir","rmdir","cls","exit","dir","type","find","findstr","setlocal","endlocal")
            $opList = @()
        } elseif ($ext -in @("sh", "bash")) {
            $kwList = @("if","then","else","elif","fi","for","do","done","while","until","case","esac","function","return","break","continue","exit","export","local","readonly","source","echo","printf","read","shift","set","unset","trap")
            $opList = @()
        } elseif ($ext -eq "sql") {
            $kwList = @("select","from","where","insert","update","delete","join","left","right","inner","outer","on","group","by","order","having","limit","create","table","drop","alter","index","into","values","and","or","not","null","is","as")
            $opList = @()
        } else {
            $kwList = @()
            $opList = @()
        }

        $linesArr = $full -split "`n"
        $charPos = 0
        $lineCount = 0

        foreach ($ln in $linesArr) {
            $lineCount++
            if ($lineCount -gt $maxLines) { break }
            $llen = $ln.Length
            $trimmed = $ln.TrimStart()

            # INI / CFG / CONF
            if ($ext -in @("ini", "cfg", "conf")) {
                if ($trimmed.StartsWith("[") -and $trimmed.Contains("]")) { $tx.Select($charPos, $llen); $tx.SelectionColor = $cSec; $charPos += $llen + 1; continue }
                if ($trimmed.StartsWith(";") -or $trimmed.StartsWith("#")) { $tx.Select($charPos, $llen); $tx.SelectionColor = $cCmt; $charPos += $llen + 1; continue }
                $eq = $ln.IndexOf("=")
                if ($eq -gt 0) {
                    $tx.Select($charPos, $eq); $tx.SelectionColor = $cKey
                    $tx.Select($charPos + $eq, $llen - $eq); $tx.SelectionColor = $cVal
                }
                $charPos += $llen + 1
                continue
            }

            # LOG / NFO
            if ($ext -in @("log", "nfo")) {
                $up = $trimmed.ToUpper()
                if ($up -match "ERROR|FAIL|FATAL|CRITICAL") { $tx.Select($charPos, $llen); $tx.SelectionColor = $cErr; $charPos += $llen + 1; continue }
                if ($up -match "WARN(ING)?") { $tx.Select($charPos, $llen); $tx.SelectionColor = $cWrn; $charPos += $llen + 1; continue }
                if ($up -match "INFO|OK|SUCCESS|DONE|COMPLETE") { $tx.Select($charPos, $llen); $tx.SelectionColor = $cInf; $charPos += $llen + 1; continue }
                if ($up -match "DEBUG|TRACE|VERBOSE") { $tx.Select($charPos, $llen); $tx.SelectionColor = $cDbg; $charPos += $llen + 1; continue }
                $charPos += $llen + 1
                continue
            }

            # JSON
            if ($ext -eq "json") {
                $colIdx = $ln.IndexOf(":")
                if ($colIdx -gt 0) {
                    $tx.Select($charPos, $colIdx); $tx.SelectionColor = $cKey
                    $tx.Select($charPos + $colIdx, $llen - $colIdx); $tx.SelectionColor = $cVal
                }
                $charPos += $llen + 1
                continue
            }

            # Comments
            $isCmt = $false
            if ($ext -in @("bat", "cmd") -and ($trimmed -match "(?i)^rem($|\s)" -or $trimmed.StartsWith("::"))) { $isCmt = $true }
            elseif ($ext -in @("sh", "bash", "ps1") -and $trimmed.StartsWith("#")) { $isCmt = $true }
            elseif ($ext -eq "sql" -and $trimmed.StartsWith("--")) { $isCmt = $true }
            if ($isCmt) { $tx.Select($charPos, $llen); $tx.SelectionColor = $cCmt; $charPos += $llen + 1; continue }

            # Echo output
            $isEcho = $false
            if ($ext -in @("bat", "cmd") -and $trimmed -match "(?i)^echo($|\s)") { $isEcho = $true }
            if ($ext -eq "ps1" -and $trimmed -match "(?i)^(Write-Host|Write-Output|Write-Warning|Write-Error|Write-Verbose)($|\s)") { $isEcho = $true }
            if ($isEcho) { $tx.Select($charPos, $llen); $tx.SelectionColor = $cEcho; $charPos += $llen + 1; continue }

            # Inline PowerShell comments
            if ($ext -eq "ps1") {
                $ci = $ln.IndexOf(" #")
                if ($ci -ge 0 -and $ci -lt $llen - 1) {
                    $tx.Select($charPos + $ci + 1, $llen - $ci - 1)
                    $tx.SelectionColor = $cCmt
                }
            }

            # Double quotes
            $si = 0
            while ($si -lt $llen) {
                $qi = $ln.IndexOf("`"", $si)
                if ($qi -lt 0) { break }
                $qi2 = $ln.IndexOf("`"", $qi + 1)
                if ($qi2 -lt 0) { $qi2 = $llen - 1 }
                $tx.Select($charPos + $qi, $qi2 - $qi + 1)
                $tx.SelectionColor = $cStr
                $si = $qi2 + 1
            }

            # Single quotes
            if ($ext -in @('ps1', 'sh', 'bash', 'sql')) {
                $si = 0
                while ($si -lt $llen) {
                    $qi = $ln.IndexOf("'", $si)
                    if ($qi -lt 0) { break }
                    $qi2 = $ln.IndexOf("'", $qi + 1)
                    if ($qi2 -lt 0) { $qi2 = $llen - 1 }
                    $tx.Select($charPos + $qi, $qi2 - $qi + 1)
                    $tx.SelectionColor = $cStr
                    $si = $qi2 + 1
                }
            }

            # Variables $var
            if ($ext -in @('ps1', 'sh', 'bash')) {
                $si = 0
                while ($si -lt $llen) {
                    $vi = $ln.IndexOf('$', $si)
                    if ($vi -lt 0) { break }
                    $ve = $vi + 1
                    while ($ve -lt $llen -and $ln[$ve] -match '[a-zA-Z0-9_]') { $ve++ }
                    if ($ve -gt $vi + 1) {
                        $tx.Select($charPos + $vi, $ve - $vi)
                        $tx.SelectionColor = $cVar
                    }
                    $si = $ve
                }
            }
            # Variables %var%
            elseif ($ext -in @("bat", "cmd")) {
                $si = 0
                while ($si -lt $llen) {
                    $vi = $ln.IndexOf("%", $si)
                    if ($vi -lt 0) { break }
                    $ve = $ln.IndexOf("%", $vi + 1)
                    if ($ve -lt 0) { break }
                    $tx.Select($charPos + $vi, $ve - $vi + 1)
                    $tx.SelectionColor = $cVarB
                    $si = $ve + 1
                }
            }

            # Keywords
            foreach ($kw in $kwList) {
                $si = 0
                while ($si -lt $llen) {
                    $idx = $ln.IndexOf($kw, $si, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($idx -lt 0) { break }
                    $pre = if ($idx -gt 0) { $ln[$idx - 1] } else { " " }
                    $suf = if ($idx + $kw.Length -lt $llen) { $ln[$idx + $kw.Length] } else { " " }
                    if (-not ($pre -match "[a-zA-Z0-9_-]") -and -not ($suf -match "[a-zA-Z0-9_-]")) {
                        $tx.Select($charPos + $idx, $kw.Length)
                        $tx.SelectionColor = $cKw
                    }
                    $si = $idx + $kw.Length
                }
            }

            # Operators
            foreach ($op in $opList) {
                $si = 0
                while ($si -lt $llen) {
                    $idx = $ln.IndexOf($op, $si, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($idx -lt 0) { break }
                    $suf = if ($idx + $op.Length -lt $llen) { $ln[$idx + $op.Length] } else { " " }
                    if (-not ($suf -match "[a-zA-Z0-9]")) {
                        $tx.Select($charPos + $idx, $op.Length)
                        $tx.SelectionColor = $cOp
                    }
                    $si = $idx + $op.Length
                }
            }

            # Numbers
            $si = 0
            while ($si -lt $llen) {
                if ($ln[$si] -match "[0-9]") {
                    $pre2 = if ($si -gt 0) { $ln[$si - 1] } else { " " }
                    if (-not ($pre2 -match "[a-zA-Z_]")) {
                        $ne = $si
                        while ($ne -lt $llen -and $ln[$ne] -match "[0-9.]") { $ne++ }
                        $tx.Select($charPos + $si, $ne - $si)
                        $tx.SelectionColor = $cNum
                        $si = $ne
                        continue
                    }
                }
                $si++
            }

            $charPos += $llen + 1
        }

        $tx.Select($sp, $sl)
    }
    finally {
        $tx.ResumeLayout()
        $script:EdHighlighting = $false
        $script:EdSuppressEvents = $false
        $script:EdModified = $wasEdModified
        if ($null -ne $script:EdForm) { $script:EdForm.Text = $wasTitle }
    }
}



function Ed-Save {
    if ($null -eq $script:EdFilePath -or $null -eq $script:EdTx) { return }
    
    # Берем кодировку из списка "Convert to:"
    $targetEncName = [string]$script:EdSaveEncBox.SelectedItem
    $targetEncoding = Get-SafeEncoding -encName $targetEncName

    try {
        # Получаем текущий текст из редактора
        $textToSave = $script:EdTx.Text
        
        # Конвертируем текст в байты целевой кодировки
        $bytesToSave = $targetEncoding.GetBytes($textToSave)
        
        # Записываем новые байты в файл на диске
        [System.IO.File]::WriteAllBytes($script:EdFilePath, $bytesToSave)
        
        # Обновляем байты в памяти редактора
        $script:EdRawBytes = $bytesToSave
        
        # Синхронизируем список "View:" с новой кодировкой сохраненного файла
        $script:EdSuppressEvents = $true
        $script:EdViewEncBox.SelectedItem = $targetEncName
        $script:EdSuppressEvents = $false

        # Сбрасываем флаг изменений
        $script:EdModified = $false
        if ($null -ne $script:EdForm) {
            $script:EdForm.Text = $script:EdTitle
        }
        if ($null -ne $script:EdStEd) {
            $script:EdStEd.Text = "  $script:EdFilePath  [Сохранено и конвертировано в: $targetEncName]"
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Ошибка при сохранении файла:`n$_", "Ошибка", "OK", "Error")
    }
}

function Ed-AskSave{
    return [System.Windows.Forms.MessageBox]::Show("Unsaved changes. Save now?","Unsaved",[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Warning)}

#function Ed-Close{
#    if($null -eq $script:EdForm){return}
#    if($script:EdModified){$r=Ed-AskSave
#        if($r -eq [System.Windows.Forms.DialogResult]::Yes){Ed-Save;$script:EdClosed=$true;$script:EdForm.Close()}
#        elseif($r -eq [System.Windows.Forms.DialogResult]::No){$script:EdClosed=$true;$script:EdForm.Close()}
#    }else{$script:EdClosed=$true;$script:EdForm.Close()}}

# ==============================================================================
# ФУНКЦИЯ ЗАКРЫТИЯ ОКНА (ИСПРАВЛЕНА)
# ==============================================================================
function Ed-Close {
    # Функция только отправляет команду на закрытие формы.
    # Вся логика проверки несохраненных изменений перенесена в FormClosing.
    if ($null -ne $script:EdForm) {
        $script:EdForm.Close()
    }
}

function Ed-ToggleWrap{
    if($null -eq $script:EdTx){return}
    $script:EdWrapOn=-not $script:EdWrapOn
    if($script:EdWrapOn){$script:EdTx.WordWrap=$true;$script:EdTx.ScrollBars="Vertical"
        if($null -ne $script:EdBWrap){$script:EdBWrap.Text="Wrap:ON";$script:EdBWrap.ForeColor=$clrGold}
    }else{$script:EdTx.WordWrap=$false;$script:EdTx.ScrollBars="Both"
        if($null -ne $script:EdBWrap){$script:EdBWrap.Text="Wrap:OFF";$script:EdBWrap.ForeColor=$clrDim}}}

# ==============================================================================
# ФУНКЦИЯ ПОИСКА И ПОДСВЕТКИ ТЕКСТА
# ==============================================================================
function Ed-Search {
    param(
        [string]$query
    )

    if ($null -eq $script:EdTx -or [string]::IsNullOrEmpty($query)) {
        $script:EdSearchIndices = @()
        $script:EdSearchCurrentIndex = -1
        $script:EdSearchQueryLength = 0
        return 0
    }

    # Сохраняем длину подсвечиваемого текста
    $script:EdSearchQueryLength = $query.Length

    $script:EdSuppressEvents = $true
    try {
        $script:EdTx.SuspendLayout()

        # Сохраняем текущее положение курсора
        $startPos = $script:EdTx.SelectionStart
        $selLen   = $script:EdTx.SelectionLength

        # 1. Сброс предыдущей подсветки
        $script:EdTx.SelectAll()
        $script:EdTx.SelectionBackColor = $script:EdTx.BackColor

        if ($script:EdHlOn) {
            Apply-SyntaxHighlight $script:EdTx $script:EdFileExt
        } else {
            $script:EdTx.SelectionColor = $clrText
        }

        # 2. Поиск совпадений и выделение желтым цветом
        $script:EdSearchIndices = @()
        $script:EdSearchCurrentIndex = -1
        $text = $script:EdTx.Text
        $index = 0

        while (($index = $text.IndexOf($query, $index, [System.StringComparison]::OrdinalIgnoreCase)) -ge 0) {
            $script:EdSearchIndices += $index

            $script:EdTx.Select($index, $query.Length)
            $script:EdTx.SelectionBackColor = [System.Drawing.Color]::Yellow
            $script:EdTx.SelectionColor     = [System.Drawing.Color]::Black

            $index += $query.Length
        }

        # 3. Возврат курсора на исходную позицию
        $script:EdTx.Select($startPos, $selLen)

    } finally {
        $script:EdTx.ResumeLayout()
        $script:EdSuppressEvents = $false
    }

    return $script:EdSearchIndices.Count
}

# ==============================================================================
# ФУНКЦИЯ НАВИГАЦИИ ПО НАЙДЕННЫМ СОВПАДЕНИЯМ (ИСПРАВЛЕНА)
# ==============================================================================
function Ed-SearchNext {
    param(
        [bool]$reverse = $false
    )

    if ($null -eq $script:EdSearchIndices -or $script:EdSearchIndices.Count -eq 0) { 
        return 
    }

    # Изменение индекса в зависимости от направления (< или >)
    if ($reverse) {
        $script:EdSearchCurrentIndex--
        if ($script:EdSearchCurrentIndex -lt 0) {
            $script:EdSearchCurrentIndex = $script:EdSearchIndices.Count - 1
        }
    } else {
        $script:EdSearchCurrentIndex++
        if ($script:EdSearchCurrentIndex -ge $script:EdSearchIndices.Count) {
            $script:EdSearchCurrentIndex = 0
        }
    }

    $pos = $script:EdSearchIndices[$script:EdSearchCurrentIndex]
    $qLen = $script:EdSearchQueryLength

    # Прокрутка и выделение найденного элемента без вызова Controls.Find
    if ($qLen -gt 0) {
        $script:EdTx.Select($pos, $qLen)
        $script:EdTx.ScrollToCaret()
    }

    if ($null -ne $script:EdSbLbl) {
        $script:EdSbLbl.Text = "  $($script:EdSearchCurrentIndex + 1)/$($script:EdSearchIndices.Count) found"
    }
}


function Set-Status{param([string]$t,[string]$col="Blue")
    $c=switch($col){
        "Green"{[System.Drawing.Color]::FromArgb(88,200,108)}
        "Red"{[System.Drawing.Color]::FromArgb(210,88,78)}
        "Yellow"{[System.Drawing.Color]::FromArgb(230,190,80)}
        "Blue"{ $clrStatus }
        default{ $clrStatus }
    }
    $stBar.Text=$t;$stBar.ForeColor=$c;$form.Update()}


# ======= Diagnostics / Logging =====================================================
# Output: Off / Window / File / Both
# Level:  Error / Important / Detailed / Debug
$script:LogOutput="Window"
$script:LogLevel="Important"
$script:LogSettingsForm=$null

function Add-Log{
    param(
        [string]$t,
        [string]$col="Gray",
        [ValidateSet("Auto","Error","Important","Detailed","Debug")]
        [string]$Level="Auto"
    )

    $entry="[$([System.DateTime]::Now.ToString("HH\:mm\:ss"))] $t"

    # Keep the old colour-based calls working:
    # Red=Error, Green=Important, everything else=Detailed.
    $effectiveLevel=$Level
    if($effectiveLevel -eq "Auto"){
        $effectiveLevel=switch($col){
            "Red"{"Error"}
            "Green"{"Important"}
            default{"Detailed"}
        }
    }

    $rank=@{"Error"=1;"Important"=2;"Detailed"=3;"Debug"=4}
    $levelRank=$rank[$effectiveLevel]
    $selectedRank=$rank[$script:LogLevel]

    $writeWindow=($script:LogOutput -eq "Window" -or $script:LogOutput -eq "Both")
    $writeFile=($script:LogOutput -eq "File" -or $script:LogOutput -eq "Both")

    if($levelRank -le $selectedRank){
        if($writeFile){
            $logFile=Join-Path $env:TEMP "adbcm_debug.log"
            Add-Content -LiteralPath $logFile -Value $entry -ErrorAction SilentlyContinue
        }

        if($writeWindow){
            if($logBox.Items.Count -gt 300){
                $logBox.Items.RemoveAt(0)
            }
            $logBox.Items.Add($entry)|Out-Null
            if(-not $script:LogPaused){
                $logBox.TopIndex=$logBox.Items.Count-1
            }
        }
    }
}

function Show-LogSettings {
    if ($script:LogSettingsForm -and -not $script:LogSettingsForm.IsDisposed) {
        $script:LogSettingsForm.BringToFront()
        $script:LogSettingsForm.Activate()
        return
    }

    $d = New-Object System.Windows.Forms.Form
    $d.Text = "Diagnostics / Logging"
    $d.Size = New-Object System.Drawing.Size(425, 340)
    $d.MinimumSize = $d.Size
    $d.MaximumSize = $d.Size
    $d.BackColor = $bgForm
    $d.ForeColor = $clrText
    $d.FormBorderStyle = "FixedDialog"
    $d.StartPosition = "CenterParent"
    $d.KeyPreview = $true
    $script:LogSettingsForm = $d

    # --- Блок «Output» ---
    $grpOut = New-Object System.Windows.Forms.GroupBox
    $grpOut.Text = "Output"
    $grpOut.Location = New-Object System.Drawing.Point(15, 10)
    $grpOut.Size = New-Object System.Drawing.Size(380, 100)
    $grpOut.ForeColor = $clrText
    $d.Controls.Add($grpOut)

    # Таблица-сетка для ровного размещения 2х2
    $tblOut = New-Object System.Windows.Forms.TableLayoutPanel
    $tblOut.Dock = "Fill"
    $tblOut.Padding = New-Object System.Windows.Forms.Padding(5, 10, 5, 5)
    $tblOut.ColumnCount = 2
    $tblOut.RowCount = 2
    $tblOut.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $tblOut.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $grpOut.Controls.Add($tblOut)

    $outNames = @(
        @("Off", "Off"),
        @("Window", "Window"),
        @("File", "File"),
        @("Window + File", "Both")
    )
    $outBtns = @{}
    foreach ($item in $outNames) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = $item[0]
        $rb.Tag = $item[1]
        $rb.AutoSize = $true
        $rb.ForeColor = $clrText
        $rb.BackColor = $bgForm
        $rb.Add_CheckedChanged({
            param($s, $e)
            if ($s.Checked) { $script:LogOutput = [string]$s.Tag }
        })
        $tblOut.Controls.Add($rb)
        $outBtns[$item[1]] = $rb
    }
    if ($outBtns.ContainsKey($script:LogOutput)) {
        $outBtns[$script:LogOutput].Checked = $true
    }

    # --- Блок «Log level» ---
    $grpLvl = New-Object System.Windows.Forms.GroupBox
    $grpLvl.Text = "Log level"
    $grpLvl.Location = New-Object System.Drawing.Point(15, 120)
    $grpLvl.Size = New-Object System.Drawing.Size(380, 100)
    $grpLvl.ForeColor = $clrText
    $d.Controls.Add($grpLvl)

    # Таблица-сетка для ровного размещения 2х2
    $tblLvl = New-Object System.Windows.Forms.TableLayoutPanel
    $tblLvl.Dock = "Fill"
    $tblLvl.Padding = New-Object System.Windows.Forms.Padding(5, 10, 5, 5)
    $tblLvl.ColumnCount = 2
    $tblLvl.RowCount = 2
    $tblLvl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $tblLvl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $grpLvl.Controls.Add($tblLvl)

    $lvlNames = @(
        @("Errors", "Error"),
        @("Errors + Important", "Important"),
        @("Detailed", "Detailed"),
        @("Debug", "Debug")
    )
    $lvlBtns = @{}
    foreach ($item in $lvlNames) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = $item[0]
        $rb.Tag = $item[1]
        $rb.AutoSize = $true
        $rb.ForeColor = $clrText
        $rb.BackColor = $bgForm
        $rb.Add_CheckedChanged({
            param($s, $e)
            if ($s.Checked) { $script:LogLevel = [string]$s.Tag }
        })
        $tblLvl.Controls.Add($rb)
        $lvlBtns[$item[1]] = $rb
    }
    if ($lvlBtns.ContainsKey($script:LogLevel)) {
        $lvlBtns[$script:LogLevel].Checked = $true
    }

    # --- Подсказка и кнопка закрытия ---
    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "F12 - show/hide this panel"
    $lblInfo.Location = New-Object System.Drawing.Point(18, 240)
    $lblInfo.Size = New-Object System.Drawing.Size(220, 22)
    $lblInfo.ForeColor = $clrDim
    $d.Controls.Add($lblInfo)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(300, 235)
    $btnClose.Size = New-Object System.Drawing.Size(90, 28)
    $btnClose.FlatStyle = "Flat"
    $btnClose.ForeColor = $clrText
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 56)
    $btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $btnClose.Add_Click({
        $d.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $d.Close()
    })
    $d.Controls.Add($btnClose)
    $d.CancelButton = $btnClose

    $d.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq "F12" -or $e.KeyCode -eq "Escape") {
            $e.SuppressKeyPress = $true
            $d.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $d.Close()
        }
    })

    $d.Add_FormClosed({ $script:LogSettingsForm = $null })
    $d.ShowDialog($form) | Out-Null
}



function Show-AdbDialog{param($title,$msg,$defVal=$null,$items=@(),$isHelp=$false)
    $d=New-Object System.Windows.Forms.Form;$d.Text=$title;$d.BackColor=$bgForm;$d.ForeColor=$clrText
    $d.FormBorderStyle="FixedDialog";$d.KeyPreview=$true;$d.StartPosition="CenterParent"
    $d.GetType().GetProperty("DoubleBuffered",[System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($d,$true,$null)
    if($isHelp){$d.Size="620,640"}elseif($null -ne $defVal){$d.Size="450,200"}else{$d.Size="480,360"}
    $rtb=New-Object System.Windows.Forms.RichTextBox
    $rtb.Location="20,15";$rtb.Size="$([int]($d.ClientSize.Width-40)),$([int]($d.ClientSize.Height-85))"
    $rtb.BackColor=$bgForm;$rtb.ForeColor=$clrText;$rtb.BorderStyle="None";$rtb.ReadOnly=$true
    $rtb.Font=New-Object System.Drawing.Font("Segoe UI",10);$rtb.Cursor=[System.Windows.Forms.Cursors]::Arrow;$rtb.TabStop=$false
    $rtb.AppendText($msg+"`r`n`r`n")
    foreach($i in $items){$rtb.SelectionColor=$markClr;$rtb.AppendText("  $i`r`n");$rtb.SelectionColor=$clrText}
    $d.Controls.Add($rtb);$inp=$null
    if($null -ne $defVal){$rtb.Visible=$false
        $lbl=New-Object System.Windows.Forms.Label;$lbl.Text=$msg;$lbl.Location="20,25";$lbl.Size="410,35";$lbl.TextAlign="MiddleCenter";$d.Controls.Add($lbl)
        $inp=New-Object System.Windows.Forms.TextBox;$inp.Location="50,75";$inp.Width=350;$inp.Text=$defVal
        $inp.BackColor=[System.Drawing.Color]::FromArgb(55,55,62);$inp.ForeColor=$clrText;$d.Controls.Add($inp)}
    $bOk=New-Object System.Windows.Forms.Button;$bOk.Text="OK";$bOk.Size="90,30";$bOk.FlatStyle="Flat";$bOk.DialogResult="OK"
    $bCn=New-Object System.Windows.Forms.Button;$bCn.Text="Cancel";$bCn.Size="90,30";$bCn.FlatStyle="Flat";$bCn.DialogResult="Cancel"
    foreach($b in @($bOk,$bCn)){$b.ForeColor=$clrText;$b.BackColor=[System.Drawing.Color]::FromArgb(52,52,60);$b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(78,78,88)}
    $hw=[int]$d.ClientSize.Width;$hh=[int]$d.ClientSize.Height
    $bOk.Location=New-Object System.Drawing.Point([int]($hw/2-100),[int]($hh-46))
    $bCn.Location=New-Object System.Drawing.Point([int]($hw/2+10),[int]($hh-46))
    $d.Controls.AddRange(@($bOk,$bCn));$d.AcceptButton=$bOk;$d.CancelButton=$bCn
    $d.Add_Shown({if($null -ne $inp){$inp.Focus();$inp.SelectAll()}else{$bOk.Focus()}})
    $res=$d.ShowDialog()
    if($res -eq "OK"){if($null -ne $inp){return $inp.Text}else{return $true}};return $null}

# TEXT EDITOR - stores everything in $script:, event handlers call Ed-* named functions

# ==============================================================================
# ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ ДЛЯ БЕЗОПАСНОГО ПОЛУЧЕНИЯ ОБЪЕКТА КОДИРОВКИ
# ==============================================================================
function Get-SafeEncoding ([string]$encName) {
    try {
        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    } catch {}

    switch ($encName) {
        "UTF-8"          { return [System.Text.UTF8Encoding]::new($false) } # UTF-8 без BOM
        "UTF-8 with BOM" { return [System.Text.UTF8Encoding]::new($true) }  # UTF-8 c BOM
        "UTF-16 LE"      { return [System.Text.Encoding]::Unicode }         # Windows Unicode (LE)
        "UTF-16 BE"      { return [System.Text.Encoding]::BigEndianUnicode }# Big Endian
        "Windows-1251"   { return [System.Text.Encoding]::GetEncoding(1251) }# Кириллица Windows
        "Windows-1252"   { return [System.Text.Encoding]::GetEncoding(1252) }# Западная Европа
        "OEM 866"        { return [System.Text.Encoding]::GetEncoding(866) } # DOS / Консоль
        "ASCII"          { return [System.Text.Encoding]::ASCII }
        default          { return [System.Text.UTF8Encoding]::new($false) }
    }
}

# ==============================================================================
# ФУНКЦИЯ ОКНА РЕДАКТОРА (ИСПРАВЛЕНА)
# ==============================================================================
function Show-TextEditor {
    param(
        [string]$FilePath,
        [string]$Title,
        [bool]$IsAdb = $false,
        [string]$AdbPath = ""
    )

    $script:EdFilePath       = $FilePath
    $script:EdTitle          = $Title
    $script:EdIsAdb          = $IsAdb
    $script:EdAdbPath        = $AdbPath
    $script:EdModified       = $false
    $script:EdClosed         = $false
    $script:EdHlOn           = $false
    $script:EdWrapOn         = $false
    $script:EdRawBytes       = $null
    $script:EdSuppressEvents = $true

    $script:EdTmpDirToCleanup = $null
    if ($FilePath -like "*\AppData\Local\Temp\*" -and -not $IsAdb) {
        $script:EdTmpDirToCleanup = Split-Path $FilePath -Parent
    }

    $dotIdx = $Title.LastIndexOf(".")
    $script:EdFileExt = if ($dotIdx -ge 0) { $Title.Substring($dotIdx + 1).ToLower() } else { "" }

    # Создание формы
    $ed = New-Object System.Windows.Forms.Form
    $ed.Text = "Edit: $Title"
    $ed.Size = New-Object System.Drawing.Size(1120, 740)
    $ed.MinimumSize = New-Object System.Drawing.Size(750, 400)
    $ed.BackColor = $bgForm
    $ed.ForeColor = $clrText
    $ed.StartPosition = "CenterParent"
    $ed.FormBorderStyle = "Sizable"
    $ed.KeyPreview = $true
    $script:EdForm = $ed

    # 1. Верхняя панель инструментов (Toolbar)
    $tb = New-Object System.Windows.Forms.Panel
    $tb.Dock = "Top"; $tb.Height = 38
    $tb.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $ed.Controls.Add($tb)

    $mkB = {
        param([string]$t2, [int]$x2, [int]$w2 = 110)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $t2
        $b.Location = New-Object System.Drawing.Point($x2, 5)
        $b.Size = New-Object System.Drawing.Size($w2, 28)
        $b.FlatStyle = "Flat"
        $b.ForeColor = $clrText
        $b.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(78, 78, 88)
        $tb.Controls.Add($b)
        return $b
    }

    $bSave  = &$mkB "Save Ctrl+S" 8 105
    $bSaveC = &$mkB "Save+Close" 118 105
    $bClose = &$mkB "Close Esc" 228 85
    $bWrap  = &$mkB "Wrap:OFF" 318 75
    $bWrap.ForeColor = $clrDim
    $bWrap.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
    $script:EdBWrap  = $bWrap

    $bHl = &$mkB "Syntax: OFF" 398 90
    $bHl.ForeColor = $clrDim
    $bHl.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)

    # Выбор кодировки для чтения (View)
    $lblView = New-Object System.Windows.Forms.Label
    $lblView.Text = "View:"
    $lblView.Location = New-Object System.Drawing.Point(495, 10)
    $lblView.Size = New-Object System.Drawing.Size(40, 18)
    $lblView.ForeColor = $clrDim
    $tb.Controls.Add($lblView)

    $viewEncBox = New-Object System.Windows.Forms.ComboBox
    $viewEncBox.Location = New-Object System.Drawing.Point(537, 7)
    $viewEncBox.Size = New-Object System.Drawing.Size(130, 24)
    $viewEncBox.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
    $viewEncBox.ForeColor = $clrText
    $viewEncBox.DropDownStyle = "DropDownList"
    $tb.Controls.Add($viewEncBox)
    $script:EdViewEncBox = $viewEncBox

    # Выбор кодировки для сохранения (Convert to)
    $lblSave = New-Object System.Windows.Forms.Label
    $lblSave.Text = "Convert to:"
    $lblSave.Location = New-Object System.Drawing.Point(675, 10)
    $lblSave.Size = New-Object System.Drawing.Size(75, 18)
    $lblSave.ForeColor = $clrDim
    $tb.Controls.Add($lblSave)

    $saveEncBox = New-Object System.Windows.Forms.ComboBox
    $saveEncBox.Location = New-Object System.Drawing.Point(753, 7)
    $saveEncBox.Size = New-Object System.Drawing.Size(130, 24)
    $saveEncBox.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
    $saveEncBox.ForeColor = $clrText
    $saveEncBox.DropDownStyle = "DropDownList"
    $tb.Controls.Add($saveEncBox)
    $script:EdSaveEncBox = $saveEncBox

    $encList = @("UTF-8", "UTF-8 with BOM", "UTF-16 LE", "UTF-16 BE", "Windows-1251", "Windows-1252", "OEM 866", "ASCII")
    foreach ($item in $encList) {
        $viewEncBox.Items.Add($item) | Out-Null
        $saveEncBox.Items.Add($item) | Out-Null
    }

    # 2. Панель поиска (Search Bar Panel)
    $sbP = New-Object System.Windows.Forms.Panel
    $sbP.Dock = "Top"; $sbP.Height = 32
    $sbP.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 34)
    $ed.Controls.Add($sbP)

    $sbBox = New-Object System.Windows.Forms.TextBox
    $sbBox.Location = New-Object System.Drawing.Point(8, 5)
    $sbBox.Size = New-Object System.Drawing.Size(180, 22)
    $sbBox.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 58)
    $sbBox.ForeColor = $clrText; $sbBox.BorderStyle = "FixedSingle"
    $sbP.Controls.Add($sbBox)

    $bPrev = New-Object System.Windows.Forms.Button
    $bPrev.Text = "<"
    $bPrev.Location = New-Object System.Drawing.Point(192, 5)
    $bPrev.Size = New-Object System.Drawing.Size(30, 20)
    $bPrev.FlatStyle = "Flat"
    $bPrev.ForeColor = $clrText
    $bPrev.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
    $bPrev.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(78, 78, 88)
    $sbP.Controls.Add($bPrev)

    $bNext = New-Object System.Windows.Forms.Button
    $bNext.Text = ">"
    $bNext.Location = New-Object System.Drawing.Point(225, 5)
    $bNext.Size = New-Object System.Drawing.Size(30, 20)
    $bNext.FlatStyle = "Flat"
    $bNext.ForeColor = $clrText
    $bNext.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
    $bNext.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(78, 78, 88)
    $sbP.Controls.Add($bNext)

    $sbLbl = New-Object System.Windows.Forms.Label
    $sbLbl.Location = New-Object System.Drawing.Point(262, 7)
    $sbLbl.Size = New-Object System.Drawing.Size(350, 20)
    $sbLbl.ForeColor = $clrDim
    $sbP.Controls.Add($sbLbl)
    $script:EdSbLbl = $sbLbl

    # 3. Нижняя строка статуса редактора ($stEd / $script:EdStEd)
    $stEd = New-Object System.Windows.Forms.Label
    $stEd.Dock = "Bottom"
    $stEd.Height = 24
    $stEd.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 36)
    $stEd.ForeColor = $clrDim
    $stEd.TextAlign = "MiddleLeft"
    $ed.Controls.Add($stEd)
    $script:EdStEd = $stEd

    # 4. Текстовое поле (RichTextBox)
    $tx = New-Object System.Windows.Forms.RichTextBox
    $tx.Dock = "Fill"; $tx.BorderStyle = "None"; $tx.AcceptsTab = $true
    $tx.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $tx.ForeColor = $clrText
    $tx.Font = $fntEd; $tx.ScrollBars = "Both"; $tx.WordWrap = $false
    $ed.Controls.Add($tx)
    $tx.BringToFront()
    $script:EdTx = $tx
$tx.Add_TextChanged({
        if ($script:EdSuppressEvents) { return }
        if (-not $script:EdModified) {
            $script:EdModified = $true
            if ($null -ne $script:EdForm -and -not $script:EdForm.Text.EndsWith(" *")) {
                $script:EdForm.Text += " *"
            }
        }
    })


    # 5. Настройка обработчиков событий
    $bPrev.Add_Click({ Ed-SearchNext -reverse $true })
    $bNext.Add_Click({ Ed-SearchNext -reverse $false })

    $sbBox.Add_TextChanged({
        $q = $this.Text
        if ($null -eq $script:EdSbLbl) { return }
        if ($q.Length -lt 3) {
            $script:EdSbLbl.Text = ""
            $script:EdSearchIndices = @()
            return
        }
        $total = Ed-Search $q
        if ($total -gt 0) {
            $script:EdSbLbl.Text = "  1/$total found"
        } else {
            $script:EdSbLbl.Text = "  not found"
        }
    })

    $sbBox.Add_KeyDown({
        param($s, $ev)
        if ($ev.KeyCode -eq "Enter") {
            if ($ev.Shift) {
                Ed-SearchNext -reverse $true
            } else {
                Ed-SearchNext -reverse $false
            }
            $ev.SuppressKeyPress = $true
        }
    })

    $bSave.Add_Click({ Ed-Save })
    $bSaveC.Add_Click({ Ed-Save; $script:EdClosed = $true; if ($null -ne $script:EdForm) { $script:EdForm.Close() } })
    $bClose.Add_Click({ Ed-Close })
    $bWrap.Add_Click({ Ed-ToggleWrap })

    $bHl.Add_Click({
        $script:EdHlOn = -not $script:EdHlOn
        if ($script:EdHlOn) {
            $this.Text = "Syntax: ON"
            $this.ForeColor = $clrGold
            if ($null -ne $script:EdTx) {
                Apply-SyntaxHighlight $script:EdTx $script:EdFileExt
            }
        } else {
            $this.Text = "Syntax: OFF"
            $this.ForeColor = $clrDim
            if ($null -ne $script:EdTx) {
                $script:EdSuppressEvents = $true
                try {
                    $script:EdTx.SuspendLayout()
                    $sp = $script:EdTx.SelectionStart
                    $sl = $script:EdTx.SelectionLength

                    $script:EdTx.SelectAll()
                    $script:EdTx.SelectionColor = $clrText
                    $script:EdTx.SelectionBackColor = $script:EdTx.BackColor

                    $script:EdTx.Select($sp, $sl)
                } finally {
                    $script:EdTx.ResumeLayout()
                    $script:EdSuppressEvents = $false
                }
            }
        }
    })

    # 6. Чтение содержимого файла
    try {
        $fs9 = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br9 = New-Object System.IO.BinaryReader($fs9)
        $script:EdRawBytes = $br9.ReadBytes([int]$fs9.Length)
        $br9.Close(); $fs9.Close()

        $det = Detect-Encoding $script:EdRawBytes
        $tx.Clear()
        $tx.Text = $det.Enc.GetString($script:EdRawBytes)

        if ($viewEncBox.Items.Contains($det.Name)) {
            $viewEncBox.SelectedItem = $det.Name
            $saveEncBox.SelectedItem = $det.Name
        } else {
            $viewEncBox.SelectedIndex = 0
            $saveEncBox.SelectedIndex = 0
        }
        $stEd.Text = "  $FilePath  [Original encoding: $($det.Name)]"

    } catch {
        $tx.Text = "Error reading file: $_"
    }

    $script:EdSuppressEvents = $false

    # Обработчик смены кодировки для просмотра
    $viewEncBox.Add_SelectedIndexChanged({
        param($sender, $e)
        if ($script:EdSuppressEvents -or $null -eq $script:EdRawBytes) { return }
        $selectedEnc = [string]$sender.SelectedItem
        if ([string]::IsNullOrEmpty($selectedEnc)) { return }

        $script:EdSuppressEvents = $true
        try {
            $encObj = Get-SafeEncoding -encName $selectedEnc
            $decodedText = $encObj.GetString($script:EdRawBytes)

            if ($null -ne $script:EdTx) {
                $script:EdTx.Clear()
                $script:EdTx.Text = $decodedText
                $script:EdTx.ForeColor = $clrText

                if ($script:EdHlOn) {
                    Apply-SyntaxHighlight $script:EdTx $script:EdFileExt
                }
            }

            if ($null -ne $script:EdStEd) {
                $script:EdStEd.Text = "  $script:EdFilePath  [View encoding: $selectedEnc]"
            }
        }
        finally {
            $script:EdSuppressEvents = $false
        }
    })

    # Обработчики закрытия и горячих клавиш
    $ed.Add_FormClosing({
        param($s, $ev)
        if ($script:EdModified) {
            $r = Ed-AskSave
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Ed-Save }
            elseif ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { $ev.Cancel = $true }
            else { $script:EdClosed = $true }
        }
        if (-not $ev.Cancel -and $script:EdTmpDirToCleanup -and (Test-Path -LiteralPath $script:EdTmpDirToCleanup)) {
            try {
                Start-Sleep -Milliseconds 100
                Remove-Item -LiteralPath $script:EdTmpDirToCleanup -Recurse -Force -ErrorAction Stop
            } catch {}
        }
    })

    $tx.Add_KeyDown({
        param($s, $ev)
        if ($ev.Control -and $ev.KeyCode -eq "S") { Ed-Save; $ev.SuppressKeyPress = $true }
        if ($ev.KeyCode -eq "Escape") { Ed-Close; $ev.SuppressKeyPress = $true }
    })

    $ed.Add_KeyDown({
        param($s, $ev)
        if ($ev.KeyCode -eq "F2" -and -not $ev.Control -and -not $ev.Alt) { Ed-Save; $ev.SuppressKeyPress = $true }
        if ($ev.KeyCode -eq "Escape") { Ed-Close; $ev.SuppressKeyPress = $true }
    })

    $ed.Add_Shown({
        $this.Activate()
        foreach($ctrl in $this.Controls){
            if($ctrl -is [System.Windows.Forms.RichTextBox]){
                $ctrl.Focus()
                break
            }
        }
    })

    $ed.Show($form)
    $ed.BringToFront()
    $ed.Activate()
}


# MAIN FORM
$form=New-Object System.Windows.Forms.Form;$form.Text="Quas ADB Commander v8.61"
$form.Size="1060,860";$form.MinimumSize="720,620";$form.BackColor=$bgForm
$form.KeyPreview=$true;$form.StartPosition="CenterScreen";$form.FormBorderStyle="Sizable"
$form.GetType().GetProperty("DoubleBuffered",[System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($form,$true,$null)

$lblPC=New-Object System.Windows.Forms.Label;$lblPC.Location="15,8";$lblPC.Size="440,20";$lblPC.ForeColor=$clrGold;$lblPC.Font=$fntPath;$form.Controls.Add($lblPC)
$lblPCn=New-Object System.Windows.Forms.Label;$lblPCn.Text="PC";$lblPCn.Size="40,20";$lblPCn.ForeColor=$clrLabel;$lblPCn.Font=$fntHdr;$lblPCn.TextAlign="MiddleRight";$form.Controls.Add($lblPCn)
$lblADB=New-Object System.Windows.Forms.Label;$lblADB.Location="545,8";$lblADB.Size="440,20";$lblADB.ForeColor=$clrGold;$lblADB.Font=$fntPath;$form.Controls.Add($lblADB)
$lblADBn=New-Object System.Windows.Forms.Label;$lblADBn.Text="Android";$lblADBn.Size="62,20";$lblADBn.ForeColor=$clrLabel;$lblADBn.Font=$fntHdr;$lblADBn.TextAlign="MiddleRight";$form.Controls.Add($lblADBn)

function New-Panel-LV{param([int]$x)
    $lv=New-Object NoHScrollListView
    $lv.Location=New-Object System.Drawing.Point($x,56);$lv.Size=New-Object System.Drawing.Size(490,460)
    $lv.View="Details";$lv.FullRowSelect=$true;$lv.GridLines=$false
    $lv.BorderStyle="None";$lv.BackColor=$bgInact;$lv.ForeColor=$clrText
    $lv.Font=$fntItem;$lv.MultiSelect=$false;$lv.OwnerDraw=$true;$lv.HeaderStyle="None"
    $il=New-Object System.Windows.Forms.ImageList;$il.ImageSize=New-Object System.Drawing.Size(1,$ROW_H);$lv.SmallImageList=$il
    $lv.Columns.Add("Name",260)|Out-Null;$lv.Columns.Add("Size",80)|Out-Null;$lv.Columns.Add("Date",130)|Out-Null
    $lv.Add_DrawItem({param($s,$e)
        if($e.Index -lt 0){return}
        $it=$e.Item;$isFoc=($form.ActiveControl -eq $s);$isSel=$it.Selected
        $isCtx=($script:CtxLVRef -eq $s -and $script:CtxItem -eq $it)
        $bg=if($isSel){if($isFoc){$curAct}else{$curInact}}elseif($isCtx){$ctxHiClr}else{$s.BackColor}
        $br=New-Object System.Drawing.SolidBrush($bg);$e.Graphics.FillRectangle($br,$e.Bounds);$br.Dispose()})
    $lv.Add_DrawSubItem({param($s,$e)
        $it=$e.Item;$isFoc=($form.ActiveControl -eq $s);$isSel=$it.Selected
        $isCtx=($script:CtxLVRef -eq $s -and $script:CtxItem -eq $it)
        $ti=Get-ItemTag $it
        $isMarked=($ti.Path -ne "__GOUP__" -and $ti.Path -ne "" -and $global:SelectedPaths.Contains($ti.Path))
        $bg=if($isSel){if($isFoc){$curAct}else{$curInact}}elseif($isCtx){$ctxHiClr}else{$s.BackColor}
        $brBg=New-Object System.Drawing.SolidBrush($bg);$e.Graphics.FillRectangle($brBg,$e.Bounds);$brBg.Dispose()
        if($e.ColumnIndex -eq 0){$fc=if($isMarked){$markClr}elseif($it.Tag -eq "__GOUP__" -or $it.Tag -eq "__ARCHCLOSE__"){$clrDim}elseif($isSel){[System.Drawing.Color]::FromArgb(235,233,227)}else{Get-FileColor $it.Text $ti.IsDir}}
        else{$fc=if($isSel){[System.Drawing.Color]::FromArgb(175,173,167)}else{$clrDim}}
        $brT=New-Object System.Drawing.SolidBrush($fc)
        $r2=New-Object System.Drawing.RectangleF([float]($e.Bounds.X+4),[float]$e.Bounds.Y,[float]($e.Bounds.Width-6),[float]$e.Bounds.Height)
        $e.Graphics.DrawString($e.SubItem.Text,$fntItem,$brT,$r2,$sfVC);$brT.Dispose()})
    $lv.Add_DrawColumnHeader({param($s,$e)
        $br=New-Object System.Drawing.SolidBrush($bgHdr);$e.Graphics.FillRectangle($br,$e.Bounds);$br.Dispose()})
    $lv.Add_DoubleClick({&$navAction});return $lv}
$lvPC=New-Panel-LV 15;$lvADB=New-Panel-LV 545
$form.Controls.AddRange(@($lvPC,$lvADB))

function New-Hdr{param([int]$x,[string]$side)
    $ph=New-Object System.Windows.Forms.Panel;$ph.Location=New-Object System.Drawing.Point($x,32)
    $ph.Size=New-Object System.Drawing.Size(490,24);$ph.BackColor=$bgHdr
    $mkHB={param([string]$col,[int]$bx,[int]$bw)
        $b=New-Object System.Windows.Forms.Button;$b.Location=New-Object System.Drawing.Point($bx,0);$b.Size=New-Object System.Drawing.Size($bw,24)
        $b.Text=$col;$b.FlatStyle="Flat";$b.Font=$fntHdr;$b.TextAlign="MiddleLeft"
        $b.Padding=New-Object System.Windows.Forms.Padding(4,0,0,0);$b.TabStop=$false
        $b.ForeColor=[System.Drawing.Color]::FromArgb(168,166,155);$b.BackColor=$bgHdr
        $b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(52,52,60)
        $b.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(48,48,58)
        $sc=$col;$sd=$side
        $b.Add_Click([scriptblock]::Create(@"
            if ('$sd' -eq 'PC') {
                if (`$global:SortPC  -eq '$sc') { `$global:SortPCAsc  = -not `$global:SortPCAsc  }
                else { `$global:SortPC  = '$sc'; `$global:SortPCAsc  = `$true }
                Refresh-Panel 'PC'
            } else {
                if (`$global:SortADB -eq '$sc') { `$global:SortADBAsc = -not `$global:SortADBAsc }
                else { `$global:SortADB = '$sc'; `$global:SortADBAsc = `$true }
                Refresh-Panel 'ADB'
            }
"@))
        $ph.Controls.Add($b);return $b}
    &$mkHB "Name" 0 260|Out-Null;&$mkHB "Size" 260 80|Out-Null;&$mkHB "Date" 340 130|Out-Null
    return $ph}
$hdrPC=New-Hdr 15 "PC";$hdrADB=New-Hdr 545 "ADB"
$form.Controls.AddRange(@($hdrPC,$hdrADB))

$stBar=New-Object System.Windows.Forms.Label;$stBar.Location="15,528";$stBar.Size="1020,20";$stBar.ForeColor=$clrDim;$stBar.TextAlign="MiddleLeft";$form.Controls.Add($stBar)

$logBox=New-Object System.Windows.Forms.ListBox
$logBox.Location="15,550"
$logBox.Size="1020,78"
$logBox.BackColor=[System.Drawing.Color]::FromArgb(18,18,22)
$logBox.ForeColor=$clrDim

#$logBox.Font=New-Object System.Drawing.Font("Consolas",8.5);$logBox.BorderStyle="None";$logBox.TabStop=$false;$logBox.SelectionMode="MultiExtended";$logBox.HideSelection=$false
$logBox.Font=New-Object System.Drawing.Font("Consolas",8.5);$logBox.BorderStyle="None";$logBox.TabStop=$false;$logBox.SelectionMode="MultiExtended"
$form.Controls.Add($logBox)

$logBox.Add_MouseDown({
    $script:LogPaused=$true
})

$logBox.Add_KeyDown({
    param($s,$e)

    if($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A){
        for($i=0;$i -lt $logBox.Items.Count;$i++){
            $logBox.SetSelected($i,$true)
        }
        $e.SuppressKeyPress=$true
    }
    elseif($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C){
        if($logBox.SelectedItems.Count -gt 0){
            try{
                $txt=($logBox.SelectedItems | ForEach-Object {[string]$_}) -join [Environment]::NewLine
                [System.Windows.Forms.Clipboard]::SetText($txt)
            }catch{}
        }
        $e.SuppressKeyPress=$true
    }
})

$logCtx=New-Object System.Windows.Forms.ContextMenuStrip
$logCtx.ShowImageMargin=$false

$miLC=New-Object System.Windows.Forms.ToolStripMenuItem("Copy line")
$miLC.Add_Click({
    if($logBox.SelectedItem){
        try{
            [System.Windows.Forms.Clipboard]::SetText($logBox.SelectedItem.ToString())
        }catch{}
    }
})

$miLA=New-Object System.Windows.Forms.ToolStripMenuItem("Select all")
$miLA.Add_Click({
    for($i=0;$i -lt $logBox.Items.Count;$i++){
        $logBox.SetSelected($i,$true)
    }
})

$miLCA=New-Object System.Windows.Forms.ToolStripMenuItem("Copy all")
$miLCA.Add_Click({
    if($logBox.Items.Count -gt 0){
        try{
            $txt=($logBox.Items | ForEach-Object {[string]$_}) -join [Environment]::NewLine
            [System.Windows.Forms.Clipboard]::SetText($txt)
        }catch{}
    }
})

$miLS=New-Object System.Windows.Forms.ToolStripMenuItem("Scroll to bottom")
$miLS.Add_Click({
    $script:LogPaused=$false
    if($logBox.Items.Count -gt 0){
        $logBox.TopIndex=$logBox.Items.Count-1
    }
})

$miLX=New-Object System.Windows.Forms.ToolStripMenuItem("Clear log")
$miLX.Add_Click({
    $logBox.Items.Clear()
})

$logCtx.Items.AddRange(@(
    $miLC,
    $miLA,
    $miLCA,
    $miLS,
    $miLX
))

$logBox.ContextMenuStrip=$logCtx



$prBg=New-Object System.Windows.Forms.Panel;$prBg.Location="15,632";$prBg.Size="1020,14";$prBg.BackColor=[System.Drawing.Color]::FromArgb(20,20,24);$prBg.Visible=$false
$prFl=New-Object System.Windows.Forms.Panel;$prFl.Location="0,0";$prFl.Size="0,14";$prFl.BackColor=[System.Drawing.Color]::FromArgb(42,118,198)
$prBg.Controls.Add($prFl);$form.Controls.Add($prBg)
function Anim-Bar{param([int]$p,[int]$d)
    $bw=[int]($prBg.Width*0.18);$np=[int]($p+$d*22)
    if(([int]$np+[int]$bw) -ge [int]$prBg.Width){$np=[int]($prBg.Width-$bw);$d=-1}
    if($np -le 0){$np=0;$d=1}
    $prFl.Width=[int]$bw;$prFl.Location=New-Object System.Drawing.Point([int]$np,0)
    return @([int]$np,[int]$d)}

$mkBtn={param([string]$t2,[int]$x2,[int]$y2,[int]$w2=95)
    $b=New-Object System.Windows.Forms.Button;$b.Text=$t2
    $b.Location=New-Object System.Drawing.Point($x2,$y2);$b.Size=New-Object System.Drawing.Size($w2,30)
    $b.FlatStyle="Flat";$b.ForeColor=$clrText;$b.TabStop=$false
    $b.BackColor=[System.Drawing.Color]::FromArgb(48,48,56);$b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)
    $form.Controls.Add($b);return $b}
$bY=654
$btnF2=&$mkBtn "F2 Rename" 15 $bY;$btnF2.Add_Click({Rename-Action})
$btnF3=&$mkBtn "F3 Search" 118 $bY;$btnF3.Add_Click({Search-Action})
$btnF4=&$mkBtn "F4 Edit" 221 $bY;$btnF4.Add_Click({Edit-Action})
$btnF5=&$mkBtn "F5 Copy" 324 $bY;$btnF5.Add_Click({Copy-Action})
$btnF6=&$mkBtn "F6 Move" 427 $bY;$btnF6.Add_Click({Move-Action})
$btnF7=&$mkBtn "F7 MkDir" 545 $bY;$btnF7.Add_Click({NewDir-Action})
$btnF8=&$mkBtn "F8 Delete" 648 $bY;$btnF8.ForeColor=[System.Drawing.Color]::FromArgb(220,100,90);$btnF8.Add_Click({Delete-Action})
$btnDt=&$mkBtn "F9 Data" 751 $bY;$btnDt.Add_Click({Go-Data})
$btnOb=&$mkBtn "F10 Obb" 854 $bY;$btnOb.Add_Click({Go-Obb})
$btnHp=&$mkBtn "?" 955 $bY 60;$btnHp.ForeColor=$clrGold;$btnHp.Add_Click({Show-Help})

function Do-Resize{
    $W=[int]$form.ClientSize.Width;$H=[int]$form.ClientSize.Height
    $half=[int](($W-30)/2);$lvH=[int]($H-300);if($lvH -lt 80){$lvH=80}
    $aX=[int]($half+20);$szW=80;$dtW=130;$nW=[int]($half-$szW-$dtW);if($nW -lt 80){$nW=80};$dtW=[int]($half-$nW-$szW)
    $lvPC.SetBounds(15,56,$half,$lvH);$hdrPC.SetBounds(15,32,$half,24)
    $hdrPC.Controls[0].SetBounds(0,0,$nW,24);$hdrPC.Controls[1].SetBounds($nW,0,$szW,24);$hdrPC.Controls[2].SetBounds([int]($nW+$szW),0,$dtW,24)
    $lvPC.Columns[0].Width=$nW;$lvPC.Columns[1].Width=$szW;$lvPC.Columns[2].Width=$dtW
    $lblPC.Width=[int]($half-48);$lblPCn.Location=New-Object System.Drawing.Point([int]($half-32),8)
    $lvADB.SetBounds($aX,56,$half,$lvH);$hdrADB.SetBounds($aX,32,$half,24)
    $hdrADB.Controls[0].SetBounds(0,0,$nW,24);$hdrADB.Controls[1].SetBounds($nW,0,$szW,24);$hdrADB.Controls[2].SetBounds([int]($nW+$szW),0,$dtW,24)
    $lvADB.Columns[0].Width=$nW;$lvADB.Columns[1].Width=$szW;$lvADB.Columns[2].Width=$dtW
    $lblADB.SetBounds($aX,8,[int]($half-68),20);$lblADBn.Location=New-Object System.Drawing.Point([int]($W-68),8)
    $stY=[int]($lvH+68);$stBar.SetBounds(15,$stY,[int]($W-30),20);$logBox.SetBounds(15,[int]($stY+22),[int]($W-30),78)
    $prBg.SetBounds(15,[int]($stY+102),[int]($W-30),14)
    $bY2=[int]($stY+120)
    $btnF2.SetBounds(15,$bY2,95,30);$btnF3.SetBounds(118,$bY2,95,30);$btnF4.SetBounds(221,$bY2,95,30)
    $btnF5.SetBounds(324,$bY2,95,30);$btnF6.SetBounds(427,$bY2,95,30);$btnF7.SetBounds(545,$bY2,95,30)
    $btnF8.SetBounds(648,$bY2,95,30);$btnDt.SetBounds(751,$bY2,95,30);$btnOb.SetBounds(854,$bY2,95,30)
    $btnHp.SetBounds([int]($W-75),$bY2,60,30)}
$form.Add_Resize({Do-Resize})

function New-AdbProcess{param([string]$args2)
    $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$envAdb;$psi.Arguments=$args2
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.StandardOutputEncoding=[System.Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[System.Text.Encoding]::UTF8
    $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi;return $proc}
function Invoke-Push{param([string]$LP,[string]$RP,[string]$Lbl,[long]$Sz)
    $adbArgs="push `"$LP`" `"$RP`""
    $proc=New-AdbProcess $adbArgs;[void]$proc.Start()
    $tO=$proc.StandardOutput.ReadToEndAsync();$tE=$proc.StandardError.ReadToEndAsync()
    $prBg.Visible=$true;$prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew();$p=0;$d=1
    while(-not $proc.HasExited){
        $szS=if($Sz -gt 0){"  $(Format-Bytes $Sz)"}else{""}
        Set-Status "PUSHING: $Lbl$szS  [$([int]$sw.Elapsed.TotalSeconds)s]"
        $r=Anim-Bar $p $d;$p=[int]$r[0];$d=[int]$r[1]
        [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 80}
    $out=$tO.Result+$tE.Result;$sp="";$ti=""
    if($out -match "([\d.]+)\s*MB/s"){$sp="  @ $($Matches[1]) MB/s"}
    if($out -match "in\s+([\d.]+)s"){$ti="  in $($Matches[1])s"}
    $prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=[int]$prBg.Width
    Add-Log "DONE push: $Lbl$ti$sp" "Green";$form.Update();Start-Sleep -Milliseconds 300;$prBg.Visible=$false;$prFl.Width=0}
function Invoke-Pull{param([string]$RP,[string]$LDir,[string]$Lbl,[long]$Sz)
    $adbArgs="pull `"$RP`" `"$LDir`""
    $proc=New-AdbProcess $adbArgs;[void]$proc.Start()
    $tO=$proc.StandardOutput.ReadToEndAsync();$tE=$proc.StandardError.ReadToEndAsync()
    $prBg.Visible=$true;$prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew();$df=Join-Path $LDir $Lbl
    while(-not $proc.HasExited){
        $wr=0L;try{if(Test-Path $df){$wr=(Get-Item $df -ErrorAction Stop).Length}}catch{}
        if($Sz -gt 0 -and $wr -gt 0){
            $pct=[int]([Math]::Min(99,$wr*100/$Sz));$spd=if($sw.Elapsed.TotalSeconds -gt 0.5){[long]($wr/$sw.Elapsed.TotalSeconds)}else{0L}
            $sS=if($spd -gt 0){"  @ $(Format-Bytes $spd)/s"}else{""}
            $prFl.Width=[int]($prBg.Width*$pct/100);Set-Status "PULLING: $Lbl  [$pct%  $(Format-Bytes $wr) / $(Format-Bytes $Sz)$sS]"
        }else{Set-Status "PULLING: $Lbl..."}
        [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 300}
    $out=$tO.Result+$tE.Result;$sp="";$ti=""
    if($out -match "([\d.]+)\s*MB/s"){$sp="  @ $($Matches[1]) MB/s"}
    if($out -match "in\s+([\d.]+)s"){$ti="  in $($Matches[1])s"}
    $prFl.Width=[int]$prBg.Width;Add-Log "DONE pull: $Lbl$ti$sp" "Green";$form.Update();Start-Sleep -Milliseconds 300;$prBg.Visible=$false;$prFl.Width=0}
function Install-APK{param([string]$apkPath)
    $apkN=Split-Path $apkPath -Leaf;$pkg=$null
    if(Test-Path $envAapt2){Set-Status "Reading package info..." "Blue";$pkg=Get-AaptPkg $apkPath}
    $obbDir=$null
    if($pkg){$cand=Join-Path(Split-Path $apkPath -Parent) $pkg;if(Test-Path $cand -PathType Container){$obbDir=$cand}}
    # Custom APK confirm dialog with colored labels
    $apkD=New-Object System.Windows.Forms.Form
    $apkD.Text="Install APK";$apkD.Size="480,230";$apkD.BackColor=$bgForm;$apkD.ForeColor=$clrText
    $apkD.FormBorderStyle="FixedDialog";$apkD.StartPosition="CenterParent";$apkD.KeyPreview=$true
    $apkRtb=New-Object System.Windows.Forms.RichTextBox
    $apkRtb.Location="20,15";$apkRtb.Size="430,130"
    $apkRtb.BackColor=$bgForm;$apkRtb.ForeColor=$clrText;$apkRtb.BorderStyle="None";$apkRtb.ReadOnly=$true
    $apkRtb.Font=New-Object System.Drawing.Font("Segoe UI",10)
    $apkRtb.SelectionColor=$clrText;$apkRtb.AppendText("Install APK on device?`r`n`r`n")
    $apkRtb.SelectionColor=$clrDim;$apkRtb.AppendText("  File:     ")
    $apkRtb.SelectionColor=$markClr;$apkRtb.AppendText("$apkN`r`n")
    $apkRtb.SelectionColor=$clrDim;$apkRtb.AppendText("  Package:  ")
    if($pkg){$apkRtb.SelectionColor=$markClr;$apkRtb.AppendText("$pkg`r`n")}
    else{$apkRtb.SelectionColor=[System.Drawing.Color]::FromArgb(120,118,112);$apkRtb.AppendText("(aapt2 not found)`r`n")}
    if($obbDir){
        $apkRtb.SelectionColor=$clrDim;$apkRtb.AppendText("  OBB:      ")
        $apkRtb.SelectionColor=[System.Drawing.Color]::FromArgb(100,200,100);$apkRtb.AppendText("found, will be copied`r`n")}
    $apkD.Controls.Add($apkRtb)
    $apkOk=New-Object System.Windows.Forms.Button;$apkOk.Text="OK";$apkOk.Size="90,30";$apkOk.FlatStyle="Flat"
    $apkCn=New-Object System.Windows.Forms.Button;$apkCn.Text="Cancel";$apkCn.Size="90,30";$apkCn.FlatStyle="Flat"
    foreach($bx in @($apkOk,$apkCn)){$bx.ForeColor=$clrText;$bx.BackColor=[System.Drawing.Color]::FromArgb(52,52,60);$bx.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)}
    $apkOk.Location=New-Object System.Drawing.Point(130,162);$apkCn.Location=New-Object System.Drawing.Point(240,162)
    $apkOk.DialogResult="OK";$apkCn.DialogResult="Cancel"
    $apkD.Controls.AddRange(@($apkOk,$apkCn));$apkD.AcceptButton=$apkOk;$apkD.CancelButton=$apkCn
    $apkD.Add_Shown({$apkOk.Focus()})
    if($apkD.ShowDialog() -ne "OK"){return}
    $prBg.Visible=$true;$prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew();$p=0;$d=1
    $adbArgs="install -r -g `"$apkPath`""
    $proc=New-AdbProcess $adbArgs;[void]$proc.Start()
    $tO=$proc.StandardOutput.ReadToEndAsync();$tE=$proc.StandardError.ReadToEndAsync()
    while(-not $proc.HasExited){Set-Status "INSTALLING: $apkN  [$([int]$sw.Elapsed.TotalSeconds)s]";$r=Anim-Bar $p $d;$p=[int]$r[0];$d=[int]$r[1];[System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 80}
    $out=($tO.Result+$tE.Result) -replace "
","" -replace "
"," "
    $prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0;$prBg.Visible=$false
    if($out -match "Success"){Add-Log "INSTALLED: $apkN  [$([int]$sw.Elapsed.TotalSeconds)s]" "Green"}
    else{$err=$out;if($out -match "(INSTALL_\w+)"){$err=$Matches[1]};Add-Log "INSTALL FAILED: $err" "Red";return}
    if($obbDir){$base="/storage/emulated/0/Android/obb";& "$envAdb" shell "mkdir -p '$base/$pkg'" 2>&1 | Out-Null
        $fs=Get-ChildItem $obbDir -File;$ix=0
        foreach($f in $fs){$ix++;Set-Status "OBB ($ix/$($fs.Count)): $($f.Name)...";Invoke-Push $f.FullName "$base/$pkg/$($f.Name)" $f.Name $f.Length}
        Add-Log "DONE: APK+OBB ($($fs.Count) files)" "Green"}
    Refresh-Panel "ADB"}

function Install-XAPK{param([string]$xapkPath)
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){Add-Log "7z.exe not found" "Red";return}
    $xapkN=Split-Path $xapkPath -Leaf
    $tmpX=New-TmpDir
    try{
        Set-Status "Extracting XAPK..." "Blue"
        $psiX=New-Object System.Diagnostics.ProcessStartInfo
        $psiX.FileName=$env7z;$psiX.Arguments="x `"$xapkPath`" -o`"$tmpX`" -aoa -y"
        $psiX.UseShellExecute=$false;$psiX.CreateNoWindow=$true
        $psiX.RedirectStandardOutput=$true;$psiX.RedirectStandardError=$true
        $procX=New-Object System.Diagnostics.Process;$procX.StartInfo=$psiX
        [void]$procX.Start();$procX.WaitForExit()
        # Find all APK files inside
        $allApks=@(Get-ChildItem -LiteralPath $tmpX -Filter "*.apk" -Recurse|Sort-Object {
            # base.apk first
            if($_.Name -eq "base.apk"){0}else{1}})
        if($allApks.Count -eq 0){Add-Log "XAPK: no APK files found inside" "Red";return}
        $baseApk=$allApks[0]
        $pkg2=$null
        if(Test-Path $envAapt2 -ErrorAction SilentlyContinue){$pkg2=Get-AaptPkg $baseApk.FullName}
        $obbFiles=@(Get-ChildItem -LiteralPath $tmpX -Filter "*.obb" -Recurse)
        $isSplit=($allApks.Count -gt 1)
        # Confirm dialog
        $apkD2=New-Object System.Windows.Forms.Form
        $apkD2.Text="Install XAPK";$apkD2.Size="480,220";$apkD2.BackColor=$bgForm;$apkD2.ForeColor=$clrText
        $apkD2.FormBorderStyle="FixedDialog";$apkD2.StartPosition="CenterParent"
        $apkRtb2=New-Object System.Windows.Forms.RichTextBox
        $apkRtb2.Location="20,15";$apkRtb2.Size="430,120"
        $apkRtb2.BackColor=$bgForm;$apkRtb2.ForeColor=$clrText;$apkRtb2.BorderStyle="None";$apkRtb2.ReadOnly=$true
        $apkRtb2.Font=New-Object System.Drawing.Font("Segoe UI",10)
        $apkRtb2.SelectionColor=$clrText;$apkRtb2.AppendText("Install XAPK on device?`r`n`r`n")
        $apkRtb2.SelectionColor=$clrDim;$apkRtb2.AppendText("  File:     ")
        $apkRtb2.SelectionColor=$markClr;$apkRtb2.AppendText("$xapkN`r`n")
        if($pkg2){$apkRtb2.SelectionColor=$clrDim;$apkRtb2.AppendText("  Package:  ");$apkRtb2.SelectionColor=$markClr;$apkRtb2.AppendText("$pkg2`r`n")}
        if($isSplit){$apkRtb2.SelectionColor=$clrDim;$apkRtb2.AppendText("  Type:     ");$apkRtb2.SelectionColor=[System.Drawing.Color]::FromArgb(100,200,100);$apkRtb2.AppendText("Split APKs ($($allApks.Count) parts)`r`n")}
        elseif($obbFiles.Count -gt 0){$apkRtb2.SelectionColor=$clrDim;$apkRtb2.AppendText("  OBB:      ");$apkRtb2.SelectionColor=[System.Drawing.Color]::FromArgb(100,200,100);$apkRtb2.AppendText("$($obbFiles.Count) file(s) will be copied`r`n")}
        $apkD2.Controls.Add($apkRtb2)
        $apkOk2=New-Object System.Windows.Forms.Button;$apkOk2.Text="OK";$apkOk2.Size="90,30";$apkOk2.FlatStyle="Flat"
        $apkCn2=New-Object System.Windows.Forms.Button;$apkCn2.Text="Cancel";$apkCn2.Size="90,30";$apkCn2.FlatStyle="Flat"
        foreach($bx2 in @($apkOk2,$apkCn2)){$bx2.ForeColor=$clrText;$bx2.BackColor=[System.Drawing.Color]::FromArgb(52,52,60);$bx2.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)}
        $apkOk2.DialogResult="OK";$apkCn2.DialogResult="Cancel"
        $apkOk2.Location=New-Object System.Drawing.Point(130,158);$apkCn2.Location=New-Object System.Drawing.Point(240,158)
        $apkD2.Controls.AddRange(@($apkOk2,$apkCn2));$apkD2.AcceptButton=$apkOk2;$apkD2.CancelButton=$apkCn2
        $apkD2.Add_Shown({$apkOk2.Focus()})
        if($apkD2.ShowDialog() -ne "OK"){return}
        # Install
        $sw2=[System.Diagnostics.Stopwatch]::StartNew()
        if($isSplit){
            # Split XAPK: use install-multiple with all APK parts
            $allApkPaths=($allApks|ForEach-Object{"`"$($_.FullName)`""}) -join " "
            $adbArgsX2="install-multiple -r -g $allApkPaths"
            $procI=New-AdbProcess $adbArgsX2;[void]$procI.Start()
            $tOX=$procI.StandardOutput.ReadToEndAsync();$tEX=$procI.StandardError.ReadToEndAsync()
            while(-not $procI.HasExited){Set-Status "Installing XAPK (split)... [$([int]$sw2.Elapsed.TotalSeconds)s]";[System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100} "Blue"
            $outX=($tOX.Result+$tEX.Result).Trim()
        }else{
            # OBB XAPK: install base.apk only
            $adbArgsX="install -r -g `"$($baseApk.FullName)`""
            $procI=New-AdbProcess $adbArgsX;[void]$procI.Start()
            $tOX=$procI.StandardOutput.ReadToEndAsync();$tEX=$procI.StandardError.ReadToEndAsync()
            while(-not $procI.HasExited){Set-Status "Installing XAPK... [$([int]$sw2.Elapsed.TotalSeconds)s]";[System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100} "Blue"
            $outX=($tOX.Result+$tEX.Result).Trim()
        }
        if($outX -match "Success"){
            Add-Log "INSTALLED XAPK: $xapkN  [$([int]$sw2.Elapsed.TotalSeconds)s]" "Green"
            # Copy OBB files if present
            if($obbFiles.Count -gt 0 -and $pkg2){
                $obbBase="/storage/emulated/0/Android/obb/$pkg2"
                & "$envAdb" shell "mkdir -p $(Escape-AdbShell $obbBase)" 2>&1|Out-Null
                $oix=0
                foreach($of in $obbFiles){
                    $oix++;Set-Status "OBB ($oix/$($obbFiles.Count)): $($of.Name)" "Blue"
                    Invoke-Push $of.FullName "$obbBase/$($of.Name)" $of.Name $of.Length}
                Add-Log "OBB copied: $($obbFiles.Count) file(s)" "Green"}
        }else{Add-Log "XAPK INSTALL FAILED: $outX" "Red"}
    }finally{Remove-Item -LiteralPath $tmpX -Recurse -Force -ErrorAction SilentlyContinue}
    Refresh-Panel "ADB"}

function Install-APKS{param([string]$apksPath)
    # APKS = ZIP with multiple split APKs (from bundletool/SAI)
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){
        Add-Log "7z.exe not found - cannot install APKS" "Red";return}
    $apksN=Split-Path $apksPath -Leaf
    $tmpA=New-TmpDir
    try{
        Set-Status "Extracting APKS..." "Blue"
        $psiA=New-Object System.Diagnostics.ProcessStartInfo
        $psiA.FileName=$env7z;$psiA.Arguments="x `"$apksPath`" -o`"$tmpA`" -aoa -y *.apk"
        $psiA.UseShellExecute=$false;$psiA.CreateNoWindow=$true
        $psiA.RedirectStandardOutput=$true;$psiA.RedirectStandardError=$true
        $procA=New-Object System.Diagnostics.Process;$procA.StartInfo=$psiA
        [void]$procA.Start();$procA.WaitForExit()
        $apkFiles=@(Get-ChildItem -LiteralPath $tmpA -Filter "*.apk" -Recurse)
        if($apkFiles.Count -eq 0){Add-Log "APKS: no APK files found inside" "Red";return}
        # Confirm dialog
        $apkD3=New-Object System.Windows.Forms.Form
        $apkD3.Text="Install APKS";$apkD3.Size="480,200";$apkD3.BackColor=$bgForm;$apkD3.ForeColor=$clrText
        $apkD3.FormBorderStyle="FixedDialog";$apkD3.StartPosition="CenterParent"
        $apkRtb3=New-Object System.Windows.Forms.RichTextBox
        $apkRtb3.Location="20,15";$apkRtb3.Size="430,100"
        $apkRtb3.BackColor=$bgForm;$apkRtb3.ForeColor=$clrText;$apkRtb3.BorderStyle="None";$apkRtb3.ReadOnly=$true
        $apkRtb3.Font=New-Object System.Drawing.Font("Segoe UI",10)
        $apkRtb3.SelectionColor=$clrText;$apkRtb3.AppendText("Install split APKs on device?`r`n`r`n")
        $apkRtb3.SelectionColor=$clrDim;$apkRtb3.AppendText("  File:     ")
        $apkRtb3.SelectionColor=$markClr;$apkRtb3.AppendText("$apksN`r`n")
        $apkRtb3.SelectionColor=$clrDim;$apkRtb3.AppendText("  Splits:   ")
        $apkRtb3.SelectionColor=$markClr;$apkRtb3.AppendText("$($apkFiles.Count) APK file(s)`r`n")
        $apkD3.Controls.Add($apkRtb3)
        $apkOk3=New-Object System.Windows.Forms.Button;$apkOk3.Text="OK";$apkOk3.Size="90,30";$apkOk3.FlatStyle="Flat"
        $apkCn3=New-Object System.Windows.Forms.Button;$apkCn3.Text="Cancel";$apkCn3.Size="90,30";$apkCn3.FlatStyle="Flat"
        foreach($bx3 in @($apkOk3,$apkCn3)){$bx3.ForeColor=$clrText;$bx3.BackColor=[System.Drawing.Color]::FromArgb(52,52,60);$bx3.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)}
        $apkOk3.Location=New-Object System.Drawing.Point(130,135);$apkCn3.Location=New-Object System.Drawing.Point(240,135)
        $apkOk3.DialogResult="OK";$apkCn3.DialogResult="Cancel"
        $apkD3.Controls.AddRange(@($apkOk3,$apkCn3));$apkD3.AcceptButton=$apkOk3;$apkD3.CancelButton=$apkCn3
        $apkD3.Add_Shown({$apkOk3.Focus()})
        if($apkD3.ShowDialog() -ne "OK"){return}
        # Install all splits with install-multiple
        $allApkPaths=($apkFiles|ForEach-Object{"`"$($_.FullName)`""}) -join " "
        $adbArgsA="install-multiple -r -g $allApkPaths"
        $procM=New-AdbProcess $adbArgsA;[void]$procM.Start()
        $tOM=$procM.StandardOutput.ReadToEndAsync();$tEM=$procM.StandardError.ReadToEndAsync()
        $sw3=[System.Diagnostics.Stopwatch]::StartNew()
        while(-not $procM.HasExited){
            Set-Status "Installing APKS... [$([int]$sw3.Elapsed.TotalSeconds)s]" "Blue"
            [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
        $outA=($tOM.Result+$tEM.Result) -replace "`r`n"," "
        if($outA -match "Success"){Add-Log "INSTALLED APKS: $apksN  [$([int]$sw3.Elapsed.TotalSeconds)s]" "Green"}
        else{Add-Log "APKS INSTALL FAILED: $outA" "Red"}
    }finally{Remove-Item -LiteralPath $tmpA -Recurse -Force -ErrorAction SilentlyContinue}
    Refresh-Panel "ADB"}

function Open-File{param([string]$fp,[string]$act)
    $leaf=Split-Path $fp -Leaf;$dot=$leaf.LastIndexOf(".")
    $ext=if($dot -ge 0){$leaf.Substring($dot+1).ToLower()}else{""};$ft=Get-FileType $leaf
    switch($act){"run"{switch($ext){"ps1"{Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$fp`""}"bat"{Start-Process cmd -ArgumentList "/c `"$fp`""}"cmd"{Start-Process cmd -ArgumentList "/c `"$fp`""} default{Start-Process $fp}}}
        "edit"{if($ft -eq "text" -or $ext -in @("ps1","bat","cmd","sh","bash")){Show-TextEditor $fp $leaf}
               else{$r=Show-AdbDialog "Not a text file" "Open in editor anyway?" $null @($leaf);if($null -ne $r){Show-TextEditor $fp $leaf}}}
        "open"{Start-Process $fp}}}
function Edit-AdbFile{param([string]$rp,[string]$fn)
    $tmp=Join-Path $env:TEMP "adbfm_$fn";Set-Status "Pulling $fn..."
    & "$envAdb" pull "`"$rp`"" "`"$tmp`"" 2>&1 | Out-Null
    if(-not(Test-Path $tmp)){Add-Log "PULL FAILED: $fn" "Red";return}
    $ft=Get-FileType $fn;$dot=$fn.LastIndexOf(".")
    $ext=if($dot -ge 0){$fn.Substring($dot+1).ToLower()}else{""}
    if($ft -ne "text" -and $ext -notin @("ps1","bat","cmd","sh","bash")){$r=Show-AdbDialog "Not a text file" "Open anyway?" $null @($fn);if($null -eq $r){return}}
    Show-TextEditor $tmp "$fn [Android]" $true $rp
    Remove-Item $tmp -ErrorAction SilentlyContinue;Set-Status "READY" "Green"}
function Make-LVI{param([string]$disp,[string]$szDisp,[long]$szBytes,[string]$dt,[string]$fullPath,[bool]$isDir=$false)
    $li=New-Object System.Windows.Forms.ListViewItem($disp)
    $li.SubItems.Add($szDisp)|Out-Null;$li.SubItems.Add($dt)|Out-Null;$li.SubItems.Add([string]$szBytes)|Out-Null
    $li.Tag=if($isDir){"DIR:$fullPath"}else{"FILE:$fullPath"};return $li}
function Get-ItemTag{param($item)
    if($null -eq $item){return @{IsDir=$false;Path=""}}
    $t=[string]$item.Tag
    if($t -eq "__GOUP__"){return @{IsDir=$false;Path="__GOUP__"}}
    if($t -eq "__ARCHCLOSE__"){return @{IsDir=$false;Path="__ARCHCLOSE__"}}
    if($t.StartsWith("ARCH:")){return @{IsDir=$false;Path=$t}}  # keep ARCH: prefix for archive items
    if($t.StartsWith("DIR:")){return @{IsDir=$true;Path=$t.Substring(4)}}
    if($t.StartsWith("FILE:")){return @{IsDir=$false;Path=$t.Substring(5)}}
    return @{IsDir=$false;Path=$t}}
function Sort-LVI{param($arr,[string]$col,[bool]$asc)
    if($arr.Count -eq 0){return $arr}
    $s=switch($col){"Size"{$arr|Sort-Object{[long]$_.SubItems[3].Text}}"Date"{$arr|Sort-Object{$_.SubItems[2].Text}}default{$arr|Sort-Object{$_.Text}}}
    if(-not $asc){[array]::Reverse($s)};return $s}
function Refresh-Panel{param([string]$panel)
    if($panel -eq "PC"){
        $lv=$lvPC;$lv.BeginUpdate();$lv.Items.Clear();$lblPC.Text=$currentLocalPath
        $dirs=@();$files=@()
        if($currentLocalPath -eq "DRIVES"){[System.IO.DriveInfo]::GetDrives()|Where-Object{$_.IsReady}|ForEach-Object{$dirs+=Make-LVI $_.Name "<Dir>" 0 "" $_.Name $true}}
        else{
            $goUp=New-Object System.Windows.Forms.ListViewItem(".. [Go Up]")
            $goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("0")|Out-Null;$goUp.Tag="__GOUP__";$lv.Items.Add($goUp)|Out-Null
            Get-ChildItem -LiteralPath $currentLocalPath -ErrorAction SilentlyContinue|ForEach-Object{
                if($_.PSIsContainer){$dirs+=Make-LVI $_.Name "<Dir>" 0 ($_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")) (Join-Path $currentLocalPath $_.Name) $true}
                else{$sz=[long]$_.Length;$files+=Make-LVI $_.Name (Format-Bytes $sz) $sz ($_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")) (Join-Path $currentLocalPath $_.Name) $false}}}
        $dirs=Sort-LVI $dirs $global:SortPC $global:SortPCAsc;$files=Sort-LVI $files $global:SortPC $global:SortPCAsc
        foreach($li in $dirs){$lv.Items.Add($li)|Out-Null};foreach($li in $files){$lv.Items.Add($li)|Out-Null}
        if($lv.Items.Count -gt 0){$lv.Items[0].Selected=$true;$lv.Items[0].Focused=$true};$lv.EndUpdate()
    }else{
        $lv=$lvADB;$lv.BeginUpdate();$lv.Items.Clear();$lblADB.Text=$currentAdbPath
        if(-not $script:AdbAvailable){$lv.EndUpdate();return}
        $goUp=New-Object System.Windows.Forms.ListViewItem(".. [Go Up]")
        $goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("0")|Out-Null;$goUp.Tag="__GOUP__";$lv.Items.Add($goUp)|Out-Null
        $dirs=@();$files=@()
        $lsOut=& "$envAdb" shell ('ls -F '+(Escape-AdbShell $currentAdbPath)) 2>&1
        foreach($entry in $lsOut){
            $r=($entry -replace "`r","").Trim()
            if(-not $r){continue}
            if($r.StartsWith("* ") -or $r -match "^daemon |^adb "){continue}
            $isD=$r.EndsWith("/")
            $cn=$r -replace "[/*@=>|]$",""
            if(-not $cn){continue}
            $fullP="$($currentAdbPath.TrimEnd("/"))/$cn"
            if($isD){$dirs+=Make-LVI $cn "<Dir>" 0 "" $fullP $true}
            else{$files+=Make-LVI $cn "" 0 "" $fullP $false}
        }
        if($dirs.Count -gt 0 -or $files.Count -gt 0){
            $statOut=& "$envAdb" shell ("stat -c " + [char]39 + "%n|%s|%y" + [char]39 + " " + (Escape-AdbShell ($currentAdbPath.TrimEnd("/")+"/*"))) 2>&1 | Out-Null
            $statMap=@{}
            foreach($line in $statOut){$l=($line -replace "
","").Trim();if(-not $l){continue};if($l.StartsWith("* ") -or $l -match "^daemon |^adb "){continue}
                $p3=$l -split "\|",3;if($p3.Count -ge 3){
                    $fn2=Split-Path $p3[0].Trim() -Leaf;$sz2=0L;try{$sz2=[long]$p3[1].Trim()}catch{}
                    $dt2=$p3[2].Trim();if($dt2.Length -gt 16){$dt2=$dt2.Substring(0,16)};$statMap[$fn2]=@{Sz=$sz2;Dt=$dt2}}}
            foreach($li in $files){$fn2=$li.Text;if($statMap.ContainsKey($fn2)){$li.SubItems[1].Text=Format-Bytes $statMap[$fn2].Sz;$li.SubItems[3].Text=[string]$statMap[$fn2].Sz;$li.SubItems[2].Text=$statMap[$fn2].Dt}}
            foreach($li in $dirs){if($statMap.ContainsKey($li.Text)){$li.SubItems[2].Text=$statMap[$li.Text].Dt}}}
        $dirs=Sort-LVI $dirs $global:SortADB $global:SortADBAsc;$files=Sort-LVI $files $global:SortADB $global:SortADBAsc
        foreach($li in $dirs){$lv.Items.Add($li)|Out-Null};foreach($li in $files){$lv.Items.Add($li)|Out-Null}
        if($lv.Items.Count -gt 0){$lv.Items[0].Selected=$true;$lv.Items[0].Focused=$true};$lv.EndUpdate()}}
function Get-ALV{if($lvPC.Focused -or $lvPC.BackColor -eq $bgActive){return $lvPC};return $lvADB}
function Get-SelI{param($lv);if($lv.SelectedItems.Count -eq 0){return $null};return $lv.SelectedItems[0]}
function Get-SelItems{param($lv)
    $res=@()
    foreach($it in $lv.Items){$ti=Get-ItemTag $it;if($ti.Path -ne "__GOUP__" -and $ti.Path -ne "" -and $global:SelectedPaths.Contains($ti.Path)){$res+=$it}}
    if($res.Count -eq 0){$s=Get-SelI $lv;if($null -ne $s -and $s.Tag -ne "__GOUP__"){$res+=$s}}
    return $res}
function Find-Sel{param($lv,[string]$name)
    foreach($li in $lv.Items){if($li.Text -eq $name){$li.Selected=$true;$li.Focused=$true;$lv.EnsureVisible($li.Index);break}}}

# ARCHIVE SUPPORT
$extArch=@("zip","7z","rar","gz","tar","bz2","xz","cab","iso","tgz","tbz2","z01","z02","z03","z04","z05","001","002","003")

function Is-ArchiveFile{param([string]$n)
    $e="";$d=$n.LastIndexOf(".");if($d -ge 0){$e=$n.Substring($d+1).ToLower()}
    return $extArch -contains $e}

function List-Archive{param([string]$archPath,[string]$subDir="")
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){Add-Log "7z.exe not found: $env7z" "Red";return @()}
    $psi2=New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName=$env7z
    $psi2.Arguments="l `"$archPath`""
    $psi2.UseShellExecute=$false;$psi2.CreateNoWindow=$true
    $psi2.RedirectStandardOutput=$true;$psi2.RedirectStandardError=$true
    $psi2.StandardOutputEncoding=[System.Text.Encoding]::GetEncoding(866)
    $proc2=New-Object System.Diagnostics.Process;$proc2.StartInfo=$psi2;[void]$proc2.Start()
    $tO2=$proc2.StandardOutput.ReadToEndAsync()
    $proc2.WaitForExit()
    $out=[string]$tO2.Result
    $allLines=$out -split "`r?`n"
    $sepCount=0;$items=@()
    foreach($line in $allLines){
        if($line -match "^[-]{5,}"){$sepCount++;continue}
        if($sepCount -lt 1 -or $sepCount -ge 2){continue}
        if($line.Trim() -eq ""){continue}
        if($line.Length -lt 26){continue}
        $attr=$line.Substring(20,5).Trim()
        $isDir=$attr.Contains("D")
        $sz=0L
        if(-not $isDir -and $line.Length -gt 39){
            $szStr=$line.Substring(26,12).Trim()
            if($szStr -match "^[0-9]+$"){$sz=[long]$szStr}}
        $name=if($line.Length -gt 53){$line.Substring(53).Trim()}else{""}
        if($name -eq ""){continue}
        $name=$name -replace "\\","/"
        $items+=@{Name=$name;Size=$sz;IsDir=$isDir}}
    $prefix=if($subDir -ne "" -and -not $subDir.EndsWith("/")){$subDir+"/"}else{$subDir}
    $seen=@{};$result=@()
    foreach($it in $items){
        $n=$it.Name.TrimEnd("/")
        if($n -eq ""){continue}
        if($prefix -ne ""){
            if(-not $n.StartsWith($prefix)){continue}
            $n=$n.Substring($prefix.Length)
            if($n -eq ""){continue}}
        $slash=$n.IndexOf("/")
        if($slash -ge 0){
            $topName=$n.Substring(0,$slash)
            if($topName -eq "" -or $seen.ContainsKey($topName)){continue}
            $seen[$topName]=$true
            $innerPath=if($prefix -ne ""){$prefix+$topName}else{$topName}
            $result+=@{Name=$topName;InnerPath=$innerPath;Size=0L;IsDir=$true}
        }else{
            if($seen.ContainsKey($n)){continue}
            $seen[$n]=$true
            $innerPath=if($prefix -ne ""){$prefix+$n}else{$n}
            $result+=@{Name=$n;InnerPath=$innerPath;Size=$it.Size;IsDir=$it.IsDir}}}
    return $result}

function Get-ArchiveFirstPart{param([string]$path)
    # Returns the first-part path for multivolume archives, or $path if not multivolume
    $dir=Split-Path $path -Parent
    $name=Split-Path $path -Leaf
    # .7z.001 -> already first part
    if($name -match "\.7z\.001$"){return $path}
    # .7z.NNN (not 001) -> find .7z.001
    if($name -match "\.7z\.[0-9]{3}$"){
        $first=$path -replace "\.[0-9]{3}$",".001"
        if(Test-Path -LiteralPath $first){return $first}
        return $path}
    # .partN.rar -> find .part1.rar
    if($name -match "\.part([0-9]+)\.rar$"){
        $first=$path -replace "\.part[0-9]+\.rar$",".part1.rar"
        if(Test-Path -LiteralPath $first){return $first}
        return $path}
    # .zNN -> find the .zip
    if($name -match "\.z[0-9]+$"){
        $base=$path -replace "\.z[0-9]+$",".zip"
        if(Test-Path -LiteralPath $base){return $base}
        return $path}
    # .NNN (generic split) -> find .001
    if($name -match "^(.+)\.[0-9]{3}$"){
        $first=$path -replace "\.[0-9]{3}$",".001"
        if(Test-Path -LiteralPath $first){return $first}
        return $path}
    return $path}

function Is-MultipartNotFirst{param([string]$path)
    $name=Split-Path $path -Leaf
    if($name -match "\.7z\.([0-9]{3})$" -and $Matches[1] -ne "001"){return $true}
    if($name -match "\.part([0-9]+)\.rar$" -and [int]$Matches[1] -gt 1){return $true}
    if($name -match "\.z([0-9]+)$" -and [int]$Matches[1] -gt 1){return $true}
    if($name -match "\.([0-9]{3})$" -and $Matches[1] -ne "001"){return $true}
    return $false}

function Open-Archive{param([string]$archPath,[bool]$isPC=$true)
    $script:ArchivePath=$archPath;$script:ArchiveIsPC=$isPC
    $script:ArchiveName=Split-Path $archPath -Leaf
    $script:ArchiveSubDir=""
    Refresh-ArchPanel}

function Refresh-ArchPanel{
    $archPath=$script:ArchivePath
    $subDir=if($null -ne $script:ArchiveSubDir){$script:ArchiveSubDir}else{""}
    $lv=if($script:ArchiveIsPC){$lvPC}else{$lvADB}
    $lbl=if($script:ArchiveIsPC){$lblPC}else{$lblADB}
    $lv.BeginUpdate();$lv.Items.Clear()
    $subLabel=if($subDir -ne ""){"/$subDir"}else{""}
    $lbl.Text="[ARCH] $archPath$subLabel"
    $goUp=New-Object System.Windows.Forms.ListViewItem(".. [Close Archive]")
    $goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("0")|Out-Null
    $goUp.Tag="__ARCHCLOSE__";$lv.Items.Add($goUp)|Out-Null
    $items=List-Archive $archPath $subDir
    $dirs=@();$files=@()
    foreach($it in $items){
        $li=New-Object System.Windows.Forms.ListViewItem($it.Name)
        $szD=if($it.IsDir){"<Dir>"}else{Format-Bytes $it.Size}
        $li.SubItems.Add($szD)|Out-Null
        $li.SubItems.Add("")|Out-Null
        $li.SubItems.Add([string]$it.Size)|Out-Null
        $li.Tag="ARCH:$($it.InnerPath)"
        if($it.IsDir){$dirs+=$li}else{$files+=$li}}
    foreach($li in $dirs){$lv.Items.Add($li)|Out-Null}
    foreach($li in $files){$lv.Items.Add($li)|Out-Null}
    if($lv.Items.Count -gt 0){$lv.Items[0].Selected=$true;$lv.Items[0].Focused=$true}
    $lv.EndUpdate()}

function Show-ExtractDialog{param([string]$archName)
    $d=New-Object System.Windows.Forms.Form;$d.Text="Extract: $archName"
    $d.Size="560,330";$d.BackColor=$bgForm;$d.ForeColor=$clrText
    $d.FormBorderStyle="FixedDialog";$d.StartPosition="CenterParent";$d.KeyPreview=$true
    $d.GetType().GetProperty("DoubleBuffered",[System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($d,$true,$null)
    $lblPC2=New-Object System.Windows.Forms.Label;$lblPC2.Text="PC path:";$lblPC2.Location="20,18";$lblPC2.Size="60,20";$lblPC2.ForeColor=$clrDim;$d.Controls.Add($lblPC2)
    $txtPC=New-Object System.Windows.Forms.TextBox;$txtPC.Location="82,15";$txtPC.Size="380,24"
    $txtPC.BackColor=[System.Drawing.Color]::FromArgb(50,50,58);$txtPC.ForeColor=$clrText;$txtPC.BorderStyle="FixedSingle"
    $archBase=[System.IO.Path]::GetFileNameWithoutExtension($archName)
    $txtPC.Text=Join-Path $currentLocalPath $archBase;$d.Controls.Add($txtPC)
    $btnBrowse=New-Object System.Windows.Forms.Button;$btnBrowse.Text="...";$btnBrowse.Location="466,14";$btnBrowse.Size="54,26"
    $btnBrowse.FlatStyle="Flat";$btnBrowse.ForeColor=$clrText;$btnBrowse.BackColor=[System.Drawing.Color]::FromArgb(48,48,56)
    $btnBrowse.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)
    $btnBrowse.Add_Click({
        $fb=New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.SelectedPath=$txtPC.Text;$fb.Description="Select extraction folder"
        if($fb.ShowDialog() -eq "OK"){$txtPC.Text=$fb.SelectedPath}})
    $d.Controls.Add($btnBrowse)
    $btnPC=New-Object System.Windows.Forms.Button
    $btnPC.Text="Unpack to PC (path above)"
    $btnPC.Location="20,50";$btnPC.Size="500,36";$btnPC.FlatStyle="Flat"
    $btnPC.ForeColor=$clrText;$btnPC.BackColor=[System.Drawing.Color]::FromArgb(48,48,56)
    $btnPC.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80);$btnPC.TextAlign="MiddleCenter"
    $btnPC.Add_Click({$d.Tag=$txtPC.Text;$d.DialogResult="Yes";$d.Close()})
    $d.Controls.Add($btnPC)
    $lblADB2=New-Object System.Windows.Forms.Label;$lblADB2.Text="Android:";$lblADB2.Location="20,108";$lblADB2.Size="520,20";$lblADB2.ForeColor=$clrDim;$d.Controls.Add($lblADB2)
    $lblADBPath=New-Object System.Windows.Forms.Label
    $lblADBPath.Text=$currentAdbPath;$lblADBPath.Location="20,128";$lblADBPath.Size="520,20"
    $lblADBPath.ForeColor=$clrGold;$d.Controls.Add($lblADBPath)
    $btnADB=New-Object System.Windows.Forms.Button
    $btnADB.Text="Unpack to Android (path above)  [Enter]"
    $btnADB.Location="20,158";$btnADB.Size="500,36";$btnADB.FlatStyle="Flat"
    $btnADB.ForeColor=$clrText;$btnADB.BackColor=[System.Drawing.Color]::FromArgb(28,78,148)
    $btnADB.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(60,120,220);$btnADB.TextAlign="MiddleCenter"
    $btnADB.Add_Click({$d.Tag="ADB";$d.DialogResult="No";$d.Close()})
    $d.Controls.Add($btnADB)
    $btnCn=New-Object System.Windows.Forms.Button;$btnCn.Text="Cancel"
    $btnCn.Location="430,252";$btnCn.Size="90,30";$btnCn.FlatStyle="Flat"
    $btnCn.ForeColor=$clrDim;$btnCn.BackColor=[System.Drawing.Color]::FromArgb(42,42,46)
    $btnCn.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(60,60,68)
    $btnCn.DialogResult="Cancel";$d.Controls.Add($btnCn)
    $d.CancelButton=$btnCn
    # Android is default (Enter)
    $d.AcceptButton=$btnADB
    $d.Add_Shown({$btnADB.Focus()})
    $result=$d.ShowDialog()
    return @{Result=$result;PCPath=$d.Tag}}

function Extract-FromArchive{param([string]$archPath,[string[]]$innerPaths,[string]$destDir,[bool]$flat=$false)
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){Add-Log "7z.exe not found" "Red";return}
    New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue|Out-Null
    $prBg.Visible=$true;$prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew();$p=0;$d=1
    if($innerPaths.Count -eq 0){
        # Extract all with full structure
        $args7="x `"$archPath`" -o`"$destDir`" -aoa -y"
    }else{
        $listFile=Join-Path $script:WorkDir "adbfm_7zlist.txt"
        [System.IO.File]::WriteAllLines($listFile,$innerPaths,[System.Text.Encoding]::UTF8)
        if($flat){
            # "e" = extract without directory structure (files only, flat)
            $args7="e `"$archPath`" @`"$listFile`" -o`"$destDir`" -aoa -y"
        }else{
            # "x" = extract with full directory structure
            $args7="x `"$archPath`" @`"$listFile`" -o`"$destDir`" -aoa -y"
        }
    }
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$env7z;$psi.Arguments=$args7
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi;[void]$proc.Start()
    $tO=$proc.StandardOutput.ReadToEndAsync();$tE=$proc.StandardError.ReadToEndAsync()
    while(-not $proc.HasExited){
        Set-Status "Extracting...  [$([int]$sw.Elapsed.TotalSeconds)s]"
        $r2=Anim-Bar $p $d;$p=[int]$r2[0];$d=[int]$r2[1]
        [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 80}
    if($innerPaths.Count -gt 0){
        $lf=Join-Path $script:WorkDir "adbfm_7zlist.txt"
        if(Test-Path $lf){Remove-Item $lf -ErrorAction SilentlyContinue}}
    $errOut=$tE.Result.Trim()
    $prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=[int]$prBg.Width
    if($proc.ExitCode -ne 0 -and $errOut){Add-Log "Extract error: $errOut" "Red"}
    else{Add-Log "Extracted to: $destDir" "Green"}
    $form.Update();Start-Sleep -Milliseconds 300;$prBg.Visible=$false;$prFl.Width=0}

function Pack-ToArchive{param([string[]]$srcPaths,[string]$archName,[string]$destDir)
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){Add-Log "7z.exe not found" "Red";return}
    $archPath=Join-Path $destDir $archName
    $prBg.Visible=$true;$prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=0
    $sw=[System.Diagnostics.Stopwatch]::StartNew();$p=0;$d=1
    $args7="a `"$archPath`""
    foreach($s in $srcPaths){$args7+=" `"$s`""}
    $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$env7z;$psi.Arguments=$args7
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi;[void]$proc.Start()
    $tO=$proc.StandardOutput.ReadToEndAsync();$tE=$proc.StandardError.ReadToEndAsync()
    while(-not $proc.HasExited){
        Set-Status "Packing: $archName  [$([int]$sw.Elapsed.TotalSeconds)s]"
        $r=Anim-Bar $p $d;$p=[int]$r[0];$d=[int]$r[1]
        [System.Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 80}
    $prFl.Location=New-Object System.Drawing.Point(0,0);$prFl.Width=[int]$prBg.Width
    Add-Log "Packed: $archName" "Green";$form.Update();Start-Sleep -Milliseconds 300;$prBg.Visible=$false;$prFl.Width=0}

function Escape-AdbShell{param([string]$p)
    # Use single-quotes for Android shell - handles spaces, [], special chars
    # Escape embedded single-quotes: replace ' with '''
    $e=$p -replace [char]39,([string][char]39+[string][char]92+[string][char]39+[string][char]39)
    return [string][char]39+$e+[string][char]39}

function AdbMkdir{param([string]$p)
    $q=Escape-AdbShell $p
    & "$envAdb" shell ('mkdir -p '+$q) 2>&1 | Out-Null}

function AdbMkdir{param([string]$p)
    $cmd='mkdir -p '+(Escape-AdbShell $p)
    & "$envAdb" shell $cmd 2>&1 | Out-Null}

function New-TmpDir{
    $guid=[System.Guid]::NewGuid().ToString("N")
    $d=Join-Path $script:WorkDir $guid
    $created=New-Item -ItemType Directory -Path $d -Force
    # Return the actual resolved path (handles short vs long path names)
    return $created.FullName}

function Unpack-Action{param($lv,$item)
    $ti=Get-ItemTag $item
    $archPath=$ti.Path
    $archName=Split-Path $archPath -Leaf
    $localArchPath=$archPath
    if($lv -ne $lvPC){
        $localArchPath=Join-Path $script:WorkDir $archName
        Set-Status "Pulling archive from Android..." "Blue"
        & "$envAdb" pull "`"$archPath`"" "`"$localArchPath`"" 2>&1 | Out-Null
        if(-not(Test-Path -LiteralPath $localArchPath)){
            Add-Log "Failed to pull archive from Android" "Red"
            return
        }
    }
    $dlg=Show-ExtractDialog $archName
    if($dlg.Result -eq "Cancel"){return}
    $tmpDir=New-TmpDir
    try{
        if($dlg.Result -eq "Yes"){
            # PC: extract directly to chosen destination
            Extract-FromArchive $localArchPath @() $dlg.PCPath
            Refresh-Panel "PC"
        }else{
            # Android: extract to tmp, push ALL content under archBase dir
            Extract-FromArchive $localArchPath @() $tmpDir
            # Resolve to actual long path to fix short/long path Substring mismatch
            $tmpDir=(Get-Item -LiteralPath $tmpDir).FullName
            $archBase=[System.IO.Path]::GetFileNameWithoutExtension($archName)
            $adbDest="$($currentAdbPath.TrimEnd("/"))/$archBase"
            AdbMkdir $adbDest
            # Push everything from tmpDir into adbDest (preserving archive structure)
            $allDirs=@(Get-ChildItem -LiteralPath $tmpDir -Recurse -Directory|Sort-Object FullName)
            $allFiles=@(Get-ChildItem -LiteralPath $tmpDir -Recurse -File)
            $total=$allDirs.Count+$allFiles.Count;$idx=0
            foreach($pd in $allDirs){
                $idx++
                $rel=$pd.FullName.Substring($tmpDir.Length+1) -replace "\\","/"
                AdbMkdir "$adbDest/$rel"
                Set-Status "Creating dir ($idx/$total): $($pd.Name)" "Blue"
            }
            foreach($pf in $allFiles){
                $idx++
                $rel=$pf.FullName.Substring($tmpDir.Length+1) -replace "\\","/"
                $pdest="$adbDest/$rel"
                Set-Status "Pushing ($idx/$total): $($pf.Name)" "Blue"
                Invoke-Push $pf.FullName $pdest $pf.Name $pf.Length
                [System.Windows.Forms.Application]::DoEvents()
            }
            Add-Log "Extracted to Android: $adbDest" "Green"
            Refresh-Panel "ADB"
        }
    }finally{
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Pack-Action{
    $lv=Get-ALV;$items=Get-SelItems $lv
    if($items.Count -eq 0){Add-Log "No items selected for packing" "Red";return}
    if($lv -ne $lvPC){Add-Log "Pack only supported on PC panel" "Red";return}
    $srcPaths=@($items|ForEach-Object{(Get-ItemTag $_).Path})
    $defName=[System.IO.Path]::GetFileName($currentLocalPath)+".7z"
    $archName=Show-AdbDialog "Pack Archive" "Archive name:" $defName
    if($null -eq $archName){return}
    if(-not $archName.Contains(".")){$archName+=".7z"}
    Pack-ToArchive $srcPaths $archName $currentLocalPath
    $global:SelectedPaths.Clear();Refresh-Panel "PC"}

function Open-ArchiveItem{param($lv,$item)
    $tag=[string]$item.Tag
    if(-not $tag.StartsWith("ARCH:")){return}
    $innerPath=$tag.Substring(5)
    $archPath=$script:ArchivePath
    $fn=($innerPath -split "[/\\]")[-1]
    if($fn -eq ""){Add-Log "Cannot open directory" "Red";return}
    
    Add-Log "Opening archive item: $fn" "Blue" -Level Important
    Add-Log "Archive path: $archPath" "Gray" -Level Detailed
    Add-Log "Inner path: $innerPath" "Gray" -Level Detailed
    
    if(-not(Test-Path $env7z -ErrorAction SilentlyContinue)){
        Add-Log "7z.exe not found" "Red"
        return
    }
    
    # Создаём временный каталог
    $tmpDir=New-TmpDir
    Add-Log "Created temp dir: $tmpDir" "Gray" -Level Detailed
    
    try{
        # ИЗВЛЕКАЕМ - точно как в Copy-Action
        Set-Status "Extracting $fn from archive..."
        Extract-FromArchive $script:ArchivePath @($innerPath) $tmpDir $false
        
        # ВАЖНО: разрешаем полный путь
        $tmpDir=(Get-Item -LiteralPath $tmpDir).FullName
        Add-Log "Resolved temp dir: $tmpDir" "Gray" -Level Detailed
        
        # Ищем файл
        $tmpFile=$null
        $allFiles=@(Get-ChildItem -LiteralPath $tmpDir -Recurse -File -ErrorAction SilentlyContinue)
        Add-Log "Files extracted: $($allFiles.Count)" "Gray" -Level Detailed
        
        foreach($f in $allFiles){
            Add-Log "  Found: $($f.FullName)" "Gray" -Level Debug
            if($f.Name -eq $fn){
                $tmpFile=$f.FullName
                Add-Log "MATCH: $tmpFile" "Green" -Level Detailed
                break
            }
        }
        
        # Открываем файл
        if($tmpFile -and (Test-Path -LiteralPath $tmpFile)){
            Add-Log "File exists, opening: $tmpFile" "Green" -Level Detailed
            $ft=Get-FileType $fn
            Add-Log "File type: $ft" "Gray" -Level Detailed
            
            if($ft -eq "media"){
                Start-Process $tmpFile
                Add-Log "Opened media from archive: $fn" "Green" -Level Important
            }
            else{
                Add-Log "Opening in text editor..." "Gray" -Level Detailed
                Show-TextEditor $tmpFile "$fn [Archive]" $false ""
                Add-Log "Text editor opened: $fn" "Green" -Level Important
            }
        }else{
            Add-Log "ERROR: File not found: $tmpFile" "Red"
            if($tmpFile){Add-Log "Path exists: $(Test-Path -LiteralPath $tmpFile)" "Red" -Level Detailed}
        }
    }
    catch{
        Add-Log "ERROR in Open-ArchiveItem: $_" "Red"
    }
    finally{
        # НЕ удаляем tmpDir - файл ещё открыт в редакторе!
        # Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function Preview-AdbMedia{param([string]$rp,[string]$fn,[long]$sz)
    $maxBytes=500MB
    if($sz -gt $maxBytes){
        $mb=[int]($sz/1MB)
        $r=Show-AdbDialog "Large File" "File is $mb MB (limit 500 MB). Download anyway?" $null @($fn)
        if($null -eq $r){return}}
    $tmp=Join-Path $env:TEMP "adbfm_media_$fn"
    Invoke-Pull $rp $env:TEMP $fn $sz
    if(Test-Path $tmp){Start-Process $tmp;Add-Log "Opened media: $fn" -Level Important}
    else{Add-Log "Failed to pull media: $fn" "Red"}}



$navAction={
    Add-Log ">>> navAction called" "Yellow" -Level Debug
    $lv=Get-ALV
    Add-Log "Active ListView: $(if($lv -eq $lvPC){'PC'}else{'ADB'})" "Gray" -Level Debug
    $item=Get-SelI $lv
    $itemText=if($null -ne $item){$item.Text}else{'NULL'}
    Add-Log "Selected item: $itemText" "Gray" -Level Debug
    if($null -eq $item){
        Add-Log "Item is NULL, returning" "Gray" -Level Debug
        return
    }
    $ti=Get-ItemTag $item
    $clean=$item.Text
    Add-Log "Item tag: $($item.Tag), Clean: $clean" "Gray" -Level Debug
    Add-Log "Archive path: $($script:ArchivePath)" "Gray" -Level Debug
    Add-Log "Label text: $($lbl0.Text)" "Gray" -Level Debug
    
    # ===== ПЕРВАЯ ПРОВЕРКА: Находимся ли мы ВНУТРИ архива? =====
    $lbl0=if($lv -eq $lvPC){$lblPC}else{$lblADB}
    Add-Log "Inside archive check: ArchivePath='$($script:ArchivePath)' Label='$($lbl0.Text)'" "Gray" -Level Debug
    
    if($script:ArchivePath -ne "" -and $lbl0.Text.StartsWith("[ARCH]")){
        Add-Log "!!! WE ARE INSIDE ARCHIVE !!!" "Yellow" -Level Debug

        
        # Close archive
        if($item.Tag -eq "__ARCHCLOSE__"){
            if($script:ArchiveSubDir -ne ""){
                $parts2=$script:ArchiveSubDir -split "/"
                if($parts2.Count -gt 1){$script:ArchiveSubDir=($parts2[0..($parts2.Count-2)]) -join "/"}
                else{$script:ArchiveSubDir=""}
                Refresh-ArchPanel;$lv.Focus();return
            }
            $savedArchName=$script:ArchiveName
            $script:ArchivePath=""
            if($lv -eq $lvPC){Refresh-Panel "PC"}else{Refresh-Panel "ADB"}
            if($savedArchName -and $savedArchName -ne ""){Find-Sel $lv $savedArchName}
            $lv.Focus();return
        }
        
        # Handle ARCH: prefixed items
        if(([string]$item.Tag).StartsWith("ARCH:")){
            $innerPath2=([string]$item.Tag).Substring(5)
            Add-Log "Archive item: $innerPath2" "Gray" -Level Debug
            
            # Check if directory
            $archItems2=List-Archive $script:ArchivePath $script:ArchiveSubDir
            $isArchDir2=$false
            foreach($ai2 in $archItems2){
                if($ai2.InnerPath -eq $innerPath2 -and $ai2.IsDir){
                    $isArchDir2=$true
                    break
                }
            }
            
            # If directory - navigate into it
            if($isArchDir2){
                Add-Log "Navigating into directory: $innerPath2" "Gray" -Level Debug
                $script:ArchiveSubDir=$innerPath2
                Refresh-ArchPanel;$lv.Focus();return
            }
            
            # If file - open in editor or media player
            $ft2=Get-FileType $clean
            Add-Log "Archive file type: $ft2, filename: $clean" "Gray" -Level Debug
            
            if($ft2 -eq "media" -or $ft2 -eq "text" -or $clean -match "\.(ps1|bat|cmd|sh|bash|ini|cfg|conf|log|nfo|sql|properties|gradle|cmake|makefile|dockerfile)$"){
                Add-Log "Opening archive file: $clean" "Yellow" -Level Debug
                Open-ArchiveItem $lv $item
            }
            $lv.Focus();return
        }
        
        $lv.Focus();return
    }
    
    # ===== ВТОРАЯ ПРОВЕРКА: Обработка APK/XAPK/APKS на PC (вне архива) =====
    if($lv -eq $lvPC -and $currentLocalPath -ne "DRIVES" -and -not $ti.IsDir){
        $e2=($clean -split "\.")[-1].ToLower()
        if($e2 -in @("apk","xapk","apks")){
            if($e2 -eq "xapk"){Install-XAPK $ti.Path}
            elseif($e2 -eq "apks"){Install-APKS $ti.Path}
            else{Install-APK $ti.Path}
            return
        }
    }
    
    # ===== ТРЕТЬЯ ПРОВЕРКА: Обработка обычных файлов на PC (вне архива) =====
    if($lv -eq $lvPC -and $currentLocalPath -ne "DRIVES" -and -not $ti.IsDir){
        $ft=Get-FileType $clean
        $dot2=$clean.LastIndexOf(".");$ext2=if($dot2 -ge 0){$clean.Substring($dot2+1).ToLower()}else{""}
        
        # Archive files - open archive
        if($ft -eq "arch"){
            if(Is-MultipartNotFirst $ti.Path){
                $first=Get-ArchiveFirstPart $ti.Path
                Add-Log "Multipart archive: opening first part: $(Split-Path $first -Leaf)" -Level Detailed
                Open-Archive $first $true
            }else{
                Open-Archive $ti.Path $true
            }
            $lv.Focus();return
        }
        
        # Executable files - run
        if($ft -eq "exec"){
            Open-File $ti.Path "run";$lv.Focus();return
        }
        
        # Text files - open
        if($ft -in @("text")){
            Open-File $ti.Path "open";$lv.Focus();return
        }
        
        # Media files - open
        if($ft -eq "media"){
            Open-File $ti.Path "open";$lv.Focus();return
        }
    }
    
    # ===== ЧЕТВЁРТАЯ ПРОВЕРКА: Media preview на ADB (вне архива) =====
    if($lv -eq $lvADB -and -not $ti.IsDir){
        $ft=Get-FileType $clean
        
        # Media files - preview
        if($ft -eq "media"){
            $szRaw=(& "$envAdb" shell stat -c "%s" "`"$($ti.Path)`"" 2>&1) -replace "`r",""
            $sz=if($szRaw -match "^[0-9]+$"){[long]$szRaw}else{0L}
            Preview-AdbMedia $ti.Path $clean $sz;$lv.Focus();return
        }
        
        # Archive files - pull and open
        if($ft -eq "arch"){
            $tmp=Join-Path $env:TEMP $clean
            Set-Status "Pulling archive..."
            & "$envAdb" pull "`"$($ti.Path)`"" "`"$tmp`"" 2>&1 | Out-Null
            if(Test-Path -LiteralPath $tmp){
                $firstPart=Get-ArchiveFirstPart $tmp
                $script:ArchivePath=$firstPart;$script:ArchiveIsPC=$false
                $script:ArchiveName=Split-Path $firstPart -Leaf
                $script:ArchiveSubDir=""
                Refresh-ArchPanel;$lv.Focus();return
            }
        }
    }
    
    # ===== ПЯТАЯ ПРОВЕРКА: Навигация вверх =====
    if($ti.Path -eq "__GOUP__"){
        if($lv -eq $lvPC){
            $fe=Split-Path $currentLocalPath -Leaf
            $pp=Split-Path $currentLocalPath -Parent
            $script:currentLocalPath=if(!$pp -or $pp -eq $currentLocalPath){"DRIVES"}else{$pp}
            Refresh-Panel "PC"
            if($fe){Find-Sel $lvPC $fe}
        }
        else{
            $parts=$currentAdbPath.TrimEnd("/").Split("/")
            $fe=$parts[-1]
            $script:currentAdbPath=($parts[0..($parts.Count-2)] -join "/")
            if(!$currentAdbPath){$script:currentAdbPath="/"}
            Refresh-Panel "ADB"
            if($fe){Find-Sel $lvADB $fe}
        }
    }
    # ===== ШЕСТАЯ ПРОВЕРКА: Навигация в папку =====
    else{
        if($lv -eq $lvPC){
            if($currentLocalPath -eq "DRIVES"){
                $script:currentLocalPath=$ti.Path
                Refresh-Panel "PC"
            }
            elseif($ti.IsDir){
                $script:currentLocalPath=$ti.Path
                Refresh-Panel "PC"
            }
        }
        else{
            if($ti.IsDir){
                $script:currentAdbPath=$ti.Path
                Refresh-Panel "ADB"
            }
        }
    }
    $lv.Focus()
    Add-Log "<<< navAction completed" "Yellow" -Level Debug
}





function Search-Action{
    $lv=Get-ALV;$script:SearchIsPC=($lv -eq $lvPC);$script:SearchStop=$false
    $query=Show-AdbDialog "Search" "Search (wildcard * supported):" "*"
    if($null -eq $query -or $query.Trim() -eq ""){return}
    $sw2=New-Object System.Windows.Forms.Form;$sw2.Text="Search: $query";$sw2.Size="740,540"
    $sw2.BackColor=$bgForm;$sw2.ForeColor=$clrText;$sw2.StartPosition="CenterParent";$sw2.FormBorderStyle="Sizable"
    $topP=New-Object System.Windows.Forms.Panel;$topP.Dock="Top";$topP.Height=32;$topP.BackColor=[System.Drawing.Color]::FromArgb(30,30,36);$sw2.Controls.Add($topP)
    $sLbl=New-Object System.Windows.Forms.Label;$sLbl.Location="8,7";$sLbl.Size="540,20";$sLbl.ForeColor=$clrDim;$topP.Controls.Add($sLbl)
    $bStop=New-Object System.Windows.Forms.Button;$bStop.Text="Stop";$bStop.Location="580,4";$bStop.Size="80,24"
    $bStop.FlatStyle="Flat";$bStop.ForeColor=$clrText;$bStop.BackColor=[System.Drawing.Color]::FromArgb(48,48,56)
    $bStop.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)
    $bStop.Add_Click({$script:SearchStop=$true;$bStop.Enabled=$false});$topP.Controls.Add($bStop)
    $sLV=New-Object System.Windows.Forms.ListView;$sLV.Dock="Fill";$sLV.View="Details";$sLV.FullRowSelect=$true
    $sLV.BackColor=$bgInact;$sLV.ForeColor=$clrText;$sLV.Font=$fntItem;$sLV.BorderStyle="None"
    $sLV.Columns.Add("Path",590)|Out-Null;$sLV.Columns.Add("Size",80)|Out-Null
    $sw2.Controls.Add($sLV);$sLV.BringToFront()
    $script:SearchSLV=$sLV;$script:SearchSW=$sw2
    $sw2.Show();$sLbl.Text="  Searching '$query'...";$form.Update()
    $cnt=0
    if($script:SearchIsPC){
        $root=if($currentLocalPath -eq "DRIVES"){"C:\"}else{$currentLocalPath}
        try{
            Get-ChildItem $root -Recurse -Filter $query -ErrorAction SilentlyContinue|ForEach-Object{
                if($script:SearchStop){return}
                $szS=if($_.PSIsContainer){"<Dir>"}else{Format-Bytes $_.Length}
                $li=New-Object System.Windows.Forms.ListViewItem($_.FullName);$li.SubItems.Add($szS)|Out-Null;$li.Tag=$_.FullName
                $sLV.Items.Add($li)|Out-Null;$cnt++;$sLbl.Text="  Found $cnt item(s)..."
                [System.Windows.Forms.Application]::DoEvents()}
        }catch{}
    }else{
        $rawS=& "$envAdb" shell ('find '+(Escape-AdbShell $currentAdbPath)+' -name '+(Escape-AdbShell $query)+' 2>/dev/null') 2>&1
        foreach($line in ($rawS -split "`n")){
            if($script:SearchStop){break}
            $pp=($line -replace "`r","").Trim();if(-not $pp){continue}
            $li=New-Object System.Windows.Forms.ListViewItem($pp);$li.SubItems.Add("")|Out-Null;$li.Tag=$pp
            $sLV.Items.Add($li)|Out-Null;$cnt++;$sLbl.Text="  Found $cnt item(s)..."
            [System.Windows.Forms.Application]::DoEvents()}
    }
    $bStop.Enabled=$false
    $sLbl.Text="  Found $cnt item(s) -- double-click to navigate"
    $sLV.Add_DoubleClick({
        if($script:SearchSLV.SelectedItems.Count -eq 0){return}
        $selPath=$script:SearchSLV.SelectedItems[0].Tag
        if($script:SearchIsPC){
            $script:currentLocalPath=Split-Path $selPath -Parent
            Refresh-Panel "PC";$form.Activate();$lvPC.Focus();Find-Sel $lvPC (Split-Path $selPath -Leaf)
        }else{
            $script:currentAdbPath=(Split-Path $selPath -Parent) -replace "\\","/"
            Refresh-Panel "ADB";$form.Activate();$lvADB.Focus();Find-Sel $lvADB (Split-Path $selPath -Leaf)
        }
        $script:SearchSW.Close()
    })
}

function Ctx-Run{Open-File $script:CtxPath "run"}
function Ctx-Edit{Open-File $script:CtxPath "edit"}
function Ctx-EditAdb{Edit-AdbFile $script:CtxPath(Split-Path $script:CtxPath -Leaf)}
function Ctx-Open{Open-File $script:CtxPath "open"}
function Ctx-Apk{
    $p=$script:CtxPath;$e=($p -split "\.")[-1].ToLower()
    if($e -eq "xapk"){Install-XAPK $p}
    elseif($e -eq "apks"){Install-APKS $p}
    else{Install-APK $p}}
# FIX Copy: CtxLVRef set before Show(); Closed fires AFTER click handler, so ref still valid

function Ctx-Unpack{
    $lv=$script:CtxLVRef;$item=$script:CtxItem
    if($null -ne $item){
        # For multipart archives - always start from first part
        $ti=Get-ItemTag $item
        $firstPath=Get-ArchiveFirstPart $ti.Path
        if($firstPath -ne $ti.Path){
            Add-Log "Multipart: using first part: $(Split-Path $firstPath -Leaf)" -Level Detailed
            # Create a fake item with first part path
            $fakeItem=New-Object System.Windows.Forms.ListViewItem
            $fakeItem.Tag="FILE:$firstPath"
            Unpack-Action $lv $fakeItem
        }else{Unpack-Action $lv $item}}}
function Ctx-Pack{Pack-Action}
function Ctx-Copy{
    $lv=$script:CtxLVRef
    $its=if($null -ne $lv){Get-SelItems $lv}else{@()}
    if($its.Count -eq 0 -and $null -ne $script:CtxItem){$its=@($script:CtxItem)}
    $global:ClipboardItems=@();$global:ClipboardIsAdb=(-not $script:CtxIsPC)
    $fl=New-Object System.Collections.Specialized.StringCollection
    foreach($it in ($its|Where-Object{$_.Tag -ne "__GOUP__"})){
        $ti=Get-ItemTag $it
        [void]$global:SelectedPaths.Add($ti.Path)
        $global:ClipboardItems+=@{Path=$ti.Path;IsDir=$ti.IsDir}
        $fl.Add($ti.Path)|Out-Null}
    if($null -ne $lv){$lv.Invalidate()}
    if($script:CtxIsPC -and $fl.Count -gt 0){
        try{[System.Windows.Forms.Clipboard]::SetFileDropList($fl);Add-Log "Copied to clipboard: $($global:ClipboardItems.Count) file(s)" -Level Important}
        catch{Add-Log "Copied: $($global:ClipboardItems.Count) item(s)" -Level Important}}
    else{Add-Log "Copied: $($global:ClipboardItems.Count) item(s)" -Level Important}}
function Ctx-Paste{
    $isPC=$script:CtxIsPC
    foreach($ci in $global:ClipboardItems){$fn=Split-Path $ci.Path -Leaf
        if($global:ClipboardIsAdb -and $isPC){
            # ADB -> PC
            $raw=(& "$envAdb" shell stat -c "%s" "`"$($ci.Path)`"" 2>&1) -replace "`r","";$sz=if($raw -match "^[0-9]+$"){[long]$raw}else{0L}
            Invoke-Pull $ci.Path $currentLocalPath $fn $sz}
        elseif(-not $global:ClipboardIsAdb -and -not $isPC){
            # PC -> ADB
            Invoke-Push $ci.Path "$($currentAdbPath.TrimEnd("/"))/$fn" $fn (Get-LocalSize $ci.Path)}
        elseif($global:ClipboardIsAdb -and -not $isPC){
            # ADB -> ADB (same side)
            $dest="$($currentAdbPath.TrimEnd("/"))/$fn"
            if($dest -ne $ci.Path){
                Set-Status "Copying on device: $fn...";$form.Update()
                if($ci.IsDir){& "$envAdb" shell "cp -r '$($ci.Path)' '$dest'" 2>&1 | Out-Null}
                else{& "$envAdb" shell "cp '$($ci.Path)' '$dest'" 2>&1 | Out-Null}
                Add-Log "Copied on device: $fn" "Green" -Level Important
            }else{Add-Log "Skipped (same path): $fn" "Red"}}
        else{
            # PC -> PC (same side)
            $dest=Join-Path $currentLocalPath $fn
            if($dest -ne $ci.Path){
                try{if($ci.IsDir){Copy-Item -LiteralPath $ci.Path -Destination $dest -Recurse -Force}else{Copy-Item -LiteralPath $ci.Path -Destination $dest -Force};Add-Log "Copied: $fn" "Green" -Level Important}
                catch{Add-Log "Copy failed: $_" "Red"}
            }else{Add-Log "Skipped (same path): $fn" "Red"}}}
    $global:ClipboardItems=@();$global:SelectedPaths.Clear();Refresh-Panel "PC";Refresh-Panel "ADB";Add-Log "Paste done" -Level Important}
Add-Type -TypeDefinition @"
using System.Drawing; using System.Windows.Forms;
public class DarkMenuRenderer:ToolStripProfessionalRenderer{
    public DarkMenuRenderer():base(new DarkColorTable()){}
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e){}
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e){
        var g=e.Graphics;var r=new Rectangle(0,0,e.Item.Width,e.Item.Height);
        Color bg=(e.Item.Selected&&e.Item.Enabled)?Color.FromArgb(42,100,175):Color.FromArgb(44,44,52);
        g.FillRectangle(new SolidBrush(bg),r);}}
public class DarkColorTable:ProfessionalColorTable{
    public override Color MenuBorder{get{return Color.FromArgb(70,70,80);}}
    public override Color ToolStripDropDownBackground{get{return Color.FromArgb(44,44,52);}}
    public override Color ImageMarginGradientBegin{get{return Color.FromArgb(44,44,52);}}
    public override Color ImageMarginGradientMiddle{get{return Color.FromArgb(44,44,52);}}
    public override Color ImageMarginGradientEnd{get{return Color.FromArgb(44,44,52);}}}
"@ -ReferencedAssemblies "System.Windows.Forms","System.Drawing" -ErrorAction SilentlyContinue
$ctxMenu=New-Object System.Windows.Forms.ContextMenuStrip
try{$ctxMenu.Renderer=New-Object DarkMenuRenderer}catch{}
$ctxMenu.BackColor=[System.Drawing.Color]::FromArgb(44,44,52);$ctxMenu.ForeColor=$clrText;$ctxMenu.ShowImageMargin=$false
$ctxMenu.Add_Closed({try{$lvPC.Invalidate()}catch{};try{$lvADB.Invalidate()}catch{}})

function Add-MI{param([string]$t2,[string]$fn,[bool]$en=$true)
    $mi=New-Object System.Windows.Forms.ToolStripMenuItem($t2)
    $mi.Enabled=$en;$mi.BackColor=[System.Drawing.Color]::FromArgb(44,44,52)
    $mi.ForeColor=if($en){$clrText}else{[System.Drawing.Color]::FromArgb(90,88,84)}
    if($en){$mi.Add_Click([scriptblock]::Create("$fn"))}
    $ctxMenu.Items.Add($mi)|Out-Null}
function Show-CtxMenu{param($lv)
    $ctxMenu.Items.Clear()
    $mp=[System.Windows.Forms.Control]::MousePosition;$cp=$lv.PointToClient($mp)
    $hit=$lv.HitTest($cp.X,$cp.Y)
    if($null -ne $hit.Item){$hit.Item.Selected=$true;$hit.Item.Focused=$true;$lv.Focus()}
    $isPC=($lv -eq $lvPC);$hasClip=$global:ClipboardItems.Count -gt 0
    $script:CtxLVRef=$lv;$script:CtxIsPC=$isPC
    $item=Get-SelI $lv
    if($null -eq $item -or $item.Tag -eq "__GOUP__"){
        $script:CtxItem=$null;$script:CtxPath="";Add-MI "Paste" "Ctx-Paste" $hasClip;$ctxMenu.Show($mp);return}
    $ti=Get-ItemTag $item;$isDir=$ti.IsDir;$ft=if(-not $isDir){Get-FileType $item.Text}else{"dir"}
    $script:CtxItem=$item;$script:CtxPath=$ti.Path;$script:CtxIsDir=$isDir
    # Snapshot items NOW before menu shows - Ctx-Copy will use this
    $script:CtxSnap=@(Get-SelItems $lv);if($script:CtxSnap.Count -eq 0){$script:CtxSnap=@($item)}
    $lv.Invalidate()
    Add-MI "Run"                    "Ctx-Run"     ($ft -eq "exec" -and $isPC)
    Add-MI "Edit (built-in)"        "Ctx-Edit"    (-not $isDir -and $isPC)
    Add-MI "Edit (pull-edit-push)"  "Ctx-EditAdb" (-not $isDir -and -not $isPC)
    Add-MI "Open with default"      "Ctx-Open"    (-not $isDir -and $isPC)
    Add-MI "Install APK/XAPK/APKS"  "Ctx-Apk"     ($ft -eq "apk" -and $isPC)
    $ctxMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))|Out-Null
    # Archive options
    $isArch=($ft -eq "arch" -and $isPC)
    Add-MI "Unpack archive"   "Ctx-Unpack"  $isArch
    Add-MI "Pack selected"    "Ctx-Pack"    ($isPC -and $global:SelectedPaths.Count -gt 0)
    $ctxMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))|Out-Null
    Add-MI "Copy (mark + clipboard)" "Ctx-Copy"   $true
    Add-MI "Paste"                   "Ctx-Paste"  $hasClip
    $ctxMenu.Show($mp)}
$lvPC.Add_MouseUp({param($s,$e);if($e.Button -eq "Right"){Show-CtxMenu $lvPC}})
$lvADB.Add_MouseUp({param($s,$e);if($e.Button -eq "Right"){Show-CtxMenu $lvADB}})

function Rename-Action{
    $lv=Get-ALV
    $item=Get-SelI $lv
    if($null -eq $item -or $item.Tag -eq "__GOUP__"){return}
    $clean=$item.Text
    $new=Show-AdbDialog "Rename" "New name:" $clean
    if($null -ne $new -and $new -ne $clean){
        $ti=Get-ItemTag $item
        if($lv -eq $lvPC){
            Rename-Item $ti.Path $new -ErrorAction SilentlyContinue
            Refresh-Panel "PC"
            Add-Log "Renamed: $clean -> $new" -Level Important
        }else{
            $rnDst="$($currentAdbPath.TrimEnd('/'))/$new"
            & "$envAdb" shell "mv '$($ti.Path)' '$rnDst'" 2>&1 | Out-Null
            Refresh-Panel "ADB"
            Add-Log "Renamed: $clean -> $new" -Level Important
        }
    }
    $lv.Focus()
}

function Copy-Action{
    $lv0=Get-ALV
    $lbl0=if($lv0 -eq $lvPC){$lblPC}else{$lblADB}
    if($script:ArchivePath -ne "" -and $lbl0.Text.StartsWith("[ARCH]")){
        $lv2=Get-ALV
        $items2=Get-SelItems $lv2
        $innerPaths2=@()
        if($items2.Count -gt 0){
            $innerPaths2=@($items2|Where-Object{([string]$_.Tag).StartsWith("ARCH:")}|ForEach-Object{([string]$_.Tag).Substring(5)})
        # Detect if any selected item is a directory
        $hasDir2=$items2|Where-Object{([string]$_.Tag).StartsWith("ARCH:")}|ForEach-Object{
            $ip=([string]$_.Tag).Substring(5)
            $archItems2b=List-Archive $script:ArchivePath $script:ArchiveSubDir
            $archItems2b|Where-Object{$_.InnerPath -eq $ip -and $_.IsDir}}
        $flatExtract2=($hasDir2.Count -eq 0)
        }
        $dlg=Show-ExtractDialog $script:ArchiveName
        if($dlg.Result -eq "Cancel"){return}
        if($dlg.Result -eq "Yes"){
            Extract-FromArchive $script:ArchivePath $innerPaths2 $dlg.PCPath $flatExtract2
            Refresh-Panel "PC"
        }else{
            # Android: extract to tmp, push content directly to currentAdbPath
            $tmpDir3=New-TmpDir
            try{
                Extract-FromArchive $script:ArchivePath $innerPaths2 $tmpDir3 $flatExtract2
                $tmpDir3=(Get-Item -LiteralPath $tmpDir3).FullName
                $adbBase3=$currentAdbPath.TrimEnd("/")
                $allDirs3=@(Get-ChildItem -LiteralPath $tmpDir3 -Recurse -Directory|Sort-Object FullName)
                $allFiles3=@(Get-ChildItem -LiteralPath $tmpDir3 -Recurse -File)
                $total3=$allDirs3.Count+$allFiles3.Count;$idx3=0
                foreach($pd3 in $allDirs3){
                    $idx3++
                    $rel3=$pd3.FullName.Substring($tmpDir3.Length+1) -replace "\\","/"
                    AdbMkdir "$adbBase3/$rel3"
                    Set-Status "Creating dir ($idx3/$total3): $($pd3.Name)" "Blue"
                }
                foreach($pf3 in $allFiles3){
                    $idx3++
                    $rel3=$pf3.FullName.Substring($tmpDir3.Length+1) -replace "\\","/"
                    $pdest3="$adbBase3/$rel3"
                    Set-Status "Pushing ($idx3/$total3): $($pf3.Name)" "Blue"
                    Invoke-Push $pf3.FullName $pdest3 $pf3.Name $pf3.Length
                    [System.Windows.Forms.Application]::DoEvents()
                }
                Add-Log "Extracted to Android: $adbBase3" "Green"
                Refresh-Panel "ADB"
            }finally{
                Remove-Item -LiteralPath $tmpDir3 -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $global:SelectedPaths.Clear()
        Refresh-ArchPanel
        return
    }
    $lv=Get-ALV
    $items=Get-SelItems $lv
    if($items.Count -eq 0){return}
    $names=@($items|ForEach-Object{$_.Text})
    if($null -eq (Show-AdbDialog "Confirm Copy" "Copy following item(s)?" $null $names)){return}
    foreach($it in $items){
        $ti=Get-ItemTag $it
        if($lv -eq $lvPC){
            $adbT=$currentAdbPath.TrimEnd("/")
            Invoke-Push $ti.Path "$adbT/$($it.Text)" $it.Text (Get-LocalSize $ti.Path)
        }else{
            $raw=(& "$envAdb" shell stat -c "%s" "`"$($ti.Path)`"" 2>&1) -replace "`r",""
            $sz=if($raw -match "^[0-9]+$"){[long]$raw}else{0L}
            Invoke-Pull $ti.Path $currentLocalPath $it.Text $sz
        }
    }
    $global:SelectedPaths.Clear()
    Refresh-Panel "PC"
    Refresh-Panel "ADB"
    Add-Log "Copy done" -Level Important
    $lv.Focus()
}

function Move-Action{
    $lv=Get-ALV
    $item=Get-SelI $lv
    if($null -eq $item -or $item.Tag -eq "__GOUP__"){return}
    $clean=$item.Text
    $new=Show-AdbDialog "Move/Rename" "New name:" $clean
    if($null -ne $new){
        $ti=Get-ItemTag $item
        if($lv -eq $lvPC){
            Rename-Item $ti.Path $new -ErrorAction SilentlyContinue
            Refresh-Panel "PC"
        }else{
            $mvDst="$($currentAdbPath.TrimEnd('/'))/$new"
            & "$envAdb" shell "mv '$($ti.Path)' '$mvDst'" 2>&1 | Out-Null
            Refresh-Panel "ADB"
        }
    }
    $lv.Focus()
}


function Edit-Action{
    $lv=Get-ALV
    $item=Get-SelI $lv
    if($null -eq $item -or $item.Tag -eq "__GOUP__"){return}
    $ti=Get-ItemTag $item
    
    # Check if inside archive
    $lbl0=if($lv -eq $lvPC){$lblPC}else{$lblADB}
    if($script:ArchivePath -ne "" -and $lbl0.Text.StartsWith("[ARCH]")){
        # Inside archive - use Open-ArchiveItem
        if(([string]$item.Tag).StartsWith("ARCH:")){
            Open-ArchiveItem $lv $item
        }
        $lv.Focus()
        return
    }
    
    if($lv -eq $lvPC){Open-File $ti.Path "edit"}
    else{Edit-AdbFile $ti.Path $item.Text}
    $lv.Focus()
}


function NewDir-Action{
    $lv=Get-ALV
    $new=Show-AdbDialog "New Folder" "Folder name:" "New_Folder"
    if($null -ne $new){
        if($lv -eq $lvPC){
            New-Item -ItemType Directory -Path (Join-Path $currentLocalPath $new) -ErrorAction SilentlyContinue|Out-Null
            Refresh-Panel "PC"
        }else{
            & "$envAdb" shell ('mkdir -p '+(Escape-AdbShell "$currentAdbPath/$new")) 2>&1 | Out-Null
            Refresh-Panel "ADB"
        }
        Add-Log "Created: $new" -Level Important
    }
    $lv.Focus()
}

function Delete-Action{
    $lv=Get-ALV
    $items=Get-SelItems $lv
    if($items.Count -eq 0){return}
    $names=@($items|ForEach-Object{$_.Text})
    if($null -eq (Show-AdbDialog "Confirm Delete" "DELETE following item(s)?" $null $names)){return}
    foreach($it in $items){
        $ti=Get-ItemTag $it
        if($lv -eq $lvPC){Remove-Item -LiteralPath $ti.Path -Recurse -Force -ErrorAction SilentlyContinue}
        else{& "$envAdb" shell "rm -rf '$($ti.Path)'" 2>&1 | Out-Null}
    }
    $global:SelectedPaths.Clear()
    Refresh-Panel "PC"
    Refresh-Panel "ADB"
    Add-Log "Deleted: $($names -join ', ')" -Level Important
    $lv.Focus()
}

function Go-Data{$script:currentAdbPath="/storage/emulated/0/Android/data";Refresh-Panel "ADB";$lvADB.Focus()}
function Go-Obb{$script:currentAdbPath="/storage/emulated/0/Android/obb";Refresh-Panel "ADB";$lvADB.Focus()}
function Show-Help{
    $d=New-Object System.Windows.Forms.Form
    $d.Text="Quas ADB Commander v8.61 - Help"
    $d.Size="1020,680";$d.MinimumSize="900,600"
    $d.BackColor=$bgForm;$d.ForeColor=$clrText
    $d.FormBorderStyle="Sizable";$d.StartPosition="CenterParent";$d.KeyPreview=$true
    $d.GetType().GetProperty("DoubleBuffered",[System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($d,$true,$null)
    $pnl=New-Object System.Windows.Forms.TableLayoutPanel
    $pnl.Dock="Fill";$pnl.ColumnCount=2;$pnl.RowCount=1
    $pnl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,50)))|Out-Null
    $pnl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,50)))|Out-Null
    $d.Controls.Add($pnl)
    $btnClose=New-Object System.Windows.Forms.Button
    $btnClose.Text="Close  [Esc]";$btnClose.Size="120,28";$btnClose.FlatStyle="Flat"
    $btnClose.ForeColor=$clrText;$btnClose.BackColor=[System.Drawing.Color]::FromArgb(48,48,56)
    $btnClose.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,70,80)
    $btnClose.Dock="Bottom";$btnClose.DialogResult="OK"
    $d.Controls.Add($btnClose)
    $d.AcceptButton=$btnClose;$d.CancelButton=$btnClose
    $mkRtb={
        $r=New-Object System.Windows.Forms.RichTextBox
        $r.Dock="Fill";$r.ReadOnly=$true;$r.BorderStyle="None"
        $r.BackColor=$bgForm;$r.ForeColor=$clrText
        $r.Font=New-Object System.Drawing.Font("Consolas",9.5)
        $r.ScrollBars="Vertical";$r.WordWrap=$false;$r.DetectUrls=$true
        $r.Add_LinkClicked({param($s,$ev)[System.Diagnostics.Process]::Start($ev.LinkText)})
        return $r}
    $L=&$mkRtb;$R=&$mkRtb
    $pnl.Controls.Add($L,0,0);$pnl.Controls.Add($R,1,0)
    $cH=[System.Drawing.Color]::FromArgb(78,201,176)
    $cK=[System.Drawing.Color]::FromArgb(156,220,254)
    $cV=[System.Drawing.Color]::FromArgb(210,208,202)
    $cD=[System.Drawing.Color]::FromArgb(150,148,142)
    $cU=[System.Drawing.Color]::FromArgb(86,156,214)
    $cW=[System.Drawing.Color]::FromArgb(220,160,50)
    $cG=[System.Drawing.Color]::FromArgb(100,200,100)
    $fB=New-Object System.Drawing.Font("Consolas",10,[System.Drawing.FontStyle]::Bold)
    $fN=New-Object System.Drawing.Font("Consolas",9.5)
    $SH={param($rtb,[string]$s)
        $rtb.SelectionFont=$fB;$rtb.SelectionColor=$cH
        $rtb.AppendText("`r`n $s`r`n")
        $rtb.SelectionFont=$fN;$rtb.SelectionColor=$cD
        $rtb.AppendText(" ------------------------------------------`r`n")}
    $KV={param($rtb,[string]$k,[string]$v)
        $rtb.SelectionFont=$fN;$rtb.SelectionColor=$cK
        $rtb.AppendText((" {0,-17}"-f $k))
        $rtb.SelectionColor=$cV;$rtb.AppendText("$v`r`n")}
    $NN={param($rtb,[string]$s="",[System.Drawing.Color]$c=$cD)
        $rtb.SelectionFont=$fN;$rtb.SelectionColor=$c
        $rtb.AppendText(" $s`r`n")}
    # LEFT
    $L.SelectionFont=New-Object System.Drawing.Font("Consolas",12,[System.Drawing.FontStyle]::Bold)
    $L.SelectionColor=[System.Drawing.Color]::FromArgb(212,188,82)
    $L.AppendText(" Quas ADB Commander v8.61`r`n")
    $L.SelectionFont=$fN;$L.SelectionColor=$cD
    $L.AppendText(" Dual-panel file manager for Meta Quest / Android`r`n`n")
    $L.AppendText(" This script was written by Varset using Claude,`r`n")
    $L.AppendText(" Chat GPT, Github Copilot, Gemini Dev, and mother f@ckin'`r`n")
    &$SH $L "NAVIGATION"
    &$KV $L "Tab"            "Switch active panel"
    &$KV $L "Enter/DblClick" "Open folder / Run / Enter archive"
    &$KV $L "Space"          "Toggle mark (yellow)"
    &$KV $L "* (Numpad)"     "Mark ALL / Unmark ALL"
    &$KV $L "Alt+X"          "Exit"
    &$KV $L "F9"             "Jump to Android/data"
    &$KV $L "F10"            "Jump to Android/obb"
     &$KV $L "F12"            "Diagnostics / logging"
    &$SH $L "FILE OPERATIONS"
    &$KV $L "F2"             "Rename"
    &$KV $L "F3"             "Search  (* wildcard)"
    &$KV $L "F4"             "Open in built-in editor"
    &$KV $L "F5"             "Copy to opposite panel"
    &$KV $L "F6"             "Move / Rename"
    &$KV $L "F7"             "Create new folder"
    &$KV $L "F8 / Delete"    "Delete selected"
    &$SH $L "BUILT-IN EDITOR"
    &$KV $L "Ctrl+S / F2"    "Save"
    &$KV $L "Esc"            "Close (asks if unsaved)"
    &$KV $L "Wrap button"    "Toggle word wrap"
    &$KV $L "Syntax button"  "Syntax highlight on/off"
    &$NN $L "* in title = unsaved changes"
    &$NN $L "Search: highlight matches (3+ chars)"
    &$KV $L "< > buttons"    "Prev/Next search results"
    &$NN $L "RMB: Copy / Paste"
    &$NN $L ""
    &$NN $L "Syntax highlight (auto):" $cW
    $L.SelectionColor=$cG;$L.AppendText(" ps1 bat cmd sh ini cfg log nfo`r`n")
    &$SH $L "CONTEXT MENU  (Right Click)"
    &$KV $L "Run"            "Execute file (PC only)"
    &$KV $L "Edit built-in"  "Open in editor (PC)"
    &$KV $L "Edit pull-push" "Pull, edit, push back (ADB)"
    &$KV $L "Open default"   "Open with system app"
    &$KV $L "Install APK"    "Install APK + auto OBB"
    &$KV $L "Copy"           "Mark + system clipboard"
    &$KV $L "Paste"          "PC<->ADB, PC->PC, ADB->ADB"
    &$KV $L "Unpack archive" "Extract to PC or Android"
    &$KV $L "Pack selected"  "Pack marked to .7z"

    # RIGHT
    &$SH $R "ARCHIVE SUPPORT  (requires 7z.exe)"
    &$KV $R "Enter/DblClick" "Browse archive as folder"
    &$KV $R "F4 on file"     "Open text file from archive"
    &$KV $R "F5 (files)"     "Extract files flat (no subfolders)"
    &$KV $R "F5 (folder)"    "Extract folder with structure"
    &$KV $R "* then F5"      "Mark all + extract everything"
    &$KV $R "[Close Archive]" "Exit / go up inside archive"
    &$NN $R ""
    &$NN $R "RMB Unpack: extract ALL, choose destination"
    &$NN $R "RMB Pack: pack marked items to .7z"
    &$NN $R ""
    &$NN $R "Formats:" $cW
    $R.SelectionColor=$cG;$R.AppendText(" zip 7z rar gz tar bz2 xz cab iso tgz`r`n")
    &$SH $R "MULTIPART ARCHIVES"
    &$KV $R ".7z.001 / .002"   "7-Zip multipart"
    &$KV $R ".part1.rar / ..." "WinRAR multipart"
    &$KV $R ".z01 / .z02"      "ZIP split"
    &$KV $R ".001 / .002"      "Generic split"
    &$NN $R ""
    &$NN $R "Open or RMB ANY part ->" $cD
    &$NN $R "  always starts from part 1" $cW
    &$SH $R "TOOLS SETUP"
    &$NN $R "Place in script folder or use -ToolsPath:" $cD
    $R.SelectionColor=$cG;$R.AppendText(" adb.exe  aapt2.exe  7z.exe  7z.dll`r`n")
    &$NN $R ""
    &$KV $R "-ToolsPath"  "Folder with adb/7z tools"
    &$KV $R "-WorkDir"    "Temp folder for archives"
    &$NN $R ""
    &$NN $R "Example launch:" $cD
    $R.SelectionColor=$cG
    $R.AppendText(" powershell -File adbcm.v8.61.ps1 -ToolsPath C:\Tools`r`n")
    &$SH $R "MEDIA PREVIEW  (Android)"
    &$NN $R "DblClick video/photo/audio on Android panel"
    &$NN $R "-> pulled to %TEMP%, opened with system app"
    &$NN $R "Files > 500 MB require confirmation" $cW
    &$SH $R "FILE COLORS"
    $cp=@(
        @("Cyan",    "Executables",[System.Drawing.Color]::FromArgb(0,255,255)),
        @("Green",   "Text files",[System.Drawing.Color]::FromArgb(0,160,0)),
        @("Blue",    "Media files",[System.Drawing.Color]::FromArgb(80,150,255)),
        @("Purple",  "APK packages",[System.Drawing.Color]::FromArgb(200,115,255)),
        @("Lt.Green","Archives",[System.Drawing.Color]::FromArgb(0,255,0)),
        @("White",   "Directories",[System.Drawing.Color]::FromArgb(255,255,255)),
        @("Yellow",  "Marked items",[System.Drawing.Color]::FromArgb(255,222,40)),
        @("Gray",    "Other files",[System.Drawing.Color]::FromArgb(150,148,142)))
    foreach($p in $cp){
        $R.SelectionFont=$fN;$R.SelectionColor=$p[2]
        $R.AppendText((" {0,-10}"-f $p[0]))
        $R.SelectionColor=$cD;$R.AppendText("$($p[1])`r`n")}

    &$SH $R "DOCUMENTATION & SOURCE"
    $R.SelectionFont=$fN;$R.SelectionColor=$cU
    $R.AppendText(" https://github.com/Varsett/QuasADBCommander`r`n")
    $R.SelectionColor=$cD
    $R.AppendText(" README_EN.md  |  README_RU.md`r`n")
    $R.AppendText("`r`n (c) 2026 Varset / QUAS toolkit`r`n")
    $L.SelectionStart=0;$L.ScrollToCaret()
    $R.SelectionStart=0;$R.ScrollToCaret()
    $d.ShowDialog()
    (Get-ALV).Focus()}


# ADB status timer
$adbT=New-Object System.Windows.Forms.Timer
$adbT.Interval=3000
$adbT.Add_Tick({
    if(-not $script:AdbAvailable){Set-Status "adb.exe not found - place it next to the script" "Red";return}
    try{
        $psi9=New-Object System.Diagnostics.ProcessStartInfo
        $psi9.FileName=$envAdb;$psi9.Arguments="devices"
        $psi9.UseShellExecute=$false;$psi9.CreateNoWindow=$true
        $psi9.RedirectStandardOutput=$true;$psi9.RedirectStandardError=$true
        $p9=New-Object System.Diagnostics.Process;$p9.StartInfo=$psi9
        [void]$p9.Start()
        $devOut=$p9.StandardOutput.ReadToEnd()
        $p9.WaitForExit()
        $dev=@($devOut -split "`r?`n"|Where-Object{$_ -match "`tdevice$"})
        if($dev.Count -gt 0){
            $serial=($dev[0] -split "`t")[0].Trim()
            Set-Status "CONNECTED: $serial" "Green"
        }else{Set-Status "DISCONNECTED - Check USB" "Red"}
    }catch{Set-Status "ADB error: $_" "Red"}
})
$adbT.Start()

$lvPC.Add_Enter({$lvPC.BackColor=$bgActive;$lvADB.BackColor=$bgInact;$form.Refresh()})
$lvADB.Add_Enter({$lvADB.BackColor=$bgActive;$lvPC.BackColor=$bgInact;$form.Refresh()})
$form.Add_FormClosed({$adbT.Stop();[System.Windows.Forms.Application]::Exit()})

$form.Add_KeyDown({param($s,$e)
    if($e.KeyCode -eq "Tab"){$e.SuppressKeyPress=$true
        if($form.ActiveControl -eq $lvPC){$lvADB.Focus()}else{$lvPC.Focus()}
        $form.Refresh()}
    if($e.KeyCode -eq "Space"){
        $lv=$form.ActiveControl
        if($lv -is [System.Windows.Forms.ListView]){
            $item=Get-SelI $lv
            if($null -ne $item -and $item.Tag -ne "__GOUP__" -and $item.Tag -ne "__ARCHCLOSE__"){
                $ti=Get-ItemTag $item
                if($global:SelectedPaths.Contains($ti.Path)){$global:SelectedPaths.Remove($ti.Path)|Out-Null}
                else{[void]$global:SelectedPaths.Add($ti.Path)}
                $lv.Invalidate()}}}
    if($e.KeyCode -eq "Multiply"){
        $lv=$form.ActiveControl
        if($lv -is [System.Windows.Forms.ListView]){
            $allP=@($lv.Items|Where-Object{$_.Tag -ne "__GOUP__" -and $_.Tag -ne "__ARCHCLOSE__" -and $null -ne $_.Tag}|ForEach-Object{(Get-ItemTag $_).Path}|Where-Object{$_})
            $allSel=$true
            foreach($pp in $allP){if(-not $global:SelectedPaths.Contains($pp)){$allSel=$false;break}}
            if($allSel){$global:SelectedPaths.Clear()}
            else{foreach($pp in $allP){[void]$global:SelectedPaths.Add($pp)}}
            $lv.Invalidate()}}
    if($e.Alt -and $e.KeyCode -eq "X"){$form.Close()}
    if($e.KeyCode -eq "Return"){&$navAction}
    if($e.KeyCode -eq "F2"){Rename-Action}
    if($e.KeyCode -eq "F3"){Search-Action}
    if($e.KeyCode -eq "F4"){Edit-Action}
    if($e.KeyCode -eq "F5"){Copy-Action}
    if($e.KeyCode -eq "F6"){Move-Action}
    if($e.KeyCode -eq "F7"){NewDir-Action}
    if($e.KeyCode -eq "F8" -or $e.KeyCode -eq "Delete"){Delete-Action}
    if($e.KeyCode -eq "F9"){Go-Data}
    if($e.KeyCode -eq "F10"){$e.SuppressKeyPress=$true;Go-Obb}
    if($e.KeyCode -eq "F12"){$e.SuppressKeyPress=$true;Show-LogSettings}
})

$form.Add_Load({Do-Resize;Refresh-Panel "PC";Refresh-Panel "ADB";$lvPC.Focus()})

$form.Add_Shown({
    $form.WindowState="Normal"
    $form.BringToFront();$form.Activate();$lvPC.Focus()
    $script:fgTimer=New-Object System.Windows.Forms.Timer
    $script:fgTimer.Interval=10
    $script:fgTimer.Add_Tick({
        $script:fgTimer.Stop();$script:fgTimer.Dispose();$script:fgTimer=$null
        try{
            [FgWin32]::ForceToForeground($form.Handle)
            $form.TopMost=$true
            $form.Activate()
            $script:fgTimer2=New-Object System.Windows.Forms.Timer
            $script:fgTimer2.Interval=5
            $script:fgTimer2.Add_Tick({
                $script:fgTimer2.Stop();$script:fgTimer2.Dispose();$script:fgTimer2=$null
                $form.TopMost=$false
                [FgWin32]::ForceToForeground($form.Handle)
                $form.Activate()
                $lvPC.Focus()
            })
            $script:fgTimer2.Start()
        }catch{$form.Activate();$lvPC.Focus()}
    })
    $script:fgTimer.Start()
})


[System.Windows.Forms.Application]::Run($form)

# Пауза перед выходом для просмотра логов
#Write-Host "`nScript finished. Press key for exit"
#$null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")