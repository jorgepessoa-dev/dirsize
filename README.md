# folder-size-analyzer

Script **PowerShell** para analisar o espaço ocupado por ficheiros e pastas numa
localização de rede (`\\servidor\share\...`) ou local, de forma **granular** (por
camadas), **sem necessidade de privilégios de administrador** e com suporte a
**caminhos longos** que ultrapassam o limite de 260 caracteres (MAX_PATH).

## Porquê

Ferramentas gráficas (TreeSize, WinDirStat, etc.) muitas vezes:

- exigem instalação / permissões que não tens numa máquina corporativa;
- falham em caminhos com mais de 260 caracteres;
- despejam a árvore inteira de uma vez, afogando-te em dados.

Este script resolve os três problemas usando apenas PowerShell + .NET
(`System.IO`), disponível em qualquer Windows.

## Características

- **Sem admin** — só lê; acessos negados são apanhados, contados, e o scan continua.
- **Long paths (>260)** — usa o prefixo estendido `\\?\` / `\\?\UNC\` para ignorar
  o MAX_PATH. No fim lista os ficheiros cujo caminho passa os 260 caracteres.
- **Granular** — faz **um** scan e guarda a árvore em memória. Depois navegas:
  em **janela gráfica** (`-Gui`, duplo-clique para entrar, estilo TreeSize),
  em modo **interativo de consola** (afundas numa pasta só quando escolheres),
  ou em modo **relatório** com profundidade fixa. A navegação é **instantânea**
  porque parte da árvore já em memória — não recalcula pastas ao entrar.
- **Foco Pareto (80/20)** — em cada nível assinala quantas das maiores pastas
  somam 80% do espaço ("as poucas vitais" onde deves atuar primeiro).
- **Tipo de conteúdo sem semântica** — classifica os ficheiros em categorias
  legíveis (Vídeo, Imagem, Documento, Email/PST, Comprimido/Backup, CAD,
  Base de dados, Instaladores…) e mostra o predominante por pasta. Dá-te uma
  ideia do *que* é cada pasta sem interpretar conteúdos. Na consola liga-se com
  `-ShowExtensions`; na janela gráfica aparece sempre na coluna "Conteúdo".
- **Junctions / symlinks ignorados** — evita contagens duplicadas e loops.
- **Exportação CSV** — árvore completa, uma linha por pasta.

## Utilização

```powershell
# Sem argumentos: abre uma JANELA para escolher a pasta e mostra resultados em janela
.\Analyze-FolderSizes.ps1

# Janela gráfica (estilo TreeSize) — duplo-clique para entrar nas pastas
.\Analyze-FolderSizes.ps1 -Path '\\servidor\share\Pasta' -Gui

# Modo interativo de consola (default) — afundas camada a camada só onde quiseres
.\Analyze-FolderSizes.ps1 -Path '\\servidor\share\Pasta'

# Relatório fixo de 2 níveis, top 10, com tipos de ficheiro
.\Analyze-FolderSizes.ps1 -Path '\\servidor\share' -Depth 2 -Top 10 -ShowExtensions

# Scan + exportar árvore completa para CSV
.\Analyze-FolderSizes.ps1 -Path '\\servidor\share' -CsvOut relatorio.csv

# Ignorar pastas durante o scan
.\Analyze-FolderSizes.ps1 -Path '\\servidor\share' -Exclude 'node_modules','.git'
```

Se a política de execução estiver bloqueada (comum em máquinas corporativas),
corre **sem alterar nada no sistema**, só para esta invocação:

```powershell
powershell -ExecutionPolicy Bypass -File .\Analyze-FolderSizes.ps1 -Path '\\servidor\share'
```

### Na janela gráfica (`-Gui`)

- **Duplo-clique** (ou Enter) numa linha → entra na pasta.
- **Subir** → volta ao nível anterior.
- **Exportar CSV** → grava a subárvore atual num ficheiro à tua escolha.
- Clica no cabeçalho de uma coluna para ordenar (por nº de ficheiros, etc.).

> A janela usa WinForms (incluído no Windows, sem admin). Funciona em consola
> local e em sessão **RDP**; não funciona em SSH puro sem interface gráfica —
> nesse caso usa o modo interativo de consola abaixo.

### No modo interativo de consola

| Tecla | Ação |
|-------|------|
| `n` (número) | afundar na pasta número *n* |
| `u` | subir um nível |
| `e` | ligar/desligar o breakdown por extensão |
| `q` | sair |

## Parâmetros

| Parâmetro | Descrição | Default |
|-----------|-----------|---------|
| `-Path` | Localização a analisar. Se omitido, abre janela para escolher a pasta | — |
| `-Top` | Nº de pastas a mostrar por nível | `15` |
| `-Depth` | Modo relatório: nº de camadas a imprimir de uma vez | `0` (= interativo) |
| `-Gui` | Abre a janela gráfica (duplo-clique para entrar) | — |
| `-Interactive` | Força o modo interativo de consola | — |
| `-ShowExtensions` | Mostra a categoria de conteúdo por pasta (consola) | desligado |
| `-Exclude` | Nomes de pasta a ignorar (wildcards) | — |
| `-CsvOut` | Caminho para exportar a árvore em CSV | — |

## Nota de desempenho

Calcular o tamanho de cada pasta obriga a percorrer **tudo** uma vez, por isso o
scan inicial de um share grande demora (há uma barra de progresso). Depois disso,
a navegação é instantânea porque a árvore já está em memória.

## Requisitos

- Windows PowerShell 5.1 (o que vem por omissão no Windows) ou PowerShell 7+.
- Nenhuma dependência externa.

## Ferramentas (`tools/`)

Auxiliares para uma revisão de código independente por outros modelos/agentes:

- **`tools/REVIEW_REQUEST.md`** — pacote de revisão: prompt estruturado (pontos de
  risco, formato de resposta obrigatório) para colar no DeepSeek/Gemini em
  sessões separadas e comparar de forma ortogonal.
- **`tools/dispatch_review.sh`** — driver `tmux` (`send-keys` + `capture-pane`)
  para submeter esse prompt aos panes de agentes locais e recolher a resposta.
  Correr na máquina onde os panes tmux vivem.

## Licença

MIT — ver [LICENSE](LICENSE).
