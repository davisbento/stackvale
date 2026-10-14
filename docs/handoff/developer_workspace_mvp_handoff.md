# Stackvale — MVP Handoff

**Marca:** Stackvale  
**Tagline:** *Every project has its place.*  
**Identidade visual:** montanhas em camadas representando ambientes/projetos, paleta azul e violeta, ícone compacto legível na menu bar.  

![Logo conceitual Stackvale](stackvale_logo.png)

**Versão:** 0.2  
**Plataforma:** macOS (aplicativo nativo, menu bar first)  
**Objetivo:** Validar a gestão de projetos e serviços locais sem alternar entre Terminal e Docker Desktop.  
**Status:** Escopo inicial para implementação e teste.

## 1. Visão do produto

**Stackvale — Every project has its place.**

Aplicativo macOS residente na **menu bar** para cadastrar projetos/repositórios locais, descobrir comandos e serviços, e permitir iniciar/parar cada serviço individualmente em um único lugar.

**Princípio fundamental:** selecionar/trocar o projeto visível **não inicia nem interrompe nada**. O estado de execução pertence ao serviço, não ao projeto selecionado na interface. Somente ações explícitas do usuário alteram processos.

### Problema

Quem trabalha em vários projetos precisa abrir o Docker Desktop, alternar janelas de terminal, identificar processos e executar comandos repetidos para gerenciar APIs, aplicações web e dependências locais.

### Resultado esperado do MVP

O usuário cadastra uma pasta de projeto, confirma os serviços detectados ou adiciona comandos manuais, e passa a controlar serviços individuais pelo popover da menu bar, visualizando o status real mesmo ao navegar entre projetos.

## 2. Escopo do MVP (P0)

1. Aplicativo nativo em Swift/SwiftUI, acessível por ícone na menu bar, com popover principal.
2. Cadastro de projeto por seleção de diretório local; nome sugerido pela pasta, editável; editar/remover projeto sem afetar serviços em execução.
3. Onboarding com **discovery automático** do diretório selecionado e revisão dos candidatos antes de salvar.
4. Discovery inicial de scripts em `package.json` e serviços em arquivos Docker Compose (`compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml`).
5. Identificação de package manager usando `packageManager` e lockfiles (`pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, `bun.lock`/`bun.lockb`) quando aplicável; caso ambíguo, pedir confirmação.
6. Cadastro manual de serviços com **nome**, **diretório de execução** (working directory), **tipo** (`command` ou `docker-compose`) e **comando/serviço**.
7. Listagem de serviços por projeto com nome, identificação amigável (`web · :3000` quando porta puder ser descoberta), status e controle individual **Start / Stop** (ícones play/stop ou pause se houver semântica de pausa real).
8. Atualização do estado de execução, incluindo falha e saída inesperada; ações temporariamente desabilitadas durante transições.
9. Persistência local dos projetos e definições de serviços entre reinicializações.
10. Navegação entre projetos sem qualquer efeito colateral nos serviços já iniciados.

### Fora do MVP (não implementar agora)

- Iniciar/parar automaticamente serviços quando o usuário seleciona outro projeto.
- Botão global "Start all" / "Stop all"; dependências e ordem de inicialização.
- Integração com agentes (Claude Code/Codex/Cursor), resumos de PRs, autenticação, sync na nuvem.
- Editor de `.env`, execução remota, Kubernetes, gestão completa de Docker Desktop.
- Descoberta automática de **qualquer** processo já existente no sistema e controle indiscriminado por PID/porta.
- Interpretação universal de Makefiles, monorepos, Go, Python etc. (evolução futura).

## 3. Fluxo UX

### 3.1 Primeiro acesso / adicionar projeto

1. Abrir popover da menu bar → estado vazio com botão **Add Project**.
2. Escolher pasta por `NSOpenPanel`.
3. App sugere nome e inicia leitura dos metadados do diretório (sem executar scripts do projeto).
4. Exibir lista de serviços candidatos com **origem**, **comando**, **working directory**, **tipo** e seleção individual para importação.
5. Usuário pode editar as sugestões, desmarcar candidatas e adicionar um serviço manual.
6. **Save Project** persiste as definições. **Nenhum serviço inicia no onboarding.**

### 3.2 Menu bar — visão de projeto

```text
[Dev Workspace ▾]
┌─────────────────────────────────────┐
│ Project:  my-monorepo            ▾  │
│ ~/code/my-monorepo                  │
│                                     │
│ SERVICES                            │
│ ● Web          :3000      [ Stop ] │
│ ● API          :4000      [ Stop ] │
│ ○ PostgreSQL   docker     [ Start ]│
│ ! Worker       exited(1)  [ Start ]│
│                                     │
│ [+ Add service]   [Rescan project]  │
│ [Manage projects]                   │
└─────────────────────────────────────┘
```

Estado ilustrativo: `●` rodando, `○` parado, `!` falhou. Se a porta não for conhecida, omitir a porta; **não presumir 3000 para todo web**.

### 3.3 Iniciar/parar serviço

- **Start:** executar somente o serviço escolhido usando a definição salva; indicar `starting`, depois `running` ou `failed`.
- **Stop (processo local):** enviar encerramento gracioso ao processo/grupo de processos iniciado pelo app e esperar a saída; nunca encerrar um PID só por coincidir com a porta.
- **Stop (Compose):** usar ação direcionada ao(s) serviço(s) Compose importado(s), sem derrubar outros serviços do projeto. Para serviço individual, `docker compose stop <service>`; iniciar com `docker compose up -d <service>` ou estratégia equivalente documentada.
- Se serviço **já estiver ativo fora do app**, mostrar status `external/unmanaged` quando identificável com segurança; **não reivindicar controle nem matar o processo por padrão**.
- Ao clicar em um serviço, mostrar detalhes: comando resolvido, origem, pasta, estado, PID/container quando disponível, última falha e logs básicos quando suportados.

### 3.4 Alternância de projeto

**Cenário obrigatório:** Web do Projeto A está rodando → usuário seleciona Projeto B → A continua rodando → usuário retorna a A → Web segue marcada como `running`.

O projeto selecionado é somente um filtro de visualização. Fechar o popover também não deve parar serviços. Ao sair completamente do aplicativo, explicitar a política de processos (ver seção 6).

## 4. Regras de discovery

### Node.js

- Ler `package.json`; criar candidatos para scripts relevantes (`dev`, `start` e outros scripts explícitos), mostrando o nome original. **Não executar o conteúdo na varredura.**
- Resolver comando usando gerenciador detectado, por exemplo `pnpm run dev`, `npm run dev`, `yarn dev`, `bun run dev`.
- Não inferir que `start` é desenvolvimento: rotular conforme o script e deixar escolha para o usuário.
- MVP varre o `package.json` **na raiz do projeto selecionado**. Monorepos/nested packages são suporte futuro ou poderão ser cadastrados apontando para subpastas.

### Docker Compose

- Identificar arquivos Compose usuais na raiz; usar `docker compose -f <file> config --services` para enumerar serviços **apenas após o usuário selecionar o projeto e autorizar a leitura da configuração**. Esse comando pode interpolar variáveis e examinar arquivos: não executar `up` na etapa de discovery.
- Cada serviço importado mantém referência explícita ao arquivo Compose, serviço e diretório.
- Exibir erro amigável se Docker CLI/daemon não estiver disponível e preservar serviços cadastrados.
- Se múltiplos arquivos Compose forem encontrados, pedir ao usuário qual configuração usar; não mesclar arbitrariamente.

### Cadastro manual

Campos mínimos: **nome**, **tipo**, **working directory**, **comando** (para processo) ou **arquivo Compose + nome do serviço** (para Docker). Validar diretório, comando vazio e duplicidade de nomes com feedback. Permitir editar e excluir uma definição, solicitando confirmação caso o serviço esteja rodando.

### Segurança de comandos

- Discovery nunca roda `npm install`, `postinstall`, `dev`, `up`, ou qualquer script automaticamente.
- Prévia do comando antes do primeiro Start; solicitar confirmação explícita para execução.
- Evitar montar comandos como concatenação insegura de strings; usar executável + argumentos quando possível. Caso suporte a shell seja necessário, sinalizar que comandos customizados são confiados ao usuário.
- Executar com privilégios do usuário, sem `sudo` automático. Não registrar tokens/variáveis sensíveis em logs.

## 5. Modelo de dados sugerido

```text
Project
  id: UUID
  name: String
  rootPath: URL / persisted bookmark
  createdAt: Date
  services: [ServiceDefinition]

ServiceDefinition
  id: UUID
  projectId: UUID
  name: String
  kind: localCommand | dockerCompose
  workingDirectory: URL
  source: discovered | manual
  command: executable + args (local)
  composeFile: URL? (Docker)
  composeService: String? (Docker)
  displayPort: Int? (opcional, observada/configurada)
  iconCategory: web | docker | nodejs | generic

ServiceRuntime (não é fonte persistente de verdade)
  serviceId: UUID
  status: stopped | starting | running | stopping | failed | external | unknown
  pidOrContainerId: String?
  lastExitCode: Int?
  lastError: String?
```

**Nota:** definições persistem; status de execução deve ser reconciliado com o SO/Docker ao abrir o app, em vez de restaurar `running` cegamente do armazenamento.

## 6. Ciclo de vida: decisões importantes

- **Alternar de projeto:** nunca inicia ou para serviços.
- **Fechar popover:** nunca inicia ou para serviços.
- **Sair do aplicativo:** processos Docker Compose detached permanecem ativos. Para processos locais iniciados como filhos do app, comportamento de sobrevivência exige um supervisor/launcher desacoplado; **no MVP, documentar a limitação e avisar antes do Quit caso haja processos locais rodando**, em vez de prometer que sobreviverão ao fechamento.
- **Reabrir o app:** reconciliar estado do Docker e dos processos monitoráveis. Não assumir gerenciamento de processos de terceiros.
- **Porta ocupada:** falhar com mensagem clara e opção de inspecionar o conflito; não finalizar automaticamente o ocupante.
- **Start duplicado:** prevenir múltiplas instâncias do mesmo serviço iniciado pelo app, com ações idempotentes quando possível.
- **Pause vs Stop:** UI do MVP deve usar **Start/Stop**. `pause` significa suspender um processo, e não simplesmente encerrar; evitar esse rótulo para não enganar o usuário.

## 7. Arquitetura sugerida (sem overengineering)

```text
MenuBarApp (SwiftUI MenuBarExtra / popover)
  ├─ ProjectStore (persistência local)
  ├─ ProjectScanner
  │    ├─ PackageJsonDetector
  │    └─ DockerComposeDetector
  └─ ServiceManager
       ├─ LocalProcessController (Foundation.Process)
       ├─ DockerComposeController (Docker CLI)
       └─ RuntimeStatusMonitor
```

- **SwiftUI** para interface, AppKit quando necessário para seleção de diretórios e comportamentos de janela.
- **Foundation.Process** para disparar comandos e obter saída/exit code.
- **Persistência:** JSON local ou SwiftData, conforme preferir; escolher uma solução simples.
- **Logs:** capturar stdout/stderr dos processos iniciados pelo app, com buffer limitado; para Compose, consultar logs sob demanda.
- Separar detecção (descreve comandos) de execução (controla serviços) para evitar efeitos colaterais na varredura.
- Não é necessário backend, autenticação ou LLM no MVP.

## 7.1 Ícones de serviços — requisito visual P0

Cada serviço deve exibir um **ícone simples de categoria**, independente do indicador de status e do botão de Start/Stop. O objetivo é identificar o serviço rapidamente no popover da menu bar.

| Categoria visual | Ícone sugerido | Regra de classificação |
|---|---|---|
| Web | `globe` (SF Symbols: `globe`) | Script ou serviço reconhecido como servidor web (ex.: Next.js, Vite); permitir corrigir manualmente. |
| Docker | `shippingbox` (SF Symbols: `shippingbox`) | Serviço descoberto via Docker Compose ou cadastrado como Compose. |
| Node.js | `chevron.left.forwardslash.chevron.right` (SF Symbols, ou símbolo `terminal`) | Comando de projeto Node.js que não foi classificado explicitamente como Web. |
| Genérico | `terminal` (SF Symbols: `terminal`) | Fallback para comando manual ou tipo desconhecido. |

**Precedência visual sugerida:** `Web > Docker > Node.js > Genérico` somente quando as categorias se sobrepuserem; para serviços Compose, priorizar Docker por padrão, mas permitir mudar a categoria visual. Não confundir tecnologia de execução com tipo visual: um servidor Web Node.js pode exibir Web, enquanto um worker Node.js pode exibir Node.js.

**Regras UX:**
- Renderizar ícones pequenos (aprox. 16–18 pt), monocromáticos/SF Symbols, sem necessidade de logos ou assets externos no MVP.
- Mostrar status **separadamente** com indicador discreto (rodando/parado/falhou); o ícone não deve trocar de forma conforme o estado.
- Manter ação individual de **Start/Stop** acessível por botão e rótulo; a escolha do projeto não altera nenhum processo.
- No onboarding e no cadastro/edição manual, sugerir a categoria automaticamente e disponibilizar seletor `Web | Docker | Node.js | Genérico`.
- Persistir `iconCategory` em `ServiceDefinition` como `web | docker | nodejs | generic`, separado de `kind` (controlador de execução).

Exemplo de uma linha do popover: `🌐 Web  · :3000  ● Running  [Stop]`; `▣ PostgreSQL · Docker  ○ Stopped [Start]`. Os emojis são apenas ilustrativos; no app usar símbolos nativos.

## 8. Critérios de aceite

- [ ] Consigo cadastrar pelo menos dois projetos de diretórios diferentes.
- [ ] Ao cadastrar um projeto Node, vejo scripts encontrados no `package.json` antes de importá-los.
- [ ] Ao cadastrar Compose, vejo os serviços e posso importar somente um subconjunto.
- [ ] Consigo adicionar um comando manual e corrigir working directory/comando.
- [ ] Nenhum comando é executado durante o onboarding ou a simples navegação.
- [ ] Consigo iniciar e parar o serviço Web individualmente pelo popover.
- [ ] O status reflete sucesso, falha ou encerramento inesperado, não apenas o último botão pressionado.
- [ ] Se A estiver rodando e eu selecionar B, A continua rodando.
- [ ] Se eu fechar/reabrir o popover, o estado do processo permanece coerente.
- [ ] Parar um serviço Docker Compose não para os demais serviços do Compose por padrão.
- [ ] O aplicativo não encerra processos externos somente por estarem na mesma porta.
- [ ] Definições de projetos e serviços permanecem após reiniciar o app.
- [ ] Erros comuns (Docker desligado, comando inexistente, porta ocupada) mostram feedback útil.
- [ ] Cada serviço exibe um ícone de categoria (Web, Docker, Node.js ou Genérico), independente do seu status.
- [ ] A categoria é sugerida no discovery, editável pelo usuário e persistida.

## 9. Cenários de teste manuais

**T1 — Node simples:** projeto com `package.json` e `dev` → importar → iniciar → confirmar processo e porta → parar → confirmar encerramento.

**T2 — Dois projetos:** iniciar Web no Projeto A → mudar para B → iniciar API de B → voltar para A → ambos continuam rodando até Stop individual.

**T3 — Docker Compose:** importar `postgres` e `redis` → iniciar ambos → parar `redis` → `postgres` continua rodando.

**T4 — Manual:** cadastrar comando local não detectado (ex.: `go run .`) → iniciar/parar → verificar diretório de execução.

**T5 — Erro:** executar comando inválido → serviço mostra `failed`, erro visível e opção de tentar novamente.

**T6 — Conflito:** porta ocupada por processo externo → Start falha informativamente; nenhuma ação destrutiva automática.

**T7 — Reinicialização:** salvar 2 projetos → reiniciar app → configurações preservadas; estados reconciliados.

## 10. Ordem de implementação

1. **Milestone 1 — Shell + projetos:** ícone menu bar, popover, diretório, cadastro e persistência.
2. **Milestone 2 — Discovery:** `package.json`, Compose, tela de revisão e cadastro manual.
3. **Milestone 3 — Lifecycle:** Start/Stop de processos locais, leitura de status, erros e logs simples.
4. **Milestone 4 — Docker:** Start/Stop e status Compose por serviço, tratamento de Docker indisponível.
5. **Milestone 5 — Robustez:** navegação entre projetos, reconciliação e cenários de teste.

## 11. Evolução depois da validação

- Monorepos (pnpm workspaces, Turborepo, Nx), Go, Python, Make/Just.
- Agrupamentos de serviços e startup em sequência, opcional e sempre explícito.
- Descoberta de portas e processos preexistentes com inspeção segura.
- Resumo de agentes de IA (Claude Code/Codex) e integração com GitHub.
- Supervisor independente para processos sobrevivendo ao Quit; painel de logs mais completo.

---

**Resumo de produto:** o usuário escolhe um projeto; o app detecta as maneiras de executá-lo, ele confirma ou adiciona comandos e depois controla **cada serviço individualmente** pela menu bar. Trocar de projeto é apenas navegar — **não é uma operação de deploy, stop ou start**.
