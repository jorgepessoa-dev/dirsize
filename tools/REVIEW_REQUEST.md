# Pedido de revisão de código — Analyze-FolderSizes.ps1

> Cola este ficheiro inteiro (ou o link do repo) no DeepSeek e no Gemini,
> **em sessões separadas**, e compara as duas respostas.
> Se a ferramenta conseguir navegar a web, dá-lhe o link; senão, cola também o
> conteúdo do script `Analyze-FolderSizes.ps1`.

## Repositório (público)

- Repo: https://github.com/jorgepessoa-dev/folderanalyzer
- Script (raw): https://raw.githubusercontent.com/jorgepessoa-dev/folderanalyzer/main/Analyze-FolderSizes.ps1

---

## PROMPT (copiar a partir daqui)

És um revisor sénior de PowerShell e Windows/.NET. Revê o script
`Analyze-FolderSizes.ps1` (abaixo ou no link). **Não reescrevas o script todo** —
quero achados concretos, ancorados em número de linha, com severidade e um patch
mínimo por cada um.

### Contexto e requisitos que o script TEM de cumprir
- Correr numa máquina Windows **sem privilégios de administrador** e **sem instalar nada**.
- Analisar uma **localização de rede** (`\\servidor\share`) e calcular o tamanho
  **acumulado** de cada pasta (ficheiros + todas as subpastas).
- Suportar **caminhos longos > 260 caracteres** (MAX_PATH) usando o prefixo
  estendido `\\?\` / `\\?\UNC\`.
- Fazer **um único scan** para memória; navegação (consola, `-Gui`, relatório) é
  instantânea sobre essa árvore.
- Compatível com **Windows PowerShell 5.1 (.NET Framework)** E **PowerShell 7+**.
- Destacar as pastas em ótica de **Pareto (80/20)** e classificar o **tipo de
  conteúdo** por categoria (sem semântica, só por extensão).

### Pontos que quero que escrutines em particular (confirma ou refuta cada um)
1. **Long paths em PS 5.1.** `[System.IO.Directory]::EnumerateFileSystemEntries`
   e `[System.IO.FileInfo].Length` funcionam mesmo com o prefixo `\\?\UNC\...`
   em Windows PowerShell 5.1 (.NET Framework 4.x)? Há algum caso em que o
   prefixo é rejeitado ou normalizado, fazendo falhar ficheiros > 260 chars?
2. **Scope dos event handlers WinForms.** As funções `Update-GuiGrid`,
   `Enter-GuiRow`, `Export-TreeCsv` são de topo e o estado está em `$script:`.
   Confirma que os handlers (`Add_CellDoubleClick`, `Add_KeyDown`, `Add_Click`)
   os resolvem corretamente e que não há fuga/estado partilhado problemático.
3. **Binding do DataGridView a um DataTable** e o mapeamento por coluna oculta
   `Idx` após o utilizador reordenar colunas — o duplo-clique entra sempre na
   pasta certa? Há risco de `Cells['Idx']` vir nulo?
4. **Reparse points.** O scan ignora junctions/symlinks (`FileAttributes.ReparsePoint`).
   Isto evita loops, mas pode **subcontar** dados legítimos (ex.: mount points,
   DFS)? É o trade-off certo? Devia ser opcional?
5. **Pareto (`Get-ParetoInfo`).** A contagem cumulativa até 80% está correta,
   incluindo divisão inteira/precisão e o caso `total = 0`?
6. **Precisão de tamanhos.** Soma em `[int64]` — há risco de overflow em shares
   de vários TB? A agregação cumulativa pai←filho está correta em
   `Get-FolderNode` (FileCount/DirCount/Size/Ext)?
7. **Continuação em acessos negados.** O `try/catch` por diretório/ficheiro
   garante que o scan **não pára** em permissões negadas e que os erros são
   contados sem inflacionar/deflacionar tamanhos?
8. **Desempenho e memória.** Em shares com **milhões** de ficheiros, a árvore
   em memória (nós PSCustomObject + hashtable `Ext` por nó) é aceitável? Onde
   está o maior custo e o que simplificarias sem perder a funcionalidade?
9. **Compatibilidade 5.1 vs 7.** Alguma sintaxe/API que se comporte de forma
   diferente entre as duas (ex.: `Add-Type` WinForms em PS7, `-band` em enums,
   `[math]::Round`, `Sort-Object` de hashtable enumerator)?
10. **Robustez geral.** Bugs de lógica, off-by-one, null-deref, encoding do CSV,
    ou qualquer caminho de código que rebente com `$ErrorActionPreference='Stop'`.

### Formato da resposta (obrigatório)
Devolve **apenas** uma lista de achados, ordenada por severidade
(CRITICAL > HIGH > MEDIUM > LOW), cada um assim:

```
[SEVERIDADE] linha X — <resumo numa frase>
  Cenário de falha: <input/estado concreto -> resultado errado>
  Patch sugerido: <a alteração mínima>
```

No fim, uma linha só: `VEREDICTO: <corre como pretendido / tem bugs bloqueantes / precisa de testes>`.

Se não encontrares nada numa categoria, não inventes — diz "sem achados".

--- (fim do prompt) ---

## Como comparar as duas respostas (verificação ortogonal)

- Um achado que **DeepSeek e Gemini apontam os dois** (mesma linha/causa) é
  quase de certeza real → corrige primeiro.
- Um achado que só **um** aponta → trata como hipótese: confirma tu (ou pede-me
  para eu confirmar) antes de mexer.
- Se discordarem sobre o mesmo ponto → é o candidato a testar em máquina real.
