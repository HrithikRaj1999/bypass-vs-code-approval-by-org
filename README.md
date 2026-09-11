<h1 align="center">approval-auto</h1>

<p align="center">
  <b>Auto-approve VS Code agent prompts — across every window, every chat session, without stealing your cursor.</b>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE">
  <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## The problem

Run several coding agents at once and two things happen.

You spend the day pressing **Allow**. And an agent in a chat you are *not*
looking at stops and waits — silently, sometimes for an hour — because VS Code
only renders the session you have open.

`approval-auto` watches the Windows accessibility tree, finds those prompts
wherever they are, and presses them. It runs from the system tray with no
console, and it does it without moving your mouse pointer or taking focus while
you type.

```console
12:08:22  revealed the sessions list
12:08:22  FOCUSED 'Local session Codebase simplification request (Needs Input)' via PostClick
12:08:26  CLICKED 'Allow' via InvokePattern      (total: 1)
12:08:31  FOCUSED 'Local session SQL discrepancy analysis (Needs Input)' via PostClick
12:08:35  CLICKED 'Keep All Edits' via PostClick (total: 2)
```

One PowerShell file. No install, no `dotnet`, no NuGet, no extension.

---

## Contents

- [Read this first](#read-this-first)
- [How it decides what to press](#how-it-decides-what-to-press)
- [Requirements](#requirements)
- [Setup](#setup)
- [Running it](#running-it)
- [Options](#options)
- [How it works](#how-it-works)
- [Known limits](#known-limits)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Read this first

These buttons are the human review step before VS Code **runs terminal
commands**, **fetches URLs**, and **writes files**. Automating them means
nothing gets reviewed.

Use it only when you already trust the work the agent is doing.

Work up to it in stages:

```powershell
approval-auto.ps1 -DryRun       # watches, presses nothing
approval-auto.ps1 -FocusOnly    # really opens sessions, still presses nothing
approval-auto.ps1 -MaxClicks 1  # approves exactly once, then exits
```

For GitHub Copilot chat specifically, VS Code has native settings that are safer
and more granular — `chat.tools.autoApprove`, `chat.tools.terminal.autoApprove`,
`chat.tools.edits.autoApprove`. Use those where they cover your case. This tool
exists for the prompts they do not reach.

---

## How it decides what to press

### Approve rules — 44 active

Extracted from VS Code's own string table (`nls.messages.json`), not guessed.
Matched with anchored regex, in priority order. **Least privilege wins:** a
one-off `Allow` is preferred over `Allow in this Session`, which beats
`Always Allow`.

| Group | Examples |
|---|---|
| One-off | `Allow`, `Allow Once`, `Allow and Review Once`, `Approve`, `Allow Access` |
| Session scoped | `Allow in this Session`, `Allow Tools from {0} in this Session`, `Allow All Commands in this Session` |
| Workspace scoped | `Allow in this Workspace`, `Allow a folder in this workspace` |
| Permanent | `Always Allow`, `Always Allow Exact Command Line`, `Always Allow Tools from {0}` |
| Terminal | `Run Command`, `Run Commands`, `Allow all commands starting with {0}` |
| Network / URL | `Allow requests to {0}`, `Allow responses from {0}`, `Allow Network` |
| Bulk | `Allow All`, `Approve all`, `Allow and Skip Reviewing Result` |
| Edits | `Keep`, `Keep All Edits`, `Keep All Chat Edits`, `Accept All` |

Run `-ShowTargets` to print all of them with their priority.

### Never pressed

```
\?$                       questions and titles, e.g. "Allow tool call?"
^Skip                     Skip, Skip All, Skip Changes, Skip Results
^Don't Allow  ^Deny  ^Reject  ^Disallow
^Cancel  ^Discard  ^Undo  ^Delete  ^Remove  ^Stop  ^Archive
^Proceed without executing            the deny button on terminal prompts
^Continue Without Signing In
^Configure Auto Approve  ^Enable Auto Approve
^Allow requests to\.\.\.$             a picker, not an approval
```

Anything inside a **MenuBar** or **TitleBar** is also excluded — see
[Known limits](#known-limits) for why that matters.

### Off by default — `-IncludeAmbiguous`

Five more rules exist but are disabled: `Continue`, `Run`, `Accept`,
`Keep Going`, `Approve Plan Only`.

They are not approval buttons. The debug toolbar, test explorer, merge editor
and inline suggestions use those exact labels and sit on screen permanently.
Enabling them once caused this tool to open VS Code's menu-bar **Run** menu 13
times in 13 seconds. The 44 default rules already cover every real prompt.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 |
| Shell | Windows PowerShell 5.1 (`powershell.exe`) |
| Install | none — UI Automation ships with Windows |
| Editors | VS Code, VS Code Insiders, and Electron forks via `-ProcessNames` |

---

## Setup

### 1. Copy the files

```
approval-auto.ps1      the tool
approval-auto.vbs      launcher, starts it hidden in the tray
```

### 2. Turn on the accessibility tree

VS Code is Electron, and Chromium keeps its accessibility tree switched off
until something asks for it.

`Ctrl+Shift+P` → *Preferences: Open User Settings (JSON)* → add:

```jsonc
"editor.accessibilitySupport": "on"
```

**Restart VS Code.** Without this you will see exactly three controls:
`Minimize`, `Restore`, `Close`.

### 3. Verify

```powershell
powershell -ExecutionPolicy Bypass -File approval-auto.ps1 -Diag
```

```
Windows attached:
  pid 37800   window  0x00710660  Chrome_WidgetWin_1            luma_mcp - Visual Studio Code
  pid 37800   render  0x00470EDC  Chrome_RenderWidgetHostHWND   luma_mcp - Visual Studio Code

1 VS Code window(s), 2 handle(s) total.

Element counts per root:
  root 0:  2876 elements,  534 clickable  [Chrome_WidgetWin_1]

Sessions currently waiting:
  ListItem  Local session Codebase simplification (Needs Input), created 9/11/2026, 10:33:23 AM

Tree looks alive.
```

`none right now` just means nothing is waiting. If element counts are near zero,
relaunch VS Code with `code --force-renderer-accessibility`.

---

## Running it

### Background — the normal way

Double-click **`approval-auto.vbs`**.

No console, no window. A coloured dot appears in the system tray.

| Dot | Meaning |
|:--:|---|
| 🟢 | idle |
| 🟠 | something is waiting |
| 🔵 | approving right now |
| 🔴 | error — hover the icon for the message |

Right-click the dot:

| Item | Does |
|---|---|
| **Allow All now** | Clear everything immediately. Double-clicking the icon does the same. |
| **Auto-approve** | On by default. Untick to keep a manual gate — the dot still turns amber. |
| **Open log** | Opens `approval-auto.log`, every approval timestamped. |
| **Exit** | Quits, like any other app. |

The launcher passes `-Background -IncludeOffscreen -NoCursor`. Edit the `cmd`
line in the `.vbs` to change that.

Only one copy runs at a time. A second launch prints a notice and exits.

**Start at logon:** `Win+R` → `shell:startup` → drop a shortcut to
`approval-auto.vbs` in that folder.

### Foreground — for watching it work

```powershell
# print all rules, the waiting-session detector, and the blocklist
approval-auto.ps1 -ShowTargets

# show what is on screen; matches print green, waiting sessions amber
approval-auto.ps1 -List

# watch and report, press nothing
approval-auto.ps1 -DryRun

# really open waiting sessions, but never approve
approval-auto.ps1 -FocusOnly

# approve once, then exit
approval-auto.ps1 -MaxClicks 1

# run continuously with a log
approval-auto.ps1 -IncludeOffscreen -NoCursor -LogFile approvals.log
```

### Floating panel instead of a tray icon

```powershell
approval-auto.ps1 -Hud
```

A small always-on-top window with a live count, an **Allow All** button and an
auto-approve checkbox.

### Other editors

```powershell
approval-auto.ps1 -ProcessNames "Cursor"
approval-auto.ps1 -ProcessNames "Code - Insiders"
```

Run `-List` first — forks relabel their buttons, and `-ExtraPatterns` lets you
add whatever they use.

---

## Options

### Modes

| Flag | Description |
|---|---|
| `-Background` | Tray icon, no console, single instance. The normal way to run it. |
| `-Hud` | Always-on-top panel with a count and an Allow All button. |
| `-Diag` | Print windows, element counts and waiting sessions. Exit. |
| `-ShowTargets` | Print every rule, the detector and the blocklist. Exit. |
| `-List` | Print what is on screen now, marking matches. Exit. |
| `-DryRun` | Watch and report. Presses nothing, opens nothing. |
| `-FocusOnly` | Really opens waiting sessions, but never approves. |

### Behaviour

| Flag | Default | Description |
|---|---|---|
| `-NoCursor` | off | Post clicks to the window instead of driving the mouse. No pointer movement, no focus theft. |
| `-IncludeOffscreen` | off | Also press buttons scrolled out of view. |
| `-IncludeAmbiguous` | off | Add the five ambiguous rules. See the warning above. |
| `-NoFocusSessions` | off | Never open other sessions; only act on what is already visible. |
| `-AllTypes` | off | With `-List`, show every control type. |
| `-MaxClicks` | `0` | Stop after N approvals. `0` means forever. |
| `-LogFile` | auto | Where to append approvals. Defaults to `approval-auto.log` beside the script in `-Background`. |
| `-ProcessNames` | `Code`, `Code - Insiders` | Which editor processes to watch. |

### Timing

| Flag | Default | Description |
|---|---|---|
| `-IntervalMs` | `1000` | Milliseconds between scans. |
| `-CooldownMs` | `2500` | Gap before pressing the same button in the same place again. |
| `-SessionCooldownMs` | `6000` | Gap before reopening the same session. |
| `-SweepMs` | `12000` | How often to sweep for background approvals when the screen looks idle. |
| `-RescanWindowsMs` | `15000` | How often to look for new or closed VS Code windows. |

### Custom rules

| Flag | Description |
|---|---|
| `-ExtraPatterns` | Regex patterns to treat as approve buttons, highest priority. |
| `-ExcludePatterns` | Regex patterns to never press, added to the blocklist. |
| `-ExtraWaitingPatterns` | Regex patterns marking a session as waiting. Off by default — see below. |

```powershell
# approve tool calls, never touch edits
approval-auto.ps1 -ExcludePatterns '^Keep', '^Accept'

# add a button this build uses
approval-auto.ps1 -ExtraPatterns '^Yes, proceed$'
```

---

## How it works

Six problems had to be solved. Each is worth knowing if you fork this.

### 1. Chromium hides its accessibility tree

Electron builds a tree only once a client sends `WM_GETOBJECT` with
`OBJID_CLIENT` to the render widget. Attach to the top-level window alone and
you get three controls: `Minimize`, `Restore`, `Close`.

The tool posts that message to every `Chrome_RenderWidgetHostHWND` child and
waits 1.5s for the tree to appear.

### 2. One process owns every window

`Process.MainWindowHandle` returns a single handle however many VS Code windows
are open, because Electron's main process owns them all. The Agent Sessions
window was invisible until this switched to `EnumWindows` across the desktop,
filtered by owning PID and window class.

### 3. Labels are templates, not strings

```
Allow (Ctrl+Enter)                     ->  Allow
Allow python in this Session           ->  ^Allow .+ in this Session$
Split Editor Right (Ctrl+\) [Alt] ...  ->  Split Editor Right
```

Names are normalized — strip the `[Alt] …` tail, strip trailing `(…)`
keybinding hints — then matched with anchored regex. Exact-string matching
cannot work here.

### 4. The editor lives in the same tree

The chat transcript and every open document share one accessibility tree with
the UI. An early version matched wording like `Needs attention`, so writing that
phrase in a document made the tool believe a session was waiting. Markdown
bullets in chat arrive as `ListItem`, so anchoring the regex did not help — a
table cell reading exactly `1 pending confirmation` is a genuine exact match.

Detection is structural instead. VS Code builds every session row from one
template in `nls.messages.json`:

```
"{0} session {1} ({2}), created {3}"
```

```
Local session Codebase simplification request (Needs Input), created 9/11/2026, 10:33:23 AM
      kind    title                             status         timestamp
```

The status in brackets is what gets read. Prose cannot imitate that shape.
Three further guards: labels over 300 characters are rejected, labels containing
a line break are rejected, and `Text` elements are not scanned at all unless you
opt in with `-ExtraWaitingPatterns`.

### 5. Session rows are barely clickable

They expose **only** `ScrollItemPattern` — no `Invoke`, no `SelectionItem` — and
`GetClickablePoint()` throws:

```
Patterns: ScrollItemPatternIdentifiers.Pattern
ClickablePoint FAILED: MethodInvocationException
Rect=1864,134,676,76
```

`BoundingRectangle` is valid, so the click chain is:

1. `InvokePattern` — no pointer movement, works off screen
2. `SelectionItemPattern`
3. **`PostClick`** — `WM_LBUTTONDOWN`/`UP` posted to the window at that point
4. `GetClickablePoint()` + real cursor click
5. Real cursor click at the centre of `BoundingRectangle`

Step 3 is what `-NoCursor` enables, and it is why the tool does not interrupt
you. Posted messages skip `WM_MOUSEACTIVATE`, so the window is never brought to
the front and the pointer never moves. Posted input is not guaranteed to be
handled, so if the session does not open, it escalates once to a real click
rather than looping on a dead row.

### 6. Being inside a chat hides everything

This is the one that matters most, and the hardest to see.

The sessions list only exists in the accessibility tree while its view is on
screen. Open a chat and the list is replaced — so the rows vanish, nothing is
found, and background approvals pile up unseen. That is exactly the situation
the tool is for.

So when a scan finds nothing, it does not conclude there is nothing to do. It
presses **Show Agent Sessions Sidebar**, rescans, and works through whatever
turns up. The sidebar is left open afterwards, so it only happens once.

Two related failures had to be fixed for that to work at all:

- **`OrCondition` throws with a single condition.** The reveal looked up one
  control type, the exception was swallowed by a `catch`, and it silently found
  zero buttons — so the reveal never fired, ever.
- **Pass 1 starved pass 2.** The loop skipped session sweeping whenever it
  *found* an approve button, even when it could not press it — cooldown, dry
  run, or a sticky element that never goes away. One phantom match blocked
  background approvals permanently. It now only skips when it actually pressed
  something, and a button pressed four times with no effect is ignored for the
  rest of that sweep.

---

## Known limits

**Long session lists are virtualized.** VS Code only renders the rows you can
see. With 110 sessions, 17 exist in the tree. A waiting session scrolled below
the fold cannot be found. `ScrollPattern` is not exposed on that list and posted
`WM_MOUSEWHEEL` messages are ignored by Chromium, so it cannot be scrolled
programmatically either. In practice `(Needs Input)` sessions sit under
**Today** at the top, which is within the rendered set.

**Opening a background session switches your chat view.** Not keyboard focus —
your typing is untouched — but the panel will be showing that session
afterwards, not the one you were reading. Opening it is the only way its buttons
enter the tree at all.

**Up to `-SweepMs` delay** (12s by default) before a background approval is
noticed. Lower it with `-SweepMs 5000`.

**Canvas-drawn buttons are invisible.** UI Automation reads elements, not
pixels. Anything painted straight to a canvas needs image matching instead.

**Windows only.** It is built on Windows UI Automation.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Only `Minimize` / `Restore` / `Close` listed | `editor.accessibilitySupport` not set, or VS Code not restarted |
| Tree still empty afterwards | Relaunch with `code --force-renderer-accessibility` |
| `Sessions currently waiting: none` but one is | It is scrolled out of the rendered rows — see Known limits |
| Runs silently, approves nothing | Run PowerShell at the same privilege level as VS Code |
| Button on screen but never listed | Canvas-drawn; UI Automation cannot see it |
| Wrong buttons pressed | Remove `-IncludeAmbiguous` |
| Cursor jumps while typing | Add `-NoCursor`; check the log for `MouseClickRect` instead of `PostClick` |
| Chat view keeps changing | Expected when clearing background sessions. `-NoFocusSessions` stops it, at the cost of missing them |
| Keeps hopping between sessions | Raise `-SessionCooldownMs` |
| Tray icon lingers after exit | Cosmetic Windows behaviour; hover over it and it disappears |

### Reading the log

```
FOCUSED ... via PostClick        headless, nothing was interrupted
FOCUSED ... via MouseClickRect   real cursor click, the posted one did not land
CLICKED 'Allow' via InvokePattern    headless
Ignoring stuck 'Keep'            pressed repeatedly with no effect, skipped
revealed the sessions list       the list was hidden and has been opened
```

---

## License

MIT.
