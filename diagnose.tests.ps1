<#
    Testes de regressao do diagnose.ps1.
      .\diagnose.tests.ps1            -> corre os asserts
      .\diagnose.tests.ps1 -Mutate   -> confirma que os asserts APANHAM regressoes

    CSV sintetico fixo -> saida deterministica. Verifica que cada linha conhecida
    cai no relatorio certo e que duas corridas dao ficheiros byte-identicos.
#>
[CmdletBinding()]
param([switch] $Mutate)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$diagOrig = Join-Path $here 'diagnose.ps1'
$root     = Join-Path $env:TEMP 'dirsize_diag_test'

$base    = 'X:\share'
$antiga  = (Get-Date).Date.AddDays(-1000).ToString('o')
$recente = (Get-Date).Date.AddDays(-10).ToString('o')

# ArrayList.Add(array) guarda cada linha como UM elemento -- '@( @(...), @(...) )'
# em PowerShell achatava tudo num so array.
$linhas = New-Object System.Collections.ArrayList
# Path ; Name ; Depth ; ParentPath ; SizeBytes ; Size ; Files ; SubDirs ; NewestFileLocal ; NewestFileUtc ; TopCategory ; Complete
[void]$linhas.Add(@("$base",                      'share',        0, 'X:\',        3000, '2,93 KB', 30, 4,   '2026-01-01', $recente, 'Documento',      'True'))
[void]$linhas.Add(@("$base\Financeiro",           'Financeiro',   1, "$base",      1800, '1,76 KB', 12, 2,   '2026-01-01', $recente, 'Folha calculo',  'True'))
[void]$linhas.Add(@("$base\Operacoes",            'Operacoes',    1, "$base",       900, '900 B',   10, 3,   '2020-01-01', $antiga,  'Documento',      'True'))
[void]$linhas.Add(@("$base\Backups_2019",         'Backups_2019', 1, "$base",       250, '250 B',    5, 0,   '2019-06-01', $antiga,  'Comprimido/Bkp', 'True'))
[void]$linhas.Add(@("$base\Instaladores",         'Instaladores', 1, "$base",        40, '40 B',     3, 0,   '2026-01-01', $recente, 'Instalador/Bin', 'True'))
[void]$linhas.Add(@("$base\SemAcesso",            'SemAcesso',    1, "$base",         0, '0 B',      0, 0,   '-',          '',       '',               'False'))
[void]$linhas.Add(@("$base\Operacoes\a\b\c\d\e\f",'f',            7, "$base\Operacoes\a\b\c\d\e", 100, '100 B', 1, 0, '2020-01-01', $antiga,  'Documento', 'True'))
[void]$linhas.Add(@("$base\Financeiro\Larga",     'Larga',        2, "$base\Financeiro", 50, '50 B', 1, 150,  '2026-01-01', $recente, 'Documento',      'True'))
# grande + antiga MAS Complete=False -> nao pode entrar em 02 (numeros sao minimos)
[void]$linhas.Add(@("$base\Operacoes\Parcial",    'Parcial',      2, "$base\Operacoes", 800, '800 B',  4, 0,   '2019-01-01', $antiga,  'Documento',      'False'))
$hdr = 'Path,Name,Depth,ParentPath,SizeBytes,Size,Files,SubDirs,NewestFileLocal,NewestFileUtc,TopCategory,Complete'

function New-Baseline {
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Recurse -File | Remove-Item -Force }
    else { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $csv = Join-Path $root 'baseline.csv'
    $body = foreach ($linha in $linhas) {
        $campos = foreach ($v in $linha) {
            $s = [string]$v
            if ($s -match '[,"]') { '"' + ($s -replace '"', '""') + '"' } else { $s }
        }
        $campos -join ','
    }
    @($hdr) + @($body) | Set-Content -LiteralPath $csv -Encoding UTF8
    return $csv
}

function Get-Rows { param([string] $Nome) @(Import-Csv -LiteralPath (Join-Path $root "diagnostico\$Nome")) }

# Corre todos os asserts contra um dado diagnose.ps1 e devolve o nº de falhas.
function Invoke-DiagAsserts {
    param([string] $DiagScript, [switch] $Silent)
    $script:_p = 0; $script:_f = 0
    function A {
        param([string] $Nome, [bool] $Cond, [string] $Det = '')
        if ($Cond) { if (-not $Silent) { Write-Host "  ok    $Nome" -ForegroundColor Green }; $script:_p++ }
        else       { if (-not $Silent) { Write-Host "  FALHA $Nome $Det" -ForegroundColor Red }; $script:_f++ }
    }

    $csv = New-Baseline
    & $DiagScript -CsvIn $csv *> $null

    $esp = Get-Rows '01-espaco-top.csv'
    A '01 exclui a raiz'           (@($esp | Where-Object { $_.Path -eq $base }).Count -eq 0)
    A '01 ordenado por SizeBytes'  ([int64]$esp[0].SizeBytes -ge [int64]$esp[-1].SizeBytes)
    A '01 maior = Financeiro'      ($esp[0].Path -eq "$base\Financeiro")

    $par = Get-Rows '01b-areas-pareto.csv'
    A '01b so pastas de nivel 1'   (@($par | Where-Object { $_.Path.Substring($base.Length + 1) -match '\\' }).Count -eq 0)
    A '01b Financeiro = Pareto 80' (($par | Where-Object { $_.Path -eq "$base\Financeiro" }).Pareto -eq '80')
    A '01b Operacoes = Pareto 95'  (($par | Where-Object { $_.Path -eq "$base\Operacoes" }).Pareto -eq '95')
    # fronteira: cumulativa em Backups_2019 e ~98%, logo fora do 80 E do 95
    A '01b Backups_2019 sem marca'  (($par | Where-Object { $_.Path -eq "$base\Backups_2019" }).Pareto -eq '')
    A '01b % cumulativa cresce'    ([double]$par[0].PctCumulativa -le [double]$par[-1].PctCumulativa)
    A '01b tem coluna TotalComplete' ($par[0].PSObject.Properties.Name -contains 'TotalComplete')
    A '01b TotalComplete=True (raiz completa)' (@($par | Where-Object { $_.TotalComplete -ne 'True' }).Count -eq 0)

    $frio = Get-Rows '02-grande-e-antigo.csv'
    A '02 inclui Operacoes'        (@($frio | Where-Object { $_.Path -eq "$base\Operacoes" }).Count -eq 1)
    A '02 inclui Backups_2019'     (@($frio | Where-Object { $_.Path -eq "$base\Backups_2019" }).Count -eq 1)
    A '02 exclui Financeiro'       (@($frio | Where-Object { $_.Path -eq "$base\Financeiro" }).Count -eq 0)
    A '02 exclui SemAcesso (0B)'   (@($frio | Where-Object { $_.Path -eq "$base\SemAcesso" }).Count -eq 0)
    # so subarvores completas: Parcial e grande e antiga mas Complete=False
    A '02 exclui Parcial (Complete=False)' (@($frio | Where-Object { $_.Path -eq "$base\Operacoes\Parcial" }).Count -eq 0)
    A '02 so tem Complete=True'    (@($frio | Where-Object { $_.Complete -ne 'True' }).Count -eq 0)
    A '02 ordenado por SizeBytes'  ([int64]$frio[0].SizeBytes -ge [int64]$frio[-1].SizeBytes)

    $cx = Get-Rows '03-complexidade.csv'
    A '03 inclui profundidade 7'   (@($cx | Where-Object { $_.Depth -eq '7' }).Count -eq 1)
    A '03 inclui 150 subpastas'    (@($cx | Where-Object { $_.Path -eq "$base\Financeiro\Larga" }).Count -eq 1)
    A '03 Motivo preenchido'       (($cx | Where-Object { $_.Depth -eq '7' }).Motivo -match 'profundidade')

    $pi = Get-Rows '04-pistas-limpeza.csv'
    A '04 Backups_2019 por NOME'      (($pi | Where-Object { $_.Path -eq "$base\Backups_2019" }).Motivo -match 'nome:')
    A '04 Backups_2019 por CATEGORIA' (($pi | Where-Object { $_.Path -eq "$base\Backups_2019" }).Motivo -match 'categoria:Comprimido')
    A '04 Instaladores por categoria' (@($pi | Where-Object { $_.Path -eq "$base\Instaladores" }).Count -eq 1)
    A '04 NAO apanha Financeiro'      (@($pi | Where-Object { $_.Path -eq "$base\Financeiro" }).Count -eq 0)
    A '04 Accao diz INVESTIGAR'       ($pi[0].Accao -match 'INVESTIGAR')

    $cob = Get-Rows '05-cobertura-parcial.csv'
    A '05 = exactamente os Complete=False' `
        (@($cob).Count -eq 2 -and
         @($cob | Where-Object { $_.Path -eq "$base\SemAcesso" }).Count -eq 1 -and
         @($cob | Where-Object { $_.Path -eq "$base\Operacoes\Parcial" }).Count -eq 1)

    $man = Get-Rows '06-manifest-esqueleto.csv'
    A '06 uma linha por area nvl 1' (@($man).Count -eq 5)
    A '06 exclui a raiz'            (@($man | Where-Object { $_.CurrentPath -eq $base }).Count -eq 0)
    A '06 decisao vazia'           ([string]::IsNullOrEmpty($man[0].Decision) -and [string]::IsNullOrEmpty($man[0].Area))
    A '06 contexto preenchido'     (-not [string]::IsNullOrEmpty($man[0].Size))

    A '_PARAMETROS.txt existe'  (Test-Path -LiteralPath (Join-Path $root 'diagnostico\_PARAMETROS.txt'))
    $pp = Get-Content -LiteralPath (Join-Path $root 'diagnostico\_PARAMETROS.txt') -Raw
    A '_PARAMETROS tem SHA-256'  ($pp -match 'csv_sha256\s*:\s*[0-9A-F]{64}')
    A '_PARAMETROS regista raiz_complete'  ($pp -match 'raiz_complete\s*:\s*(True|False)')

    # --- validacao fail-closed da baseline: CSV estruturalmente mau -> aborta ---
    function Test-Aborts {
        param([string] $Nome, [string] $CsvBody)
        $bad = Join-Path $root 'bad.csv'
        Set-Content -LiteralPath $bad -Value $CsvBody -Encoding UTF8
        try { & $DiagScript -CsvIn $bad -OutDir (Join-Path $root 'diag_bad') *> $null; A "aborta: $Nome" $false '(nao abortou)' }
        catch { A "aborta: $Nome" $true }
    }
    $ok1 = "$base\r,r,0,X:\,10,10 B,1,0,,,Doc,True"
    Test-Aborts 'duas raizes Depth=0'  ($hdr + "`n" + $ok1 + "`n" + "$base\b,b,0,$base,5,5 B,1,0,,,Doc,True")
    Test-Aborts 'zero raizes Depth=0'  ($hdr + "`n" + "$base\b,b,1,$base,5,5 B,1,0,,,Doc,True")
    Test-Aborts 'SizeBytes nao inteiro' ($hdr + "`n" + "$base\r,r,0,X:\,banana,x,1,0,,,Doc,True")
    Test-Aborts 'Depth negativo'        ($hdr + "`n" + "$base\r,r,-1,X:\,10,10 B,1,0,,,Doc,True")
    Test-Aborts 'Complete invalido'     ($hdr + "`n" + "$base\r,r,0,X:\,10,10 B,1,0,,,Doc,talvez")
    Test-Aborts 'NewestFileUtc lixo'    ($hdr + "`n" + "$base\r,r,0,X:\,10,10 B,1,0,ontem,ontem,Doc,True")
    Test-Aborts 'falta coluna'          ('Path,Name,Depth' + "`n" + "$base\r,r,0")

    # determinismo: 2a corrida -> RELATORIOS byte-identicos. _PARAMETROS.txt tem
    # timestamp e e a excepcao deliberada -- filtra-se com Where-Object porque o
    # -Exclude do Get-ChildItem e ignorado quando se usa -LiteralPath (PS 5.1).
    function Get-RelatorioHashes {
        Get-ChildItem -LiteralPath (Join-Path $root 'diagnostico') -File |
            Where-Object { $_.Name -ne '_PARAMETROS.txt' } | Sort-Object Name |
            ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }
    $h1 = @(Get-RelatorioHashes)
    & $DiagScript -CsvIn $csv *> $null
    $h2 = @(Get-RelatorioHashes)
    A 'duas corridas -> relatorios byte-identicos' `
        ($h1.Count -gt 0 -and $h1.Count -eq $h2.Count -and @(Compare-Object $h1 $h2).Count -eq 0) `
        "(h1=$($h1.Count) h2=$($h2.Count))"

    return $script:_f
}

# ---------------------------------------------------------------------------
if (-not $Mutate) {
    Write-Host 'diagnose.ps1 - relatorios deterministas' -ForegroundColor Cyan
    $fails = Invoke-DiagAsserts -DiagScript $diagOrig
    Write-Host ''
    if ($fails -eq 0) { Write-Host "diagnose: $($script:_p) asserts, todos ok" -ForegroundColor Green; exit 0 }
    Write-Host "diagnose: $fails de $($script:_p + $fails) asserts falharam" -ForegroundColor Red
    exit 1
}

# ---- modo -Mutate: injecta defeitos conhecidos, confirma que a suite os apanha
$src = Get-Content -LiteralPath $diagOrig -Raw
$mut = Join-Path $env:TEMP 'diagnose_mut.ps1'
# Nota: nos 'Para', '$' e especial para [regex]::Replace (grupos de substituicao).
# Escreve-se '$$' para produzir um '$' literal no mutante.
$casos = @(
    @{ Nome = 'M1 categorias de pista -> lista vazia'
       Rx = "\@\('Comprimido/Bkp', 'Instalador/Bin'\)"; Para = "@('___nada___')" }
    @{ Nome = 'M2 corte do frio invertido (-lt -> -ge)'
       Rx = '\$dt -and \$dt -lt \$Corte'; Para = '$$dt -and $$dt -ge $$Corte' }
    @{ Nome = 'M3 limiar do Pareto 80 -> 200 (nada marcado)'
       Rx = '\$cpct -le 80'; Para = '$$cpct -le 200' }
    @{ Nome = 'M4 cobertura parcial mostra os Complete=True'
       Rx = 'Where-Object \{ -not \(Test-Truthy \$_\.Complete\) \}'; Para = 'Where-Object { (Test-Truthy $$_.Complete) }' }
    @{ Nome = 'M5 report 02 deixa entrar Complete=False'
       Rx = '\[int64\]\$_\.SizeBytes -gt 0 -and \(Test-Truthy \$_\.Complete\)'; Para = '[int64]$$_.SizeBytes -gt 0' }
    @{ Nome = 'M6 Read-Baseline deixa passar baseline sem raiz'
       Rx = 'if \(\$raizes\.Count -ne 1\)'; Para = 'if ($$false)' }
)
$anyMiss = $false
foreach ($c in $casos) {
    if (-not [regex]::IsMatch($src, $c.Rx)) {
        Write-Host "$($c.Nome): PADRAO NAO ENCONTRADO" -ForegroundColor Yellow; $anyMiss = $true; continue
    }
    [regex]::Replace($src, $c.Rx, $c.Para) | Set-Content -LiteralPath $mut -Encoding UTF8
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($mut, [ref]$null, [ref]$e)
    if ($e) {
        Write-Host "$($c.Nome): MUTANTE NAO COMPILA (mutacao invalida)" -ForegroundColor Yellow; $anyMiss = $true; continue
    }
    $f = Invoke-DiagAsserts -DiagScript $mut -Silent
    if ($f -gt 0) { Write-Host "$($c.Nome): APANHADO ($f assert(s))" -ForegroundColor Green }
    else          { Write-Host "$($c.Nome): NAO APANHADO - buraco na suite" -ForegroundColor Red; $anyMiss = $true }
}
if (Test-Path -LiteralPath $mut) { Remove-Item -LiteralPath $mut -Force }
if ($anyMiss) { exit 1 } else { exit 0 }
