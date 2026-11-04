# The CLI's help reply: commands, actions, parameter schemas, examples and safety notes. Keep it in
# step with the visible controls and README.md (every capability exists in both the GUI and the CLI).
function Get-CockpitHelp {
    return [pscustomobject]@{
        ok = $true
        command = 'help'
        data = @{
            commands = @('start','close','new-session','select-session','close-session','new-tab','select-tab','configure','release-plan','add-app','gitignore','bootstrap-plan','bootstrap-prepare','bootstrap-publish','action')
            actions = @('git-pull','merge-tool','merge-refresh','merge-file','merge-use-local','merge-use-incoming','merge-save','merge-continue','retry-last-job','rerun','rerun-failed','pr-list','pr-create','pr-merge','upload','deploy','retag-deploy','dispatch','load-runs','publish-run','undraft','make-public','make-private','open-actions','open-release','copy-command','task','git-status','git-add','git-unstage','git-commit','git-push','create-repo','actions-secrets','code-cli','code-cli-terminal','update') + @(Get-FixCliActions)
            parameters = @{
                newSession = @{ required = @(); optional = @() }
                selectSession = @{ required = @('session'); optional = @('tab') }
                closeSession = @{ required = @('confirm:true'); optional = @('session','tab') }
                configure = @{ required = @(); optional = @('session','tab','target','version','publish','dryRun','notes','workflow','gitPaths','commitMessage','taskName','bootstrapRoot','githubRepo','bootstrapMessage','gitleaksPath','prBase','prHead','prTitle','prBody','prNumber') }
                releasePlan = @{ required = @(); optional = @('session','tab','target','version') }
                addApp = @{ required = @('name','repoRoot','githubRepo'); optional = @('session','tab') }
                gitignore = @{ required = @(); optional = @('session','tab','target','repoRoot') }
                bootstrapPlan = @{ required = @(); optional = @('session','tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                bootstrapPrepare = @{ required = @('confirm:true'); optional = @('session','tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                bootstrapPublish = @{ required = @('confirm:true'); optional = @('session','tab','repoRoot','githubRepo','commitMessage','gitleaksPath','waitMs') }
                action = @{ required = @('action'); optional = @('session','tab','target','version','publish','dryRun','notes','bundles','models','runId','prBase','prHead','prTitle','prBody','prNumber','mergeFile','mergeResult','taskName','gitPaths','commitMessage','githubRepo','agent','confirm','replaceExistingTag','waitMs') }
                fixSettings = @{ required = @('confirm:true'); optional = @('supabaseUrl','publishableKey','suggestionsFolder','tradutorInstall','scanInstall','suiteInstall','registryPath','rootKeyPath','inboxFolder','worktreeRoot') }
                fixSuggest = @{ required = @(); optional = @('bundle','email') }
                fixSuggestSend = @{ required = @('confirm:true (or dryRun:true)'); optional = @() }
                fixInbox = @{ required = @(); optional = @() }
                fixInboxRegister = @{ required = @('confirm:true (or dryRun:true)'); optional = @() }
                fixInboxOpenClose = @{ required = @('confirm:true (or dryRun:true)'); optional = @('maxPerHour') }
                fixInboxVerify = @{ required = @('id or bundle'); optional = @() }
                fixInboxOpenPr = @{ required = @('confirm:true (or dryRun:true)'); optional = @('overrideCeiling','waitMs') }
                fixInboxDecline = @{ required = @('id','note','confirm:true (or dryRun:true)'); optional = @('waitMs') }
                fixInboxMerge = @{ required = @('id','confirm:true (or dryRun:true)'); optional = @('waitMs') }
                fixRegistrySign = @{ required = @('in','rootIdentity','confirm:true'); optional = @() }
            }
            examples = @(
                '{"command":"add-app","name":"MyApp","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}',
                '{"command":"gitignore","tab":1,"repoRoot":"C:\\work\\MyApp"}',
                '{"command":"action","action":"create-repo","githubRepo":"owner/AI-config","confirm":true}',
                '{"command":"release-plan","target":"TradutorBUDA"}',
                '{"command":"action","tab":1,"action":"deploy","target":"TradutorBUDA","version":"1.8.2","notes":"Release notes","confirm":true,"waitMs":900000}',
                '{"command":"action","tab":1,"action":"retag-deploy","target":"TradutorBUDA","version":"1.8.1","replaceExistingTag":true,"confirm":true,"waitMs":900000}',
                '{"command":"action","tab":1,"action":"actions-secrets","target":"ScanBUDA","confirm":true}',
                '{"command":"action","tab":1,"action":"code-cli","target":"TradutorBUDA","confirm":true}',
                '{"command":"action","tab":1,"action":"code-cli-terminal","target":"TradutorBUDA","agent":"Claude Code","confirm":true}',
                '{"command":"action","tab":1,"action":"fix-suggest","bundle":"C:\\Users\\me\\.tradutorbuda\\sugestoes\\corrige.budafix","email":"me@example.org"}',
                '{"command":"action","tab":1,"action":"fix-suggest-send","confirm":true}',
                '{"command":"action","tab":1,"action":"fix-inbox"}',
                '{"command":"action","tab":1,"action":"fix-inbox-verify","id":12}',
                '{"command":"action","tab":1,"action":"fix-inbox-open-pr","confirm":true,"waitMs":900000}',
                '{"command":"action","tab":1,"action":"fix-registry-verify"}',
                '{"command":"action","tab":1,"action":"fix-inbox-register","confirm":true}',
                '{"command":"action","tab":1,"action":"fix-inbox-close","confirm":true}',
                '{"command":"action","tab":1,"action":"fix-inbox-add-developer","name":"Tenzin Wangmo","email":"tenzin@example.org","apps":["ScanBUDA"],"confirm":true}',
                '{"command":"action","tab":1,"action":"fix-status"}'
            )
            safety = @{
                retry = 'rerun/rerun-failed require runId and confirm:true; retries the original commit and inputs and waits for a new attempt. retry-last-job repeats this session failed job; tag builds use their existing run.'
                pullRequests = 'pr-create takes prBase/prHead/prTitle/prBody, with the head already pushed. pr-merge takes prNumber and confirm:true, pins the inspected head SHA and does not bypass checks.'
                merge = 'git-pull requires confirm:true and a clean worktree, uses --no-rebase --no-commit. merge-tool opens the visual editor; merge-save/merge-continue require confirm:true. Save rejects conflict markers and files changed since loading. Continue runs Gitleaks before committing.'
                deploy = 'Rejects an existing local tag, remote tag, or GitHub release.'
                retagDeploy = 'Moves an existing remote tag only with replaceExistingTag:true and confirm:true; uses a remote-object lease.'
                createRepo = 'Creates an empty private GitHub repository and does not stage or push local files.'
                actionsSecrets = 'Requires confirm:true. Opens the visible Actions-secrets manager. Values are sent only through GitHub CLI standard input and are not accepted in request JSON.'
                gitCommitPush = 'git-commit scans the staged changes and git-push the commits not yet on the upstream with Gitleaks first (findings redacted); a finding, a scanner error, or no Gitleaks found stops the step. Set gitleaksPath with configure to choose the scanner.'
                codeCli = 'Requires confirm:true. Opens the visible in-app agent chat; the first prompt in each conversation asks before allowing project edits.'
                codeCliTerminal = 'Requires confirm:true. Clicks Open in terminal in the visible agent chat (opening the chat first when it is closed; agent selects the profile by name). The CLI starts interactively, without a prompt, in its own terminal window in the project folder, with the profile Permission and Model flags but not its Arguments, so you can sign in (/login) and use its slash commands. Refused while the chat is open for another project or running a prompt.'
                closeSession = 'Requires confirm:true and uses the same visible confirmation as the Close session button; it discards that session log and stops its job if active.'
                fixInbox = 'Suggested changes (fix-*). The contributor''s Supabase password and the maintainer''s admin passphrase are typed only in the visible windows (never in CLI JSON: password, passphrase and other credential-like fields are rejected); only the contributor''s session token and the passphrase, as a SecureString in the open Sugestões recebidas window, are kept, in memory; replies never carry them (passphraseSet says only whether one is held). fix-suggest opens the contributor window (bundle and email fill its fields) and fix-suggest-send inserts the row with the bundle in it (bundle_b64, at most 4 MiB). fix-inbox opens the maintainer window; its other actions click that window''s buttons and call the fix_inbox_* functions. fix-inbox-register registers the verified registry''s developers in the inbox; fix-inbox-close / fix-inbox-open are the kill switch (maxPerHour sets the cap). fix-inbox-add-developer (confirm:true; name, email, optional developerId, apps "all" or a list of TradutorBUDA/ScanBUDA, optional publicKey) calls the dev-invite Edge Function: it approves the e-mail, creates the account, has Supabase e-mail the invitation and makes it a developer; when Supabase did not send it (its hourly quota, or its built-in sender, which writes only to the organization''s members) the link opens in a cockpit window, never in the reply (lastInvite says emailSent, outcome and linkShown); with publicKey the next registry version is written and the signing console opens. fix-inbox-verify runs BundleTool bundle-verify with the installed runtime against a detached worktree at the release tag and reports problems, capabilities and overCeiling before the diff; nothing is branched or built until fix-inbox-open-pr (confirm:true; overrideCeiling:true when the change goes beyond the developer''s ceiling), which runs worktree → bundle-apply → commit as you → Gitleaks → push of the verifier''s contrib/<id>/<slug> branch → gh pr create --base main, then writes pr-opened back to the row. A status that cannot be written yet (the window closed with the passphrase) waits on disk, listed by fix-status as pendingStatus, for the next Usar or fix-inbox-refresh, which also ask GitHub about rows still without a PR. fix-inbox-merge and fix-inbox-decline are separate confirmed actions. fix-registry-sign opens a console where the root password is typed. With dryRun:true nothing is sent to Supabase or GitHub.'
                addApp = 'Clicks the visible Add app button: registers the whole apps.json entry in one step (githubRepo, releaseRepo, manageVisibility:true, and workflow, tag prefix, release branch and dispatch inputs read from .github/workflows) and replies with the same wiring check the session log shows. Set manageVisibility:false in apps.json afterwards for a repository whose visibility must not change.'
            }
            status = 'Each session reports its visibility label (read from GitHub), the repository it reads, and whether Make public / Make private are enabled.'
            parity = 'Every operational capability is available in the visible GUI and CLI; command requests drive the same visible controls. Use the Session dropdown in the window or new-session/select-session/close-session to manage job sessions. The older new-tab/select-tab commands remain aliases.'
            pipe = $script:ControlPipeName
        }
    }
}
