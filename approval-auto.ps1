<#
.SYNOPSIS
  Auto-clicks VS Code approval buttons across every window and chat session.

.DESCRIPTION
  No install needed. Uses the UIAutomationClient assemblies shipped with Windows.
  Run with Windows PowerShell 5.1 (powershell.exe).

  Labels were extracted from this machine's own VS Code string table:
    resources\app\out\nls.messages.json
  Many are templates, e.g. "Allow {0} in this Session" renders as
  "Allow python in this Session", so matching uses regex, not fixed names.
  VS Code also appends keybinding hints, e.g. "Allow (Ctrl+Enter)". Stripped.

  MULTI-WINDOW
    Electron owns every window from one process, so Process.MainWindowHandle
    returns only ONE window. This script uses EnumWindows instead, so it sees
    every VS Code window plus the Agent Sessions window.

  MULTI-SESSION
    Only the active chat session is rendered, so a background session waiting
    for approval has no buttons in the tree at all. When no approve button is
    found, the script clicks whatever is marked as waiting -
    "1 pending confirmation", "Needs attention", "2 sessions require input",
    "Awaiting Permission: ..." - which focuses or scrolls to that session.
    The approve button then appears on the next scan and gets clicked.

  EMPTY TREE
    Chromium only builds an accessibility tree once a client pokes the CHILD
    window (Chrome_RenderWidgetHostHWND) with WM_GETOBJECT. This script does
    that. Last resort: relaunch with  code --force-renderer-accessibility

  WARNING: these buttons are the human approval step for running terminal
  commands, fetching URLs and writing files. Automating them means nothing
  gets reviewed before it happens - now across every window at once.

.EXAMPLE
  # Show every window and session the script can see
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -Diag

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
  # Run for real, including buttons scrolled out of view
  powershell -ExecutionPolicy Bypass -File .\approval-auto.ps1 -IncludeOffscreen
#>

[CmdletBinding()]
param(
    # Turn on the ambiguous rules: bare Run, Accept, Continue, Keep Going.
    # Off by default because the debug toolbar, test explorer and merge editor
    # use those exact same labels, and they are on screen all the time.
    [switch] $IncludeAmbiguous,

    # Also click approve buttons that are scrolled out of view.
    # Useful when a long chat has pushed the confirmation off screen.
    [switch] $IncludeOffscreen,

    # Do NOT click waiting sessions to bring their buttons into the tree.
    [switch] $NoFocusSessions,

    # Extra regex patterns to treat as approve buttons, highest priority.
    [string[]] $ExtraPatterns = @(),

    # Extra regex patterns to never click, on top of the built-in deny list.
    [string[]] $ExcludePatterns = @(),

    # Dump elements found right now, then exit.
    [switch] $List,

    # With -List: show every control type, not just clickable ones.
    [switch] $AllTypes,

    # Print windows, sessions and element counts, then exit.
    [switch] $Diag,

    # Print the rule list with priority order, then exit.
    [switch] $ShowTargets,

    # Find targets and report them, but never click.
    [switch] $DryRun,

    # Milliseconds between scans.
    [int] $IntervalMs = 1000,

    # Do not click the same label again within this many milliseconds.
    [int] $CooldownMs = 2500,

    # Do not re-focus the same waiting session within this many milliseconds.
    [int] $SessionCooldownMs = 6000,

    # Rescan for new/closed VS Code windows every this many milliseconds.
    [int] $RescanWindowsMs = 15000,

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
    '^Archive'
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

# ====================================================== waiting-session marks =
# Elements whose label says a session is blocked on a human. Clicking one
# focuses that session, or scrolls to the confirmation inside the active one.
# Strings taken from nls.messages.json.
$waitingPatterns = @(
    'pending confirmation'      # "1 pending confirmation", "3 pending confirmations"
    'requires? input'           # "1 session requires input", "2 sessions require input"
    'Needs [Aa]ttention'
    'Awaiting Permission'
)

# ================================================================= rules =====
# Ordered: the earliest match wins when several buttons are on screen.
# Least privilege first - a one-off Allow beats a permanent Always Allow.
function New-Rule {
    param([string] $Pattern, [string] $Tier, [string] $Note)
    [pscustomobject]@{ Pattern = $Pattern; Tier = $Tier; Note = $Note }
}

$rules = @()
foreach ($p in $ExtraPatterns) { $rules += New-Rule $p 'safe' 'user supplied' }

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
    private static extern bool EnumWindows(EnumWindowProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowProc cb, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

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

    public static string TitleOf(IntPtr hWnd)
    {
        var sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static uint PidOf(IntPtr hWnd)
    {
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        return pid;
    }

    public static bool Visible(IntPtr hWnd) { return IsWindowVisible(hWnd); }

    // Every top-level window on the desktop. Electron owns all of its windows
    // from one process, so Process.MainWindowHandle only ever returns one.
    public static List<IntPtr> TopLevel()
    {
        var found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }

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

# Types that can carry a "waiting" badge. Text and TreeItem included, because
# the session list rows and the status line are not buttons.
$waitingTypes = @($CT::Button, $CT::ListItem, $CT::TreeItem, $CT::Text,
                  $CT::Hyperlink, $CT::MenuItem, $CT::Group)

# ============================================================== helpers ======

function Write-Log {
    param([string] $Message, [string] $Color = "Green")

    Write-Host $Message -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try { Add-Content -Path $LogFile -Value $Message -Encoding UTF8 } catch { }
    }
}

function Get-EditorPids {
    $pids = @{}
    foreach ($n in $ProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $pids[[uint32]$p.Id] = $n
        }
    }
    return $pids
}

# Every VS Code window, main and Agent Sessions, plus their render widgets.
function Get-TargetHandles {
    $pids    = Get-EditorPids
    $handles = @()

    if ($pids.Count -eq 0) { return $handles }

    foreach ($h in [Win32Windows]::TopLevel()) {
        if (-not [Win32Windows]::Visible($h)) { continue }

        $windowPid = [Win32Windows]::PidOf($h)
        if (-not $pids.ContainsKey($windowPid)) { continue }

        $cls = [Win32Windows]::ClassOf($h)
        if ($cls -notlike "Chrome_WidgetWin*") { continue }

        $title = [Win32Windows]::TitleOf($h)
        if ([string]::IsNullOrWhiteSpace($title)) { continue }   # hidden helper windows

        $handles += [pscustomobject]@{
            Handle = $h; Class = $cls; Pid = $windowPid; Kind = "window"; Title = $title
        }

        foreach ($child in [Win32Windows]::Children($h)) {
            if (-not [Win32Windows]::Visible($child)) { continue }

            $ccls = [Win32Windows]::ClassOf($child)
            if ($ccls -notlike "Chrome_RenderWidgetHostHWND*" -and
                $ccls -notlike "Intermediate D3D Window*") { continue }

            $handles += [pscustomobject]@{
                Handle = $child; Class = $ccls; Pid = $windowPid; Kind = "render"; Title = $title
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
    param($Root, $Types, [bool] $EveryType = $false)

    try {
        if ($EveryType) {
            return @($Root.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition))
        }

        $conds = @()
        foreach ($t in $Types) {
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
    param($Element, [bool] $AllowOffscreen = $false)

    try {
        if (-not $Element.Current.IsEnabled) { return $false }
        if ($Element.Current.IsOffscreen -and -not $AllowOffscreen) { return $false }
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

# True when a label says this session is blocked waiting for a human.
function Test-Waiting {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($w in $waitingPatterns) {
        if ($Name -match $w) { return $true }
    }
    return $false
}

function Invoke-Element {
    param($Element)

    # Preferred: InvokePattern. No mouse movement, and works off screen.
    $pattern = $null
    if ($Element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern, [ref] $pattern)) {
        $pattern.Invoke()
        return "InvokePattern"
    }

    # Fallback 1: SelectionItem. Session list rows use this to become active.
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

# Scroll an off-screen element into view so its buttons render.
function Show-Element {
    param($Element)

    $sc = $null
    if ($Element.TryGetCurrentPattern(
            [System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $sc)) {
        try { $sc.ScrollIntoView(); return $true } catch { }
    }
    return $false
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

    Write-Host "`nWaiting-session markers (clicked to focus that session):" -ForegroundColor Cyan
    foreach ($w in $waitingPatterns) { Write-Host "     $w" -ForegroundColor DarkGray }

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
        Write-Host ("  pid {0,-7} {1,-7} 0x{2:X8}  {3,-32} {4}" -f
            $h.Pid, $h.Kind, [int64]$h.Handle, $h.Class, $h.Title)
    }

    $windowCount = @($handles | Where-Object { $_.Kind -eq "window" }).Count
    Write-Host ("`n{0} VS Code window(s), {1} handle(s) total." -f
        $windowCount, $handles.Count) -ForegroundColor Cyan

    Write-Host "`nElement counts per root:" -ForegroundColor Cyan
    $total = 0
    for ($i = 0; $i -lt $roots.Count; $i++) {
        $all  = (Get-Elements $roots[$i] $null $true).Count
        $clik = (Get-Elements $roots[$i] $clickableTypes).Count
        $total += $all
        Write-Host ("  root {0}: {1,5} elements, {2,4} clickable  [{3}]" -f
            $i, $all, $clik, $handles[$i].Class)
    }

    Write-Host "`nSessions currently waiting:" -ForegroundColor Cyan
    $waits = 0
    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $waitingTypes)) {
            $n = Get-ElementName $e
            if (Test-Waiting $n) {
                $waits++
                Write-Host ("  {0,-12} {1}" -f (Get-ElementType $e), $n) -ForegroundColor Yellow
            }
        }
    }
    if ($waits -eq 0) { Write-Host "  none right now" -ForegroundColor DarkGray }

    Write-Host ""
    if ($total -le 10) {
        Write-Warning "Tree is basically empty. Chromium accessibility is off."
        Write-Warning "Fix: close ALL VS Code windows, then relaunch with:"
        Write-Warning "     code --force-renderer-accessibility"
    } else {
        Write-Host "Tree looks alive." -ForegroundColor Green
    }
    exit 0
}

# ============================================================ discovery ======

if ($List) {
    Write-Host "Elements visible right now:" -ForegroundColor Cyan
    $seen  = @{}
    $count = 0
    $hits  = 0
    $waits = 0

    $types = if ($AllTypes) { $null } else { $clickableTypes + $waitingTypes }

    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $types $AllTypes.IsPresent)) {
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
            }
            elseif (Test-Waiting $name) {
                $waits++
                Write-Host ("  [{0}] {1,-12} {2}  <-- WAITING SESSION, would focus" -f
                    $tag, $type, $shown) -ForegroundColor Yellow
            }
            else {
                Write-Host ("  [{0}] {1,-12} {2}" -f $tag, $type, $shown)
            }
        }
    }

    Write-Host ("`n{0} elements, {1} would be clicked, {2} waiting session(s)." -f
        $count, $hits, $waits) -ForegroundColor Cyan
    if ($count -le 5) {
        Write-Warning "Almost nothing found. Run -Diag, or relaunch VS Code with:"
        Write-Warning "     code --force-renderer-accessibility"
    }
    exit 0
}

# ============================================================== clicker ======

$activeCount  = @($rules | Where-Object { $_.Tier -eq 'safe' -or $IncludeAmbiguous }).Count
$windowCount  = @($handles | Where-Object { $_.Kind -eq "window" }).Count

Write-Host ("Watching {0} rules across {1} VS Code window(s)." -f $activeCount, $windowCount) -ForegroundColor Cyan
Write-Host ("Ambiguous: {0}   Offscreen: {1}   FocusSessions: {2}   DryRun: {3}" -f
    $IncludeAmbiguous.IsPresent, $IncludeOffscreen.IsPresent,
    (-not $NoFocusSessions.IsPresent), $DryRun.IsPresent) -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

$clicks      = 0
$lastClick   = @{}                       # label -> UTC time of last click
$lastFocus   = @{}                       # waiting label -> UTC time of last focus
$lastRescan  = [DateTime]::UtcNow

while ($true) {

    # Pick up windows opened or closed since last time.
    $sinceRescan = ([DateTime]::UtcNow - $lastRescan).TotalMilliseconds
    if ($roots.Count -eq 0 -or $sinceRescan -ge $RescanWindowsMs) {
        $newHandles = Get-TargetHandles
        $lastRescan = [DateTime]::UtcNow

        if ($newHandles.Count -eq 0) {
            $roots = @()
            Start-Sleep -Milliseconds $IntervalMs
            continue
        }

        if ($newHandles.Count -ne $handles.Count -or $roots.Count -eq 0) {
            $handles = $newHandles
            Wake-Accessibility $handles
            Start-Sleep -Milliseconds 800
            $roots = Get-Roots $handles
            $wc = @($handles | Where-Object { $_.Kind -eq "window" }).Count
            Write-Host ("Re-attached: {0} window(s)." -f $wc) -ForegroundColor DarkGray
        }
    }

    # --- pass 1: any approve button anywhere, highest priority wins ----------
    $best     = $null
    $bestRank = [int]::MaxValue
    $bestName = ""

    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $clickableTypes)) {
            $name = Get-ElementName $e
            $rank = Get-Rank $name
            if ($null -eq $rank -or $rank -ge $bestRank) { continue }
            if (-not (Test-Clickable $e $IncludeOffscreen.IsPresent)) { continue }

            $best     = $e
            $bestRank = $rank
            $bestName = Get-NormalizedName $name
        }
    }

    if ($best) {
        $since = if ($lastClick.ContainsKey($bestName)) {
            ([DateTime]::UtcNow - $lastClick[$bestName]).TotalMilliseconds
        } else { [double]::MaxValue }

        if ($DryRun) {
            Write-Host ("{0}  FOUND '{1}' (rule {2}, dry run)" -f
                (Get-Date -Format "HH:mm:ss"), $bestName, ($bestRank + 1)) -ForegroundColor Yellow
        }
        elseif ($since -ge $CooldownMs) {
            try {
                if ($IncludeOffscreen) { [void](Show-Element $best) }
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

        Start-Sleep -Milliseconds $IntervalMs
        continue
    }

    # --- pass 2: no button on screen, so surface a waiting session ----------
    # A background session's buttons are not in the tree at all. Clicking its
    # "Needs attention" / "1 pending confirmation" marker focuses it, and the
    # button shows up on the next scan.
    if (-not $NoFocusSessions) {
        foreach ($r in $roots) {
            $done = $false
            foreach ($e in (Get-Elements $r $waitingTypes)) {
                $name = Get-ElementName $e
                if (-not (Test-Waiting $name)) { continue }
                if (-not (Test-Clickable $e $true)) { continue }

                $since = if ($lastFocus.ContainsKey($name)) {
                    ([DateTime]::UtcNow - $lastFocus[$name]).TotalMilliseconds
                } else { [double]::MaxValue }
                if ($since -lt $SessionCooldownMs) { continue }

                if ($DryRun) {
                    Write-Host ("{0}  WAITING '{1}' (would focus, dry run)" -f
                        (Get-Date -Format "HH:mm:ss"), $name) -ForegroundColor Yellow
                    $lastFocus[$name] = [DateTime]::UtcNow
                    $done = $true
                    break
                }

                try {
                    [void](Show-Element $e)
                    $how = Invoke-Element $e
                    $lastFocus[$name] = [DateTime]::UtcNow
                    Write-Host ("{0}  FOCUSED '{1}' via {2}" -f
                        (Get-Date -Format "HH:mm:ss"), $name, $how) -ForegroundColor Magenta
                    Start-Sleep -Milliseconds 700   # let the session render
                    $done = $true
                    break
                } catch {
                    Write-Verbose "Could not focus '$name': $_"
                    $lastFocus[$name] = [DateTime]::UtcNow
                }
            }
            if ($done) { break }
        }
    }

    Start-Sleep -Milliseconds $IntervalMs
}
