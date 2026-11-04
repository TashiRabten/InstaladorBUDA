# InstaladorBUDA

A small **standalone deployment cockpit** for the BUDA apps. Pick a target app and a
version, then **Upload models**, **Deploy (push tag)**, **Trigger workflow**, or
**Publish from an existing run (no rebuild)** — without memorizing any commands. Every
action has a **command fallback**: tick *Dry run* to print the exact command, copy it, or
let it run — its output streams into that session's log. After a Deploy or Trigger, the log
**follows the GitHub build step by step and reports the release or image publication**
(see 2a), so you don't have to open GitHub to see the result.

Each **session** is an independent job with its own app, version, notes and log. Use the
**Session** dropdown to switch between release, GitHub and bootstrap work; **New session**
opens another job so several operations can run side by side.

The main window's operation groups are also expandable sections: click a heading to hide or
show its controls. This applies to the GitHub groups as well, keeping the work area compact.

It is **fully config-driven**. The app list lives in [`apps.json`](apps.json) next to the
program. Use **Add app** in the GitHub bootstrap group (or the `add-app` CLI command) to
register an app in one step: it writes the whole entry, reading the release fields from the
project's `.github/workflows`, and logs a check of every control it wired. The checklist of
what "fully wired" means is in [`MDs/adicionar-app.md`](MDs/adicionar-app.md).

---

## 1. Run it

**As a script (no build):**
```powershell
.\InstaladorBUDA.ps1            # GUI
.\InstaladorBUDA.ps1 -Console   # text menu (auto-used if no GUI is available)
```

**As a standalone `.exe`:**
```powershell
.\build-exe.ps1                 # produces InstaladorBUDA.exe (installs ps2exe if needed)
```
Then double-click `InstaladorBUDA.exe`. **Keep `apps.json` in the same folder as the
`.exe`** — it is read at runtime so you can add/edit apps without recompiling.
When the script changes, rebuild/restart the executable before using new CLI commands;
an already-open executable keeps its original embedded script. The cockpit's **Update**
button performs that rebuild and warns if running jobs would be stopped.

The source is split across `modules/`: `AppRegistry.psm1` owns the app registry,
`GitBootstrap.ps1` owns first-push setup, and separate files hold release operations,
console selection, GUI layout, native file dialogs, CLI cockpit controls, and the WinForms
session panels. The build bundles these modules into the executable, so the distributed `.exe` still needs only
`apps.json`.

### Control the visible cockpit from the CLI

The GUI exposes a local, current-user-only named pipe. CLI requests are applied to the
same session selector and controls used by mouse clicks, so the selected target, version,
options, job status, and output remain visible in the cockpit. Start it from a terminal:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"start"}'
& .\InstaladorBUDA.exe -Cli '{"command":"help"}'
& .\InstaladorBUDA.exe -Cli '{"command":"list"}'
& .\InstaladorBUDA.exe -Cli '{"command":"status"}'
```

`start` opens the visible cockpit if it is not already running. Then configure its first
session and run a job through the same GUI controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"configure","session":1,"target":"SegBUDA","version":"1.0.18","notes":"Release notes"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"dispatch","bundles":["essential"],"confirm":true,"waitMs":900000}'
& .\InstaladorBUDA.exe -Cli '{"command":"status","session":1}'
```

Use `new-session` and `select-session` to manage concurrent jobs. `close-session` removes
the selected session after confirmation; `new-tab` and `select-tab` remain aliases.
`close` closes the cockpit after the response has been returned. Both `close` and `update` require `"confirm":true`; if any
job is running, also pass `"stopRunning":true` to confirm that it may be stopped. Update
returns an acknowledgement before rebuilding and restarting the cockpit.

An `action` request can also
include `target`, `version`, `publish`, `dryRun`, and `notes` to configure and run in one
call. Bundle IDs/names and model IDs are available from `list`; omit `bundles` to use the
configured defaults, or pass `"all"`. `waitMs` waits for the session's job to finish and returns
its final status/log tail. `status` returns `sessions` and a backwards-compatible `tabs` alias.

`help` returns the parameter schemas and examples. `release-plan` is a read-only preflight:
it reports the published version, suggested next version, selected tag, branch and HEAD,
working-tree state, and any existing-tag blockers. You can pass `target`, `session` (or the
older `tab` field), and an optional `version`; with no target/version it uses the selected
session's target and version:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"release-plan","target":"TradutorBUDA"}'
```

### GUI and CLI capability parity

Every operational capability must be available in both the GUI and CLI. GUI buttons and
their CLI actions use the same handlers, command builders, validation, confirmations and
job log. When adding an operation, add its control and CLI route together, then update
`help` and this README.

The command endpoint also has control commands whose GUI equivalent is direct: `start` /
`close` open or close the window, `new-session` / `select-session` / `close-session` use the
Session dropdown and its buttons, `configure` sets the visible fields, `status` reads sessions
and logs, `list` reads the target and task
choices, and `help` is documented here and in the CLI response. These commands do not
represent extra deployment operations.

The GUI now includes **Release plan** and **Retag existing release** beside Deploy. It also
includes a **GitHub repository bootstrap** group with the same three phases as the CLI:
`Preflight`, `Prepare and stage`, and `Commit and push`. Both paths write to the selected
session's log. `Prepare and stage` sets up `main` and `origin`, scans and stages the project;
review the staged paths in the log before `Commit and push`. The publish phase checks the
prepared tree again and stops if files changed.

The bootstrap group also has **Actions secrets...**. It targets the selected app's GitHub
repository and opens a manager with the existing secret names, an add/update field, and a
delete option. Values are masked and passed to `gh secret set` through standard input; they
never go in a CLI request, process arguments, a temporary file, or the job log. The GUI asks
before adding/replacing or deleting a secret. The CLI action opens that same manager and
requires explicit confirmation. It returns a scheduled acknowledgement before opening the
dialog; after closing it, inspect the session log or request `status` for the result:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"target":"ScanBUDA","action":"actions-secrets","confirm":true}'
```

Do not add `secret`, `token`, `value`, `apiKey`, or `password` to the request JSON. The
handler rejects those fields. Close the manager to leave the repository unchanged. Secret
names follow [GitHub's Actions naming rules](https://docs.github.com/en/actions/reference/security/secrets#naming-your-secrets); the manager lists names only because GitHub does not
return stored secret values. For ScanBUDA's private OCR bridge, use the name
`TRADUTORBUDA_REPO_TOKEN` and a fine-grained token with read-only access to the private
TradutorBUDA repository. The rebuilt executable exposes the action in `help`.

The value reaches `gh` as UTF-8 with no byte-order mark. Earlier builds, running with a
UTF-8 console code page (Windows' "Use Unicode UTF-8 for worldwide language support"), sent
the bytes `EF BB BF` before the value, and GitHub rejected a token saved that way with
`HTTP 401: Bad credentials`. Save any secret entered through an earlier build again. Not yet
verified in the app: no real secret has been saved through the rebuilt dialog.

The bootstrap group also has **Git ignore...** for the selected project folder. It opens the
existing `.gitignore`, lets you add a pattern or comment and remove selected lines, and saves
only when you click **Save**. Existing comments and entries stay in place unless you edit or
remove them. The CLI opens the same visible manager and returns a scheduled acknowledgement:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"gitignore","session":1,"repoRoot":"C:\\work\\MyApp"}'
```

The **Agent chat...** button in the Git group opens an in-app prompt window for the selected
app. Choose an agent profile and a conversation from their dropdowns, type a prompt, and
send it without leaving the installer. The window does not block the cockpit: you can keep
working in the main window while it is open, and clicking **Agent chat...** again brings it
back to the front. A running agent counts as a running job when the cockpit or its session
closes, and closing the cockpit closes the chat and stops its agent. Starter profiles for three common coding CLIs are
created on first use; **Help...** in **Configure agents** lists their values and sign-in
requirements. **Configure agents...** adds profiles, chooses a
local `.exe`, `.cmd` or `.bat` with Browse, and sets arguments plus whether the prompt is
passed as an argument or through standard input. Standard input is the default for new
profiles; argument mode places the prompt in the process command line and is refused for
`.cmd`/`.bat` commands, which Windows re-parses. Commands are looked up on `PATH`, the saved
user/system `PATH`, and npm's global folder.

Each profile also has a **Permission** and a **Model**. The chat runs the CLI without a
terminal, so no one can answer its permission prompts; Permission decides up front:
**Full access (no prompts)** (the default) lets the agent edit files and run commands,
**Edit files only** refuses commands that need approval, and **Read-only** changes nothing.
For the three starter CLIs these become their own flags (for example Full access is
`--permission-mode bypassPermissions` for one and `--dangerously-bypass-approvals-and-sandbox`
for another); other CLIs take such flags in Arguments. **Model** is passed as the CLI's model
option; leave it empty for the CLI's default. A flag typed in Arguments takes precedence.

The embedded chat disables automatic account connectors for the CLI that supports the
`apps` feature, matching SuiteBUDA's default and avoiding repeated HTTP response-decoding
errors. This affects only chat launches; explicit MCP servers, global configuration and
**Open in terminal** keep their existing behavior. To opt in, set **Arguments** to
`--enable apps exec -` in **Configure agents...**. An explicit `apps` feature flag or
`features.apps` configuration argument takes precedence. Not yet verified in the app.

While an agent works, its steps appear in the conversation as they happen (tool calls and
progress lines, indented under **Agent**), a progress bar runs, and the status line shows the
elapsed time and how long it has been quiet. The steps are kept with the reply. **Stop**
ends the agent and any process it started. Conversations stay local to this Windows user and
are protected with Windows user encryption; the executable uses its existing local sign-in.
The first send in a conversation states what the agent may do and asks to continue. Not yet
verified in the app with a real agent run. The CLI can open the same chat window:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"code-cli","target":"MyApp","confirm":true}'
```

The chat cannot run a CLI's interactive commands, so **Open in terminal** (beside **Configure
agents...**) starts the selected agent's CLI interactively in a terminal window of its own, in
the project folder, without a prompt. Use it to sign in (`/login`) and for the CLI's own slash
commands (`/mcp`, `/model` and others), then come back to the chat. The session gets the
profile's Permission and Model flags (Kiro starts as `kiro-cli chat`) but not its Arguments,
which are written for the chat's non-interactive runs. The terminal runs through `cmd /k`, so
the window stays open when the CLI exits and a command such as `codex login` or
`kiro-cli login` can be typed there. The button is unavailable while the chat runs a prompt.
The CLI clicks the same button, opening the chat first when it is closed; `agent` picks the
profile by name (default: the selected one). Not yet verified in the app.

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"code-cli-terminal","target":"MyApp","agent":"Claude Code","confirm":true}'
```

The **Project folder** Browse button in **Add app** and the executable Browse button use
Windows' native file dialog. Each purpose remembers its last folder and keeps recent folders
in the navigation pane; the executable selector supports multiple selection even though the
installer uses the first selected executable.

TradutorBUDA's suggested version comes from the newest published release tag, with local
tags as a fallback when no release is available. Deploy checks the local tag, remote tag,
and GitHub release before creating a tag, and stops if that version is already present.
Use `dispatch` to rerun a workflow without moving a tag. Only when you intentionally need
to move an existing remote tag, use the separate `retag-deploy` action with both explicit
flags; it uses a lease against the remote tag object so it will stop if someone changes the
tag after the preflight:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"retag-deploy","target":"TradutorBUDA","version":"1.8.1","replaceExistingTag":true,"confirm":true,"waitMs":900000}'
```

Available actions mirror the cockpit: `upload`, `deploy`, `dispatch`, `load-runs`,
`retag-deploy` (with `replaceExistingTag:true`), `publish-run` (with `runId`), `undraft`,
`make-public`, `make-private`, `open-actions`,
`open-release`, `copy-command`, `task` (with `taskName`), `git-status`, `git-add`, `git-unstage`,
`git-commit`, `git-push`, and `update`. Actions that change a repository or publish work
(`upload`, `deploy`, `retag-deploy`, `dispatch`, `publish-run`, `undraft`, visibility changes, `git-add`,
`git-unstage`, `git-commit`, `git-push`, and `task`) require `"confirm":true`. Set `dryRun:true` to show
commands in the visible log without running them. CLI output is one JSON response per
command; failures return a nonzero exit code. If the GUI is closed, commands other than
`start` return a clear error.

For example, stage, commit, and push selected files through the same Git panel controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"configure","session":1,"gitPaths":"InstaladorBUDA.ps1 README.md","commitMessage":"Add cockpit CLI control"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"git-add","confirm":true,"waitMs":30000}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"git-commit","confirm":true,"waitMs":30000}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"git-push","confirm":true,"waitMs":30000}'
```

A path staged by mistake leaves the next commit with `git-unstage`, which reads the same `gitPaths`
field (the file on disk is not touched):

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"configure","session":1,"gitPaths":"apps.json notes.bak"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"git-unstage","confirm":true,"waitMs":30000}'
```

To initialize a local project against an existing, empty GitHub repository, use the
bootstrap preflight, prepare, and publish commands. Preflight is read-only. Prepare sets
the branch to `main`, configures `origin`, scans and stages files; inspect the visible
staged-path list before publishing. Publish commits as your configured Git identity and
pushes `main` to `origin`. A successful prepare records the staged tree in `.git`, and
publish stops if that tree or the working files changed afterward:

```powershell
$base = @{ repoRoot = 'C:\path\to\project'; githubRepo = 'owner/repository'; waitMs = 30000 }
$plan = $base + @{ command = 'bootstrap-plan' }
& .\InstaladorBUDA.exe -Cli ($plan | ConvertTo-Json -Compress)
$prepare = $base + @{ command = 'bootstrap-prepare'; confirm = $true }
& .\InstaladorBUDA.exe -Cli ($prepare | ConvertTo-Json -Compress)
$publish = $base + @{ command = 'bootstrap-publish'; commitMessage = 'Initial project commit'; confirm = $true }
& .\InstaladorBUDA.exe -Cli ($publish | ConvertTo-Json -Compress)
```

Register a target from the current session, then continue using those same bootstrap
fields and controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"add-app","name":"MyApp","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}'
& .\InstaladorBUDA.exe -Cli '{"command":"gitignore","session":1,"repoRoot":"C:\\work\\MyApp"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","action":"create-repo","githubRepo":"owner/MyApp","confirm":true}'
& .\InstaladorBUDA.exe -Cli '{"command":"bootstrap-plan","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}'
```

The GUI's **Add app** button uses the same validation and registration handler. It appends
the complete entry to `apps.json` (see 3a), selects it in all open sessions and logs the
wiring check; the `add-app` reply carries the same check (`wiring`, `fullyWired`) and the
entry. **Create private repo** creates the empty GitHub repository from the `owner/name`
field inside InstaladorBUDA; it does not upload files.

`status` reports, for each session, the visibility label read from GitHub (`visibility`),
the repository it reads (`visibilityRepo`) and whether **Make public** / **Make private** are
enabled (`visibilityToggle`). `list` gives each target's own repository (`githubRepo`),
release repository and branch, and `manageVisibility`.

The same sequence is available in the GUI's **GitHub repository bootstrap** group. Enter
the project folder, GitHub `owner/name`, an initial commit message, and optionally a
Gitleaks path. Use **Browse...** to select an existing local project folder; when **App
name** is blank, the selected folder name is suggested. If the GitHub repo field still
contains the selected target's default, Browse also suggests `owner/folder-name`. Click
**Add app** to register it. If its remote does not exist yet, click **Create private repo**;
this creates an empty private repository without publishing files. Leave the scanner path blank to use the
automatic lookup. Run **Preflight**, then **Prepare and stage** and review every staged path
in the log. Use **Commit and push** only after that review; the cockpit asks for confirmation
before each local or remote mutation.

Bootstrap requires `git`, authenticated `gh`, a configured Git author name and email, an
empty GitHub remote, and Gitleaks. Managing Actions secrets requires authenticated `gh`
with permission to manage repository secrets. Gitleaks is found on `PATH` or in a sibling
`gitleaks_*_windows_*` folder; pass `gitleaksPath` to select another executable.
The bootstrap fields can be saved on a session with `configure` (`bootstrapRoot`, `githubRepo`,
`bootstrapMessage`, and `gitleaksPath`); later bootstrap commands use those values when
the corresponding request fields are omitted.

**Prerequisites:** [`git`](https://git-scm.com/) and the
[GitHub CLI `gh`](https://cli.github.com/) on `PATH`, with `gh auth login` done once.
If either is missing, InstaladorBUDA still runs and just **prints the commands** for you
to run elsewhere.

---

## 2. The deployment model (how a release reaches users)

Desktop apps publish GitHub Releases into **one release repo** (`TashiRabten/GlossarioBUDA`),
which the website and in-app updaters read. The Namsel daemon publishes a versioned image
to GHCR; Flux watches that image and updates the Kubernetes deployment. Each target is
distinguished by its **tag** and/or **workflow**. For GitHub Releases, the rule is:

> **The git tag is the source of the version.** Push `…-v<version>` and that exact version
> is injected into the installer, the release, and what the app shows at runtime. You never
> hand-edit a version file.

Three actions, in order:

| Action | What it does | When |
|---|---|---|
| **Upload models** | Zips large model files and uploads them to a `*-models-*` release (assets too big for git). | Once per app, and again only when a model changes. |
| **Deploy (push tag)** | Checks the local tag, remote tag, and release first, then creates a new tag and pushes it → the app's build workflow fires. It stops if the version already exists. Desktop targets publish installers and a release; a `container-image` target publishes its image and reports the Flux handoff. | New releases; for SegBUDA, also supports one selected bundle. |
| **Trigger workflow** | `gh workflow run …` with the configured inputs, dispatched directly (no local `git tag`/`git push`). Desktop targets can publish a GitHub Release; a `container-image` target always publishes the image. A dispatched version does not update local tags. | Test/manual builds, or re-runs. |

Current desktop and daemon targets:

| App | Tag pushed | Build workflow | Published output |
|---|---|---|---|
| **TradutorBUDA** | `tradutor-buda-v1.4.5` | `build-app-installers.yml` | GlossarioBUDA release `v1.4.5` — `TradutorBUDA-1.4.5.{exe,pkg}` |
| **SegBUDA** | `segbuda-v1.0.0` | `build-segbuda.yml` | GlossarioBUDA release `segbuda-v1.0.0` — tiered installers |
| **Namsel** | `namsel-v1.0.0.5` | `build-namsel.yml` | GlossarioBUDA release `v1.0.0.5` — `NamselOCR_Installer.{exe,pkg}` |
| **Namsel Kubernetes release** | `namsel-ocr-v1.3.5` | `publish-namsel-ocr-image.yml` | GHCR image `ghcr.io/tashirabten/namsel-ocr:1.3.5`; Flux updates the deployment manifest |

**Typical desktop release:** open InstaladorBUDA → pick the app → the version pre-fills (current +1)
→ **Upload models** only if a model changed → **Deploy (push tag)** → watch the build in the
session's log. When it ends, the log shows the release and its files. Done.

If the selected version already has a tag or release, use `release-plan` to see the collision
and choose a new version. To rerun work for an existing version, use **Trigger workflow**;
`retag-deploy` is reserved for an intentional move of an existing tag and requires both
`replaceExistingTag:true` and `confirm:true`.

For **Namsel Kubernetes release**, use the versioned tag flow. The workflow writes the
tag's version into `docker/version.properties` before building the image. Flux's
`ImageUpdateAutomation` then commits the matching image tag to the Kubernetes repo; the
InstaladorBUDA job confirms image publication but does not wait for the cluster rollout.
The **Namsel Kubernetes GitOps** target opens the Flux repo in the Git panel so its update
commit can be inspected.
This InstaladorBUDA integration is compiled but not yet verified in the running app.

---

## 2a. Following the build in the log

After **Deploy** or **Trigger workflow** runs, the same job keeps going: it finds the workflow
run that the step started (the newest run of the app's `workflow` created after you clicked —
for Deploy, the run for the pushed tag) and reports it until it finishes, checking every 8 s.

```
Run 36358766934: https://github.com/TashiRabten/TradutorBUDA/actions/runs/36358766934
[windows]   ▶ Build installer with Inno Setup
[windows]   ✓ Build installer with Inno Setup  1m 59s
[windows]   · Upload .exe artifact (test runs only — not published) (skipped)
[windows] ✓ success  3m 44s
Run finished: success in 4m 48s

Release tradutor-buda-v1.7.20 on TashiRabten/GlossarioBUDA: PUBLISHED 2026-09-27 18:32
  TradutorBUDA-1.7.20-arm64.pkg                    329.9 MB
  TradutorBUDA-1.7.20.exe                          309.4 MB
```

For a `container-image` target, the log reports the successful image workflow and that
Flux can advance the manifest. Confirm the cluster rollout in the Kubernetes repo or its
deployment dashboard.

| Line | Meaning |
|---|---|
| `▶` / `✓` / `✗` / `·` | a step started / succeeded / failed / was skipped (with how long it took) |
| `Run finished:` | the run's result and total time |
| `Release …: PUBLISHED` / `DRAFT` | the release on the app's release repo, and each file attached to it. `DRAFT` means it is not public yet — **Un-draft release** publishes it. |

- **Trigger with *Publish* unchecked** is a test build: no release is expected, so the log lists
  the run's **artifacts** instead (release them later with *Publish selected run*).
- **Publish selected run** and **Un-draft release** end with the same release report.
- The **Session dropdown** shows where each job is — `waiting for the run...`, `building (1/3 jobs done)`,
  `checking the release...` — and ends on `done`, or `failed (1)` when the run failed or the
  release is missing.
- If the push or dispatch itself fails, it says so and does not wait for a build.
- While it follows a build that session is busy; use **New session** for another job. Closing the window only
  stops the following — the build keeps going on GitHub.
- `-Console` mode reports the same way after it runs the commands.

---

## 2b. Publish from an existing run — no rebuild

The **"Publish from existing run (no rebuild)"** panel attaches installers that a *previous*
build already produced to a release, **without re-running the slow build** (the macOS leg
especially). Use it when a build is green but wasn't published, or a publish run built but
didn't finalize.

| Control | What it does |
|---|---|
| **Workflow** | Defaults to the app's build workflow; the dropdown lists every workflow in the repo so you can pick another. |
| **Load runs** | Lists the latest 20 runs of that workflow (date, conclusion, title, branch) and preselects the newest **successful** one. |
| **Publish selected run** | Downloads that run's installer **artifacts** (`.exe/.pkg/.dmg/.msi`) and uploads them to the release tag `tagPrefix+version` on the app's release repo — creating the release (targeting `releaseBranch`) if needed, then un-drafting it. **No rebuild.** |
| **Un-draft release** | Flips an existing **draft** release public (`--draft=false`). Use when a *publish* run already uploaded installers straight to a draft release (so there are no artifacts to download) but didn't finalize. |
| **Open release** | Opens the release page for `tagPrefix+version` in the browser. |

**Artifacts vs. draft — which to use:** the build workflows upload installers as run
**artifacts on test runs**, but on **publish runs** they upload **straight to the release**
(a draft) and never create artifacts. So:
- green **test** run → **Publish selected run** (downloads its artifacts).
- **publish** run that built but didn't finalize → **Un-draft release** (no artifacts exist).

The release tag/repo come from `version`, `tagPrefix`, and `releaseRepo`/`releaseBranch` in
`apps.json` — BUDA apps publish to `TashiRabten/GlossarioBUDA`; standalone apps to their own
repo (the group header shows the resolved release repo).

---

## 2c. Repo visibility (public / private toggle)

A **"Repo visibility"** panel (GUI) / `v`/`p` actions (console) let you flip an app's
**own repo** — not the release repo — between public and private without leaving the
dashboard. This is for the common situation where a private repo's Actions minutes run
out: flip it public to deploy for free, then flip it back private once the build lands.

| Control | What it does |
|---|---|
| **(status label)** | Shows the selected app's current visibility, read live via `gh repo view --json visibility`. Turns red when public, green when private, so you don't forget a repo left public. |
| **Make public** | Runs `gh repo edit <repo> --visibility public --accept-visibility-change-consequences`. Asks for confirmation first (skipped under *Dry run*). |
| **Make private** | Same, with `--visibility private`. No confirmation prompt — reverting to private is the safe direction. |

This always targets **the app's own repo** (resolved the same way as *Publish from run*,
from `repoRoot`'s git remote, else the entry's `githubRepo`) — that's the repo whose Actions minutes are being spent,
which is not necessarily `TashiRabten/GlossarioBUDA` (the release repo installers get
published to). `--accept-visibility-change-consequences` is passed automatically so the
command doesn't hang waiting on an interactive confirmation `gh` would otherwise print.

**Auth:** this uses the same `gh` CLI session as everything else in InstaladorBUDA — there's
no separate token field. If you want a *different* GitHub account/token than whatever `gh`
is currently logged in as, run `gh auth login` (or `gh auth switch`) once in a terminal;
InstaladorBUDA picks up whatever `gh` is authenticated as. `gh auth login` accepts a
personal access token directly (`gh auth login --with-token < token.txt`) if you'd rather
not go through the browser flow. Changing visibility requires the token/account to have
admin rights on the repo.

## 2d. Git (status / add / commit / push)

A **"Git"** group runs git in the selected app's `repoRoot`. Its title shows the app, the
current branch and the folder (`Git -> TradutorBUDA [main] C:\...`); the buttons are off when
the folder is not a git repo. Output goes to the session's log like any other job.

| Control | What it does |
|---|---|
| **Status** | `git status` — read-only, so it runs without the confirmation dialog. |
| **Add** + field | `git add -- <paths>`: paths separated by spaces, a path with spaces in `"double quotes"` (`"Screenshot 2026-09-02 171631.png" README.md`), `.` for every change. Shows `git status --short --branch` after. |
| **Unstage** | `git restore --staged -- <paths>` of the paths in the Add field: they leave the next commit (their index entry goes back to the last commit's) and the files on disk stay as they are; `.` unstages everything. For a path that `.` staged by mistake, such as a backup or a shortcut. Shows `git status --short --branch` after. |
| **Commit** + Message | `git commit -F <file>`: the message box can hold several lines, accents and quotes — it reaches git exactly as typed (it travels base64-encoded through a temp file, like the release note). Gitleaks first scans the staged changes (`gitleaks git --pre-commit --staged`, findings redacted); a finding, a scanner error, or no Gitleaks found stops before `git commit`. Shows the new commit and the status after. |
| **Push** | `git push` of the current branch to its upstream — never `--force`. Gitleaks first scans the commits the upstream does not have yet (the whole history on a first push) and stops the push on a finding. |

`core.quotepath=false` is passed, so file names with accents or Tibetan print as written. Add,
Unstage, Commit and Push ask for confirmation (skipped under *Dry run*, which only prints the commands).
InstaladorBUDA's own repo is in `apps.json` too (no build workflow, so its release steps are
off) — pick it as the target to commit and push changes to this cockpit.

## 2e. Update (rebuild + restart)

The **Update (rebuild + restart)** button at the top of the window rebuilds `InstaladorBUDA.exe`
from `InstaladorBUDA.ps1` and reopens it. It closes the window (asking first, and saying which
jobs it would stop), then a console window waits for it to exit, runs `build-exe.ps1` and starts
the new exe. If the build fails, that console stays open with the error and the old exe (or the
`.ps1`) is started instead. The line beside the button shows when the running exe was built, so
you can see the update took effect. The button is off when `build-exe.ps1` is not next to the exe.

The exe is a console program so that `-Cli` can print its JSON reply. When it opens the window, it
starts itself once more without a console window and the first copy exits, so no empty terminal
window stays behind. This matters when Windows Terminal hosts consoles, the Windows 11 default:
such a window cannot be hidden, and closing it used to close the cockpit. A terminal may flash
briefly at launch.

## 2f. Suggested changes (a PR without access to GitHub)

TradutorBUDA can change its own code on a user's machine. A user who wants that change in the app
for everyone has no access to the private repository and none of the project's secrets: the app
writes the change as a signed bundle (`.budafix`, in `~/.tradutorbuda/sugestoes`), this section
sends it to a Supabase inbox, and only the maintainer's cockpit turns it into a branch and a pull
request. The inbox is TradutorBUDA's `dev/security/supabase-fix-inbox.sql` (v2): contributors are
invited Supabase accounts registered as developers; the maintainer has no account and uses the
admin passphrase. Every session has the group **Sugestões de mudança (PR sem acesso ao GitHub)**.

**Configurar...** stores, per Windows user (`%LOCALAPPDATA%\InstaladorBUDA\fix-inbox.json`): the
Supabase project URL and its *publishable* key (a secret `sb_secret_…` key, or a JWT whose role
is not `anon`, is refused), the bundles folder, the TradutorBUDA install whose BundleTool is used
(`<install>\runtime\bin\java.exe -cp <install>\app\TradutorBUDA.jar
com.example.glossariobuda.selfcode.BundleTool`), the developer registry and the root public key,
where downloaded bundles and worktrees go, and the highest registry version seen (an older
registry is then refused as a rollback). No password or passphrase is ever stored there.

**Contributor — Sugerir mudança (PR)...** Pick the `.budafix`; the window shows what its manifest
says (title, app and version, the files and whether each is changed, new or deleted, the
capabilities the change adds, the signing key). Sign in with the e-mail and password of the
invited account: the password is typed in a masked field, goes into one request, and is
neither stored, logged nor accepted from the CLI; only the session token is kept, in memory.
**Enviar sugestão** inserts the row with the bundle in it (`bundle_b64`, at most 4 MiB); the
database checks the SHA-256 and size against the bytes, the account's registered key and app, the
open switch and the hourly cap. A bundle already in the inbox is not sent twice. The list shows
this account's suggestions and their status (received, PR opened, merged, declined with the
maintainer's note); before signing in it shows the last status this machine saw
(`%LOCALAPPDATA%\InstaladorBUDA\fix-sent.json`).

**Maintainer — Sugestões recebidas...** Type the admin passphrase and click **Usar**: it is checked
by listing the inbox and then held as a SecureString in that window only, until **Esquecer** or
the window closes. **Baixar e verificar** fetches the bundle (`fix_inbox_bundle`), checks it
against the row's SHA-256 and size, and runs `BundleTool bundle-verify` against a detached
worktree at the release tag (`tradutor-buda-v<version>`, made once per version under the
worktree folder, checked out with `core.autocrlf=true` like the Windows build that ships the
sources). When the clone has no such tag (a release built through **Trigger workflow** runs on
`main` and is tagged only in the release repository: on 2026-11-02 `tradutor-buda-v1.8.11`,
`scanbuda-v1.0.16` and `suitebuda-v1.0.5` were missing from the app repositories), the review
first fetches the tag from GitHub and otherwise tags, in this clone only and never pushed, the
commit the release was built from: the one run of the app's workflow that was running when each
`.exe` of the release was uploaded, all from the same commit (`Find-FixReleaseBuildCommit`).
The bundle's base hashes are then checked against that commit's files, as for any release.
The report shows the verdict and every problem, the capabilities the change adds and
those beyond the developer's ceiling **first**, then who, which branch and which files, then the
diff against the release. Nothing is branched or built until **Abrir PR...**, which asks first
(and asks again when the change goes beyond the ceiling) and runs as a job of the session:
a worktree on the branch the verifier returned (`contrib/<id>/<slug>`, from the root-signed
registry, never from the bundle), `bundle-apply` (which verifies again), a commit authored by
you that credits the contributor by name, Gitleaks on the staged change and on the commits the
branch adds, `git push`, `gh pr create --base main`, and then `pr-opened` and the PR address
written back to the row (`fix_inbox_set_status`). It stops before anything if the bundle changed
since it was verified or the branch already exists here or on GitHub. **Mesclar PR...**
(`gh pr merge --merge`, after the build, the targeted tests and the Codacy mirror in the PR's
worktree) and **Recusar...** (a note for the developer; an open PR is closed) are separate
confirmed actions. **Verificar arquivo local...** verifies a bundle on disk the same way.
**Registrar desenvolvedores...** registers in the inbox each developer of the registry BundleTool
has just verified (each must have been invited first, with the same e-mail); **Fechar a caixa** /
**Abrir a caixa** is the kill switch.

**Adicionar desenvolvedor...** (`modules/FixDevInvite.ps1`) brings a new developer in from this one
window, with the admin passphrase already given to **Usar**. The form takes the name, the e-mail, the
id (`contrib/<id>/`, made from the name without accents until it is edited), the apps (all apps by
default, which the inbox stores as `SuiteBUDA` and the registry as an empty `apps` list),
**Sênior** (may change protected classes: kept on the developer row in Supabase and written as
`"senior": true` in the registry entry; only the root-signed registry grants it) and, optionally, the
person's public key (the `ssh-ed25519` line from Segurança do código ▸ Copiar chave
pública). After one confirmation it calls the `dev-invite` Edge Function (SuiteBUDA
`supabase/functions/dev-invite`; the publishable key goes on `apikey` only, the passphrase in the
body, checked by the function itself). The function approves the e-mail, creates the account with
`generateLink` type `invite`, asks Supabase to e-mail the invitation, and calls `dev_access_grant`
(SuiteBUDA `supabase/20261104_dev_access_grant.sql`, service role only) so the account is a developer
at once and its apps register their own key on the first `/sugerir`. The invitation lands on the
site's `/set-password` page.

When Supabase cannot send the e-mail, the account is still created and a separate window
(**Convite para …**) says why, with a ready message and the link to copy and send by hand. The two
known causes: the hourly e-mail quota, and Supabase's built-in sender, which writes only to members
of the Supabase organization, so **every outside invitation needs custom SMTP configured in the
project** before it can be e-mailed. An account that already existed gets no e-mail and the link
(which sets a new password) is shown the same way. The link appears only in that window: it is not
written to the log and not returned to the CLI (the reply says only whether it was shown). If the
account was created but `dev_access_grant` failed, the status says so; adding the same person again
completes it.

With a public key, the cockpit then verifies the registry, writes its next version with the new
developer beside it (unsigned) and opens the `registry-sign` console, where the root password is
typed; **Verificar registro** afterwards confirms it. Without a key the person can already send
suggestions; add them again with the key when it arrives. With **Dry run**, only the request
(passphrase left out) is written to the log.

**Only an invited developer compiles** (TradutorBUDA, ScanBUDA and SuiteBUDA from the versions that carry
`security/Invitation.java`), and the invitation is all it takes: the person accepts it on the site and does nothing
else. The first time Ctrl+F5 or Ctrl+Shift+F5 asks for the password, the app asks for the e-mail and password of the
invitation instead: it signs in, makes the developer identity with that same password (the site's page asks for at
least 10 characters, the identity's rule), and the inbox's `dev-attest` function confirms the invitation for that
key. It signs who, which apps, senior and until when (30 days, renewed at each unlock while the account is signed in)
with the inbox's key, whose public half every app carries (`registry\convites.pub`; the private half is the
function's secret `DEV_INVITE_SIGNING_KEY`). SuiteBUDA takes the identity an app made and confirms through the
session the apps share. The apps check that signature offline. The root-signed registry still counts: it holds your
own keys, and a key it suspends stays out whatever the inbox says; each app keeps the newest one verified
(`developer-registry.json`; on the maintainer's computer it also reads
`%LOCALAPPDATA%\InstaladorBUDA\registry\developers.json`) and refuses an older one. With neither, Ctrl+F5,
Ctrl+Shift+F5 and the agent's tool (in SuiteBUDA, keeping a build) are refused and at start a kept patch is set
aside; a lapsed confirmation stops a compile, not a start. The review of a suggestion still needs the key in the
registry: **Chaves novas...** lists the keys the inbox confirmed that the registry lacks
(`fix_inbox_developer_keys`), writes its next version with them (the invitation's apps and senior; nothing removed)
and opens the signing console; **Publicar registro** runs `registry-verify` and sends the signed file as text
(`dev_registry_publish`) for the apps. Server side: SuiteBUDA `supabase/20261104_dev_registry.sql` and
`supabase/functions/dev-attest`.

Closing the window does not cost a suggestion its PR. What a job found out goes to the row with
the passphrase, and the passphrase leaves with the window, so the status first waits in
`%LOCALAPPDATA%\InstaladorBUDA\fix-pending.json` (no secret in it; `fix-status` lists it as
`pendingStatus`) and reaches the row at the next **Usar** or **Atualizar lista**; a window opened
while the job ran takes it at once. Those two also ask GitHub about the rows still without a PR
(`gh pr list`, once per repository, only when there is such a row): a PR is the row's only when
its branch is `contrib/<id>/<slug>` in the repository itself, not a fork, and its body carries the
package hash. An open PR gives `pr-opened`, a merged one `merged`; a closed one is left to the
maintainer, because declining takes a note. Not yet verified in the app.

**Verificar registro** runs `BundleTool registry-verify` and lists the developers in the log.
**Assinar registro...** opens a console that runs `BundleTool registry-sign`: the root password is
typed in that console, never in the cockpit.

With **Dry run** checked nothing is sent to Supabase or GitHub: the requests (with the password and
the passphrase left out) and the PR commands are written to the session log.

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-suggest","bundle":"C:\\Users\\me\\.tradutorbuda\\sugestoes\\corrige.budafix"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-suggest-send","confirm":true}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-inbox"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-inbox-verify","id":12}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-inbox-open-pr","confirm":true,"waitMs":900000}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","session":1,"action":"fix-status"}'
```

Every button has a CLI action that clicks it (`fix-settings`, `fix-suggest`, `fix-suggest-send`,
`fix-suggest-refresh`, `fix-sign-out`, `fix-inbox`, `fix-inbox-refresh`, `fix-inbox-verify` with
`id` or `bundle`, `fix-inbox-open-pr` with `overrideCeiling`, `fix-inbox-decline` with `id` and
`note`, `fix-inbox-merge` with `id`, `fix-inbox-register`, `fix-inbox-add-developer` with `name`,
`email` and optionally `developerId`, `apps` (`["all"]` by default, or `TradutorBUDA` / `ScanBUDA`),
`publicKey` and `senior`, `fix-inbox-new-keys`, `fix-registry-publish`, `fix-inbox-open` / `fix-inbox-close` with
`maxPerHour`, `fix-inbox-forget`, `fix-registry-verify`, `fix-registry-sign` with `in` and
`rootIdentity`); `fix-status` reads both windows. Signing in and **Usar** have no CLI route on
purpose: the password and the passphrase are typed only in the window, and a request carrying
`password`, `passphrase`, `token` or a similar field is refused. Actions that send, build, push,
merge, decline, register, add a developer or a key, publish the registry or switch the inbox need
`"confirm":true` (or `dryRun:true`).
SuiteBUDA suggestions use its installed runtime and the trusted launcher dispatcher
`org.budasuite.SuiteBUDA --bundle-tool`; the reviewer and PR both use `app/src/main/java`.
Configure the SuiteBUDA install in **Configurar...** or `fix-settings` with `suiteInstall`
(`scanInstall` selects ScanBUDA independently). Signature, registry, capability and base-hash
checks are mandatory for each app. A developer must be authorized for SuiteBUDA in the
root-signed registry and in the inbox before sending.

For the initial SuiteBUDA base version `0.0.0`, there is no published release tag. Set its
`suggestionBaseCommit` in `apps.json` to the exact 40-character initial commit; a branch name
is refused. Versions after that use `suitebuda-v<version>` exclusively. The base hashes still
have to match that commit. After the PR is merged, select SuiteBUDA and use **Test build**
(`dispatch`, `publish:false`) to run `build-suitebuda-installer.yml` with `version` and
`publish` inputs. Publishing to GlossarioBUDA requires the release signing configuration.
The integration passes `tests\FixSuite.Tests.ps1`; not yet verified in the app.

`tests\FixInbox.Tests.ps1` runs both flows with no network: a Supabase stand-in with the schema's
rules, a bare repository as GitHub, a recording `gh`, and TradutorBUDA's own BundleTool with a
temporary root key and registry. Not yet verified in the app.

## 3. Adding a new app

### 3a. Add an app in the cockpit (GUI or CLI)

Fill **App name**, **Project folder**, and **GitHub repo** in the bootstrap group and click
**Add app** (the `add-app` CLI command takes the same three values and clicks the same
button). One click writes the complete entry: `githubRepo` (the app's own repository),
`manageVisibility: true`, and — when the project has a release workflow in
`.github/workflows` (`build-app-installers.yml`, else `build-installers.yml`, else the only
workflow with a push-tag trigger and dispatch inputs) — `workflow`, `tagPrefix`,
`versionFromGitTag`, `versionFromReleaseTag`, `releaseRepo` / `releaseBranch` (from the
workflow's `RELEASE_REPO` and `RELEASE_BRANCH` / `RELEASE_TARGET`, else its own repository)
and `dispatchInputs` (`version`, `publish`, `release_notes`, `bundles`). A project without a
release workflow becomes a Git-only target. `apps.json` refuses a new entry that lacks one of
these fields, so neither path can register a half-wired app.

The new target is selected in each open session and the log lists a check per control family
(registry, project folder, Git, GitHub repository, visibility, Actions page, Actions secrets
with the secrets the workflow reads, release steps). A project not yet on GitHub continues
with **Create private repo**, **Preflight**, **Prepare and stage**, and **Commit and push**.
The full checklist, including what the app's own repository must provide, is
[`MDs/adicionar-app.md`](MDs/adicionar-app.md).

Afterwards, edit the entry by hand only for what a workflow file cannot say: set
`manageVisibility` to `false` for a repository the cockpit must never make public, or add
`uploadScript` / `uploadModels` / `bundles` / `outputKind`. A full entry looks like this:

```jsonc
{
  "name": "MyApp",
  "repoRoot": "C:\\path\\to\\myapp-repo",      // where the app's git repo lives on disk
  "githubRepo": "owner/MyApp",                  // the app's own repository (visibility, Actions, secrets)
  "releaseRepo": "TashiRabten/GlossarioBUDA",   // where its releases are published
  "manageVisibility": true,                     // Make public / Make private enabled
  "tagPrefix": "myapp-v",                       // tag = tagPrefix + version
  "workflow": "build-myapp.yml",                // workflow file name in that repo
  "releaseBranch": "myapp",                     // target_commitish for the release (or "")
  // "outputKind": "container-image",             // optional: publishes an OCI image, not a GitHub Release

  // ONE of these tells InstaladorBUDA the current version (to pre-fill +1):
  "versionFile": "VERSION",                     //   read a file…
  "versionRegex": "([0-9.]+)",                  //   …and capture group 1
  // "versionFromGitTag": "myapp-v*",           //   …or take the highest existing tag

  // OPTIONAL model upload. Either point at the repo's own script…
  "uploadScript": "scripts\\upload-myapp-models.ps1",
  // …or declare assets and let InstaladorBUDA zip+upload them generically:
  "models": [
    { "tag": "myapp-models-v1", "repo": "TashiRabten/GlossarioBUDA", "items": [
      { "name": "big-model", "path": "models\\big-model", "type": "folder" },
      { "name": "weights",   "path": "models\\weights.bin", "type": "file" }
    ]}
  ],

  // OPTIONAL, only with uploadScript: a per-model picker (checklist in the GUI, a
  // numbered prompt in -Console). Each entry's "path" (relative to repoRoot) is checked
  // with Test-Path so a model whose folder isn't on THIS machine shows "not found
  // locally" and starts unchecked. "default": true pre-checks it (when found). The
  // upload script itself must accept a matching -Models [string[]] parameter — see
  // upload-segbuda-models.ps1. Omit entirely to just run uploadScript with no args.
  "uploadModels": [
    { "name": "big-model", "path": "models\\big-model", "default": true },
    { "name": "extra-model", "path": "models\\extra-model", "default": false }
  ],

  // Inputs passed to `gh workflow run`. {version} and {publish} are substituted.
  "dispatchInputs": [
    { "name": "version", "value": "{version}" },
    { "name": "publish", "value": "{publish}" }
    // add { "...", "onlyIfPublish": true } for inputs that should appear only when publishing
  ]
}
```

**Field reference**

| Field | Required | Meaning |
|---|---|---|
| `name` | ✅ | Shown in the dropdown. |
| `repoRoot` | ✅ | Absolute path to the app's git repo on your machine. May be any repo — InstaladorBUDA can drive many. |
| `githubRepo` | ✅ for new entries | The app's own `owner/name`. The origin remote wins when the folder is its own repository; this field covers an app registered before its first push. Visibility, *Load runs*, *Open Actions page* and *Actions secrets* use it. |
| `tagPrefix` | For release targets | The release tag is `tagPrefix + version`. A Git-only target leaves this empty. |
| `workflow` | For release targets | Workflow file name (for *Trigger workflow*). A Git-only target leaves this empty. |
| `outputKind` | — | Set to `container-image` for an image workflow with no GitHub Release. InstaladorBUDA hides release-only controls and follows image publication instead. Omit for standard GitHub Release targets. |
| `manageVisibility` | ✅ for new entries | `true` enables **Make public** / **Make private** (Add app writes `true`; an older entry without it counts as `true`). Set to `false` for a repo whose visibility this app should not change. |
| `releaseBranch` | — | `target_commitish` if the updater filters by branch; otherwise `""`. Also used as `--target` when *Publish from run* creates the release. |
| `releaseRepo` | — | Repo that hosts this app's **releases**. Omit for BUDA apps (defaults to `releaseRepoDefault` = `TashiRabten/GlossarioBUDA`); set it to the app's own `owner/repo` for standalone apps that publish to themselves. Used by *Publish from run* / *Un-draft*. |
| `versionFile` + `versionRegex` | one of these¹ | Read current version from a file (capture group 1). |
| `versionFromGitTag` | one of these¹ | Or read the highest existing tag matching this glob. |
| `versionFromReleaseTag` | one of these¹ | Read the highest published, non-draft release tag matching `tagPrefix`; use the matching Git tag setting as a fallback. |
| `uploadScript` | — | A `.ps1` (relative to `repoRoot`) that uploads the models. Preferred if present. |
| `models` | — | Declarative assets to zip+upload when there is no `uploadScript`. |
| `uploadModels` | — | Per-model checklist shown before running `uploadScript` (checkboxes in the GUI, numbered prompt in `-Console`); passes the checked names as `-Models 'a','b',...`. Missing-on-this-machine folders are flagged and start unchecked. Omit to just run `uploadScript` with no args. |
| `bundles` | — | Per-bundle checklist shown before *Deploy* and *Trigger workflow* (checkboxes in the GUI, numbered prompt in `-Console`). Lets one tier ship without rebuilding the others. *Trigger workflow* passes the checked ids as the `{bundles}` dispatch-input placeholder (comma-joined, e.g. `essential,audio`); *Deploy* writes them as a `Bundles: <ids>` line in the annotated tag message, since a tag push carries no inputs — `build-segbuda.yml` reads that line. Every bundle ticked → no line, all bundles build. |
| `dispatchInputs` | ✅ | `-f name=value` pairs for `gh workflow run`; `{version}`/`{publish}`/`{bundles}` are templated; `onlyIfPublish` skips the input unless *Publish* is ticked. |

¹ If neither is given, the version defaults to `1.0.0` (still editable in the UI).

### 3b. What the new app's repo must provide (the deployment strategy)

InstaladorBUDA only **pushes the tag / triggers the workflow**. The app's own repo must
contain a workflow that does the rest. Model the workflow on
[`build-app-installers.yml`](../.github/workflows/build-app-installers.yml) /
[`build-namsel.yml`](../.github/workflows/build-namsel.yml). It must:

1. **Trigger** on `push: tags: ['myapp-v*']` **and** `workflow_dispatch` (with a `version`
   input) so both InstaladorBUDA actions work.
2. **Derive the version from the tag** and inject it into the app's version file, e.g.:
   ```bash
   V="${VERSION_INPUT}"
   [[ "${GITHUB_REF}" == refs/tags/myapp-v* ]] && V="${GITHUB_REF_NAME#myapp-v}"
   ```
   Inject `V` into the build (Maven `-Dapp.version=$V`, a `sed` into `version.py`, etc.) so
   the installer, the release, and the runtime version all agree.
3. **Pull big models** (if any) from the `*-models-*` release with
   `gh release download <models-tag> --repo <release-repo> --pattern '<name>.zip'`, matching
   what InstaladorBUDA's *Upload models* produced (one `<name>.zip` per item, the folder/file
   at the zip's top level).

4. **Build** the platform installers.
5. **Publish**: create the release on the release repo if missing, targeting `releaseBranch`,
   then `gh release upload --clobber` the installers. Cross-repo publishing needs a PAT —
   reuse the `GH_PAT` secret pattern already in the other workflows.

For a `container-image` target, the workflow publishes the image tag instead of creating a
GitHub Release. If the daemon reports its version from a file, set that version from the
validated tag or dispatch input inside the workflow before building the image.

If models are too big for git (the common reason to use a `*-models-*` release), add an
upload helper modeled on
[`upload-segbuda-models.ps1`](../scripts/upload-segbuda-models.ps1) /
[`upload-namsel-models.ps1`](../scripts/upload-namsel-models.ps1) and point `uploadScript`
at it — **or** just fill in the declarative `models` block and let InstaladorBUDA do it.

### 3c. Verify

Pick the new app in InstaladorBUDA, tick **Dry run**, and click each step to confirm the
generated commands look right before running for real.

---

## 3d. Tasks (non-release utilities)

The **Tasks** dropdown runs one-off commands that aren't app releases — e.g. rebuilding
the portable Tesseract bundle. Add them to the `tasks` array in `apps.json`:

```jsonc
"tasks": [
  {
    "name": "Rebuild Tesseract Intel bundle  (run on your Intel Mac VM)",
    "runOn": "mac",                 // mac = can't run on Windows; InstaladorBUDA shows + copies it
    "cwdRepo": "TradutorBUDA",       // working dir = this app's repoRoot
    "command": "bash scripts/build-tesseract-mac.sh --upload"
  },
  {
    "name": "Trigger Tesseract CI  (build arm64 + fetch Intel)",
    "runOn": "local",                // local = run in a console (or print under Dry run)
    "cwdRepo": "TradutorBUDA",
    "command": "gh workflow run build-tesseract-portable.yml"
  }
]
```

`runOn: "mac"` commands are **shown and copied to the clipboard** (Windows can't run mac
bash) so you paste them into the VM terminal; `runOn: "local"` commands run in a console
window or print under *Dry run*.

> **Tesseract deployment.** The installer build fetches the Intel Tesseract bundle from the
> `tesseract-portable-v1` release instead of building it on a slow `macos-13` runner. Seed it
> once with the first task above on your Intel Mac, then it just works.

## 4. Its own repo

InstaladorBUDA is self-contained (`InstaladorBUDA.ps1`, `modules/`, `apps.json`,
`build-exe.ps1`, `README.md`). To split it out:

```powershell
# from a copy of this folder
git init
git add .
git commit -m "InstaladorBUDA: standalone deployment cockpit"
git remote add origin https://github.com/<you>/InstaladorBUDA.git
git push -u origin main
```

Because `repoRoot` is absolute per app, InstaladorBUDA can live anywhere and drive every
BUDA app repo from one place. After moving it, just keep `apps.json` beside the `.exe` and
update each `repoRoot` if your checkout paths differ.

---

## 5. Files

| File | Purpose |
|---|---|
| `InstaladorBUDA.ps1` | Small entrypoint: loads modules and chooses CLI, console, or GUI startup. |
| `modules/AppRegistry.psm1` | App registry class and safe `apps.json` registration. |
| `modules/GitBootstrap.ps1` | Empty-remote preflight, prepare, and publish logic. |
| `modules/ReleaseOperations.ps1` | Release, Git, workflow, and follow-up commands. |
| `modules/AppWiring.ps1` | Add app's complete entry (release fields read from the project's workflow), the per-control wiring check, the app's Actions page, and the CLI `list` reply. |
| `modules/AppSelection.ps1` | Console menu and app/model/bundle selection. |
| `modules/GuiLayout.ps1` | Shared GUI metrics and layout helpers. |
| `modules/FilePicker.ps1` | Native Windows file/folder dialogs with per-purpose folder memory. |
| `modules/GitIgnore.ps1` | `.gitignore` editor dialog with safe, explicit saves. |
| `modules/AgentProfiles.ps1` | Agent profiles, command lookup, and the Configure agents and setup-help windows. |
| `modules/AgentOutput.ps1` | Reads an agent's output while it runs and turns it into steps and the reply. |
| `modules/CodeCli.ps1` | Encrypted local conversations and the in-app prompt window. |
| `modules/AgentTerminal.ps1` | Open in terminal: runs an agent's CLI interactively in its own terminal window. |
| `modules/FixInbox.ps1` | Suggested changes: settings, the publishable-key check, reading a bundle's manifest. |
| `modules/FixInboxClient.ps1` | The Supabase inbox: contributor sign-in and submissions, the maintainer's `fix_inbox_*` functions, the local records of what was sent and of the statuses still to be written. |
| `modules/FixReview.ps1` | BundleTool with the installed runtime, the release worktree, the diff, the verification report, the registry. |
| `modules/FixPullRequest.ps1` | The Abrir PR / Mesclar PR / close jobs, the status written back to the row, and the lookup of a PR the row lost. |
| `modules/FixInboxGui.ps1` | The session group, Configurar..., sign-in and passphrase rows, the step runner. |
| `modules/FixSuggestWindow.ps1` | Sugerir mudança (PR): the contributor's window. |
| `modules/FixInboxWindow.ps1` | Sugestões recebidas: the maintainer's window. |
| `modules/FixDevInvite.ps1` | Adicionar desenvolvedor...: the form, the `dev-invite` request, the invitation-link window, the next registry version for signing; Chaves novas... and Publicar registro. |
| `modules/FixInboxCli.ps1` | The `fix-*` CLI actions and `fix-status`. |
| `modules/CockpitHelp.ps1` | The CLI `help` reply: commands, parameters, examples and safety notes. |
| `modules/Cockpit.ps1` | CLI requests and named-pipe cockpit commands. |
| `modules/Gui.ps1` | Main window, session dropdown, and independent WinForms job panels. |
| `apps.json` | The app registry. **Add app** writes complete entries; edit by hand only for fields a workflow cannot give. |
| `build-exe.ps1` | Compiles `InstaladorBUDA.exe` via ps2exe. |
| `tests/FixInbox.Tests.ps1`, `tests/FixInbox.Flow.ps1`, `tests/FixInboxFakes.ps1`, `tests/fixtures/MakeBundle.java` | Suggested changes end to end with no network (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixInbox.Tests.ps1`); needs TradutorBUDA's compiled classes beside this folder and its installed runtime, else the end-to-end part is skipped. |
| `tests/FixPrStatus.Tests.ps1` | A window closed during a PR, merge or decline job: the status waits and reaches the row; a row whose status was lost finds its PR on GitHub (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixPrStatus.Tests.ps1`). |
| `tests/FixDevInvite.Tests.ps1` | Adicionar desenvolvedor... with no network: the form's rules, the request, each e-mail outcome through the real window driven by the CLI, the link kept out of CLI replies, the registry draft (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixDevInvite.Tests.ps1`). |
| `tests/AddApp.Tests.ps1` | Add app tests: workflow reading, the complete entry, the wiring check, and the GUI and CLI add paths in a headless STA window (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\AddApp.Tests.ps1`). |
| `tests/GitUnstage.Tests.ps1` | Unstage from the button and from `git-unstage` on a temporary repository: the named paths leave the index, their files stay as they are, and the other git actions still reach their buttons (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\GitUnstage.Tests.ps1`). |
| `MDs/adicionar-app.md` | Checklist of what a fully wired app needs (Portuguese). |
| `README.md` | This file. |

### Retry, pull requests and conflict resolution

**Retry last failed job** repeats the failed job in its original target session. For a failed
release-tag build it finds that tag's existing workflow run instead of pushing the tag again.
Use **Workflow runs: retry or publish → Load runs → Retry selected run** to repeat an entire
GitHub run, or **Retry failed jobs** to repeat only its failed jobs. Retry retains the original
commit and workflow inputs, waits for the new attempt, and follows its result. Use a fresh
version or Trigger workflow when changed source must be built. An unchanged Retag explains
this choice; a failed tag push can be resumed when the local tag still matches HEAD.

The **Pull requests** section lists open PRs, creates a PR from a pushed head branch to the
chosen base, and merges a selected PR number. Merge pins the inspected head commit and keeps
GitHub's normal checks. Suggested bundles retain their existing signature/review/PR route.

**Git → Pull** merges the upstream without rebasing. Commit or stash local changes first.
A divergent merge is left uncommitted for review. **Resolve conflicts…** opens a modeless
editor with local, incoming, common-ancestor and editable result views. Save resolution
checks that the file has not changed, rejects leftover markers, and stages that file.
Complete merge requires no unresolved files and runs Gitleaks before committing.
The editor supports UTF-8 text up to 1 MB; binary/deleted/linked conflicts require another editor.

GUI and CLI use the same handlers:

```json
{"command":"action","action":"rerun-failed","session":1,"runId":"123456","confirm":true}
{"command":"action","action":"pr-create","session":1,"prBase":"main","prHead":"feature/change","prTitle":"Describe change","prBody":"Details","confirm":true}
{"command":"action","action":"pr-merge","session":1,"prNumber":"7","confirm":true}
{"command":"action","action":"git-pull","session":1,"confirm":true}
{"command":"action","action":"merge-tool","session":1}
{"command":"action","action":"merge-save","session":1,"mergeFile":"path.txt","mergeResult":"Resolved text\n","confirm":true}
{"command":"action","action":"merge-continue","session":1,"confirm":true}
```

Other routes: `retry-last-job`, `rerun`, `pr-list`, `merge-refresh`, `merge-file`,
`merge-use-local`, and `merge-use-incoming`. The conflict window must belong to the selected target.
New modules: `RecoveryOperations.ps1` and `MergeTool.ps1`, bundled into the standalone EXE.
Not yet verified by the user in the app.
