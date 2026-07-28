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

[Console]::OutputEncoding=[System.Text.Encoding]::UTF8

$scriptDir=if($PSScriptRoot){$PSScriptRoot}else{Split-Path $MyInvocation.MyCommand.Path -Parent}
# WorkDir: temp folder for archive operations
$script:WorkDir=if($WorkDir -ne ""){$WorkDir}else{$env:TEMP}
# Clean leftover temp dirs older than 1 hour
Get-ChildItem $script:WorkDir -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^[0-9a-f]{32}$' -and $_.LastWriteTime -lt (Get-Date).AddHours(-1)}|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
if(-not(Test-Path $script:WorkDir)){New-Item -ItemType Directory -Path $script:WorkDir -Force|Out-Null}
# ToolsPath: folder with adb.exe, aapt2.exe, 7z.exe
$script:ToolsPath=if($ToolsPath -ne ""){$ToolsPath}else{$scriptDir}
function Find-Tool{param([string]$n)
    # 1. ToolsPath param (set from -ToolsPath argument)
    if($script:ToolsPath -ne ""){$l=Join-Path $script:ToolsPath $n;if(Test-Path $l){return $l}}
    # 2. Script directory
    $l2=Join-Path $scriptDir $n;if(Test-Path $l2){return $l2}
    # 3. myfiles env variable
    $ev=[Environment]::GetEnvironmentVariable("myfiles","Process")
    if($ev){$p=if(Test-Path $ev -PathType Container){Join-Path $ev $n}else{$ev};if(Test-Path $p){return $p}}
    return $n}
$envAdb=Find-Tool "adb.exe"; $envAapt2=Find-Tool "aapt2.exe"; $env7z=Find-Tool "7z.exe"
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
$extText=@("txt","log","cfg","ini","conf","xml","json","yaml","yml","md","csv","nfo","inf","reg","sh","bash")
$extMedia=@("mp4","mkv","avi","mov","wmv","flv","webm","jpg","jpeg","png","gif","bmp","webp","svg","mp3","wav","flac","aac","ogg")

function Get-FileType{param([string]$n)
    $leaf=($n.TrimEnd("/") -split "[/\\]")[-1];$e="";$dot=$leaf.LastIndexOf(".")
    if($dot -ge 0){$e=$leaf.Substring($dot+1).ToLower()}
    $archExts2=@("zip","7z","rar","gz","tar","bz2","xz","cab","iso","tgz","tbz2","z01","z02","z03","z04","z05")
    if($archExts2-contains $e){return "arch"}
    # Multivolume: .001 .002 ... or .partN.rar pattern
    if($e -match "^[0-9]{2,3}$"){return "arch"}
    if($n -match "\.part[0-9]+\.rar$"){return "arch"}
    if($extExec-contains $e){return "exec"};if($extText-contains $e){return "text"}
    if($extMedia-contains $e){return "media"};if($e-eq "apk"){return "apk"}
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
    try{return @{Enc=[System.Text.Encoding]::GetEncoding(1251);Name="Windows-1251"}}catch{return @{Enc=[System.Text.Encoding]::Default;Name="Default"}}}
function Get-EncFromName{param([string]$n)
    switch($n){"UTF-8"{return New-Object System.Text.UTF8Encoding($false)}"UTF-8 with BOM"{return New-Object System.Text.UTF8Encoding($true)}
        "Windows-1251"{try{return [System.Text.Encoding]::GetEncoding(1251)}catch{return [System.Text.Encoding]::UTF8}}
        "Windows-1252"{try{return [System.Text.Encoding]::GetEncoding(1252)}catch{return [System.Text.Encoding]::UTF8}}
        "OEM 866"{try{return [System.Text.Encoding]::GetEncoding(866)}catch{return [System.Text.Encoding]::UTF8}}
        "ASCII"{return [System.Text.Encoding]::ASCII}default{return New-Object System.Text.UTF8Encoding($false)}}}

# Syntax highlight - named function, only uses params and $script:
function Apply-SyntaxHighlight{param($tx,[string]$ext,[int]$maxLines=3000)
    $ext=$ext.ToLower()
    $supported=@("ps1","bat","cmd","sh","bash","ini","cfg","conf","log","nfo")
    if($ext -notin $supported){return}
    $wasEdModified=$script:EdModified
    $wasTitle=if($null -ne $script:EdForm){$script:EdForm.Text}else{""}
    $script:EdHighlighting=$true
    $tx.SuspendLayout()
    $sp=$tx.SelectionStart;$sl=$tx.SelectionLength
    $tx.SelectAll();$tx.SelectionColor=$clrText;$tx.SelectionBackColor=$tx.BackColor;$tx.Select(0,0)
    $full=$tx.Text
    $cKw  =[System.Drawing.Color]::FromArgb(86,156,214)
    $cStr =[System.Drawing.Color]::FromArgb(206,145,120)
    $cCmt =[System.Drawing.Color]::FromArgb(106,153,85)
    $cVar =[System.Drawing.Color]::FromArgb(64,216,182)
    $cNum =[System.Drawing.Color]::FromArgb(181,206,168)
    $cOp  =[System.Drawing.Color]::FromArgb(200,180,100)
    $cEcho=[System.Drawing.Color]::FromArgb(210,190,80)
    $cSec =[System.Drawing.Color]::FromArgb(78,201,176)
    $cKey =[System.Drawing.Color]::FromArgb(156,220,254)
    $cVal =[System.Drawing.Color]::FromArgb(220,220,170)
    $cErr =[System.Drawing.Color]::FromArgb(220,80,80)
    $cWrn =[System.Drawing.Color]::FromArgb(220,160,50)
    $cInf =[System.Drawing.Color]::FromArgb(100,180,100)
    $cDbg =[System.Drawing.Color]::FromArgb(130,130,150)
    $cVarB=[System.Drawing.Color]::FromArgb(180,220,100)
    $cVarB=[System.Drawing.Color]::FromArgb(180,220,100)
    if($ext -eq "ps1"){
        $kwList=@("function","param","if","else","elseif","foreach","for","while","do","switch","return","break","continue","try","catch","finally","throw","class","end","begin","process","filter","trap","exit","in","using","namespace")
        $opList=@("-eq","-ne","-lt","-gt","-le","-ge","-like","-notlike","-match","-notmatch","-contains","-notcontains","-in","-notin","-and","-or","-not","-xor","-band","-bor","-bnot")
    }elseif($ext -in @("bat","cmd")){
        $kwList=@("if","else","for","do","goto","call","set","pause","not","exist","defined","shift","pushd","popd","move","copy","del","mkdir","rmdir","cls","exit","dir","type","find","findstr","setlocal","endlocal","enabledelayedexpansion","disabledelayedexpansion")
        $opList=@()
    }elseif($ext -in @("sh","bash")){
        $kwList=@("if","then","else","elif","fi","for","do","done","while","until","case","esac","function","return","break","continue","exit","export","local","readonly","source","echo","printf","read","shift","set","unset","trap")
        $opList=@()
    }else{$kwList=@();$opList=@()}
    $linesArr=$full -split "`n"
    $charPos=0;$lineCount=0
    foreach($ln in $linesArr){
        $lineCount++;if($lineCount -gt $maxLines){break}
        $llen=$ln.Length;$trimmed=$ln.TrimStart()
        # INI/CFG/CONF
        if($ext -in @("ini","cfg","conf")){
            if($trimmed.StartsWith("[") -and $trimmed.Contains("]")){$tx.Select($charPos,$llen);$tx.SelectionColor=$cSec;$charPos+=$llen+1;continue}
            if($trimmed.StartsWith(";") -or $trimmed.StartsWith("#")){$tx.Select($charPos,$llen);$tx.SelectionColor=$cCmt;$charPos+=$llen+1;continue}
            $eq=$ln.IndexOf("=");if($eq -gt 0){$tx.Select($charPos,$eq);$tx.SelectionColor=$cKey;$tx.Select($charPos+$eq,$llen-$eq);$tx.SelectionColor=$cVal}
            $charPos+=$llen+1;continue}
        # LOG/NFO
        if($ext -in @("log","nfo")){
            $up=$trimmed.ToUpper()
            if($up -match "ERROR|FAIL|FATAL|CRITICAL"){$tx.Select($charPos,$llen);$tx.SelectionColor=$cErr;$charPos+=$llen+1;continue}
            if($up -match "WARN(ING)?"){$tx.Select($charPos,$llen);$tx.SelectionColor=$cWrn;$charPos+=$llen+1;continue}
            if($up -match "INFO|OK|SUCCESS|DONE|COMPLETE"){$tx.Select($charPos,$llen);$tx.SelectionColor=$cInf;$charPos+=$llen+1;continue}
            if($up -match "DEBUG|TRACE|VERBOSE"){$tx.Select($charPos,$llen);$tx.SelectionColor=$cDbg;$charPos+=$llen+1;continue}
            $charPos+=$llen+1;continue}
        # Scripts: full-line comments
        $isCmt=$false
        if($ext -in @("bat","cmd") -and ($trimmed -match "(?i)^rem($|\s)" -or $trimmed.StartsWith("::"))){$isCmt=$true}
        elseif($ext -in @("sh","bash","ps1") -and $trimmed.StartsWith("#")){$isCmt=$true}
        if($isCmt){$tx.Select($charPos,$llen);$tx.SelectionColor=$cCmt;$charPos+=$llen+1;continue}
        # Echo/print full lines
        $isEcho=$false
        if($ext -in @("bat","cmd") -and $trimmed -match "(?i)^echo($|\s)"){$isEcho=$true}
        if($ext -eq "ps1" -and $trimmed -match "(?i)^(Write-Host|Write-Output|Write-Warning|Write-Error|Write-Verbose)($|\s)"){$isEcho=$true}
        if($isEcho){$tx.Select($charPos,$llen);$tx.SelectionColor=$cEcho;$charPos+=$llen+1;continue}
        # Inline comment (ps1)
        if($ext -eq "ps1"){$ci=$ln.IndexOf(" #");if($ci -ge 0 -and $ci -lt $llen-1){$tx.Select($charPos+$ci+1,$llen-$ci-1);$tx.SelectionColor=$cCmt}}
        # Double-quoted strings
        $si=0;while($si -lt $llen){$qi=$ln.IndexOf("`"",$si);if($qi -lt 0){break}
            $qi2=$ln.IndexOf("`"",$qi+1);if($qi2 -lt 0){$qi2=$llen-1}
            $tx.Select($charPos+$qi,$qi2-$qi+1);$tx.SelectionColor=$cStr;$si=$qi2+1}
        # Single-quoted strings
        if($ext -in @('ps1','sh','bash')){$si=0;while($si -lt $llen){
            $qi=$ln.IndexOf("'",$si);if($qi -lt 0){break}
            $qi2=$ln.IndexOf("'",$qi+1);if($qi2 -lt 0){$qi2=$llen-1}
            $tx.Select($charPos+$qi,$qi2-$qi+1);$tx.SelectionColor=$cStr;$si=$qi2+1}}
        # Variables $var
        if($ext -in @('ps1','sh','bash')){$si=0;while($si -lt $llen){
            $vi=$ln.IndexOf('$',$si);if($vi -lt 0){break}
            $ve=$vi+1;while($ve -lt $llen -and $ln[$ve] -match '[a-zA-Z0-9_]'){$ve++}
            if($ve -gt $vi+1){$tx.Select($charPos+$vi,$ve-$vi);$tx.SelectionColor=$cVar}
            $si=$ve}}
        # Variables %var% (bat/cmd)
        elseif($ext -in @("bat","cmd")){$si=0;while($si -lt $llen){
            $vi=$ln.IndexOf("%",$si);if($vi -lt 0){break}
            $ve=$ln.IndexOf("%",$vi+1);if($ve -lt 0){break}
            $tx.Select($charPos+$vi,$ve-$vi+1);$tx.SelectionColor=$cVarB;$si=$ve+1}}
        # Keywords
        foreach($kw in $kwList){$si=0;while($si -lt $llen){
            $idx=$ln.IndexOf($kw,$si,[System.StringComparison]::OrdinalIgnoreCase);if($idx -lt 0){break}
            $pre=if($idx -gt 0){$ln[$idx-1]}else{" "};$suf=if($idx+$kw.Length -lt $llen){$ln[$idx+$kw.Length]}else{" "}
            if(-not($pre -match "[a-zA-Z0-9_-]") -and -not($suf -match "[a-zA-Z0-9_-]")){$tx.Select($charPos+$idx,$kw.Length);$tx.SelectionColor=$cKw}
            $si=$idx+$kw.Length}}
        # Operators (ps1)
        foreach($op in $opList){$si=0;while($si -lt $llen){
            $idx=$ln.IndexOf($op,$si,[System.StringComparison]::OrdinalIgnoreCase);if($idx -lt 0){break}
            $suf=if($idx+$op.Length -lt $llen){$ln[$idx+$op.Length]}else{" "}
            if(-not($suf -match "[a-zA-Z0-9]")){$tx.Select($charPos+$idx,$op.Length);$tx.SelectionColor=$cOp}
            $si=$idx+$op.Length}}
        # Numbers
        $si=0;while($si -lt $llen){
            if($ln[$si] -match "[0-9]"){$pre2=if($si -gt 0){$ln[$si-1]}else{" "}
                if(-not($pre2 -match "[a-zA-Z_]")){$ne=$si
                    while($ne -lt $llen -and $ln[$ne] -match "[0-9.]"){$ne++}
                    $tx.Select($charPos+$si,$ne-$si);$tx.SelectionColor=$cNum;$si=$ne;continue}}
            $si++}
        $charPos+=$llen+1}
    $tx.Select($sp,$sl)
    $tx.ResumeLayout()
    # Restore original modified state unconditionally
    $script:EdHighlighting=$false
    $script:EdModified=$wasEdModified
    if($null -ne $script:EdForm){$script:EdForm.Text=$wasTitle}}

function Ed-Save{
    if($null -eq $script:EdTx -or $null -eq $script:EdForm){return}
    try{
        $se=Get-EncFromName $script:EdEncBox.SelectedItem
        [System.IO.File]::WriteAllText($script:EdFilePath,$script:EdTx.Text,$se)
        $script:EdModified=$false
        $script:EdForm.Text="Edit: $($script:EdTitle)"
        $script:EdStEd.Text="  Saved [$($se.WebName)]: $([System.IO.Path]::GetFileName($script:EdFilePath))"
        if($script:EdIsAdb -and $script:EdAdbPath){
            $script:EdStEd.Text="  Pushing...";$script:EdForm.Update()
            & "$envAdb" push "`"$script:EdFilePath`"" "`"$script:EdAdbPath`"" 2>&1 | Out-Null
            $script:EdStEd.Text="  Saved+pushed: $script:EdAdbPath"}}
    catch{if($null -ne $script:EdStEd){$script:EdStEd.Text="  SAVE ERROR: $_"}}}

function Ed-AskSave{
    return [System.Windows.Forms.MessageBox]::Show("Unsaved changes. Save now?","Unsaved",[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Warning)}

function Ed-Close{
    if($null -eq $script:EdForm){return}
    if($script:EdModified){$r=Ed-AskSave
        if($r -eq [System.Windows.Forms.DialogResult]::Yes){Ed-Save;$script:EdClosed=$true;$script:EdForm.Close()}
        elseif($r -eq [System.Windows.Forms.DialogResult]::No){$script:EdClosed=$true;$script:EdForm.Close()}
    }else{$script:EdClosed=$true;$script:EdForm.Close()}}

function Ed-ToggleWrap{
    if($null -eq $script:EdTx){return}
    $script:EdWrapOn=-not $script:EdWrapOn
    if($script:EdWrapOn){$script:EdTx.WordWrap=$true;$script:EdTx.ScrollBars="Vertical"
        if($null -ne $script:EdBWrap){$script:EdBWrap.Text="Wrap:ON";$script:EdBWrap.ForeColor=$clrGold}
    }else{$script:EdTx.WordWrap=$false;$script:EdTx.ScrollBars="Both"
        if($null -ne $script:EdBWrap){$script:EdBWrap.Text="Wrap:OFF";$script:EdBWrap.ForeColor=$clrDim}}}

function Ed-Search{param([string]$q)
    if($null -eq $script:EdTx -or $q.Length -lt 3){return 0}
    $full=$script:EdTx.Text;$n2=0;$pos2=0
    $script:EdTx.SelectAll();$script:EdTx.SelectionBackColor=$script:EdTx.BackColor;$script:EdTx.SelectionColor=$clrText;$script:EdTx.Select(0,0)
    while($true){$idx=$full.IndexOf($q,$pos2,[System.StringComparison]::OrdinalIgnoreCase);if($idx -lt 0){break}
        $script:EdTx.Select($idx,$q.Length);$script:EdTx.SelectionBackColor=[System.Drawing.Color]::FromArgb(255,220,0);$script:EdTx.SelectionColor=[System.Drawing.Color]::Black
        $pos2=$idx+1;$n2++}
    if($n2 -gt 0){$script:EdTx.Select($full.IndexOf($q,0,[System.StringComparison]::OrdinalIgnoreCase),$q.Length);$script:EdTx.ScrollToCaret()}
    return $n2}

function Set-Status{param([string]$t,[string]$col="Gray")
    $c=switch($col){"Green"{[System.Drawing.Color]::FromArgb(88,200,108)}"Red"{[System.Drawing.Color]::FromArgb(210,88,78)}default{$clrDim}}
    $stBar.Text=$t;$stBar.ForeColor=$c;$form.Update()}
function Add-Log{param([string]$t,[string]$col="Gray")
    Set-Status $t $col
    $entry="[$([System.DateTime]::Now.ToString("HH:mm:ss"))] $t"
    if($logBox.Items.Count -gt 300){$logBox.Items.RemoveAt(0)}
    $logBox.Items.Add($entry)|Out-Null
    if(-not $script:LogPaused){$logBox.TopIndex=$logBox.Items.Count-1}}

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
function Show-TextEditor{param([string]$FilePath,[string]$Title,[bool]$IsAdb=$false,[string]$AdbPath="")
    $script:EdFilePath=$FilePath;$script:EdTitle=$Title;$script:EdIsAdb=$IsAdb;$script:EdAdbPath=$AdbPath
    $script:EdModified=$false;$script:EdClosed=$false;$script:EdHlOn=$false;$script:EdWrapOn=$false;$script:EdHighlighting=$false
    $dotIdx=$Title.LastIndexOf(".");$script:EdFileExt=if($dotIdx -ge 0){$Title.Substring($dotIdx+1).ToLower()}else{""}
    $ed=New-Object System.Windows.Forms.Form;$ed.Text="Edit: $Title";$ed.Size="980,740";$ed.MinimumSize="500,400"
    $ed.BackColor=$bgForm;$ed.ForeColor=$clrText;$ed.StartPosition="CenterParent";$ed.FormBorderStyle="Sizable";$ed.KeyPreview=$true
    $ed.GetType().GetProperty("DoubleBuffered",[System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic).SetValue($ed,$true,$null)
    $script:EdForm=$ed
    $tb=New-Object System.Windows.Forms.Panel;$tb.Dock="Top";$tb.Height=38;$tb.BackColor=[System.Drawing.Color]::FromArgb(34,34,40);$ed.Controls.Add($tb)
    $mkB={param([string]$t2,[int]$x2,[int]$w2=118)
        $b=New-Object System.Windows.Forms.Button;$b.Text=$t2
        $b.Location=New-Object System.Drawing.Point($x2,5);$b.Size=New-Object System.Drawing.Size($w2,28)
        $b.FlatStyle="Flat";$b.ForeColor=$clrText;$b.BackColor=[System.Drawing.Color]::FromArgb(52,52,60)
        $b.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(78,78,88);$tb.Controls.Add($b);return $b}
    $bSave=&$mkB "Save Ctrl+S" 8;$bSaveC=&$mkB "Save+Close" 134;$bClose=&$mkB "Close Esc" 252
    $bWrap=&$mkB "Wrap:OFF" 374 80;$bWrap.ForeColor=$clrDim;$bWrap.BackColor=[System.Drawing.Color]::FromArgb(44,44,52)
    $script:EdBWrap=$bWrap
        $encLbl=New-Object System.Windows.Forms.Label;$encLbl.Text="Enc:";$encLbl.Location="548,10";$encLbl.Size="36,18";$encLbl.ForeColor=$clrDim;$tb.Controls.Add($encLbl)
    $encBox=New-Object System.Windows.Forms.ComboBox;$encBox.Location="586,7";$encBox.Size="180,24"
    $encBox.BackColor=[System.Drawing.Color]::FromArgb(52,52,60);$encBox.ForeColor=$clrText;$encBox.DropDownStyle="DropDownList"
    @("UTF-8","UTF-8 with BOM","Windows-1251","Windows-1252","OEM 866","ASCII")|ForEach-Object{$encBox.Items.Add($_)|Out-Null}
    $encBox.SelectedIndex=0;$tb.Controls.Add($encBox);$script:EdEncBox=$encBox
    $sbP=New-Object System.Windows.Forms.Panel;$sbP.Dock="Top";$sbP.Height=32;$sbP.BackColor=[System.Drawing.Color]::FromArgb(28,28,34);$ed.Controls.Add($sbP)
    $sbBox=New-Object System.Windows.Forms.TextBox;$sbBox.Location="8,5";$sbBox.Size="260,22"
    $sbBox.BackColor=[System.Drawing.Color]::FromArgb(50,50,58);$sbBox.ForeColor=$clrText;$sbBox.BorderStyle="FixedSingle";$sbP.Controls.Add($sbBox)
    $sbLbl=New-Object System.Windows.Forms.Label;$sbLbl.Location="278,7";$sbLbl.Size="340,20";$sbLbl.ForeColor=$clrDim;$sbP.Controls.Add($sbLbl)
    $stEd=New-Object System.Windows.Forms.Label;$stEd.Dock="Bottom";$stEd.Height=22
    $stEd.BackColor=[System.Drawing.Color]::FromArgb(26,26,32);$stEd.ForeColor=$clrDim
    $stEd.TextAlign="MiddleLeft";$stEd.Padding=New-Object System.Windows.Forms.Padding(8,0,0,0);$ed.Controls.Add($stEd);$script:EdStEd=$stEd
    $tx=New-Object System.Windows.Forms.RichTextBox;$tx.Dock="Fill";$tx.BorderStyle="None";$tx.AcceptsTab=$true
    $tx.BackColor=[System.Drawing.Color]::FromArgb(24,24,28);$tx.ForeColor=$clrText
    $tx.Font=$fntEd;$tx.ScrollBars="Both";$tx.WordWrap=$false;$ed.Controls.Add($tx);$tx.BringToFront()
    $script:EdTx=$tx
    $edCtx=New-Object System.Windows.Forms.ContextMenuStrip;$edCtx.ShowImageMargin=$false
    $edCtx.BackColor=[System.Drawing.Color]::FromArgb(44,44,52);$edCtx.ForeColor=$clrText
    $miCp=New-Object System.Windows.Forms.ToolStripMenuItem("Copy");$miCp.BackColor=[System.Drawing.Color]::FromArgb(44,44,52);$miCp.ForeColor=$clrText;$miCp.Add_Click({$script:EdTx.Copy()})
    $miPs=New-Object System.Windows.Forms.ToolStripMenuItem("Paste");$miPs.BackColor=[System.Drawing.Color]::FromArgb(44,44,52);$miPs.ForeColor=$clrText;$miPs.Add_Click({$script:EdTx.Paste()})
    $edCtx.Items.AddRange(@($miCp,$miPs));$tx.ContextMenuStrip=$edCtx
    # Load file
    $edBytes=$null
    try{$edBytes=[System.IO.File]::ReadAllBytes($FilePath)
        $det=Detect-Encoding $edBytes
        $tx.Text=$det.Enc.GetString($edBytes)
        if($encBox.Items.Contains($det.Name)){$encBox.SelectedItem=$det.Name}else{$encBox.SelectedIndex=0}
        $stEd.Text="  $FilePath  [$($det.Name)]"
        # Auto-apply syntax highlight for supported types
        if($script:EdFileExt -in @("ps1","bat","cmd","sh","bash","ini","cfg","conf","log","nfo")){Apply-SyntaxHighlight $tx $script:EdFileExt}
    }catch{$tx.Text="ERROR: $_"}
    # FIX TextChanged: $ed captured in closure here is valid; use $script:EdForm for title
    $tx.Add_TextChanged({
        if($script:EdHighlighting){return}  # ignore changes during syntax highlight
        $script:EdModified=$true
        if($null -ne $script:EdForm -and -not $script:EdForm.Text.StartsWith("* ")){$script:EdForm.Text="* "+$script:EdForm.Text}})
    # Buttons - all call named Ed-* functions
    $bSave.Add_Click({Ed-Save})
    $bSaveC.Add_Click({Ed-Save;$script:EdClosed=$true;if($null -ne $script:EdForm){$script:EdForm.Close()}})
    $bClose.Add_Click({Ed-Close})
    $bWrap.Add_Click({Ed-ToggleWrap})
    # Encoding change - $edBytes captured in closure, valid for lifetime of editor
    $encBox.Add_SelectedIndexChanged({
        if($null -eq $edBytes){return}
        $enc2=Get-EncFromName $script:EdEncBox.SelectedItem
        $wasM=$script:EdModified
        $script:EdTx.Text=$enc2.GetString($edBytes)
        $script:EdModified=$wasM
        if(-not $wasM -and $null -ne $script:EdForm){$script:EdForm.Text="Edit: $($script:EdTitle)"}
        $script:EdStEd.Text="  $FilePath  [$($script:EdEncBox.SelectedItem)]"})
    # Search - $sbLbl and $sbBox captured in closure; sbLbl is a local panel label
    $sbBox.Add_TextChanged({
        $q=$sbBox.Text
        if($q.Length -lt 3){$sbLbl.Text="";return}
        $n2=Ed-Search $q
        $sbLbl.Text=if($n2 -gt 0){"  $n2 found"}else{"  not found"}})
    # FormClosing
    $ed.Add_FormClosing({param($s,$ev)
        if($script:EdClosed){return}
        if($script:EdModified){$r=Ed-AskSave
            if($r -eq [System.Windows.Forms.DialogResult]::Yes){Ed-Save}
            elseif($r -eq [System.Windows.Forms.DialogResult]::Cancel){$ev.Cancel=$true}
            else{$script:EdClosed=$true}}})
    # KeyDown on $tx: Ctrl+S and Esc
    $tx.Add_KeyDown({param($s,$ev)
        if($ev.Control -and $ev.KeyCode -eq "S"){Ed-Save;$ev.SuppressKeyPress=$true}
        if($ev.KeyCode -eq "Escape"){Ed-Close;$ev.SuppressKeyPress=$true}})
    # KeyDown on form: F2
    $ed.Add_KeyDown({param($s,$ev)
        if($ev.KeyCode -eq "F2" -and -not $ev.Control -and -not $ev.Alt){Ed-Save;$ev.SuppressKeyPress=$true}
        if($ev.KeyCode -eq "Escape"){Ed-Close;$ev.SuppressKeyPress=$true}})
    $ed.Show($form);$ed.BringToFront();$ed.Activate()}

# MAIN FORM
$form=New-Object System.Windows.Forms.Form;$form.Text="Quas ADB Commander v8.25"
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
$logBox=New-Object System.Windows.Forms.ListBox;$logBox.Location="15,550";$logBox.Size="1020,78"
$logBox.BackColor=[System.Drawing.Color]::FromArgb(18,18,22);$logBox.ForeColor=$clrDim
$logBox.Font=New-Object System.Drawing.Font("Consolas",8.5);$logBox.BorderStyle="None";$logBox.TabStop=$false;$logBox.SelectionMode="One"
$form.Controls.Add($logBox)
$logBox.Add_MouseDown({$script:LogPaused=$true})
$logBox.Add_KeyDown({param($s,$e);if($e.Control -and $e.KeyCode -eq "C" -and $logBox.SelectedItem){try{[System.Windows.Forms.Clipboard]::SetText($logBox.SelectedItem.ToString())}catch{}}})
$logCtx=New-Object System.Windows.Forms.ContextMenuStrip;$logCtx.ShowImageMargin=$false
$miLC=New-Object System.Windows.Forms.ToolStripMenuItem("Copy line");$miLC.Add_Click({if($logBox.SelectedItem){try{[System.Windows.Forms.Clipboard]::SetText($logBox.SelectedItem.ToString())}catch{}}})
$miLS=New-Object System.Windows.Forms.ToolStripMenuItem("Scroll to bottom");$miLS.Add_Click({$script:LogPaused=$false;if($logBox.Items.Count -gt 0){$logBox.TopIndex=$logBox.Items.Count-1}})
$miLX=New-Object System.Windows.Forms.ToolStripMenuItem("Clear log");$miLX.Add_Click({$logBox.Items.Clear()})
$logCtx.Items.AddRange(@($miLC,$miLS,$miLX));$logBox.ContextMenuStrip=$logCtx

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
function Install-Apk{param([string]$apkPath)
    $apkN=Split-Path $apkPath -Leaf;$pkg=$null
    if(Test-Path $envAapt2){Set-Status "Reading package info...";$pkg=Get-AaptPkg $apkPath}
    $info=@("File: $apkN");if($pkg){$info+="Package: $pkg"}else{$info+="Package: (aapt2 not found)"}
    $obbDir=$null
    if($pkg){$cand=Join-Path(Split-Path $apkPath -Parent) $pkg;if(Test-Path $cand -PathType Container){$obbDir=$cand;$info+="OBB: $pkg -> /Android/obb/"}}
    if($null -eq (Show-AdbDialog "Install APK" "Install APK on device?" $null $info)){return}
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
    Remove-Item $tmp -ErrorAction SilentlyContinue;Set-Status "READY"}
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
        $goUp=New-Object System.Windows.Forms.ListViewItem(".. [Go Up]")
        $goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("")|Out-Null;$goUp.SubItems.Add("0")|Out-Null;$goUp.Tag="__GOUP__";$lv.Items.Add($goUp)|Out-Null
        $dirs=@();$files=@()
        $lsOut=& "$envAdb" shell ('ls -F '+(Escape-AdbShell $currentAdbPath))
        foreach($entry in $lsOut){
            $r=($entry -replace "`r","").Trim()
            if(-not $r){continue}
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
","").Trim();if(-not $l){continue}
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
        Set-Status "Pulling archive from Android..."
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
                Set-Status "Creating dir ($idx/$total): $($pd.Name)"
            }
            foreach($pf in $allFiles){
                $idx++
                $rel=$pf.FullName.Substring($tmpDir.Length+1) -replace "\\","/"
                $pdest="$adbDest/$rel"
                Set-Status "Pushing ($idx/$total): $($pf.Name)"
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
    $tmpDir=Join-Path $script:WorkDir "adbfm_arch"
    New-Item -ItemType Directory -Path $tmpDir -Force|Out-Null
    Set-Status "Extracting $fn from archive..."
    $listFile=Join-Path $script:WorkDir "adbfm_open.txt"
    [System.IO.File]::WriteAllLines($listFile,@($innerPath),[System.Text.Encoding]::UTF8)
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$env7z
    $psi.Arguments="e `"$archPath`" @`"$listFile`" -o`"$tmpDir`" -aoa -y"
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi;[void]$proc.Start()
    $proc.WaitForExit()
    Remove-Item $listFile -ErrorAction SilentlyContinue
    $tmpFile=Join-Path $tmpDir $fn
    if(Test-Path $tmpFile){
        $ft2=Get-FileType $fn
        if($ft2 -eq "media"){Start-Process $tmpFile;Add-Log "Opened media from archive: $fn"}
        else{Show-TextEditor $tmpFile $fn $false "";Add-Log "Opened from archive: $fn"}
    }else{Add-Log "Failed to extract: $fn (exit=$($proc.ExitCode))" "Red"}}

function Preview-AdbMedia{param([string]$rp,[string]$fn,[long]$sz)
    $maxBytes=500MB
    if($sz -gt $maxBytes){
        $mb=[int]($sz/1MB)
        $r=Show-AdbDialog "Large File" "File is $mb MB (limit 500 MB). Download anyway?" $null @($fn)
        if($null -eq $r){return}}
    $tmp=Join-Path $env:TEMP "adbfm_media_$fn"
    Invoke-Pull $rp $env:TEMP $fn $sz
    if(Test-Path $tmp){Start-Process $tmp;Add-Log "Opened media: $fn"}
    else{Add-Log "Failed to pull media: $fn" "Red"}}


$navAction={
    $lv=Get-ALV;$item=Get-SelI $lv;if($null -eq $item){return}
    $ti=Get-ItemTag $item;$clean=$item.Text
    # Archive virtual navigation
    if($item.Tag -eq "__ARCHCLOSE__"){
        if($script:ArchiveSubDir -ne ""){
            $parts2=$script:ArchiveSubDir -split "/"
            if($parts2.Count -gt 1){$script:ArchiveSubDir=($parts2[0..($parts2.Count-2)]) -join "/"}
            else{$script:ArchiveSubDir=""}
            Refresh-ArchPanel;$lv.Focus();return}
        $savedArchName=$script:ArchiveName
        $script:ArchivePath=""
        if($lv -eq $lvPC){Refresh-Panel "PC"}else{Refresh-Panel "ADB"}
        if($savedArchName -and $savedArchName -ne ""){Find-Sel $lv $savedArchName}
        $lv.Focus();return}
    if($null -ne $item.Tag -and ([string]$item.Tag).StartsWith("ARCH:")){
        $innerPath2=([string]$item.Tag).Substring(5)
        # Check if dir - navigate into it
        $archItems2=List-Archive $script:ArchivePath $script:ArchiveSubDir
        $isArchDir2=$false
        foreach($ai2 in $archItems2){if($ai2.InnerPath -eq $innerPath2 -and $ai2.IsDir){$isArchDir2=$true;break}}
        if($isArchDir2){$script:ArchiveSubDir=$innerPath2;Refresh-ArchPanel;$lv.Focus();return}
        # File: open in editor or media player
        $ft2=Get-FileType $clean
        if($ft2 -eq "media" -or $ft2 -eq "text" -or $clean -match "\.(ps1|bat|cmd|sh|bash|ini|cfg|conf|log|nfo)$"){
            Open-ArchiveItem $lv $item}
        $lv.Focus();return}
    # Normal PC navigation
    if($lv -eq $lvPC -and $clean -match "\.apk$" -and -not $ti.IsDir -and $currentLocalPath -ne "DRIVES"){Install-Apk $ti.Path;$lv.Focus();return}
    if($lv -eq $lvPC -and $currentLocalPath -ne "DRIVES" -and -not $ti.IsDir){$ft=Get-FileType $clean
        if($ft -eq "arch"){
            if(Is-MultipartNotFirst $ti.Path){
                $first=Get-ArchiveFirstPart $ti.Path
                Add-Log "Multipart archive: opening first part: $(Split-Path $first -Leaf)"
                Open-Archive $first $true
            }else{Open-Archive $ti.Path $true}
            $lv.Focus();return}
        if($ft -eq "exec"){Open-File $ti.Path "run";$lv.Focus();return}
        if($ft -in @("text")){Open-File $ti.Path "open";$lv.Focus();return}
        if($ft -eq "media"){Open-File $ti.Path "open";$lv.Focus();return}}
    # ADB media/archive preview
    if($lv -eq $lvADB -and -not $ti.IsDir){$ft=Get-FileType $clean
        if($ft -eq "media"){
            $szRaw=(& "$envAdb" shell stat -c "%s" "`"$($ti.Path)`"") -replace "`r","";$sz=if($szRaw -match "^[0-9]+$"){[long]$szRaw}else{0L}
            Preview-AdbMedia $ti.Path $clean $sz;$lv.Focus();return}
        if($ft -eq "arch"){
            $tmp=Join-Path $env:TEMP $clean;Set-Status "Pulling archive..."
            & "$envAdb" pull "`"$($ti.Path)`"" "`"$tmp`"" 2>&1 | Out-Null
            if(Test-Path -LiteralPath $tmp){
                $firstPart=Get-ArchiveFirstPart $tmp
                $script:ArchivePath=$firstPart;$script:ArchiveIsPC=$false
                $script:ArchiveName=Split-Path $firstPart -Leaf
                $script:ArchiveSubDir=""
                Refresh-ArchPanel;$lv.Focus();return}}}
    if($ti.Path -eq "__GOUP__"){
        if($lv -eq $lvPC){$fe=Split-Path $currentLocalPath -Leaf;$pp=Split-Path $currentLocalPath -Parent
            $script:currentLocalPath=if(!$pp -or $pp -eq $currentLocalPath){"DRIVES"}else{$pp}
            Refresh-Panel "PC";if($fe){Find-Sel $lvPC $fe}}
        else{$parts=$currentAdbPath.TrimEnd("/").Split("/");$fe=$parts[-1]
            $script:currentAdbPath=($parts[0..($parts.Count-2)] -join "/");if(!$currentAdbPath){$script:currentAdbPath="/"}
            Refresh-Panel "ADB";if($fe){Find-Sel $lvADB $fe}}}
    else{if($lv -eq $lvPC){if($currentLocalPath -eq "DRIVES"){$script:currentLocalPath=$ti.Path;Refresh-Panel "PC"}elseif($ti.IsDir){$script:currentLocalPath=$ti.Path;Refresh-Panel "PC"}}
        else{if($ti.IsDir){$script:currentAdbPath=$ti.Path;Refresh-Panel "ADB"}}}
    $lv.Focus()}
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
        $rawS=& "$envAdb" shell ('find '+(Escape-AdbShell $currentAdbPath)+' -name '+(Escape-AdbShell $query)+' 2>/dev/null')
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
function Ctx-Apk{Install-Apk $script:CtxPath}
# FIX Copy: CtxLVRef set before Show(); Closed fires AFTER click handler, so ref still valid
function Ctx-Unpack{
    $lv=$script:CtxLVRef;$item=$script:CtxItem
    if($null -ne $item){
        # For multipart archives - always start from first part
        $ti=Get-ItemTag $item
        $firstPath=Get-ArchiveFirstPart $ti.Path
        if($firstPath -ne $ti.Path){
            Add-Log "Multipart: using first part: $(Split-Path $firstPath -Leaf)"
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
        try{[System.Windows.Forms.Clipboard]::SetFileDropList($fl);Add-Log "Copied to clipboard: $($global:ClipboardItems.Count) file(s)"}
        catch{Add-Log "Copied: $($global:ClipboardItems.Count) item(s)"}}
    else{Add-Log "Copied: $($global:ClipboardItems.Count) item(s)"}}
function Ctx-Paste{
    $isPC=$script:CtxIsPC
    foreach($ci in $global:ClipboardItems){$fn=Split-Path $ci.Path -Leaf
        if($global:ClipboardIsAdb -and $isPC){
            # ADB -> PC
            $raw=(& "$envAdb" shell stat -c "%s" "`"$($ci.Path)`"") -replace "`r","";$sz=if($raw -match "^[0-9]+$"){[long]$raw}else{0L}
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
                Add-Log "Copied on device: $fn" "Green"
            }else{Add-Log "Skipped (same path): $fn" "Red"}}
        else{
            # PC -> PC (same side)
            $dest=Join-Path $currentLocalPath $fn
            if($dest -ne $ci.Path){
                try{if($ci.IsDir){Copy-Item -LiteralPath $ci.Path -Destination $dest -Recurse -Force}else{Copy-Item -LiteralPath $ci.Path -Destination $dest -Force};Add-Log "Copied: $fn" "Green"}
                catch{Add-Log "Copy failed: $_" "Red"}
            }else{Add-Log "Skipped (same path): $fn" "Red"}}}
    $global:ClipboardItems=@();$global:SelectedPaths.Clear();Refresh-Panel "PC";Refresh-Panel "ADB";Add-Log "Paste done"}
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
    Add-MI "Install APK"            "Ctx-Apk"     ($ft -eq "apk" -and $isPC)
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
            Add-Log "Renamed: $clean -> $new"
        }else{
            $rnDst="$($currentAdbPath.TrimEnd('/'))/$new"
            & "$envAdb" shell "mv '$($ti.Path)' '$rnDst'" 2>&1 | Out-Null
            Refresh-Panel "ADB"
            Add-Log "Renamed: $clean -> $new"
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
                    Set-Status "Creating dir ($idx3/$total3): $($pd3.Name)"
                }
                foreach($pf3 in $allFiles3){
                    $idx3++
                    $rel3=$pf3.FullName.Substring($tmpDir3.Length+1) -replace "\\","/"
                    $pdest3="$adbBase3/$rel3"
                    Set-Status "Pushing ($idx3/$total3): $($pf3.Name)"
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
            $raw=(& "$envAdb" shell stat -c "%s" "`"$($ti.Path)`"") -replace "`r",""
            $sz=if($raw -match "^[0-9]+$"){[long]$raw}else{0L}
            Invoke-Pull $ti.Path $currentLocalPath $it.Text $sz
        }
    }
    $global:SelectedPaths.Clear()
    Refresh-Panel "PC"
    Refresh-Panel "ADB"
    Add-Log "Copy done"
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
        Add-Log "Created: $new"
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
    Add-Log "Deleted: $($names -join ', ')"
    $lv.Focus()
}

function Go-Data{$script:currentAdbPath="/storage/emulated/0/Android/data";Refresh-Panel "ADB";$lvADB.Focus()}
function Go-Obb{$script:currentAdbPath="/storage/emulated/0/Android/obb";Refresh-Panel "ADB";$lvADB.Focus()}
function Show-Help{
    $d=New-Object System.Windows.Forms.Form
    $d.Text="Quas ADB Commander v8.25 - Help"
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
    $L.AppendText(" Quas ADB Commander v8.25`r`n")
    $L.SelectionFont=$fN;$L.SelectionColor=$cD
    $L.AppendText(" Dual-panel file manager for Meta Quest / Android`r`n")
    &$SH $L "NAVIGATION"
    &$KV $L "Tab"            "Switch active panel"
    &$KV $L "Enter/DblClick" "Open folder / Run / Enter archive"
    &$KV $L "Space"          "Toggle mark (yellow)"
    &$KV $L "* (Numpad)"     "Mark ALL / Unmark ALL"
    &$KV $L "Alt+X"          "Exit"
    &$KV $L "F9"             "Jump to Android/data"
    &$KV $L "F10"            "Jump to Android/obb"
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
    &$NN $L "* in title = unsaved changes"
    &$NN $L "Search: highlight matches (3+ chars)"
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
    &$SH $L "FILE COLORS"
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
        $L.SelectionFont=$fN;$L.SelectionColor=$p[2]
        $L.AppendText((" {0,-10}"-f $p[0]))
        $L.SelectionColor=$cD;$L.AppendText("$($p[1])`r`n")}
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
    $R.AppendText(" powershell -File adbcm.v8.25.ps1 -ToolsPath C:\Tools`r`n")
    &$SH $R "MEDIA PREVIEW  (Android)"
    &$NN $R "DblClick video/photo/audio on Android panel"
    &$NN $R "-> pulled to %TEMP%, opened with system app"
    &$NN $R "Files > 500 MB require confirmation" $cW
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


$adbT=New-Object System.Windows.Forms.Timer;$adbT.Interval=3000
$adbT.Add_Tick({
    $devOut=& "$envAdb" devices 2>&1
    $dev=$devOut|Where-Object{$_ -match "\tdevice$"}
    if($dev){$serial=([string]($dev|Select-Object -First 1)) -split "\t"|Select-Object -First 1;Set-Status "CONNECTED: $serial" "Green"}else{Set-Status "DISCONNECTED - Check USB" "Red"}})
$adbT.Start()

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
})

$lvPC.Add_Enter({$lvPC.BackColor=$bgActive;$lvADB.BackColor=$bgInact;$form.Refresh()})
$lvADB.Add_Enter({$lvADB.BackColor=$bgActive;$lvPC.BackColor=$bgInact;$form.Refresh()})
$form.Add_Load({Do-Resize;Refresh-Panel "PC";Refresh-Panel "ADB";$lvPC.Focus()})
$form.ShowDialog()