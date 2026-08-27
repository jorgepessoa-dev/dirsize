# dirsize

`dirsize.ps1` — mede o espaço ocupado por pastas (local ou `\\servidor\share`),
**sem admin**, com suporte a caminhos **> 260 caracteres**. Windows PowerShell 5.1.

Faz **um** scan para memória; depois navega em janela gráfica (`-Gui`), consola interativa
(default) ou relatório de profundidade fixa (`-Depth`).

## Usar

Duplo-clique em **`Pastas.cmd`** — abre janela para escolher a pasta (com histórico).

Ou por linha de comando:

```powershell
# janela gráfica: scan com progresso + Cancelar, depois navegação
.\dirsize.ps1 -Path '\\servidor\share' -Gui

# relatório: 2 níveis + as 50 maiores pastas de toda a árvore
.\dirsize.ps1 -Path '\\servidor\share' -Depth 2 -Top 20 -FlatTop 50

# relatório HTML + snapshot para comparar depois
.\dirsize.ps1 -Path '\\servidor\share' -HtmlOut rel.html -SnapshotOut hoje.json

# o que mudou desde um snapshot anterior
.\dirsize.ps1 -Path '\\servidor\share' -CompareWith hoje.json -HtmlOut evolucao.html
```

Se o `.ps1` for bloqueado ("not digitally signed" / MOTW), desbloqueia e corre:

```powershell
Get-ChildItem *.ps1 | Unblock-File
powershell -ExecutionPolicy Bypass -File .\dirsize.ps1 -Path '\\servidor\share'
```

O `Pastas.cmd` já faz as duas coisas (numa GPO corporativa com `MachinePolicy
RemoteSigned`, o `-ExecutionPolicy Bypass` é ignorado — o que resolve é o `Unblock-File`).
Com `MachinePolicy AllSigned` só assinando o script.

## Parâmetros

| Parâmetro | Descrição | Default |
|---|---|---|
| `-Path` | Pasta/share a analisar. Omitido → janela de escolha | — |
| `-Gui` | Janela de navegação (+ progresso com Cancelar no scan) | — |
| `-Depth` | Modo relatório: nº de níveis a imprimir | `0` (= interativo) |
| `-Top` | Pastas por nível | `15` |
| `-FlatTop` | Nº de pastas na vista "maiores de toda a árvore" (consola) | `0` |
| `-ShowExtensions` | Categoria de conteúdo por pasta (consola) | desligado |
| `-Exclude` | Nomes de pasta a ignorar (wildcards) | — |
| `-CsvOut` | Exporta a árvore (uma linha por pasta) | — |
| `-HtmlOut` | Relatório HTML autónomo | — |
| `-SnapshotOut` | Grava snapshot JSON | — |
| `-CompareWith` | Compara com um snapshot anterior | — |
| `-NoProgressGui` | Não mostra a janela de progresso | — |

Consola interativa: `n` (número) afunda, `u` sobe, `e` liga/desliga tipos, `t` top global, `q` sai.
Janela: duplo-clique/Enter entra, Backspace sobe, caixa **Filtrar** restringe a lista por nome,
clique no cabeçalho **Tamanho** ordena por tamanho real, clique direito = abrir no Explorador /
copiar caminho / exportar sub-árvore.

## Comportamento

- **Sem acesso**: pastas que não se conseguiu enumerar (e ficheiros sem acesso a metadados)
  são contados à parte e listados no fim / no HTML. **O espaço dessas pastas não entra nos
  totais.** O scan continua sempre — um erro a meio de uma pasta só faz perder o resto *dessa*
  pasta.
- **Cobertura** (`Complete`): cada pasta é marcada `True` se ela e toda a subárvore foram
  lidas por completo, `False` se algo falhou (sem acesso, falha de enumeração). Numa pasta
  `False` — e em todas as ascendentes, incluindo o Total — os números são **mínimos** (`≥`),
  não totais. O resumo diz `Cobertura: COMPLETA` ou `PARCIAL - N pasta(s)`; no CSV é a coluna
  `Complete`; na consola/HTML as linhas afetadas levam `≥`.
- **Junctions/symlinks**: ignorados (loops, dupla contagem). Placeholders de cloud (OneDrive)
  são percorridos normalmente.
- **"Fich. + recente"**: é a data do ficheiro **mais recente da subárvore** — não significa
  que a pasta foi mexida agora (pode ter 1 ficheiro de 2026 e 500 GB de 2015).
- **Caminhos > 260**: suportados (`\\?\`); ficheiros **e pastas** com caminho longo são
  listados no fim (o Explorer pode na mesma não os abrir).
- **CSV**: uma linha por pasta — `Path, Name, Depth, ParentPath, SizeBytes, Size, Files,
  SubDirs, NewestFileLocal, NewestFileUtc, TopCategory, Complete`. `Depth` = nível relativo à
  raiz. Filtra `Complete = True` para trabalhar só com números exatos.
- Cancelar o scan → resultados parciais (exit code 2).
- O 1.º scan de um share grande demora (percorre tudo uma vez); depois a navegação é instantânea.
- Estado por utilizador em `%APPDATA%\dirsize` (histórico, tamanho da janela).

## Licença

MIT — ver [LICENSE](LICENSE).
