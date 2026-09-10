<#
.SYNOPSIS
  Auto-clicks VS Code approval buttons using Windows UI Automation.

.DESCRIPTION
  No install needed. Uses the UIAutomationClient assemblies shipped with Windows.
  Run with Windows PowerShell 5.1 (powershell.exe).

  The approval labels below were extracted from this machine's own VS Code
  string table:
    resources\app\out\nls.messages.json
  Many are templates, e.g. "Allow {0} in this Session" renders as
  "Allow python in this Session". So matching uses regex rules, not fixed names.

  VS Code also appends keybinding hints, e.g. "Allow (Ctrl+Enter)".
  Those are stripped before matching.

  Why the tree can look empty:
    VS Code is Electron/Chromium. The renderer only builds an accessibility
    tree once a client pokes the CHILD window (Chrome_RenderWidgetHostHWND)
    with WM_GETOBJECT. Attaching to only the top window returns just
    Minimize/Restore/Close. This script pokes the child windows too.
    Last resort: relaunch with  code --force-renderer-accessibility

  WARNING: these buttons are the human approval step for running terminal
  commands, fetching URLs and writing files. Automating them means nothing
  gets reviewed before it happens.

.EXAMPLE
  # Show every rule and its click priority
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -ShowTargets

.EXAMPLE
  # List what is on screen; matches print green
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -List

.EXAMPLE
  # Dry run, click nothing
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -DryRun

.EXAMPLE
  # Run for real
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1

.EXAMPLE
  # Also click bare "Run" / "Accept" / "Continue" / "Keep Going"
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -IncludeAmbiguous
#>

[CmdletBinding()]
param(
    # Turn on the ambiguous rules: bare Run, Accept, Continue, Keep Going.
    # Off by default because the debug toolbar, test explorer and merge editor
    # use those exact same labels, and they are on screen all the time.
    [switch] $IncludeAmbiguous,

    # Extra regex patterns to treat as approve buttons, highest priority.
    [string[]] $ExtraPatterns = @(),

    # Extra regex patterns to never click, on top of the built-in deny list.
    [string[]] $ExcludePatterns = @(),

    # Dump elements found right now, then exit.
    [switch] $List,

    # With -List: show every control type, not just clickable ones.
    [switch] $AllTypes,

    # Print processes, child windows and element counts, then exit.
    [switch] $Diag,

    # Print the rule list with priority order, then exit.
    [switch] $ShowTargets,

    # Find targets and report them, but never click.
    [switch] $DryRun,

    # Milliseconds between scans.
    [int] $IntervalMs = 1000,

    # Do not click the same label again within this many milliseconds.
    [int] $CooldownMs = 2500,

    # Stop after this many clicks. 0 = run forever.
    [int] $MaxClicks = 0,

    # Write every click to this file as well as the console.
    [string] $LogFile,

    # Process names of editor windows to watch.
    [string[]] $ProcessNames = @("Code", "Code - Insiders")
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ============================================================== deny list ====
# Checked first. Anything matching here is never clicked, whatever else matches.
$denyPatterns = @(
    '\?$'                      # questions/titles, e.g. "Allow tool call?"
    '^Skip'                    # Skip, Skip All, Skip Changes, Skip Results
    '^Don''t Allow'
    '^Do Not Allow'
    '^Disallow'
    '^Deny'
    '^Reject'
    '^Cancel'
    '^Discard'
    '^Undo'
    '^Delete'
    '^Remove'
    '^Stop'
    '^Proceed without executing'
    '^Continue Without Signing In'
    '^Continue in Background'
    '^Continue In'
    '^Continue in Agents Window'
    '^Continue in Requested Workspace'
    '^Trust but Verify'
    '^Configure Auto Approve'
    '^Enable Auto Approve'
    '^Edit Auto Approve'
    '^Allow requests to\.\.\.$'   # opens a picker, does not approve
) + $ExcludePatterns

# ================================================================= rules =====
# Ordered: the earliest match wins when several buttons are on screen.
# Least privilege first - a one-off Allow beats a permanent Always Allow.
# Tier 'safe'      -> always active.
# Tier 'ambiguous' -> only with -IncludeAmbiguous.
function New-Rule {
    param([string] $Pattern, [string] $Tier, [string] $Note)
    [pscustomobject]@{ Pattern = $Pattern; Tier = $Tier; Note = $Note }
}

$rules = @()

foreach ($p in $ExtraPatterns) {
    $rules += New-Rule $p 'safe' 'user supplied'
}

$rules += @(
    # --- one-off approvals, narrowest possible scope
    New-Rule '^Allow$'                                   'safe' 'tool call, generic'
    New-Rule '^Allow Once$'                              'safe' 'tool call, once'
    New-Rule '^Allow once$'                              'safe' 'auth prompt, once'
    New-Rule '^Allow once: .+$'                          'safe' 'auth prompt, once'
    New-Rule '^Allow and Review Once$'                   'safe' 'tool call, review result'
    New-Rule '^Approve$'                                 'safe' 'generic approve'
    New-Rule '^Approve Tool Result$'                     'safe' 'tool result'
    New-Rule '^Allow Access$'                            'safe' 'resource access'

    # --- session scoped
    New-Rule '^Allow in this Session$'                   'safe' 'session scope'
    New-Rule '^Allow Tools from .+ in this Session$'     'safe' 'MCP server, session'
    New-Rule '^Allow Exact Command Line in this Session$' 'safe' 'terminal, session'
    New-Rule '^Allow All Commands in this Session$'      'safe' 'terminal, session, broad'
    New-Rule '^Allow this folder in this session$'       'safe' 'folder read, session'
    New-Rule '^Allow Without Review in this Session$'    'safe' 'session, skips result review'

    # --- workspace scoped
    New-Rule '^Allow in this Workspace$'                 'safe' 'workspace scope'
    New-Rule '^Allow Tools from .+ in this Workspace$'   'safe' 'MCP server, workspace'
    New-Rule '^Allow a folder in this workspace$'        'safe' 'folder read, workspace'
    New-Rule '^Allow Without Review in this Workspace$'  'safe' 'workspace, skips review'

    # --- permanent
    New-Rule '^Always Allow$'                            'safe' 'permanent'
    New-Rule '^Always Allow Tools from .+$'              'safe' 'MCP server, permanent'
    New-Rule '^Always Allow Exact Command Line$'         'safe' 'terminal, permanent'
    New-Rule '^Always Allow Without Review$'             'safe' 'permanent, skips review'
    New-Rule '^Always Allow Tools from .+ Without Review$' 'safe' 'permanent, skips review'

    # --- terminal / command specific
    New-Rule '^Allow all commands starting with .+$'     'safe' 'terminal, command prefix'
    New-Rule '^Run Command$'                             'safe' 'terminal, single command'
    New-Rule '^Run Commands$'                            'safe' 'terminal, several commands'
    New-Rule '^Allow \S+$'                               'safe' 'terminal, named command'

    # --- network / url / fetch
    New-Rule '^Allow requests to .+$'                    'safe' 'url fetch, request'
    New-Rule '^Allow responses from .+$'                 'safe' 'url fetch, response'
    New-Rule '^Allow reading files from .+$'             'safe' 'file read scope'
    New-Rule '^Allow Network$'                           'safe' 'sandbox network'
    New-Rule '^Allow Unsandboxed Commands$'              'safe' 'sandbox escape'
    New-Rule '^Allow Remote Connections$'                'safe' 'port forwarding'

    # --- bulk approvals
    New-Rule '^Allow All$'                               'safe' 'all pending'
    New-Rule '^Allow all$'                               'safe' 'all pending'
    New-Rule '^Approve all$'                             'safe' 'all pending'
    New-Rule '^Allow and Skip Reviewing Result$'         'safe' 'skips result review'

    # --- edits: keep / accept
    New-Rule '^Keep$'                                    'safe' 'keep one edit'
    New-Rule '^Keep this Change$'                        'safe' 'keep one hunk'
    New-Rule '^Keep All Edits$'                          'safe' 'keep every edit'
    New-Rule '^Keep Chat Edits$'                         'safe' 'keep chat edits'
    New-Rule '^Keep All Chat Edits$'                     'safe' 'keep every chat edit'
    New-Rule '^Keep All$'                                'safe' 'keep every edit'
    New-Rule '^Accept All$'                              'safe' 'accept every edit'

    # --- ambiguous: same label used by debug, tests, merge editor, suggestions
    New-Rule '^Continue$'                                'ambiguous' 'also debug F5 Continue'
    New-Rule '^Run$'                                     'ambiguous' 'also debug / test Run'
    New-Rule '^Accept$'                                  'ambiguous' 'also merge / inline suggest'
    New-Rule '^Keep Going$'                              'ambiguous' 'chat continue prompt'
    New-Rule '^Approve Plan Only$'                       'ambiguous' 'plan approval'
)

# ================================================================ win32 ======
if (-not ("Win32Windows" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32Windows
{
    private delegate bool EnumWindowProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowProc cb, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT p);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);

    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    public static string ClassOf(IntPtr hWnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static bool Visible(IntPtr hWnd) { return IsWindowVisible(hWnd); }

    public static List<IntPtr> Children(IntPtr parent)
    {
        var found = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

    // WM_GETOBJECT / OBJID_CLIENT. Tells Chromium an assistive-tech client is
    // present, so it starts publishing its accessibility tree.
    public static void WakeAccessibility(IntPtr hWnd)
    {
        IntPtr result;
        SendMessageTimeout(hWnd, 0x003D, IntPtr.Zero, unchecked((IntPtr)(-4)), 0x0002, 500, out result);
    }

    // Last-resort click. Moves the cursor, clicks, then puts the cursor back.
    public static void ClickAt(int x, int y)
    {
        POINT old;
        GetCursorPos(out old);
        SetCursorPos(x, y);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, IntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP,   0, 0, 0, IntPtr.Zero);
        SetCursorPos(old.X, old.Y);
    }
}
"@
}

$AE    = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]::Descendants
$CT    = [System.Windows.Automation.ControlType]

# Control types that can act as a button inside a VS Code webview.
$clickableTypes = @($CT::Button, $CT::Hyperlink, $CT::MenuItem, $CT::ListItem, $CT::CheckBox)

# ============================================================== helpers ======

function Write-Log {
    param([string] $Message, [string] $Color = "Green")

    Write-Host $Message -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try { Add-Content -Path $LogFile -Value $Message -Encoding UTF8 } catch { }
    }
}

function Get-EditorProcesses {
    $procs = @()
    foreach ($n in $ProcessNames) {
        $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowHandle -ne 0 })
    }
    return $procs
}

function Get-TargetHandles {
    $handles = @()

    foreach ($p in (Get-EditorProcesses)) {
        $main = $p.MainWindowHandle
        $handles += [pscustomobject]@{
            Handle = $main; Class = [Win32Windows]::ClassOf($main); Pid = $p.Id; Kind = "main"
        }

        foreach ($child in [Win32Windows]::Children($main)) {
            if (-not [Win32Windows]::Visible($child)) { continue }

            $cls = [Win32Windows]::ClassOf($child)
            if ($cls -notlike "Chrome_RenderWidgetHostHWND*" -and
                $cls -notlike "Intermediate D3D Window*" -and
                $cls -notlike "Chrome_WidgetWin*") { continue }

            $handles += [pscustomobject]@{
                Handle = $child; Class = $cls; Pid = $p.Id; Kind = "child"
            }
        }
    }
    return $handles
}

function Wake-Accessibility {
    param($Handles)
    foreach ($h in $Handles) {
        try { [Win32Windows]::WakeAccessibility($h.Handle) } catch { }
    }
}

function Get-Roots {
    param($Handles)

    $roots = @()
    foreach ($h in $Handles) {
        try {
            $el = $AE::FromHandle($h.Handle)
            if ($el) { $roots += $el }
        } catch {
            Write-Verbose "FromHandle failed for $($h.Class): $_"
        }
    }
    return $roots
}

function Get-Elements {
    param($Root, [bool] $EveryType)

    try {
        if ($EveryType) {
            return @($Root.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition))
        }

        $conds = @()
        foreach ($t in $clickableTypes) {
            $conds += New-Object System.Windows.Automation.PropertyCondition(
                $AE::ControlTypeProperty, $t)
        }
        $or = New-Object System.Windows.Automation.OrCondition($conds)
        return @($Root.FindAll($Scope, $or))
    } catch {
        Write-Verbose "FindAll failed: $_"
        return @()
    }
}

function Get-ElementName {
    param($Element)
    try { return ([string]$Element.Current.Name).Trim() } catch { return "" }
}

function Get-ElementType {
    param($Element)
    try { return $Element.Current.ControlType.ProgrammaticName -replace "^ControlType\.", "" }
    catch { return "?" }
}

# VS Code appends keybinding hints to button names, e.g.
#   "Allow (Ctrl+Enter)"
#   "Split Editor Right (Ctrl+\) [Alt] Split EditorDown"
# Strip those so the plain label is left.
function Get-NormalizedName {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = $Name.Trim()

    $n = [regex]::Replace($n, '\s*\[Alt\].*$', '')
    while ($n -match '\s*\([^()]*\)\s*$') {
        $n = [regex]::Replace($n, '\s*\([^()]*\)\s*$', '')
    }
    return $n.Trim()
}

function Test-Clickable {
    param($Element)

    try {
        if ($Element.Current.IsOffscreen) { return $false }
        if (-not $Element.Current.IsEnabled) { return $false }
    } catch {
        return $false
    }
    return $true
}

# Returns the rule index for a label, or $null if it should not be clicked.
function Get-Rank {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $norm = Get-NormalizedName $Name

    foreach ($d in $denyPatterns) {
        if ($norm -match $d -or $Name -match $d) { return $null }
    }

    for ($i = 0; $i -lt $rules.Count; $i++) {
        if ($rules[$i].Tier -eq 'ambiguous' -and -not $IncludeAmbiguous) { continue }
        if ($norm -match $rules[$i].Pattern) { return $i }
    }
    return $null
}

function Invoke-Element {
    param($Element)

    # Preferred: InvokePattern. No mouse movement.
    $pattern = $null
    if ($Element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern, [ref] $pattern)) {
        $pattern.Invoke()
        return "InvokePattern"
    }

    # Fallback 1: SelectionItem (toolbar-style buttons).
    $select = $null
    if ($Element.TryGetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern, [ref] $select)) {
        $select.Select()
        return "SelectionItemPattern"
    }

    # Fallback 2: real mouse click. Cursor is restored afterwards.
    try {
        $pt = $Element.GetClickablePoint()
        [Win32Windows]::ClickAt([int]$pt.X, [int]$pt.Y)
        return "MouseClick"
    } catch {
        Write-Verbose "No clickable point: $_"
    }

    throw "Element '$(Get-ElementName $Element)' supports no clickable pattern."
}

# ============================================================== targets ======

if ($ShowTargets) {
    $active = @($rules | Where-Object { $_.Tier -eq 'safe' -or $IncludeAmbiguous })

    Write-Host "Approve rules, highest priority first:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $rules.Count; $i++) {
        $r  = $rules[$i]
        $on = ($r.Tier -eq 'safe' -or $IncludeAmbiguous)
        $c  = if ($on) { "White" } else { "DarkGray" }
        $t  = if ($on) { "  " } else { "off" }
        Write-Host ("  {0} {1,3}. {2,-48} {3}" -f $t, ($i + 1), $r.Pattern, $r.Note) -ForegroundColor $c
    }

    Write-Host "`nNever clicked (deny list):" -ForegroundColor Cyan
    foreach ($d in $denyPatterns) { Write-Host "     $d" -ForegroundColor DarkGray }

    Write-Host ("`n{0} of {1} rules active. Use -IncludeAmbiguous for the rest." -f
        $active.Count, $rules.Count) -ForegroundColor Cyan
    exit 0
}

# =============================================================== attach ======

$handles = Get-TargetHandles
if ($handles.Count -eq 0) {
    Write-Warning "No VS Code window found. Is it running?"
    exit 1
}

Wake-Accessibility $handles
Start-Sleep -Milliseconds 1500      # give Chromium time to build the tree
$roots = Get-Roots $handles

# ============================================================= diagnose ======

if ($Diag) {
    Write-Host "Windows attached:" -ForegroundColor Cyan
    foreach ($h in $handles) {
        Write-Host ("  pid {0,-7} {1,-6} 0x{2:X8}  {3}" -f $h.Pid, $h.Kind, [int64]$h.Handle, $h.Class)
    }

    Write-Host "`nElement counts per root:" -ForegroundColor Cyan
    $total = 0
    for ($i = 0; $i -lt $roots.Count; $i++) {
        $all  = (Get-Elements $roots[$i] $true).Count
        $clik = (Get-Elements $roots[$i] $false).Count
        $total += $all
        Write-Host ("  root {0}: {1,5} elements, {2,4} clickable  [{3}]" -f
            $i, $all, $clik, $handles[$i].Class)
    }

    Write-Host ""
    if ($total -le 10) {
        Write-Warning "Tree is basically empty. Chromium accessibility is off."
        Write-Warning "Fix: close ALL VS Code windows, then relaunch with:"
        Write-Warning "     code --force-renderer-accessibility"
    } else {
        Write-Host "Tree looks alive. Run -List with a prompt open." -ForegroundColor Green
    }
    exit 0
}

# ============================================================ discovery ======

if ($List) {
    Write-Host "Elements visible right now:" -ForegroundColor Cyan
    $seen  = @{}
    $count = 0
    $hits  = 0

    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $AllTypes.IsPresent)) {
            $name = Get-ElementName $e
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $type = Get-ElementType $e
            $key  = "$type|$name"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $count++

            $off = $true
            try { $off = $e.Current.IsOffscreen } catch { }
            $tag = if ($off) { "offscreen" } else { "visible  " }

            $norm  = Get-NormalizedName $name
            $shown = if ($norm -ne $name -and $norm) { "$name   -> '$norm'" } else { $name }
            $rank  = Get-Rank $name

            if ($null -ne $rank) {
                $hits++
                Write-Host ("  [{0}] {1,-12} {2}  <-- WOULD CLICK (rule {3}: {4})" -f
                    $tag, $type, $shown, ($rank + 1), $rules[$rank].Pattern) -ForegroundColor Green
            } else {
                Write-Host ("  [{0}] {1,-12} {2}" -f $tag, $type, $shown)
            }
        }
    }

    Write-Host ("`n{0} elements, {1} would be clicked." -f $count, $hits) -ForegroundColor Cyan
    if ($count -le 5) {
        Write-Warning "Almost nothing found. Run -Diag, or relaunch VS Code with:"
        Write-Warning "     code --force-renderer-accessibility"
    }
    exit 0
}

# ============================================================== clicker ======

$activeCount = @($rules | Where-Object { $_.Tier -eq 'safe' -or $IncludeAmbiguous }).Count
Write-Host ("Watching {0} rules across {1} window(s). Ambiguous: {2}. DryRun: {3}." -f
    $activeCount, $roots.Count, $IncludeAmbiguous.IsPresent, $DryRun.IsPresent) -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

$clicks    = 0
$lastClick = @{}   # label -> UTC time of last click

while ($true) {

    if ($roots.Count -eq 0) {
        $handles = Get-TargetHandles
        if ($handles.Count -eq 0) {
            Start-Sleep -Milliseconds $IntervalMs
            continue
        }
        Wake-Accessibility $handles
        Start-Sleep -Milliseconds 1000
        $roots = Get-Roots $handles
        Write-Host "Re-attached ($($roots.Count) windows)." -ForegroundColor DarkGray
    }

    # Scan once, keep the highest-priority clickable target.
    $best     = $null
    $bestRank = [int]::MaxValue
    $bestName = ""

    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $false)) {
            $name = Get-ElementName $e
            $rank = Get-Rank $name
            if ($null -eq $rank -or $rank -ge $bestRank) { continue }
            if (-not (Test-Clickable $e)) { continue }

            $best     = $e
            $bestRank = $rank
            $bestName = Get-NormalizedName $name
        }
    }

    if ($best) {
        $since = if ($lastClick.ContainsKey($bestName)) {
            ([DateTime]::UtcNow - $lastClick[$bestName]).TotalMilliseconds
        } else {
            [double]::MaxValue
        }

        if ($DryRun) {
            Write-Host ("{0}  FOUND '{1}' (rule {2}, dry run)" -f
                (Get-Date -Format "HH:mm:ss"), $bestName, ($bestRank + 1)) -ForegroundColor Yellow
        }
        elseif ($since -ge $CooldownMs) {
            try {
                $how = Invoke-Element $best
                $lastClick[$bestName] = [DateTime]::UtcNow
                $clicks++
                Write-Log ("{0}  CLICKED '{1}' via {2}  (total: {3})" -f
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $bestName, $how, $clicks)

                if ($MaxClicks -gt 0 -and $clicks -ge $MaxClicks) {
                    Write-Host "Reached MaxClicks. Exiting." -ForegroundColor Cyan
                    break
                }
            } catch {
                Write-Warning $_.Exception.Message
                $lastClick[$bestName] = [DateTime]::UtcNow
            }
        }
    }

    if ((Get-EditorProcesses).Count -eq 0) { $roots = @() }

    Start-Sleep -Milliseconds $IntervalMs
}
