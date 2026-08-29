# Pedido de revisão — ecossistema `dirsize`

> Cola a secção **PROMPT** (a partir da linha marcada) num revisor à tua escolha.
> Um de cada vez. Se o revisor navega a web, dá-lhe o link do repo; senão, cola
> também os ficheiros indicados.
>
> O `tools/dispatch-review.sh` extrai a secção PROMPT sozinho.

## Repositório (público)

- Repo: https://github.com/jorgepessoa-dev/dirsize
- Ficheiros:
  `dirsize.ps1` (scanner, congelado `v2.1`),
  `diagnose.ps1` (Fase 2, congelado `diagnose-v1.1`),
  `golden.ps1` + `diagnose.tests.ps1` (suites de regressão, dev-only),
  `Pastas.cmd`, `README.md`, `CLAUDE.md`.

---

## PROMPT (copiar a partir daqui)

És um revisor sénior de PowerShell e Windows/.NET. Vais rever o ecossistema
`dirsize`. **Não reescrevas nada** — quero achados concretos, ancorados em
ficheiro + número de linha, com severidade e um patch mínimo por cada um.

### Estado atual (não é para "melhorar", é para verificar)

- **`dirsize.ps1`** — scanner de tamanhos de pastas, congelado (`v2.1`). Um scan
  para memória; depois GUI WinForms / consola interativa / relatório fixo.
  Comportamento fixado pelo `golden.ps1` (`-Mode all`: 6 artefactos byte-idênticos
  + 41 invariantes + 27 asserts de GUI).
- **`diagnose.ps1`** — Fase 2, congelado (`diagnose-v1.1`). Consome a baseline
  (`dirsize.ps1 -CsvOut`) e produz 7 CSVs deterministas + `resumo.html`.
  `diagnose.tests.ps1`: 46 asserts + modo `-Mutate` (7 mutações, todas apanhadas).
- Alvo: **Windows PowerShell 5.1**, **sem admin**, **sem instalar nada**, GPO
  `MachinePolicy RemoteSigned`. Rede via `\\servidor\share`. Caminhos > 260 via `\\?\`.
- Próximo passo (por construir): `validate-manifest.ps1` (Fase 3).

### Invariantes que o código afirma cumprir — confirma ou refuta cada uma

1. **Long paths.** `EnumerateFileSystemEntries` com raiz `\\?\` devolve entradas
   já prefixadas, logo `GetAttributes` / `FileInfo` / `Test-IsJunctionOrSymlink`
   funcionam em caminhos > 260 sem reconversão. `ConvertTo-ExtendedPath` é
   idempotente. Há algum caso (UNC, drive-relative, `.`/`..`) em que isto quebra?
2. **`Complete` (cobertura).** Um nó é `Complete=$false` em falha de
   `enum-dir`/`enum-iter`/`attr`/`size` E em cancelamento (o `break` sai do
   `foreach` sem excepção — há um check dedicado antes do `return`). Propaga
   para os antecessores. Os totais de um nó `False` são mínimos. Falta algum
   caminho de código que devolva números parciais como se fossem exactos?
3. **Reparse points.** Só se ignoram junctions/symlinks reais (tag
   `IO_REPARSE_TAG_MOUNT_POINT` / `_SYMLINK`); placeholders de cloud são
   percorridos. Contado em `$script:Scan.SkipReparse`. Mount points NTFS e DFS
   caem em que lado, e é o correcto?
4. **Estado `$script:`.** Agrupado em `$script:Scan` / `$script:Prog` /
   `$script:Ui` (PSCustomObject — atribuição a propriedade inexistente rebenta).
   `Show-Gui` delega a construção mas mantém os handlers inline porque fecham
   sobre locais. Há alguma fuga de estado ou handler que resolva mal?
5. **`Get-FlatTop`.** Selecção parcial (mantém só os N maiores durante o
   varrimento, inserção binária) em vez de `Sort-Object` a tudo. Devolve
   `,$array` (o `return` desenrola 1 elemento). Empates: ordem de travessia
   (determinista; `Sort-Object` do PS 5.1 não é estável). O resultado é mesmo
   o mesmo CONJUNTO e os mesmos TAMANHOS que ordenar tudo?
6. **`diagnose.ps1` — determinismo.** Os `0x-*.csv` e o `resumo.html` são
   byte-idênticos para o mesmo CSV + parâmetros; `_PARAMETROS.txt` é a excepção
   (tem data). O `resumo.html` não leva data no corpo. Alguma fonte de
   não-determinismo escondida (ordem de hashtable, cultura, `Get-Date` implícito)?
7. **`diagnose.ps1` — fail-closed.** `Read-Baseline` aborta se: não houver
   exactamente uma raiz `Depth=0`; alguma coluna numérica não for inteiro ≥ 0;
   `Complete` não for `True`/`False`; `NewestFileUtc` não for vazio nem ISO.
   `Get-RootRow` não tem fallback. É suficientemente estrito para uma ferramenta
   de diagnóstico?
8. **`diagnose.ps1` — fronteira analítica.** As "pistas de limpeza" são regra
   fixa (categoria OU nome bate num padrão), rotuladas `INVESTIGAR`, nunca
   veredicto. O `02-grande-e-antigo` só inclui subárvores `Complete=True`. O
   `06-manifest-esqueleto` só tem factos observados; decisões vazias. Há algum
   sítio onde o programa esteja a decidir em vez de apresentar?
9. **`Pastas.cmd`.** Faz `Unblock-File` (via `-LiteralPath -Filter`, porque
   `-Path` com wildcard falha em pastas com `[`/`]`) e depois
   `-ExecutionPolicy Bypass`. Sob GPO `MachinePolicy`, o `Bypass` é ignorado e
   só o `Unblock-File` destranca. Falta cobrir algum cenário de bloqueio?
10. **Suites de teste.** O `golden.ps1` carrega funções por AST e re-corre o
    bloco `Add-Type` do `FsReparse.Native`. O `diagnose.tests.ps1` tem modo
    `-Mutate`. Há alguma invariante crítica que a suite NÃO force
    explicitamente (e que passe por acaso)?
11. **Fase 3 (design, ainda não há código).** O `validate-manifest.ps1` deve
    ser fail-closed e provar ausência de conflitos espaciais: **nenhuma
    operação pode ter origem ou destino que seja igual a, contenha, ou esteja
    contida na origem ou destino de outra** (nem origem↔destino entre linhas).
    Esta regra é completa? Falta algum caso (case-insensitive, trailing `\`,
    `8.3` names, symlinks no destino, mesma origem para dois destinos)?
12. **Robustez geral.** Bugs de lógica, off-by-one, null-deref, encoding,
    qualquer caminho que rebente com `$ErrorActionPreference='Stop'`, ou
    qualquer sintaxe/API que difira entre PS 5.1 e 7 (mesmo que só o 5.1 seja
    o alvo).

### Formato da resposta (obrigatório)

Lista de achados, ordenada por severidade (CRITICAL > HIGH > MEDIUM > LOW):

```
[SEVERIDADE] ficheiro:linha — <resumo numa frase>
  Cenário de falha: <input/estado concreto -> resultado errado>
  Patch sugerido: <a alteração mínima>
```

No fim, uma linha só:
`VEREDICTO: <congelar como está / tem bugs bloqueantes / precisa de X testes>`.

Se não encontrares nada numa categoria, diz "sem achados" — não inventes.

--- (fim do prompt) ---

## Depois de teres 2+ respostas

- Achado que **dois revisores** apontam (mesmo ficheiro/linha/causa) → quase de
  certeza real, corrige primeiro.
- Achado que só **um** aponta → hipótese; confirma antes de mexer.
- Discordância no mesmo ponto → candidato a teste em máquina real.
