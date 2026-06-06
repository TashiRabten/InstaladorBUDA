# InstaladorBUDA

A small **standalone deployment cockpit** for the BUDA apps. Pick a target app and a
version, then **Upload models**, **Deploy (push tag)**, or **Trigger workflow** — without
memorizing any commands. Every action has a **command fallback**: tick *Dry run* to print
the exact command, copy it, or let it run in a real console window.

It is **fully config-driven**. The app list lives in [`apps.json`](apps.json) next to the
program. **Adding a new app is a JSON edit — no code changes.**

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

**Prerequisites:** [`git`](https://git-scm.com/) and the
[GitHub CLI `gh`](https://cli.github.com/) on `PATH`, with `gh auth login` done once.
If either is missing, InstaladorBUDA still runs and just **prints the commands** for you
to run elsewhere.

---

## 2. The deployment model (how a release reaches the website)

All apps publish GitHub Releases into **one release repo** (`TashiRabten/GlossarioBUDA`),
which the website and the in-app updaters read. Each app is distinguished by its **tag**
and/or **target branch**. The single rule that ties it together:

> **The git tag is the source of the version.** Push `…-v<version>` and that exact version
> is injected into the installer, the release, and what the app shows at runtime. You never
> hand-edit a version file.

Three actions, in order:

| Action | What it does | When |
|---|---|---|
| **Upload models** | Zips large model files and uploads them to a `*-models-*` release (assets too big for git). | Once per app, and again only when a model changes. |
| **Deploy (push tag)** | `git tag <prefix><version>` + `git push` → the app's build workflow fires, builds installers, and publishes the release. | Every release. |
| **Trigger workflow** | `gh workflow run …` with the same inputs but **without** a tag. | Test/manual builds, or re-runs. |

The three apps already wired up:

| App | Tag pushed | Build workflow | Release on GlossarioBUDA |
|---|---|---|---|
| **TradutorBUDA** | `tradutor-buda-v1.4.5` | `build-app-installers.yml` | `v1.4.5` (branch `tradutor-buda`) — `TradutorBUDA-1.4.5.{exe,pkg}` |
| **SegBUDA** | `segbuda-v1.0.0` | `build-segbuda.yml` | `segbuda-v1.0.0` — tiered `SegBUDA-*-Setup.exe` / `*.pkg` |
| **Namsel** | `namsel-v1.0.0.5` | `build-namsel.yml` | `v1.0.0.5` (branch `Namsel`) — `NamselOCR_Installer.{exe,pkg}` |

**Typical release:** open InstaladorBUDA → pick the app → the version pre-fills (current +1)
→ **Upload models** only if a model changed → **Deploy (push tag)** → watch the run on the
**Actions page** button. Done — the installer lands on the website a couple of minutes later.

---

## 3. Adding a new app

### 3a. Add a block to `apps.json`

```jsonc
{
  "name": "MyApp",
  "repoRoot": "C:\\path\\to\\myapp-repo",      // where the app's git repo lives on disk
  "tagPrefix": "myapp-v",                       // tag = tagPrefix + version
  "workflow": "build-myapp.yml",                // workflow file name in that repo
  "releaseBranch": "myapp",                     // target_commitish for the release (or "")

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
| `tagPrefix` | ✅ | The release tag is `tagPrefix + version`. |
| `workflow` | ✅ | Workflow file name (for *Trigger workflow*). |
| `releaseBranch` | — | `target_commitish` if the updater filters by branch; otherwise `""`. |
| `versionFile` + `versionRegex` | one of these¹ | Read current version from a file (capture group 1). |
| `versionFromGitTag` | one of these¹ | Or read the highest existing tag matching this glob. |
| `uploadScript` | — | A `.ps1` (relative to `repoRoot`) that uploads the models. Preferred if present. |
| `models` | — | Declarative assets to zip+upload when there is no `uploadScript`. |
| `dispatchInputs` | ✅ | `-f name=value` pairs for `gh workflow run`; `{version}`/`{publish}` are templated; `onlyIfPublish` skips the input unless *Publish* is ticked. |

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

InstaladorBUDA is self-contained (`InstaladorBUDA.ps1`, `apps.json`, `build-exe.ps1`,
`README.md`). To split it out:

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
| `InstaladorBUDA.ps1` | The app (GUI + console fallback), config-driven. |
| `apps.json` | The app registry. **Edit this to add apps.** |
| `build-exe.ps1` | Compiles `InstaladorBUDA.exe` via ps2exe. |
| `README.md` | This file. |
