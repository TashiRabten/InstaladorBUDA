# InstaladorBUDA

A small **standalone deployment cockpit** for the BUDA apps. Pick a target app and a
version, then **Upload models**, **Deploy (push tag)**, **Trigger workflow**, or
**Publish from an existing run (no rebuild)** — without memorizing any commands. Every
action has a **command fallback**: tick *Dry run* to print the exact command, copy it, or
let it run — its output streams into the tab's log. After a Deploy or Trigger, the log
**follows the GitHub build step by step and reports the release or image publication**
(see 2a), so you don't have to open GitHub to see the result.

Each **tab** is an independent job (its own app, version, notes and log); the **+** tab opens
another, so several releases can run side by side.

It is **fully config-driven**. The app list lives in [`apps.json`](apps.json) next to the
program. Use **Add app** in the GitHub bootstrap group to register a Git-only app and then
continue with the existing preflight / prepare / publish flow. Apps with release workflows
can still be added by editing `apps.json` directly.

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
console selection, GUI layout, CLI cockpit controls, and the WinForms tabs. The build
bundles these modules into the executable, so the distributed `.exe` still needs only
`apps.json`.

### Control the visible cockpit from the CLI

The GUI exposes a local, current-user-only named pipe. CLI requests are applied to the
same tabs and controls used by mouse clicks, so the selected target, version, options,
job status, and output remain visible in the cockpit. Start it from a terminal:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"start"}'
& .\InstaladorBUDA.exe -Cli '{"command":"help"}'
& .\InstaladorBUDA.exe -Cli '{"command":"list"}'
& .\InstaladorBUDA.exe -Cli '{"command":"status"}'
```

`start` opens the visible cockpit if it is not already running. Then configure its first
tab and run a job through the same GUI controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"configure","tab":1,"target":"SegBUDA","version":"1.0.18","notes":"Release notes"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","tab":1,"action":"dispatch","bundles":["essential"],"confirm":true,"waitMs":900000}'
& .\InstaladorBUDA.exe -Cli '{"command":"status","tab":1}'
```

Use `new-tab` and `select-tab` to manage concurrent jobs. `close` closes the cockpit after
the response has been returned. Both `close` and `update` require `"confirm":true`; if any
job is running, also pass `"stopRunning":true` to confirm that it may be stopped. Update
returns an acknowledgement before rebuilding and restarting the cockpit.

An `action` request can also
include `target`, `version`, `publish`, `dryRun`, and `notes` to configure and run in one
call. Bundle IDs/names and model IDs are available from `list`; omit `bundles` to use the
configured defaults, or pass `"all"`. `waitMs` waits for the tab's job to finish and returns
its final status/log tail.

`help` returns the parameter schemas and examples. `release-plan` is a read-only preflight:
it reports the published version, suggested next version, selected tag, branch and HEAD,
working-tree state, and any existing-tag blockers. You can pass `target`, `tab`, and an
optional `version`; with no target/version it uses the selected tab's target and version:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"release-plan","target":"TradutorBUDA"}'
```

### GUI and CLI capability parity

Every operational capability must be available in both the GUI and CLI. GUI buttons and
their CLI actions use the same handlers, command builders, validation, confirmations and
job log. When adding an operation, add its control and CLI route together, then update
`help` and this README.

The command endpoint also has control commands whose GUI equivalent is direct: `start` /
`close` open or close the window, `new-tab` / `select-tab` use the tab strip, `configure`
sets the visible fields, `status` reads the tabs and logs, `list` reads the target and task
choices, and `help` is documented here and in the CLI response. These commands do not
represent extra deployment operations.

The GUI now includes **Release plan** and **Retag existing release** beside Deploy. It also
includes a **GitHub repository bootstrap** group with the same three phases as the CLI:
`Preflight`, `Prepare and stage`, and `Commit and push`. Both paths write to the selected
tab's log. `Prepare and stage` sets up `main` and `origin`, scans and stages the project;
review the staged paths in the log before `Commit and push`. The publish phase checks the
prepared tree again and stops if files changed.

TradutorBUDA's suggested version comes from the newest published release tag, with local
tags as a fallback when no release is available. Deploy checks the local tag, remote tag,
and GitHub release before creating a tag, and stops if that version is already present.
Use `dispatch` to rerun a workflow without moving a tag. Only when you intentionally need
to move an existing remote tag, use the separate `retag-deploy` action with both explicit
flags; it uses a lease against the remote tag object so it will stop if someone changes the
tag after the preflight:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"action","tab":1,"action":"retag-deploy","target":"TradutorBUDA","version":"1.8.1","replaceExistingTag":true,"confirm":true,"waitMs":900000}'
```

Available actions mirror the cockpit: `upload`, `deploy`, `dispatch`, `load-runs`,
`retag-deploy` (with `replaceExistingTag:true`), `publish-run` (with `runId`), `undraft`,
`make-public`, `make-private`, `open-actions`,
`open-release`, `copy-command`, `task` (with `taskName`), `git-status`, `git-add`,
`git-commit`, `git-push`, and `update`. Actions that change a repository or publish work
(`upload`, `deploy`, `retag-deploy`, `dispatch`, `publish-run`, `undraft`, visibility changes, `git-add`,
`git-commit`, `git-push`, and `task`) require `"confirm":true`. Set `dryRun:true` to show
commands in the visible log without running them. CLI output is one JSON response per
command; failures return a nonzero exit code. If the GUI is closed, commands other than
`start` return a clear error.

For example, stage, commit, and push selected files through the same Git panel controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"configure","tab":1,"gitPaths":"InstaladorBUDA.ps1 README.md","commitMessage":"Add cockpit CLI control"}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","tab":1,"action":"git-add","confirm":true,"waitMs":30000}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","tab":1,"action":"git-commit","confirm":true,"waitMs":30000}'
& .\InstaladorBUDA.exe -Cli '{"command":"action","tab":1,"action":"git-push","confirm":true,"waitMs":30000}'
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

Register a Git-only target from the current tab, then continue using those same bootstrap
fields and controls:

```powershell
& .\InstaladorBUDA.exe -Cli '{"command":"add-app","name":"MyApp","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}'
& .\InstaladorBUDA.exe -Cli '{"command":"bootstrap-plan","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}'
```

The GUI's **Add app** button uses the same validation and registration handler. It appends
a Git-only entry to `apps.json`, selects it in all open tabs, and leaves the repo creation
and Git bootstrap phases to their existing controls. When a build workflow is ready, edit
that entry in `apps.json` with the release fields below.

The same sequence is available in the GUI's **GitHub repository bootstrap** group. Enter
the project folder, GitHub `owner/name`, an initial commit message, and optionally a
Gitleaks path. Use **Browse...** to select an existing local project folder; when **App
name** is blank, the selected folder name is suggested. Leave the scanner path blank to use the automatic lookup. Run **Preflight**,
then **Prepare and stage** and review every staged path in the log. Use **Commit and push**
only after that review; the cockpit asks for confirmation before each local or remote
mutation.

Bootstrap requires `git`, authenticated `gh`, a configured Git author name and email, an
empty GitHub remote, and Gitleaks. Gitleaks is found on `PATH` or in a sibling
`gitleaks_*_windows_*` folder; pass `gitleaksPath` to select another executable.
The bootstrap fields can be saved on a tab with `configure` (`bootstrapRoot`, `githubRepo`,
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
tab's log. When it ends, the log shows the release and its files. Done.

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
- The **tab title** shows where it is — `waiting for the run...`, `building (1/3 jobs done)`,
  `checking the release...` — and ends on `done`, or `failed (1)` when the run failed or the
  release is missing.
- If the push or dispatch itself fails, it says so and does not wait for a build.
- While it follows a build the tab is busy; use **+** for another job. Closing the window only
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
from `repoRoot`'s git remote) — that's the repo whose Actions minutes are being spent,
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
the folder is not a git repo. Output goes to the tab's log like any other job.

| Control | What it does |
|---|---|
| **Status** | `git status` — read-only, so it runs without the confirmation dialog. |
| **Add** + field | `git add -- <paths>`: paths separated by spaces, a path with spaces in `"double quotes"` (`"Screenshot 2026-09-02 171631.png" README.md`), `.` for every change. Shows `git status --short --branch` after. |
| **Commit** + Message | `git commit -F <file>`: the message box can hold several lines, accents and quotes — it reaches git exactly as typed (it travels base64-encoded through a temp file, like the release note). Shows the new commit and the status after. |
| **Push** | `git push` of the current branch to its upstream — never `--force`. |

`core.quotepath=false` is passed, so file names with accents or Tibetan print as written. Add,
Commit and Push ask for confirmation (skipped under *Dry run*, which only prints the commands).
InstaladorBUDA's own repo is in `apps.json` too (no build workflow, so its release steps are
off) — pick it as the target to commit and push changes to this cockpit.

## 2e. Update (rebuild + restart)

The **Update (rebuild + restart)** button at the top of the window rebuilds `InstaladorBUDA.exe`
from `InstaladorBUDA.ps1` and reopens it. It closes the window (asking first, and saying which
jobs it would stop), then a console window waits for it to exit, runs `build-exe.ps1` and starts
the new exe. If the build fails, that console stays open with the error and the old exe (or the
`.ps1`) is started instead. The line beside the button shows when the running exe was built, so
you can see the update took effect. The button is off when `build-exe.ps1` is not next to the exe.

## 3. Adding a new app

### 3a. Add a Git-only app in the cockpit or configure a release target

For a new project that only needs Git controls and first-push bootstrap, fill **App name**,
**Project folder**, and **GitHub repo** in the bootstrap group and click **Add app**. The new
target is stored in `apps.json` and selected in each open tab. You can then click
**Preflight**, inspect the plan, prepare and review the staged files, and commit and push
through the existing bootstrap flow. The `add-app` CLI command accepts the same three values.

To configure an app that already has a build/release workflow, add or edit a full entry in
`apps.json`:

```jsonc
{
  "name": "MyApp",
  "repoRoot": "C:\\path\\to\\myapp-repo",      // where the app's git repo lives on disk
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
| `tagPrefix` | For release targets | The release tag is `tagPrefix + version`. A Git-only target leaves this empty. |
| `workflow` | For release targets | Workflow file name (for *Trigger workflow*). A Git-only target leaves this empty. |
| `outputKind` | — | Set to `container-image` for an image workflow with no GitHub Release. InstaladorBUDA hides release-only controls and follows image publication instead. Omit for standard GitHub Release targets. |
| `manageVisibility` | — | Set to `false` to disable the public/private controls for a repo target whose visibility this app should not change. |
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
| `modules/AppSelection.ps1` | Console menu and app/model/bundle selection. |
| `modules/GuiLayout.ps1` | Shared GUI metrics and layout helpers. |
| `modules/Cockpit.ps1` | CLI requests and named-pipe cockpit commands. |
| `modules/Gui.ps1` | Main window and per-tab WinForms controls/handlers. |
| `apps.json` | The app registry. Use **Add app** for Git-only targets or edit for release fields. |
| `build-exe.ps1` | Compiles `InstaladorBUDA.exe` via ps2exe. |
| `README.md` | This file. |
