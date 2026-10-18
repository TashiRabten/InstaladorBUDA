# The CLI's help reply: commands, actions, parameter schemas, examples and safety notes. Keep it in
# step with the visible controls and README.md (every capability exists in both the GUI and the CLI).
function Get-CockpitHelp {
    return [pscustomobject]@{
        ok = $true
        command = 'help'
        data = @{
            commands = @('start','close','new-session','select-session','close-session','new-tab','select-tab','configure','release-plan','add-app','gitignore','bootstrap-plan','bootstrap-prepare','bootstrap-publish','action')
            actions = @('upload','deploy','retag-deploy','dispatch','load-runs','publish-run','undraft','make-public','make-private','open-actions','open-release','copy-command','task','git-status','git-add','git-commit','git-push','create-repo','actions-secrets','code-cli','update')
            parameters = @{
                newSession = @{ required = @(); optional = @() }
                selectSession = @{ required = @('session'); optional = @('tab') }
                closeSession = @{ required = @('confirm:true'); optional = @('session','tab') }
                configure = @{ required = @(); optional = @('session','tab','target','version','publish','dryRun','notes','workflow','gitPaths','commitMessage','taskName','bootstrapRoot','githubRepo','bootstrapMessage','gitleaksPath') }
                releasePlan = @{ required = @(); optional = @('session','tab','target','version') }
                addApp = @{ required = @('name','repoRoot','githubRepo'); optional = @('session','tab') }
                gitignore = @{ required = @(); optional = @('session','tab','target','repoRoot') }
                bootstrapPlan = @{ required = @(); optional = @('session','tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                bootstrapPrepare = @{ required = @('confirm:true'); optional = @('session','tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                bootstrapPublish = @{ required = @('confirm:true'); optional = @('session','tab','repoRoot','githubRepo','commitMessage','gitleaksPath','waitMs') }
                action = @{ required = @('action'); optional = @('session','tab','target','version','publish','dryRun','notes','bundles','models','runId','taskName','gitPaths','commitMessage','githubRepo','confirm','replaceExistingTag','waitMs') }
            }
            examples = @(
                '{"command":"add-app","name":"MyApp","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}',
                '{"command":"gitignore","tab":1,"repoRoot":"C:\\work\\MyApp"}',
                '{"command":"action","action":"create-repo","githubRepo":"owner/AI-config","confirm":true}',
                '{"command":"release-plan","target":"TradutorBUDA"}',
                '{"command":"action","tab":1,"action":"deploy","target":"TradutorBUDA","version":"1.8.2","notes":"Release notes","confirm":true,"waitMs":900000}',
                '{"command":"action","tab":1,"action":"retag-deploy","target":"TradutorBUDA","version":"1.8.1","replaceExistingTag":true,"confirm":true,"waitMs":900000}',
                '{"command":"action","tab":1,"action":"actions-secrets","target":"ScanBUDA","confirm":true}',
                '{"command":"action","tab":1,"action":"code-cli","target":"TradutorBUDA","confirm":true}'
            )
            safety = @{
                deploy = 'Rejects an existing local tag, remote tag, or GitHub release.'
                retagDeploy = 'Moves an existing remote tag only with replaceExistingTag:true and confirm:true; uses a remote-object lease.'
                createRepo = 'Creates an empty private GitHub repository and does not stage or push local files.'
                actionsSecrets = 'Requires confirm:true. Opens the visible Actions-secrets manager. Values are sent only through GitHub CLI standard input and are not accepted in request JSON.'
                gitCommitPush = 'git-commit scans the staged changes and git-push the commits not yet on the upstream with Gitleaks first (findings redacted); a finding, a scanner error, or no Gitleaks found stops the step. Set gitleaksPath with configure to choose the scanner.'
                codeCli = 'Requires confirm:true. Opens the visible in-app agent chat; the first prompt in each conversation asks before allowing project edits.'
                closeSession = 'Requires confirm:true and uses the same visible confirmation as the Close session button; it discards that session log and stops its job if active.'
            }
            parity = 'Every operational capability is available in the visible GUI and CLI; command requests drive the same visible controls. Use the Session dropdown in the window or new-session/select-session/close-session to manage job sessions. The older new-tab/select-tab commands remain aliases.'
            pipe = $script:ControlPipeName
        }
    }
}
