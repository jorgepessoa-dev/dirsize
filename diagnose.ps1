<#
.SYNOPSIS
    Fase 2 do processo: transforma a baseline do dirsize (-CsvOut) num conjunto
    de rankings DETERMINISTAS que orientam a reorganizacao do share.

.DESCRIPTION
    Cada relatorio e uma funcao mecanica das linhas do CSV, com regras fixas e
    visiveis. A ferramenta faz APARECER o que precisa de decisao humana
    (ownership, taxonomia, "isto pode ser eliminado"); NAO toma nenhuma dessas
    decisoes. Todas as pistas de limpeza sao rotuladas "investigar", nunca
    "eliminar".

    Reproducivel: mesmo CSV + mesmos parametros -> ficheiros byte-identicos.
    Auditavel: _PARAMETROS.txt regista o CSV de entrada, o seu SHA-256, a data
    e todos os limiares usados.

    Alvo: Windows PowerShell 5.1. Sem dependencias externas. Sem admin.

.PARAMETER CsvIn
    O CSV produzido por  dirsize.ps1 -CsvOut baseline.csv

.PARAMETER OutDir
    Pasta de saida. Default: <pasta do CSV>\diagnostico

.PARAMETER TopEspaco
    Quantas pastas listar no ranking de espaco absoluto. Default: 100.

.PARAMETER FrioAntesDe
    Uma pasta e "fria" (candidata a arquivo) se o ficheiro MAIS RECENTE de toda
    a sua subarvore for anterior a esta data. Default: hoje - 730 dias.

.PARAMETER ProfundoEm
    Nivel a partir do qual uma pasta conta como estruturalmente profunda. Default: 6.

.PARAMETER LargoEm
    Nº de subpastas diretas a partir do qual uma pasta conta como larga. Default: 100.

.PARAMETER ManifestNivel
    Nivel (relativo a raiz) das pastas que entram no esqueleto do Migration
    Manifest -- as "areas" candidatas. Default: 1.

.EXAMPLE
    .\diagnose.ps1 -CsvIn .\baseline\2026-08-27_baseline.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CsvIn,
    [string]   $OutDir,
    [int]      $TopEspaco = 100,
    [datetime] $FrioAntesDe = (Get-Date).Date.AddDays(-730),
    [int]      $ProfundoEm = 6,
    [int]      $LargoEm = 100,
    [int]      $ManifestNivel = 1
)

$ErrorActionPreference = 'Stop'
$script:DiagVersion = '1.0'

# ----------------------------------------------------------------------------
# Regras FIXAS. Alterar aqui e alterar o criterio -- de proposito visivel.
# ----------------------------------------------------------------------------

# Categorias de conteudo (coluna TopCategory do dirsize) que, por si so, sao
# pista de "espaco possivelmente descartavel". NAO e veredicto.
$script:CategoriasPista = @('Comprimido/Bkp', 'Instalador/Bin')

# Palavras no NOME da pasta que sao pista de conteudo transitorio/duplicado.
# Sem acentos e com acentos, porque ambos aparecem em shares reais.
# Fronteira a esquerda (\b) + "nao seguido de letra" (?![a-z]) em vez de \b a
# direita: assim "Backups_2019" ou "old_files" batem ('_' e digitos contam como
# fim), mas "golden"/"bold" nao (o \b a esquerda falha).
$script:PadraoNomePista = '(?i)(\b(backup|backups|bkp|old|antig[oa]s?|temp|tmp|copy|copies|draft|delete|apagar|lixo|trash)(?![a-z]))|(\barquiv\w*)|(\bc[oó]pias?)|(\brascunh\w*)|(\btest\w*)|(\bobsolet\w*)|(\bdescontinuad\w*)|(_old|_bak|_tmp)'

# Estados validos para a coluna Decision do manifesto (o humano preenche).
$script:DecisoesValidas = @('MIGRATE', 'ARCHIVE', 'DELETE_CANDIDATE', 'REVIEW')

$script:ColunasEsperadas = @(
    'Path', 'Name', 'Depth', 'ParentPath', 'SizeBytes', 'Size', 'Files',
    'SubDirs', 'NewestFileLocal', 'NewestFileUtc', 'TopCategory', 'Complete'
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Read-Baseline {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "CSV nao encontrado: $Path" }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "CSV vazio: $Path" }
    $faltam = $script:ColunasEsperadas | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ }
    if ($faltam) {
        throw ("CSV nao parece uma baseline do dirsize -- faltam colunas: {0}" -f ($faltam -join ', '))
    }
    return $rows
}

# Linha da raiz da arvore (Depth = 0). Fallback: a de maior SizeBytes.
function Get-RootRow {
    param($Rows)
    $r = @($Rows | Where-Object { [int]$_.Depth -eq 0 })
    if ($r.Count -ge 1) { return ($r | Sort-Object { [int64]$_.SizeBytes } -Descending)[0] }
    return ($Rows | Sort-Object { [int64]$_.SizeBytes } -Descending)[0]
}

# Converte NewestFileUtc (ISO 8601 UTC) para [datetime], ou $null se vazio.
function ConvertFrom-Iso {
    param([string] $s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try {
        return [datetime]::Parse(
            $s, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

function Test-Truthy { param([string] $s) return ($s -eq 'True' -or $s -eq '1' -or $s -eq 'true') }

# Escreve um relatorio de forma deterministica (ordem de colunas fixa, UTF-8).
function Write-Report {
    param([string] $Nome, $Linhas, [string[]] $Colunas)
    $fp = Join-Path $script:OutFull $Nome
    if ($null -eq $Linhas -or @($Linhas).Count -eq 0) {
        # cria o ficheiro na mesma, so com o cabecalho, para o output ser estavel
        ($Colunas -join ',') | Set-Content -LiteralPath $fp -Encoding UTF8
    } else {
        @($Linhas) | Select-Object $Colunas |
            Export-Csv -LiteralPath $fp -NoTypeInformation -Encoding UTF8
    }
    Write-Host ("  {0,-32} {1,6} linha(s)" -f $Nome, @($Linhas).Count)
}

# ----------------------------------------------------------------------------
# Relatorios (cada um = funcao pura das linhas)
# ----------------------------------------------------------------------------

# 01 - espaco absoluto: onde esta a massa. Pastas aninhadas aparecem (o tamanho
#      de um pai inclui os filhos) -- e por isso que NAO ha % cumulativa aqui.
function Get-RankEspaco {
    param($Rows, $Root, [int] $N)
    $Rows |
        Where-Object { $_.Path -ne $Root.Path } |
        Sort-Object @{ e = { [int64]$_.SizeBytes }; Descending = $true }, Path |
        Select-Object -First $N |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path; Size = $_.Size; SizeBytes = [int64]$_.SizeBytes
                Depth = [int]$_.Depth; Files = [int]$_.Files
                TopCategory = $_.TopCategory; Complete = $_.Complete
            }
        }
}

# 01b - Pareto das AREAS (nivel N): irmaos ao mesmo nivel nao se sobrepoem, por
#       isso somar os seus tamanhos e valido. % cumulativa sobre o total da raiz.
function Get-RankAreasPareto {
    param($Rows, $Root, [int] $Nivel)
    $total = [int64]$Root.SizeBytes
    $areas = @($Rows |
        Where-Object { [int]$_.Depth -eq $Nivel } |
        Sort-Object @{ e = { [int64]$_.SizeBytes }; Descending = $true }, Path)
    $acc = [int64]0
    $out = foreach ($a in $areas) {
        $b = [int64]$a.SizeBytes
        $acc += $b
        $pct  = if ($total -gt 0) { [math]::Round(100.0 * $b / $total, 2) } else { 0 }
        $cpct = if ($total -gt 0) { [math]::Round(100.0 * $acc / $total, 2) } else { 0 }
        $mark = if ($cpct -le 80) { '80' } elseif ($cpct -le 95) { '95' } else { '' }
        [pscustomobject]@{
            Path = $a.Path; Size = $a.Size; SizeBytes = $b
            PctDoTotal = $pct; PctCumulativa = $cpct; Pareto = $mark
            Files = [int]$a.Files; TopCategory = $a.TopCategory; Complete = $a.Complete
        }
    }
    return $out
}

# 02 - grande E antigo: o ficheiro mais recente de TODA a subarvore e anterior a
#      $FrioAntesDe -> nada la dentro mudou recentemente. Candidato a arquivo.
function Get-RankFrio {
    param($Rows, $Root, [datetime] $Corte)
    $Rows |
        Where-Object {
            $_.Path -ne $Root.Path -and [int64]$_.SizeBytes -gt 0
        } |
        ForEach-Object {
            $dt = ConvertFrom-Iso $_.NewestFileUtc
            if ($dt -and $dt -lt $Corte) {
                [pscustomobject]@{
                    Path = $_.Path; Size = $_.Size; SizeBytes = [int64]$_.SizeBytes
                    FicheiroMaisRecente = $_.NewestFileLocal
                    Files = [int]$_.Files; TopCategory = $_.TopCategory; Complete = $_.Complete
                }
            }
        } |
        Sort-Object @{ e = { $_.SizeBytes }; Descending = $true }, Path
}

# 03 - complexidade estrutural: pastas que serao caras/arriscadas de migrar
#      (caminhos longos, aninhamento profundo, muitas subpastas).
function Get-RankComplexidade {
    param($Rows, $Root, [int] $Profundo, [int] $Largo)
    $Rows |
        Where-Object {
            $_.Path -ne $Root.Path -and
            ([int]$_.Depth -ge $Profundo -or [int]$_.SubDirs -ge $Largo -or $_.Path.Length -gt 240)
        } |
        ForEach-Object {
            $motivos = @()
            if ([int]$_.Depth -ge $Profundo)   { $motivos += "profundidade>=$Profundo" }
            if ([int]$_.SubDirs -ge $Largo)    { $motivos += "subpastas>=$Largo" }
            if ($_.Path.Length -gt 240)        { $motivos += "caminho=$($_.Path.Length)ch" }
            [pscustomobject]@{
                Path = $_.Path; Depth = [int]$_.Depth; SubDirs = [int]$_.SubDirs
                CharsNoCaminho = $_.Path.Length; Size = $_.Size; SizeBytes = [int64]$_.SizeBytes
                Motivo = ($motivos -join '; '); Complete = $_.Complete
            }
        } |
        Sort-Object @{ e = { $_.Depth }; Descending = $true }, @{ e = { $_.SubDirs }; Descending = $true }, Path
}

# 04 - PISTAS de limpeza (nao veredicto): categoria de conteudo ou nome da pasta
#      bate num padrao fixo. Coluna Motivo diz exactamente porque foi marcada.
function Get-PistasLimpeza {
    param($Rows, $Root)
    $Rows |
        Where-Object { $_.Path -ne $Root.Path } |
        ForEach-Object {
            $motivos = @()
            if ($script:CategoriasPista -contains $_.TopCategory) { $motivos += "categoria:$($_.TopCategory)" }
            if ($_.Name -match $script:PadraoNomePista)           { $motivos += "nome:$($Matches[0])" }
            if ($motivos.Count -gt 0) {
                [pscustomobject]@{
                    Path = $_.Path; Size = $_.Size; SizeBytes = [int64]$_.SizeBytes
                    Files = [int]$_.Files; TopCategory = $_.TopCategory
                    FicheiroMaisRecente = $_.NewestFileLocal
                    Motivo = ($motivos -join '; ')
                    Accao = 'INVESTIGAR (nunca eliminar sem validacao humana)'
                }
            }
        } |
        Sort-Object @{ e = { $_.SizeBytes }; Descending = $true }, Path
}

# 05 - cobertura parcial: Complete=False -> os numeros desta pasta sao MINIMOS.
#      Tem de se resolver o acesso antes de decidir seja o que for sobre eles.
function Get-CoberturaParcial {
    param($Rows, $Root)
    $Rows |
        Where-Object { -not (Test-Truthy $_.Complete) } |
        Sort-Object @{ e = { [int64]$_.SizeBytes }; Descending = $true }, Path |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path; SizeMinimo = $_.Size; SizeBytesMinimo = [int64]$_.SizeBytes
                Files = [int]$_.Files; Depth = [int]$_.Depth; TopCategory = $_.TopCategory
            }
        }
}

# 06 - esqueleto do Migration Manifest: uma linha por pasta ao nivel N (as
#      "areas"). Colunas de contexto preenchidas (so leitura); colunas de
#      decisao vazias -- o humano preenche Area/Responsavel*/Decision/Destino.
function Get-ManifestEsqueleto {
    param($Rows, $Root, [int] $Nivel)
    $Rows |
        Where-Object { [int]$_.Depth -eq $Nivel } |
        Sort-Object @{ e = { [int64]$_.SizeBytes }; Descending = $true }, Path |
        ForEach-Object {
            [pscustomobject]@{
                CurrentPath = $_.Path
                Size = $_.Size; SizeBytes = [int64]$_.SizeBytes; Files = [int]$_.Files
                FicheiroMaisRecente = $_.NewestFileLocal; TopCategory = $_.TopCategory
                Complete = $_.Complete
                Area = ''; ResponsibleTeam = ''; ResponsiblePerson = ''
                Decision = ''      # um de: MIGRATE | ARCHIVE | DELETE_CANDIDATE | REVIEW
                DestinationPath = ''
                Notes = ''
            }
        }
}

# ----------------------------------------------------------------------------
# Execucao
# ----------------------------------------------------------------------------

$csvFull = (Resolve-Path -LiteralPath $CsvIn).Path
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $csvFull) 'diagnostico' }
$script:OutFull = $OutDir
if (Test-Path -LiteralPath $script:OutFull) {
    Get-ChildItem -LiteralPath $script:OutFull -File | Remove-Item -Force
} else {
    New-Item -ItemType Directory -Force -Path $script:OutFull | Out-Null
}

$rows = Read-Baseline -Path $csvFull
$root = Get-RootRow -Rows $rows
$hash = (Get-FileHash -LiteralPath $csvFull -Algorithm SHA256).Hash

Write-Host ("dirsize diagnose v{0}" -f $script:DiagVersion) -ForegroundColor Cyan
Write-Host ("Baseline : {0}" -f $csvFull)
Write-Host ("Raiz     : {0}  ({1})" -f $root.Path, $root.Size)
Write-Host ("Pastas   : {0}" -f $rows.Count)
Write-Host ("Saida    : {0}" -f $script:OutFull)
Write-Host ''

Write-Report '01-espaco-top.csv'       (Get-RankEspaco       -Rows $rows -Root $root -N $TopEspaco) `
    @('Path','Size','SizeBytes','Depth','Files','TopCategory','Complete')
Write-Report '01b-areas-pareto.csv'    (Get-RankAreasPareto  -Rows $rows -Root $root -Nivel $ManifestNivel) `
    @('Path','Size','SizeBytes','PctDoTotal','PctCumulativa','Pareto','Files','TopCategory','Complete')
Write-Report '02-grande-e-antigo.csv'  (Get-RankFrio         -Rows $rows -Root $root -Corte $FrioAntesDe) `
    @('Path','Size','SizeBytes','FicheiroMaisRecente','Files','TopCategory','Complete')
Write-Report '03-complexidade.csv'     (Get-RankComplexidade -Rows $rows -Root $root -Profundo $ProfundoEm -Largo $LargoEm) `
    @('Path','Depth','SubDirs','CharsNoCaminho','Size','SizeBytes','Motivo','Complete')
Write-Report '04-pistas-limpeza.csv'   (Get-PistasLimpeza    -Rows $rows -Root $root) `
    @('Path','Size','SizeBytes','Files','TopCategory','FicheiroMaisRecente','Motivo','Accao')
Write-Report '05-cobertura-parcial.csv' (Get-CoberturaParcial -Rows $rows -Root $root) `
    @('Path','SizeMinimo','SizeBytesMinimo','Files','Depth','TopCategory')
Write-Report '06-manifest-esqueleto.csv' (Get-ManifestEsqueleto -Rows $rows -Root $root -Nivel $ManifestNivel) `
    @('CurrentPath','Size','SizeBytes','Files','FicheiroMaisRecente','TopCategory','Complete',
      'Area','ResponsibleTeam','ResponsiblePerson','Decision','DestinationPath','Notes')

# Registo de reproducibilidade
$params = @(
    "dirsize diagnose v$($script:DiagVersion)"
    "gerado          : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    "csv_entrada     : $csvFull"
    "csv_sha256      : $hash"
    "csv_pastas      : $($rows.Count)"
    "raiz            : $($root.Path)"
    "raiz_bytes      : $($root.SizeBytes)"
    "TopEspaco       : $TopEspaco"
    "FrioAntesDe     : $($FrioAntesDe.ToString('yyyy-MM-dd'))"
    "ProfundoEm      : $ProfundoEm"
    "LargoEm         : $LargoEm"
    "ManifestNivel   : $ManifestNivel"
    "CategoriasPista : $($script:CategoriasPista -join ', ')"
    "PadraoNomePista : $($script:PadraoNomePista)"
    "DecisoesValidas : $($script:DecisoesValidas -join ' | ')"
)
$params | Set-Content -LiteralPath (Join-Path $script:OutFull '_PARAMETROS.txt') -Encoding UTF8

Write-Host ''
Write-Host 'Feito. Proximo passo (humano, nao determinista):' -ForegroundColor Green
Write-Host '  1. preencher 06-manifest-esqueleto.csv: Area, Responsaveis, Decision, DestinationPath'
Write-Host '  2. cruzar 02/03/04/05 com os responsaveis de cada area'
Write-Host '  3. so depois -> Fase 3 (validar o manifesto) e Fase 4 (migrar + verificar)'
