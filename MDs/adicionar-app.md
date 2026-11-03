# Adicionar um app ao InstaladorBUDA

> **Estado:** ainda não verificado no app — *not yet verified in the app* (2026-10-20).
> Verificado por `tests/AddApp.Tests.ps1` (55 verificações, Windows PowerShell 5.1 em STA, o mesmo
> ambiente do executável) e pela leitura do registro real (`apps.json`).

## O que é um app "totalmente conectado"

Um app está totalmente conectado quando **cada controle do cockpit — na janela e na CLI — encontra
na entrada do app em `apps.json` tudo o que lê**. Não existe outro cadastro: os seletores de app das
sessões, o comando `list`, o menu `-Console` e todos os botões leem o mesmo registro
(`BudaAppRegistry`). O que falta numa entrada vira um controle desligado ou apontado para o
repositório errado — foi o caso do ScanBUDA (ver o fim deste documento).

## O caminho em um passo (janela e CLI)

- **Janela:** grupo **GitHub repository bootstrap** → preencher **App name**, **Project folder**
  (ou **Browse...**) e **GitHub repo** (`dono/nome`) → **Add app**.
- **CLI:** `& .\InstaladorBUDA.exe -Cli '{"command":"add-app","name":"MeuApp","repoRoot":"C:\\trabalho\\MeuApp","githubRepo":"dono/MeuApp"}'`
  — preenche os mesmos campos e clica no mesmo botão.

Os dois caminhos fazem exatamente o mesmo:

1. `Build-AppRegistryEntry` (`modules/AppWiring.ps1`) monta a entrada completa. Lê o *workflow* de
   *release* do projeto em `.github/workflows`: `build-app-installers.yml`; senão
   `build-installers.yml`; senão o único *workflow* com gatilho de *push* de *tag* e entradas de
   *dispatch*. Dele saem `workflow`, `tagPrefix`, `versionFromGitTag`, `releaseRepo` e
   `releaseBranch` (de `RELEASE_REPO` e `RELEASE_BRANCH` / `RELEASE_TARGET`) e `dispatchInputs`.
   Sem *workflow* de *release*, o app entra como alvo só de Git.
2. `BudaAppRegistry.Add` recusa uma entrada a que falte um dos campos obrigatórios (tabela abaixo)
   e grava só o novo objeto, sem reformatar o resto do arquivo.
3. O novo app aparece no seletor de todas as sessões abertas e fica selecionado; o rótulo de
   visibilidade lê o estado atual no GitHub.
4. O log da sessão mostra a verificação de conexão, uma linha por família de controles
   (`registry`, `projectFolder`, `git`, `githubRepo`, `visibility`, `actionsPage`, `actionsSecrets`,
   `release`). A resposta da CLI traz a mesma verificação (`wiring`, `fullyWired`) e a entrada
   gravada (`entry`).

Depois, editar a entrada à mão só para o que um *workflow* não diz: `manageVisibility: false` para
um repositório cuja visibilidade o cockpit nunca deve mudar; `uploadScript` / `uploadModels` /
`models`, `bundles` ou `outputKind`.

## Lista de verificação

### 1. Registro — a entrada em `apps.json`

| Campo | Obrigatório | Quem lê | Add app preenche com |
|---|---|---|---|
| `name` | sim | seletor de app, `list`, `configure target`, todas as ações | **App name** |
| `repoRoot` | sim | grupo Git, **Agent chat...**, **Open in terminal**, **Git ignore...**, *bootstrap*, versão por *tag* local | **Project folder** |
| `githubRepo` | sim | visibilidade, **Load runs**, **Open Actions page**, **Actions secrets...**, *bootstrap* | **GitHub repo** (o *remote* `origin` vence quando a pasta é um repositório próprio) |
| `releaseRepo` | sim | **Release plan**, **Publish selected run**, **Un-draft release**, **Open release**, acompanhamento da *release* | `RELEASE_REPO` do *workflow*; senão o próprio `githubRepo` |
| `manageVisibility` | sim | **Make public** / **Make private** | `true` |
| `tagPrefix` | sim (vazio em alvo só de Git) | **Deploy**, **Retag existing release**, **Release plan**, *tags* de *release* | prefixo do gatilho `push: tags:` |
| `workflow` | sim (vazio em alvo só de Git) | **Trigger workflow**, **Load runs**, **Open Actions page** | arquivo do *workflow* de *release* |
| `releaseBranch` | sim (pode ser vazio) | `--target` ao criar a *release*; o AutoUpdater do app filtra por ele | `RELEASE_BRANCH` / `RELEASE_TARGET` |
| `versionFromGitTag` | sim (pode ser vazio) | versão atual a partir das *tags* locais | `tagPrefix` + `*` |
| `versionFromReleaseTag` | não | versão atual a partir das *releases* publicadas | `true` quando há *workflow* de *release* |
| `uploadScript`, `models` | sim (`null` / `[]` quando não há modelos) | **Upload models** | `null`, `[]` |
| `dispatchInputs` | sim (`[]` em alvo só de Git) | **Trigger workflow** (`gh workflow run -f nome=valor`) | `version` → `{version}`, `publish` → `{publish}`, `release_notes` → `{notes}`, `bundles` → `{bundles}` |
| `uploadModels`, `bundles`, `outputKind`, `versionFile` + `versionRegex` | não | seletor de modelos, seletor de pacotes, alvo de imagem de contêiner, versão por arquivo | à mão |

Uma entrada antiga sem `githubRepo` ou `manageVisibility` continua funcionando (*remote* `origin` e
`true` como padrão); o relatório de conexão mostra esses padrões como "Defaults apply".

### 2. Configurações globais de `apps.json`

- `releaseRepoDefault`: *release* de um app sem `releaseRepo` (entradas antigas).
- `actionsUrl`: só o último recurso de **Open Actions page**, para um app ainda sem repositório; com
  repositório, o botão abre `https://github.com/<githubRepo>/actions/workflows/<workflow>`.
- `tasks[].cwdRepo` (opcional): uma tarefa que roda na pasta do app cita o seu `name`.

### 3. Controles da janela e o comando de CLI de cada um

| Grupo | Controle | Campos lidos | CLI |
|---|---|---|---|
| topo da sessão | **Target app** | `name` | `configure` com `target`; `list` |
| Steps | **1. Upload models** | `uploadScript`, `models`, `uploadModels` | `action: upload` |
| Steps | **2. Deploy (push tag)** | `repoRoot`, `tagPrefix`, `bundles` | `action: deploy` |
| Steps | **or: Trigger workflow** | `workflow`, `dispatchInputs` | `action: dispatch` |
| Steps | **Retag existing release** | `tagPrefix`, `releaseRepo` | `action: retag-deploy` |
| Steps | **Release plan** | `tagPrefix`, `releaseRepo`, `versionFrom*` | `release-plan` |
| Steps | **Copy last command** | — | `action: copy-command` |
| Steps | **Open Actions page** | `githubRepo`, `workflow` | `action: open-actions` |
| Publish from existing run | **Workflow**, **Load runs** | `githubRepo`, `workflow` | `action: load-runs` |
| Publish from existing run | **Publish selected run** | `releaseRepo`, `releaseBranch`, `tagPrefix` | `action: publish-run` |
| Publish from existing run | **Un-draft release**, **Open release** | `releaseRepo`, `tagPrefix` | `action: undraft`, `action: open-release` |
| Repo visibility | rótulo (*currently: private / public*) | `githubRepo` | `status` → `visibility`, `visibilityRepo` |
| Repo visibility | **Make public**, **Make private** | `githubRepo`, `manageVisibility` | `action: make-public`, `action: make-private`; `status` → `visibilityToggle` |
| Tasks | **Run / copy** | `tasks[].cwdRepo` | `action: task` |
| Git | **Add**, **Commit**, **Status**, **Push** | `repoRoot` (com *branch*) | `action: git-add`, `git-commit`, `git-status`, `git-push` |
| Git | **Agent chat...**, **Open in terminal** | `repoRoot` | `action: code-cli`, `action: code-cli-terminal` |
| GitHub repository bootstrap | **Add app** | (escreve a entrada) | `add-app` |
| GitHub repository bootstrap | **Create private repo** | **GitHub repo** | `action: create-repo` |
| GitHub repository bootstrap | **Actions secrets...** | `githubRepo` | `action: actions-secrets` |
| GitHub repository bootstrap | **Git ignore...** | `repoRoot` | `gitignore` |
| GitHub repository bootstrap | **Preflight**, **Prepare and stage**, **Commit and push** | `repoRoot`, `githubRepo` | `bootstrap-plan`, `bootstrap-prepare`, `bootstrap-publish` |
| Release notes | caixa de texto | `dispatchInputs` com `{notes}` | campo `notes` em `configure` / `action` |
| `-Console` | menu de texto | o mesmo registro | — |

Todo controle novo entra nesta tabela, com o seu comando de CLI, na mesma mudança (regra de
paridade entre janela e CLI do README).

### 4. Fora do InstaladorBUDA — o repositório do app e a suíte

- ***Workflow* de *release*** no repositório do app (modelo: `build-app-installers.yml` do
  TradutorBUDA ou do ScanBUDA):
  - `workflow_dispatch` com as entradas `version`, `publish`, `release_notes`;
  - gatilho `push: tags: ['<prefixo>*']`, o mesmo `tagPrefix` do registro;
  - `RELEASE_REPO` e `RELEASE_BRANCH` (ou `RELEASE_TARGET`) quando publica noutro repositório
    (GlossarioBUDA);
  - a versão derivada da *tag* ou da entrada `version` e injetada na compilação.
- ***Secrets* do repositório do app**, configurados em **Actions secrets...** (os valores nunca vão
  num JSON nem num log): `GH_PAT` com escrita de conteúdo no repositório de *releases* quando a
  publicação é noutro repositório, e todo *secret* que o *workflow* lê — a linha `actionsSecrets` do
  relatório lista os nomes.
- **AutoUpdater do app**: filtra as *releases* pelo `target_commitish` igual a `releaseBranch`.
- **Repositório de *releases***: o *branch* de `releaseBranch` existe (por exemplo `compact-version`
  no GlossarioBUDA).
- **Site de *releases*** (`rel-site-2025`): o catálogo de downloads inclui o app.

### 5. Verificar

1. O relatório de conexão no log (ou `wiring` na resposta de `add-app`) só com `[ok]`.
2. `status` da sessão: `visibility` = `currently: private` ou `currently: public`, `visibilityRepo`
   = o repositório do app, `visibilityToggle` = `true`.
3. Com **Dry run** marcado, **Make public** mostra `gh repo edit '<githubRepo>' --visibility public ...`
   sem executar.
4. **Release plan** sem `BLOCKED` para a próxima versão.
5. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\AddApp.Tests.ps1` verde.

## O caso ScanBUDA (2026-10-20)

- **Sintoma:** **Make public** e **Make private** desligados para o ScanBUDA; **Open Actions page**
  abria a página de *Actions* do TradutorBUDA.
- **Causa medida:** a entrada fora gravada pelo **Add app** antigo, que escrevia sempre
  `"manageVisibility": false` e não guardava o repositório do próprio app; depois a entrada recebeu
  os campos de *release* à mão, com `releaseRepo` = `TashiRabten/GlossarioBUDA`. O botão de *Actions*
  usava o `actionsUrl` global para todos os apps.
- **Correção:** a entrada do ScanBUDA tem `githubRepo` = `TashiRabten/ScanBUDA` e
  `manageVisibility` = `true`; **Open Actions page** abre o repositório de cada app; o **Add app**
  (janela e CLI) grava a entrada completa e recusa uma incompleta.
- **Prova:** o relatório de conexão do ScanBUDA no registro real dá todas as linhas `[ok]`
  (visibilidade em `TashiRabten/ScanBUDA`, *Actions* em
  `.../ScanBUDA/actions/workflows/build-app-installers.yml`, *release* em GlossarioBUDA no
  `compact-version`). A visibilidade do repositório não foi alterada.
