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
    found, the script looks in the Sessions list for a row whose status is
    "(Needs Input)" and clicks it. That session becomes active, its approve
    button appears on the next scan, and gets clicked.

    Detection is structural, not textual. The chat transcript and every open
    editor share this same tree, so matching badge wording like "Needs
    attention" would fire on any document containing that phrase.

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

    # Focus waiting sessions but never press an approve button. Safe way to
    # prove the session-switching half works before letting it approve anything.
    [switch] $FocusOnly,

    # Show a small always-on-top window with a live count and an "Allow All"
    # button. Lets you clear every waiting terminal and chat from wherever you
    # are, without hunting through the sessions list.
    [switch] $Hud,

    # Run silently as a daemon: hides its own console window, logs to a file
    # instead of the screen, and refuses to start twice. Approves whatever
    # appears, whichever chat you happen to be looking at.
    [switch] $Background,

    # Never drive the real mouse. Opening a session normally needs a click,
    # which moves the pointer and can pull focus. With this, the click is
    # posted straight to the window instead, so the pointer never moves and
    # the window is not activated. If a posted click does not land, the tool
    # falls back to a real one automatically rather than getting stuck.
    [switch] $NoCursor,

    # Extra regex patterns to treat as approve buttons, highest priority.
    [string[]] $ExtraPatterns = @(),

    # Extra regex patterns to never click, on top of the built-in deny list.
    [string[]] $ExcludePatterns = @(),

    # Extra regex patterns that mark a session as waiting, e.g.
    #   -ExtraWaitingPatterns '^\s*.\s*1 pending confirmation$'
    # Off by default: badge wording is ordinary English and matches document
    # and chat text that lives in the same accessibility tree.
    [string[]] $ExtraWaitingPatterns = @(),

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

    # How often to sweep for background approvals even when the screen looks
    # idle. Sitting inside a chat hides the sessions list, so nothing is found
    # and the tool would otherwise never look again. The sweep opens the list,
    # clears everything, and leaves it open - so later scans are free.
    [int] $SweepMs = 12000,

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
# IMPORTANT: loose substring matching does NOT work here. The chat transcript
# and any open editor are part of the same accessibility tree, so a phrase like
# "pending confirmation" appearing in a document or a chat reply would be picked
# up as a real session. Markdown bullets in chat even render as ListItem.
# Everything below is therefore anchored, short, and structural.

# The sessions list builds each row from this template, found in
# nls.messages.json:   "{0} session {1} ({2}), created {3}"
# which renders as:
#   Local session IoT implementation request (Needs Input), created 9/11/2026, 12:35:58 AM
#            ^ kind        ^ title                ^ status          ^ timestamp
$sessionRowPattern = '^\S+\s*session\s+.+\s\(([^()]{1,40})\),\s*created\s'

# Status values inside those parentheses that mean "blocked on a human".
$waitingStatuses = @(
    'Needs Input'
    'Needs Attention'
    'Awaiting Permission'
)

# Badge strings like "1 pending confirmation", "Needs attention" and
# "2 sessions require input" are NOT used by default. They are ordinary English
# and appear verbatim in documentation, in markdown tables, and in chat replies,
# all of which live in the same accessibility tree. Anchoring the regex does not
# help: a table cell reading exactly "1 pending confirmation" is an exact match.
# The session row template above is unambiguous, so that is what we rely on.
# Pass -ExtraWaitingPatterns to opt back in.
$waitingBadgePatterns = @() + $ExtraWaitingPatterns

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

    [DllImport("user32.dll")]
    private static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT p);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    private const uint WM_MOUSEMOVE   = 0x0200;
    private const uint WM_LBUTTONDOWN = 0x0201;
    private const uint WM_LBUTTONUP   = 0x0202;
    private const int  MK_LBUTTON     = 0x0001;

    public static IntPtr WindowAt(int x, int y)
    {
        POINT p; p.X = x; p.Y = y;
        return WindowFromPoint(p);
    }

    // Post a click straight to the window at that point instead of driving the
    // real cursor. The pointer never moves and the window is not activated,
    // because activation comes from WM_MOUSEACTIVATE on real input, which
    // posted messages skip entirely.
    public static bool PostClick(int screenX, int screenY)
    {
        POINT p; p.X = screenX; p.Y = screenY;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) { return false; }

        ScreenToClient(h, ref p);
        IntPtr lp = (IntPtr)(((p.Y & 0xFFFF) << 16) | (p.X & 0xFFFF));

        PostMessage(h, WM_MOUSEMOVE,   IntPtr.Zero,        lp);
        PostMessage(h, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, lp);
        PostMessage(h, WM_LBUTTONUP,   IntPtr.Zero,        lp);
        return true;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int cmd);

    // Hide this process's own console so the daemon leaves nothing on screen.
    public static void HideConsole()
    {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) { ShowWindow(h, 0); }   // SW_HIDE
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

# Session rows are ListItem/TreeItem. Text is scanned only when the user opted
# into badge patterns - there are thousands of Text elements and every line of
# every open document is one of them.
$waitingTypes = @($CT::ListItem, $CT::TreeItem, $CT::DataItem)
if ($ExtraWaitingPatterns.Count -gt 0) { $waitingTypes += $CT::Text }

# Real button and row labels are short. Anything longer is document or chat
# content that happens to live in the same tree - never a control.
$MaxLabelLength = 300

# =========================================================== background ======
# Held for the life of the process. Two daemons clicking the same buttons would
# double-approve, so the second one exits instead of starting.
$script:singleton = $null

if ($Background) {
    $created = $false
    $script:singleton = New-Object System.Threading.Mutex($true, "Local\approval-auto-daemon", [ref] $created)

    if (-not $created) {
        Write-Host "approval-auto is already running in the background. Exiting." -ForegroundColor Yellow
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $LogFile = Join-Path $PSScriptRoot "approval-auto.log"
    }

    # Nothing reads the console once we detach, so keep a record on disk.
    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value (
            "{0}  ---- started (pid {1}) ----" -f
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $PID)
    } catch { }

    [Win32Windows]::HideConsole()
}

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

            # "Intermediate D3D Window" is a GPU compositing surface and always
            # exposes zero elements, so it is not worth attaching to.
            $ccls = [Win32Windows]::ClassOf($child)
            if ($ccls -notlike "Chrome_RenderWidgetHostHWND*") { continue }

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

        # OrCondition needs at least two conditions; handing it one throws.
        # Single-type lookups are common here, so use the condition directly.
        if ($conds.Count -eq 0) { return @() }
        if ($conds.Count -eq 1) { return @($Root.FindAll($Scope, $conds[0])) }

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

# The window menu bar contains File, Edit, View, Run, Terminal, Help. "Run" is
# an exact match for an approve rule, so without this guard the tool opens the
# Run menu on a loop. Approval dropdowns live under a Menu or Pane, never a
# MenuBar, so excluding that whole subtree is safe.
function Test-InMenuBar {
    param($Element)

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur    = $Element

    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        try {
            if ($cur.Current.ControlType -eq $CT::MenuBar) { return $true }
            if ($cur.Current.ControlType -eq $CT::TitleBar) { return $true }
            $cur = $walker.GetParent($cur)
        } catch {
            break
        }
    }
    return $false
}

function Test-Clickable {
    param($Element, [bool] $AllowOffscreen = $false)

    try {
        if (-not $Element.Current.IsEnabled) { return $false }
        if ($Element.Current.IsOffscreen -and -not $AllowOffscreen) { return $false }
    } catch {
        return $false
    }

    if (Test-InMenuBar $Element) { return $false }
    return $true
}

# Cooldown key for a button. Keyed on label AND screen position, so approving
# "Allow" in one session does not throttle the identical "Allow" in the next
# one. The same button in the same place stays throttled as intended.
function Get-ClickKey {
    param($Element, [string] $Label)

    try {
        $r = $Element.Current.BoundingRectangle
        if ($r.Width -gt 0 -and -not [double]::IsInfinity($r.X)) {
            return ("{0}@{1},{2}" -f $Label, [int]$r.X, [int]$r.Y)
        }
    } catch { }
    return $Label
}

# Returns the rule index for a label, or $null if it should not be clicked.
function Get-Rank {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Name.Length -gt $MaxLabelLength) { return $null }   # document / chat text
    if ($Name -match "[\r\n]") { return $null }

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
# Deliberately strict: the chat transcript and open editors share this tree, so
# anything unanchored or long is treated as content, not as a control.
function Test-Waiting {
    param([string] $Name, [string] $Type = "")

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt $MaxLabelLength) { return $false }
    if ($Name -match "[\r\n]") { return $false }        # multi-line = document text

    # 1. A real sessions-list row. Status must say it is blocked.
    $m = [regex]::Match($Name, $sessionRowPattern)
    if ($m.Success) {
        $status = $m.Groups[1].Value.Trim()
        foreach ($s in $waitingStatuses) {
            if ($status -eq $s) { return $true }
        }
        return $false
    }

    # 2. A short badge that is the entire label.
    foreach ($p in $waitingBadgePatterns) {
        if ($Name -match $p) { return $true }
    }

    return $false
}

# The waiting text is often a child label inside the real session row.
# Walk up to the nearest row or button so the click actually selects it.
function Get-ClickableAncestor {
    param($Element)

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur    = $Element

    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        try {
            $t = $cur.Current.ControlType
            if ($t -eq $CT::ListItem -or $t -eq $CT::TreeItem -or
                $t -eq $CT::DataItem -or $t -eq $CT::Button) { return $cur }
            $cur = $walker.GetParent($cur)
        } catch {
            break
        }
    }
    return $Element
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

    # Fallback 2a: post the click to the window. The pointer never moves and
    # the window is never activated, so it cannot interrupt what you are doing.
    if ($NoCursor) {
        try {
            $r = $Element.Current.BoundingRectangle
            if ($r.Width -gt 0 -and -not [double]::IsInfinity($r.X)) {
                $x = [int]($r.X + $r.Width  / 2)
                $y = [int]($r.Y + $r.Height / 2)
                if ([Win32Windows]::PostClick($x, $y)) { return "PostClick" }
            }
        } catch {
            Write-Verbose "PostClick failed: $_"
        }
    }

    # Fallback 2: real mouse click at the point UIA nominates.
    # Cursor is moved, clicked, then put straight back.
    try {
        $pt = $Element.GetClickablePoint()
        [Win32Windows]::ClickAt([int]$pt.X, [int]$pt.Y)
        return "MouseClick"
    } catch {
        Write-Verbose "GetClickablePoint failed: $_"
    }

    # Fallback 3: centre of the bounding rectangle.
    # Agent Sessions rows expose ScrollItemPattern and nothing else - no Invoke,
    # no SelectionItem - and GetClickablePoint() throws on them. Their
    # BoundingRectangle is valid though, so click its centre.
    try {
        $r = $Element.Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0 -and
            -not [double]::IsInfinity($r.X) -and -not [double]::IsInfinity($r.Y)) {

            $x = [int]($r.X + $r.Width  / 2)
            $y = [int]($r.Y + $r.Height / 2)
            [Win32Windows]::ClickAt($x, $y)
            return "MouseClickRect"
        }
    } catch {
        Write-Verbose "BoundingRectangle unusable: $_"
    }

    throw "Element '$(Get-ElementName $Element)' has no usable pattern, clickable point or rectangle."
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

    Write-Host "`nWaiting-session detection (clicked to focus that session):" -ForegroundColor Cyan
    Write-Host "     row template : $sessionRowPattern" -ForegroundColor DarkGray
    Write-Host ("     blocked when status is: {0}" -f ($waitingStatuses -join ", ")) -ForegroundColor DarkGray
    if ($waitingBadgePatterns.Count -eq 0) {
        Write-Host "     badges       : none (use -ExtraWaitingPatterns to add)" -ForegroundColor DarkGray
    } else {
        foreach ($w in $waitingBadgePatterns) { Write-Host "     badge        : $w" -ForegroundColor DarkGray }
    }
    Write-Host "     labels longer than $MaxLabelLength chars are ignored as document text" -ForegroundColor DarkGray

    Write-Host "`nNever clicked (deny list):" -ForegroundColor Cyan
    foreach ($d in $denyPatterns) { Write-Host "     $d" -ForegroundColor DarkGray }

    Write-Host ("`n{0} of {1} rules active. Use -IncludeAmbiguous for the rest." -f
        $active.Count, $rules.Count) -ForegroundColor Cyan
    exit 0
}

# =============================================================== attach ======

$handles = @(Get-TargetHandles)
if ($handles.Count -eq 0) {
    Write-Warning "No VS Code window found. Is it running?"
    exit 1
}

Wake-Accessibility $handles
Start-Sleep -Milliseconds 1500      # give Chromium time to build the tree
$roots = @(Get-Roots $handles)

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
            $t = Get-ElementType $e
            if (Test-Waiting $n $t) {
                $waits++
                $anc = Get-ClickableAncestor $e
                $via = if ($anc -ne $e) { " -> clicks $(Get-ElementType $anc) '$(Get-ElementName $anc)'" } else { "" }
                Write-Host ("  {0,-12} {1}{2}" -f $t, $n, $via) -ForegroundColor Yellow
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

    # Both sets overlap, so dedupe before building the OrCondition.
    $types = if ($AllTypes) { $null } else { @(($clickableTypes + $waitingTypes) | Select-Object -Unique) }

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

            # Editor and chat content lives in this tree too. Keep the console readable.
            $shown = ($shown -replace "\s+", " ")
            if ($shown.Length -gt 160) { $shown = $shown.Substring(0, 157) + "..." }

            $rank  = Get-Rank $name

            if ($null -ne $rank) {
                $hits++
                Write-Host ("  [{0}] {1,-12} {2}  <-- WOULD CLICK (rule {3}: {4})" -f
                    $tag, $type, $shown, ($rank + 1), $rules[$rank].Pattern) -ForegroundColor Green
            }
            elseif (Test-Waiting $name $type) {
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

# ================================================================== hud ======
# A small always-on-top window: live count of what is waiting, plus one button
# that clears every waiting terminal and chat. Solves the case where you are
# reading one panel and a different session quietly blocks - you never have to
# notice it, and you never have to go hunting through the sessions list.

# The sessions list only exists in the tree while its view is on screen. If
# nothing is found, reveal it, then rescan.
function Show-SessionsList {
    param($Roots)

    # Ordered by how little they disturb what you are looking at. Opening the
    # sidebar leaves the chat you are reading in place; "Go Back" would navigate
    # the chat panel away, so it is the last resort.
    #
    # Matched against the RAW name, because "Go Back (Ctrl+N)" is the chat
    # panel while "Go Back (Alt+LeftArrow)" is editor history. Normalizing both
    # to "Go Back" would make them indistinguishable.
    $reveal = @(
        '^Show Agent Sessions Sidebar$'
        '^Focus Agent Sessions$'
        '^Chat Agent Sessions$'
        '^Go Back \(Ctrl\+N\)$'
    )

    foreach ($p in $reveal) {
        foreach ($r in $Roots) {
            foreach ($e in (Get-Elements $r @($CT::Button))) {
                $raw = Get-ElementName $e
                if ($raw -notmatch $p) { continue }
                if (-not (Test-Clickable $e $false)) { continue }
                try {
                    [void](Invoke-Element $e)
                    Start-Sleep -Milliseconds 900
                    return $true
                } catch { }
            }
        }
    }
    return $false
}

# One approve button, highest priority, anywhere. Returns $null when there is none.
function Find-ApproveButton {
    param($Roots, [hashtable] $Skip = $null)

    $best = $null; $bestRank = [int]::MaxValue; $bestName = ""; $bestKey = ""

    foreach ($r in $Roots) {
        foreach ($e in (Get-Elements $r $clickableTypes)) {
            $name = Get-ElementName $e
            $rank = Get-Rank $name
            if ($null -eq $rank -or $rank -ge $bestRank) { continue }
            if (-not (Test-Clickable $e $true)) { continue }

            # A button that has been pressed repeatedly without anything
            # changing is stuck. Ignoring it lets the sweep move on to the
            # sessions instead of pressing it forever.
            $key = Get-ClickKey $e (Get-NormalizedName $name)
            if ($Skip -and $Skip.ContainsKey($key)) { continue }

            $best = $e; $bestRank = $rank
            $bestName = Get-NormalizedName $name
            $bestKey  = $key
        }
    }
    if (-not $best) { return $null }
    return [pscustomobject]@{ Element = $best; Rank = $bestRank; Name = $bestName; Key = $bestKey }
}

# Open a sessions-list row so its approve buttons enter the tree.
#
# Rows expose only ScrollItemPattern, so a click is the only way in. With
# -NoCursor the click is posted to the window: the pointer never moves and the
# window is never activated. Posted input is not guaranteed to be handled, so
# the caller checks whether it landed and calls again with -Force to escalate
# to a real cursor click.
function Open-SessionRow {
    param($Element, [switch] $Force)

    try { [void](Show-Element $Element) } catch { }

    if ($NoCursor -and -not $Force) {
        try {
            $r = $Element.Current.BoundingRectangle
            if ($r.Width -gt 0 -and -not [double]::IsInfinity($r.X)) {
                $x = [int]($r.X + $r.Width  / 2)
                $y = [int]($r.Y + $r.Height / 2)
                if ([Win32Windows]::PostClick($x, $y)) { return "PostClick" }
            }
        } catch {
            Write-Verbose "PostClick failed: $_"
        }
    }

    return (Invoke-Element $Element)
}

# Every sessions-list row currently reporting a blocked status.
function Find-WaitingRows {
    param($Roots)

    $rows = @()
    foreach ($r in $Roots) {
        foreach ($e in (Get-Elements $r $waitingTypes)) {
            $name = Get-ElementName $e
            if (-not (Test-Waiting $name (Get-ElementType $e))) { continue }
            $target = Get-ClickableAncestor $e
            if (-not (Test-Clickable $target $true)) { continue }
            $rows += [pscustomobject]@{ Element = $target; Name = $name }
        }
    }
    return $rows
}

# Approve everything, hopping between sessions until nothing is left.
function Invoke-ApproveAll {
    param([int] $MaxRounds = 60, [scriptblock] $Report = $null)

    $approved = 0
    $reveals  = 0
    $skip     = @{}      # click keys that did not respond
    $hits     = @{}      # click key -> times pressed in this sweep

    for ($round = 0; $round -lt $MaxRounds; $round++) {

        $handles = @(Get-TargetHandles)
        if ($handles.Count -eq 0) { break }
        $roots = @(Get-Roots $handles)

        # 1. Anything approvable on screen right now.
        $btn = Find-ApproveButton $roots $skip
        if ($btn -and ($DryRun -or $FocusOnly)) {
            if ($Report) { & $Report ("Would approve '{0}' (not clicked)" -f $btn.Name) }
            break
        }
        if ($btn) {
            $hits[$btn.Key] = 1 + $(if ($hits.ContainsKey($btn.Key)) { $hits[$btn.Key] } else { 0 })
            if ($hits[$btn.Key] -gt 3) {
                $skip[$btn.Key] = $true
                if ($Report) { & $Report ("Ignoring stuck '{0}'" -f $btn.Name) }
                continue
            }
            try {
                $how = Invoke-Element $btn.Element
                $approved++
                if ($Report) { & $Report ("Approved '{0}' via {1}" -f $btn.Name, $how) }
                Write-Log ("{0}  CLICKED '{1}' via {2}  (total: {3})" -f
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $btn.Name, $how, $approved)
            } catch {
                if ($Report) { & $Report ("Failed: " + $_.Exception.Message) }
            }
            Start-Sleep -Milliseconds 500
            continue
        }

        # 2. Nothing on screen, so open the next blocked session.
        # The sessions list is only in the tree while its view is on screen.
        # Sitting inside a chat replaces it, which is exactly when background
        # sessions pile up unnoticed - so reveal it before concluding there is
        # nothing to do. Two attempts: the sidebar, then a fallback control.
        $rows = Find-WaitingRows $roots
        if ($rows.Count -eq 0 -and $reveals -lt 2) {
            $reveals++
            if (Show-SessionsList $roots) {
                if ($Report) { & $Report "Opened the sessions list" }
                continue
            }
        }
        if ($rows.Count -eq 0) { break }

        try {
            $how = Open-SessionRow $rows[0].Element
            Start-Sleep -Milliseconds 900

            # A posted click can be ignored. If nothing appeared, escalate once
            # to a real cursor click rather than looping on a dead row.
            if ($how -eq "PostClick") {
                $check = @(Get-Roots @(Get-TargetHandles))
                if (-not (Find-ApproveButton $check)) {
                    $how = Open-SessionRow $rows[0].Element -Force
                    Start-Sleep -Milliseconds 900
                }
            }

            if ($Report) { & $Report ("Opened via {0}: {1}" -f $how, $rows[0].Name) }
        } catch {
            if ($Report) { & $Report ("Could not open session: " + $_.Exception.Message) }
            break
        }
    }

    return $approved
}

if ($Hud) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Approvals"
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.Size            = New-Object System.Drawing.Size(300, 152)
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(
        ($wa.Right - $form.Width - 24), ($wa.Bottom - $form.Height - 24))

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location  = New-Object System.Drawing.Point(12, 10)
    $lblCount.Size      = New-Object System.Drawing.Size(266, 24)
    $lblCount.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblCount.Text      = "checking..."
    $form.Controls.Add($lblCount)

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Location  = New-Object System.Drawing.Point(12, 40)
    $btnAll.Size      = New-Object System.Drawing.Size(266, 36)
    $btnAll.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnAll.FlatStyle = 'Flat'
    $btnAll.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnAll.ForeColor = [System.Drawing.Color]::White
    $btnAll.Text      = "Allow All"
    $form.Controls.Add($btnAll)

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Location = New-Object System.Drawing.Point(12, 82)
    $chkAuto.Size     = New-Object System.Drawing.Size(266, 20)
    $chkAuto.Text     = "Auto-approve as soon as anything waits"
    $chkAuto.ForeColor = [System.Drawing.Color]::Gainsboro
    $form.Controls.Add($chkAuto)

    $lblLast = New-Object System.Windows.Forms.Label
    $lblLast.Location  = New-Object System.Drawing.Point(12, 104)
    $lblLast.Size      = New-Object System.Drawing.Size(266, 34)
    $lblLast.ForeColor = [System.Drawing.Color]::Gray
    $lblLast.Text      = ""
    $form.Controls.Add($lblLast)

    $script:busy = $false

    $say = {
        param([string] $Message)
        $lblLast.Text = $Message
        [System.Windows.Forms.Application]::DoEvents()
    }

    $runAll = {
        if ($script:busy) { return }
        $script:busy  = $true
        $btnAll.Enabled = $false
        $btnAll.Text    = "Working..."
        try {
            $n = Invoke-ApproveAll -Report $say
            & $say ("Approved {0} this run" -f $n)
        } catch {
            & $say ("Error: " + $_.Exception.Message)
        } finally {
            $btnAll.Enabled = $true
            $btnAll.Text    = "Allow All"
            $script:busy    = $false
        }
    }

    $btnAll.Add_Click($runAll)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    # WinForms swallows errors raised inside a handler, so catch and surface them
    # in the window instead of failing silently.
    $timer.Add_Tick({
        if ($script:busy) { return }

        try {
            $handles = @(Get-TargetHandles)
            if ($handles.Count -eq 0) {
                $lblCount.Text      = "VS Code not running"
                $lblCount.ForeColor = [System.Drawing.Color]::Gray
                return
            }
            $roots = @(Get-Roots $handles)

            $btn   = Find-ApproveButton $roots
            $rows  = @(Find-WaitingRows $roots)
            $total = $rows.Count + $(if ($btn) { 1 } else { 0 })

            if ($total -gt 0) {
                $lblCount.Text      = "$total waiting"
                $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(255, 190, 80)
                $btnAll.Text        = "Allow All ($total)"
                if ($chkAuto.Checked) { & $runAll }
            } else {
                $lblCount.Text      = "Nothing waiting"
                $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(110, 200, 120)
                $btnAll.Text        = "Allow All"
            }
        } catch {
            $lblCount.Text      = "Scan error"
            $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(230, 110, 110)
            $lblLast.Text       = $_.Exception.Message
        }
    })
    $timer.Start()

    Write-Host "HUD open. Close the window to exit." -ForegroundColor Cyan
    [void]$form.ShowDialog()
    $timer.Stop()
    exit 0
}

# ================================================================ tray =======
# Background mode: no console, no window, just a tray icon. It approves whatever
# appears, whichever chat you are looking at. Right-click the icon to quit,
# the same as any other app.

if ($Background) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Build the three state icons once. Making them per-tick would leak handles.
    function New-DotIcon {
        param([System.Drawing.Color] $Colour)

        $bmp = New-Object System.Drawing.Bitmap 16, 16
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $Colour
        $g.FillEllipse($brush, 1, 1, 14, 14)
        $brush.Dispose()
        $g.Dispose()

        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $bmp.Dispose()
        return $icon
    }

    $iconIdle    = New-DotIcon ([System.Drawing.Color]::FromArgb(110, 200, 120))  # green
    $iconWaiting = New-DotIcon ([System.Drawing.Color]::FromArgb(255, 170, 40))   # amber
    $iconBusy    = New-DotIcon ([System.Drawing.Color]::FromArgb(0, 150, 235))    # blue
    $iconError   = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 90, 90))    # red

    $notify         = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon    = $iconIdle
    $notify.Text    = "approval-auto - starting"
    $notify.Visible = $true

    $script:busy      = $false
    $script:autoOn    = $true
    $script:total     = 0
    $script:lastState = ""
    $script:lastSweep = [DateTime]::MinValue

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $miStatus = $menu.Items.Add("Starting...")
    $miStatus.Enabled = $false
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miAll  = $menu.Items.Add("Allow All now")
    $miAuto = $menu.Items.Add("Auto-approve")
    $miAuto.CheckOnClick = $true
    $miAuto.Checked      = $true

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miLog  = $menu.Items.Add("Open log")
    $miExit = $menu.Items.Add("Exit")

    $notify.ContextMenuStrip = $menu

    $ctx = New-Object System.Windows.Forms.ApplicationContext

    $say = {
        param([string] $Message)
        $miStatus.Text = $Message
        # NotifyIcon tooltips are capped at 63 characters by Windows.
        $t = "approval-auto - $Message"
        if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + "..." }
        $notify.Text = $t
    }

    $runAll = {
        if ($script:busy) { return }
        $script:busy   = $true
        $notify.Icon   = $iconBusy
        try {
            $n = Invoke-ApproveAll -Report $say
            $script:total += $n
            if ($n -gt 0) { & $say ("approved {0} (total {1})" -f $n, $script:total) }
        } catch {
            $notify.Icon = $iconError
            & $say ("error: " + $_.Exception.Message)
        } finally {
            $script:busy = $false
        }
    }

    $miAll.Add_Click($runAll)
    $miAuto.Add_Click({ $script:autoOn = $miAuto.Checked })

    $miLog.Add_Click({
        try {
            if ($LogFile -and (Test-Path $LogFile)) { Start-Process notepad.exe $LogFile }
            else { & $say "no log yet" }
        } catch { }
    })

    $miExit.Add_Click({
        $timer.Stop()
        $notify.Visible = $false
        $notify.Dispose()
        $ctx.ExitThread()
    })

    # Double-click the icon to clear everything now.
    $notify.Add_DoubleClick($runAll)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $IntervalMs
    $timer.Add_Tick({
        if ($script:busy) { return }

        try {
            $handles = @(Get-TargetHandles)
            if ($handles.Count -eq 0) {
                $notify.Icon = $iconIdle
                & $say "VS Code not running"
                return
            }
            $roots = @(Get-Roots $handles)

            $btn   = Find-ApproveButton $roots
            $rows  = @(Find-WaitingRows $roots)
            $count = $rows.Count + $(if ($btn) { 1 } else { 0 })

            if ($count -gt 0) {
                $notify.Icon = $iconWaiting
                & $say "$count waiting"
                if ($script:autoOn) { & $runAll }
            }
            elseif ($script:autoOn -and
                    ([DateTime]::UtcNow - $script:lastSweep).TotalMilliseconds -ge $SweepMs) {
                # Looks idle, but the sessions list may simply not be on screen.
                # Sweep anyway: this is the only thing that catches approvals
                # piling up in chats you are not currently looking at.
                $script:lastSweep = [DateTime]::UtcNow
                & $runAll
                if ($script:total -eq 0) {
                    $notify.Icon = $iconIdle
                    & $say "idle"
                }
            }
            else {
                $notify.Icon = $iconIdle
                & $say ("idle - approved {0} so far" -f $script:total)
            }
        } catch {
            $notify.Icon = $iconError
            & $say ("scan error: " + $_.Exception.Message)
        }
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($ctx)

    $notify.Visible = $false
    $notify.Dispose()
    exit 0
}

# ============================================================== clicker ======

$activeCount  = @($rules | Where-Object { $_.Tier -eq 'safe' -or $IncludeAmbiguous }).Count
$windowCount  = @($handles | Where-Object { $_.Kind -eq "window" }).Count

Write-Host ("Watching {0} rules across {1} VS Code window(s)." -f $activeCount, $windowCount) -ForegroundColor Cyan
Write-Host ("Ambiguous: {0}   Offscreen: {1}   FocusSessions: {2}   DryRun: {3}   FocusOnly: {4}" -f
    $IncludeAmbiguous.IsPresent, $IncludeOffscreen.IsPresent,
    (-not $NoFocusSessions.IsPresent), $DryRun.IsPresent, $FocusOnly.IsPresent) -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

$clicks      = 0
$lastClick   = @{}                       # click key -> UTC time of last click
$lastFocus   = @{}                       # waiting label -> UTC time of last focus
$lastRescan  = [DateTime]::UtcNow
$lastReveal  = [DateTime]::MinValue     # last time the sessions list was revealed

while ($true) {

    # Pick up windows opened or closed since last time.
    $sinceRescan = ([DateTime]::UtcNow - $lastRescan).TotalMilliseconds
    if ($roots.Count -eq 0 -or $sinceRescan -ge $RescanWindowsMs) {
        $newHandles = @(Get-TargetHandles)
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
            $roots = @(Get-Roots $handles)
            $wc = @($handles | Where-Object { $_.Kind -eq "window" }).Count
            Write-Host ("Re-attached: {0} window(s)." -f $wc) -ForegroundColor DarkGray
        }
    }

    # --- pass 1: any approve button anywhere, highest priority wins ----------
    $best     = $null
    $bestRank = [int]::MaxValue
    $bestName = ""
    $bestKey  = ""

    foreach ($r in $roots) {
        foreach ($e in (Get-Elements $r $clickableTypes)) {
            $name = Get-ElementName $e
            $rank = Get-Rank $name
            if ($null -eq $rank -or $rank -ge $bestRank) { continue }
            if (-not (Test-Clickable $e $IncludeOffscreen.IsPresent)) { continue }

            $best     = $e
            $bestRank = $rank
            $bestName = Get-NormalizedName $name
            $bestKey  = Get-ClickKey $e $bestName
        }
    }

    # Tracks whether pass 1 actually pressed something this tick. If it only
    # found a match it could not act on - cooldown, dry run, a sticky element
    # that never goes away - we must still fall through to pass 2, or one
    # phantom button starves the session sweep forever.
    $didClick = $false

    if ($best) {
        $since = if ($lastClick.ContainsKey($bestKey)) {
            ([DateTime]::UtcNow - $lastClick[$bestKey]).TotalMilliseconds
        } else { [double]::MaxValue }

        if ($DryRun -or $FocusOnly) {
            $why = if ($FocusOnly) { "focus only" } else { "dry run" }
            Write-Host ("{0}  FOUND '{1}' (rule {2}, {3}, not clicked)" -f
                (Get-Date -Format "HH:mm:ss"), $bestName, ($bestRank + 1), $why) -ForegroundColor Yellow
        }
        elseif ($since -ge $CooldownMs) {
            try {
                if ($IncludeOffscreen) { [void](Show-Element $best) }
                $how = Invoke-Element $best
                $lastClick[$bestKey] = [DateTime]::UtcNow
                $didClick = $true
                $clicks++
                Write-Log ("{0}  CLICKED '{1}' via {2}  (total: {3})" -f
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $bestName, $how, $clicks)

                if ($MaxClicks -gt 0 -and $clicks -ge $MaxClicks) {
                    Write-Host "Reached MaxClicks. Exiting." -ForegroundColor Cyan
                    break
                }
            } catch {
                Write-Warning $_.Exception.Message
                $lastClick[$bestKey] = [DateTime]::UtcNow
            }
        }

        if ($didClick) {
            Start-Sleep -Milliseconds $IntervalMs
            continue
        }
        # Otherwise fall through: there is a match we cannot act on, and the
        # background sessions still need sweeping.
    }

    # --- pass 2: no button on screen, so surface a waiting session ----------
    # A background session's buttons are not in the tree at all. Opening its
    # row in the sessions list makes them appear on the next scan.
    #
    # The sessions list itself only exists in the tree while its view is on
    # screen. If it is hidden, nothing is ever found, so reveal it first -
    # at most once a minute, since it is a visible change to the UI.
    if (-not $NoFocusSessions -and -not $DryRun) {
        $rowsAnywhere = 0
        foreach ($r in $roots) { $rowsAnywhere += @(Find-WaitingRows @($r)).Count }

        if ($rowsAnywhere -eq 0) {
            $sinceReveal = ([DateTime]::UtcNow - $lastReveal).TotalMilliseconds
            if ($sinceReveal -ge 60000) {
                $lastReveal = [DateTime]::UtcNow
                if (Show-SessionsList $roots) {
                    Write-Host ("{0}  revealed the sessions list" -f
                        (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
                    $roots = @(Get-Roots $handles)
                }
            }
        }
    }

    if (-not $NoFocusSessions) {
        foreach ($r in $roots) {
            $done = $false
            foreach ($e in (Get-Elements $r $waitingTypes)) {
                $name = Get-ElementName $e
                if (-not (Test-Waiting $name (Get-ElementType $e))) { continue }

                # The "?" label is usually a child of the real session row.
                $target = Get-ClickableAncestor $e
                if (-not (Test-Clickable $target $true)) { continue }

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
                    $how = Open-SessionRow $target
                    $lastFocus[$name] = [DateTime]::UtcNow
                    Write-Host ("{0}  FOCUSED '{1}' via {2}" -f
                        (Get-Date -Format "HH:mm:ss"), $name, $how) -ForegroundColor Magenta
                    Start-Sleep -Milliseconds 900   # let the session render
                    $done = $true
                    break
                } catch {
                    Write-Warning "Could not focus '$name': $($_.Exception.Message)"
                    $lastFocus[$name] = [DateTime]::UtcNow
                }
            }
            if ($done) { break }
        }
    }

    Start-Sleep -Milliseconds $IntervalMs
}
