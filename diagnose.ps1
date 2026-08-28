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

    Determinismo: os RELATORIOS (0x-*.csv) sao byte-identicos para o mesmo CSV +
    os mesmos parametros. _PARAMETROS.txt e a excepcao deliberada -- contem
    metadados volateis da execucao (data). E por isso que os testes de
    determinismo excluem _PARAMETROS.txt da comparacao.
    Auditavel: _PARAMETROS.txt regista o CSV de entrada, o seu SHA-256, a data,
    o estado de cobertura da raiz e todos os limiares usados.

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
$script:DiagVersion = '1.1'   # 1.1: resumo.html (mesmos rankings, apresentacao)

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

# Le e VALIDA a baseline. Fail-closed: uma baseline estruturalmente invalida
# aborta -- nao se tenta inferir nada. A origem e uma ferramenta controlada
# (dirsize), por isso qualquer desvio ao formato e um erro, nao um caso a tolerar.
function Read-Baseline {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "CSV nao encontrado: $Path" }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "CSV vazio: $Path" }

    $faltam = $script:ColunasEsperadas | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ }
    if ($faltam) {
        throw ("CSV nao parece uma baseline do dirsize -- faltam colunas: {0}" -f ($faltam -join ', '))
    }

    # tipos, linha a linha (Int64.TryParse e barato mesmo em 500k linhas)
    $ln = 0; $ref = [int64]0
    foreach ($r in $rows) {
        $ln++
        foreach ($col in 'Depth', 'SizeBytes', 'Files', 'SubDirs') {
            if (-not [int64]::TryParse([string]$r.$col, [ref]$ref) -or $ref -lt 0) {
                throw ("Linha {0}: coluna '{1}' nao e um inteiro >= 0 (valor: '{2}')" -f $ln, $col, $r.$col)
            }
        }
        if ($r.Complete -ne 'True' -and $r.Complete -ne 'False') {
            throw ("Linha {0}: coluna 'Complete' tem de ser True ou False (valor: '{1}')" -f $ln, $r.Complete)
        }
        if (-not [string]::IsNullOrWhiteSpace($r.NewestFileUtc) -and $null -eq (ConvertFrom-Iso $r.NewestFileUtc)) {
            throw ("Linha {0}: 'NewestFileUtc' nem vazio nem ISO 8601 valido (valor: '{1}')" -f $ln, $r.NewestFileUtc)
        }
    }

    # exactamente uma raiz
    $raizes = @($rows | Where-Object { [int]$_.Depth -eq 0 })
    if ($raizes.Count -ne 1) {
        throw "A baseline tem de ter EXACTAMENTE uma linha Depth=0 (tem $($raizes.Count))"
    }
    return $rows
}

# A raiz e a (unica) linha Depth=0 -- garantido por Read-Baseline.
function Get-RootRow {
    param($Rows)
    return @($Rows | Where-Object { [int]$_.Depth -eq 0 })[0]
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

function ConvertTo-HtmlText {
    param([string] $s)
    if ($null -eq $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

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
#       TotalComplete = estado de cobertura da raiz: se for False, Root.SizeBytes
#       e um MINIMO e o denominador pode crescer -> as % sao PROVISORIAS.
function Get-RankAreasPareto {
    param($Rows, $Root, [int] $Nivel)
    $total = [int64]$Root.SizeBytes
    $totComplete = if (Test-Truthy $Root.Complete) { 'True' } else { 'False' }
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
            TotalComplete = $totComplete
        }
    }
    return $out
}

# 02 - grande E antigo: o ficheiro mais recente de TODA a subarvore e anterior a
#      $FrioAntesDe -> nada la dentro mudou recentemente. Candidato a arquivo.
#      SO subarvores COMPLETAMENTE observadas entram aqui: numa pasta Complete=False
#      o tamanho e a data sao minimos -- o ficheiro mais recente pode estar na
#      parte que nao se conseguiu ler. Essas pastas aparecem em 05-cobertura-parcial.
function Get-RankFrio {
    param($Rows, $Root, [datetime] $Corte)
    $Rows |
        Where-Object {
            $_.Path -ne $Root.Path -and [int64]$_.SizeBytes -gt 0 -and (Test-Truthy $_.Complete)
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
# resumo.html -- os mesmos rankings lado a lado, num ficheiro autonomo para
# mostrar as areas / a chefia. DETERMINISTA: nao leva data no corpo (a
# proveniencia e o nome do CSV + o SHA-256). Mesmo CSV -> HTML byte-identico.
# ----------------------------------------------------------------------------
function Export-Resumo {
    param($Root, [string] $CsvPath, [string] $CsvHash,
          $Areas, $Frio, $Complexo, $Pistas, $Parcial,
          [datetime] $Corte, [int] $TopHtml = 20)

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }
    $rootParcial = -not (Test-Truthy $Root.Complete)

    $css = @'
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1c1c1c;background:#fafafa}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:26px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
 .muted{color:#666;font-size:12px} .cards{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0}
 .card{background:#fff;border:1px solid #e2e2e2;border-radius:8px;padding:10px 14px;min-width:110px}
 .card .v{font-size:18px;font-weight:600} .card .l{font-size:11px;color:#777;text-transform:uppercase;letter-spacing:.04em}
 table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;margin-bottom:8px}
 th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eee} th{background:#f0f0f0}
 td.num{text-align:right;white-space:nowrap} .bar{background:#e8e8e8;border-radius:3px;height:12px;overflow:hidden}
 .bar>span{display:block;height:12px;background:#4a7fb5} .path{font-family:Consolas,monospace;font-size:12px;word-break:break-all}
 .warn{background:#fff4d6;border:1px solid #e6c34d;border-radius:6px;padding:8px 12px;margin:10px 0}
 .note{background:#eef6ee;border:1px solid #bcd9bc;border-radius:6px;padding:8px 12px;margin:14px 0}
</style>
'@

    & $add '<!doctype html><html lang="pt"><head><meta charset="utf-8">'
    & $add ("<title>Diagnostico - " + (ConvertTo-HtmlText $Root.Path) + "</title>")
    & $add $css
    & $add '</head><body>'
    & $add '<h1>Diagnostico do share &mdash; resumo</h1>'
    & $add ("<div class='muted'>" + (ConvertTo-HtmlText $Root.Path) +
            " &mdash; baseline: " + (ConvertTo-HtmlText (Split-Path -Leaf $CsvPath)) +
            " &mdash; SHA-256 " + $CsvHash.Substring(0, 16) + "&hellip;" +
            " &mdash; diagnose v" + $script:DiagVersion + "</div>")

    if ($rootParcial) {
        & $add ("<div class='warn'><b>Cobertura parcial.</b> A raiz tem pastas nao lidas " +
                "(sem acesso). O total e as percentagens sao <b>minimos</b> &mdash; podem crescer " +
                "quando o acesso for resolvido. Ver a seccao <i>Cobertura parcial</i>.</div>")
    }

    & $add "<div class='cards'>"
    & $add ("<div class='card'><div class='v'>" + (ConvertTo-HtmlText $Root.Size) +
            $(if ($rootParcial) { ' &ge;' } else { '' }) + "</div><div class='l'>Total</div></div>")
    & $add ("<div class='card'><div class='v'>" + @($Areas).Count + "</div><div class='l'>Areas</div></div>")
    & $add ("<div class='card'><div class='v'>" + @($Frio).Count + "</div><div class='l'>Grande + antigo</div></div>")
    & $add ("<div class='card'><div class='v'>" + @($Complexo).Count + "</div><div class='l'>Complexas</div></div>")
    & $add ("<div class='card'><div class='v'>" + @($Pistas).Count + "</div><div class='l'>Pistas limpeza</div></div>")
    & $add ("<div class='card'><div class='v'>" + @($Parcial).Count + "</div><div class='l'>Sem acesso</div></div>")
    & $add "</div>"

    # --- Pareto das areas ---
    & $add "<h2>Areas por espaco (Pareto)</h2>"
    & $add ("<p class='muted'>As areas marcadas <b>80</b> somam ~80% do espaco. E onde comeca o trabalho." +
            $(if ($rootParcial) { " Percentagens PROVISORIAS (raiz parcial)." } else { '' }) + "</p>")
    & $add "<table><tr><th>Area</th><th class='num'>Tamanho</th><th class='num'>%</th><th></th><th class='num'>% cumul.</th><th>Pareto</th><th>Conteudo</th></tr>"
    foreach ($a in $Areas) {
        $w = [math]::Min(100, [double]$a.PctDoTotal)
        & $add ("<tr><td class='path'>" + (ConvertTo-HtmlText $a.Path) + "</td>" +
                "<td class='num'>" + (ConvertTo-HtmlText $a.Size) + "</td>" +
                "<td class='num'>" + $a.PctDoTotal + "%</td>" +
                "<td style='width:120px'><div class='bar'><span style='width:$w%'></span></div></td>" +
                "<td class='num'>" + $a.PctCumulativa + "%</td>" +
                "<td>" + (ConvertTo-HtmlText $a.Pareto) + "</td>" +
                "<td>" + (ConvertTo-HtmlText $a.TopCategory) + "</td></tr>")
    }
    & $add "</table>"

    # --- grande e antigo ---
    & $add ("<h2>Grande e antigo (candidatas a arquivo)</h2>")
    & $add ("<p class='muted'>Subarvores completamente observadas cujo ficheiro mais recente e anterior a " +
            $Corte.ToString('yyyy-MM-dd') + ". Nada la dentro mudou desde entao.</p>")
    if (@($Frio).Count -eq 0) { & $add '<p class="muted">(nenhuma)</p>' }
    else {
        & $add "<table><tr><th>Pasta</th><th class='num'>Tamanho</th><th>Ficheiro mais recente</th><th class='num'>Fich.</th><th>Conteudo</th></tr>"
        foreach ($f in (@($Frio) | Select-Object -First $TopHtml)) {
            & $add ("<tr><td class='path'>" + (ConvertTo-HtmlText $f.Path) + "</td>" +
                    "<td class='num'>" + (ConvertTo-HtmlText $f.Size) + "</td>" +
                    "<td>" + (ConvertTo-HtmlText $f.FicheiroMaisRecente) + "</td>" +
                    "<td class='num'>" + $f.Files + "</td>" +
                    "<td>" + (ConvertTo-HtmlText $f.TopCategory) + "</td></tr>")
        }
        & $add "</table>"
    }

    # --- complexidade ---
    & $add "<h2>Complexidade estrutural (caras de migrar)</h2>"
    & $add "<p class='muted'>Profundas, largas ou com caminhos longos. Planear estas separadamente.</p>"
    if (@($Complexo).Count -eq 0) { & $add '<p class="muted">(nenhuma)</p>' }
    else {
        & $add "<table><tr><th>Pasta</th><th class='num'>Nivel</th><th class='num'>Subpastas</th><th class='num'>Chars</th><th>Motivo</th></tr>"
        foreach ($c in (@($Complexo) | Select-Object -First $TopHtml)) {
            & $add ("<tr><td class='path'>" + (ConvertTo-HtmlText $c.Path) + "</td>" +
                    "<td class='num'>" + $c.Depth + "</td><td class='num'>" + $c.SubDirs + "</td>" +
                    "<td class='num'>" + $c.CharsNoCaminho + "</td>" +
                    "<td>" + (ConvertTo-HtmlText $c.Motivo) + "</td></tr>")
        }
        & $add "</table>"
    }

    # --- pistas de limpeza ---
    & $add "<h2>Pistas de limpeza</h2>"
    & $add ("<div class='warn'>Sao <b>pistas para investigar</b>, decididas por regra fixa (categoria ou " +
            "nome). <b>Nao sao veredicto.</b> Nada se elimina sem validacao de quem responde pela area.</div>")
    if (@($Pistas).Count -eq 0) { & $add '<p class="muted">(nenhuma)</p>' }
    else {
        & $add "<table><tr><th>Pasta</th><th class='num'>Tamanho</th><th>Conteudo</th><th>Motivo</th></tr>"
        foreach ($p in (@($Pistas) | Select-Object -First $TopHtml)) {
            & $add ("<tr><td class='path'>" + (ConvertTo-HtmlText $p.Path) + "</td>" +
                    "<td class='num'>" + (ConvertTo-HtmlText $p.Size) + "</td>" +
                    "<td>" + (ConvertTo-HtmlText $p.TopCategory) + "</td>" +
                    "<td>" + (ConvertTo-HtmlText $p.Motivo) + "</td></tr>")
        }
        & $add "</table>"
    }

    # --- cobertura parcial ---
    if (@($Parcial).Count -gt 0) {
        & $add "<h2>Cobertura parcial (sem acesso) &mdash; $(@($Parcial).Count)</h2>"
        & $add "<p class='muted'>O espaco destas pastas NAO entra nos totais. Pedir acesso antes de decidir.</p>"
        & $add "<ul class='path'>"
        foreach ($x in (@($Parcial) | Select-Object -First 100)) { & $add ("<li>" + (ConvertTo-HtmlText $x.Path) + "</li>") }
        & $add "</ul>"
    }

    & $add ("<div class='note'>Isto e um retrato quantitativo, nao um plano. Ownership, taxonomia e " +
            "decisoes de eliminacao sao das areas. Dados completos: os ficheiros <code>0x-*.csv</code> " +
            "na pasta <code>diagnostico\</code>; limiares usados: <code>_PARAMETROS.txt</code>.</div>")
    & $add '</body></html>'

    $fp = Join-Path $script:OutFull 'resumo.html'
    [System.IO.File]::WriteAllText($fp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
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

# Cada relatorio e calculado uma vez, gravado em CSV, e (01b..05) reaproveitado
# no resumo.html.
$rEspaco   = Get-RankEspaco       -Rows $rows -Root $root -N $TopEspaco
$rAreas    = Get-RankAreasPareto  -Rows $rows -Root $root -Nivel $ManifestNivel
$rFrio     = Get-RankFrio         -Rows $rows -Root $root -Corte $FrioAntesDe
$rComplexo = Get-RankComplexidade -Rows $rows -Root $root -Profundo $ProfundoEm -Largo $LargoEm
$rPistas   = Get-PistasLimpeza    -Rows $rows -Root $root
$rParcial  = Get-CoberturaParcial -Rows $rows -Root $root
$rManifest = Get-ManifestEsqueleto -Rows $rows -Root $root -Nivel $ManifestNivel

Write-Report '01-espaco-top.csv'        $rEspaco `
    @('Path','Size','SizeBytes','Depth','Files','TopCategory','Complete')
Write-Report '01b-areas-pareto.csv'     $rAreas `
    @('Path','Size','SizeBytes','PctDoTotal','PctCumulativa','Pareto','Files','TopCategory','Complete','TotalComplete')
Write-Report '02-grande-e-antigo.csv'   $rFrio `
    @('Path','Size','SizeBytes','FicheiroMaisRecente','Files','TopCategory','Complete')
Write-Report '03-complexidade.csv'      $rComplexo `
    @('Path','Depth','SubDirs','CharsNoCaminho','Size','SizeBytes','Motivo','Complete')
Write-Report '04-pistas-limpeza.csv'    $rPistas `
    @('Path','Size','SizeBytes','Files','TopCategory','FicheiroMaisRecente','Motivo','Accao')
Write-Report '05-cobertura-parcial.csv' $rParcial `
    @('Path','SizeMinimo','SizeBytesMinimo','Files','Depth','TopCategory')
Write-Report '06-manifest-esqueleto.csv' $rManifest `
    @('CurrentPath','Size','SizeBytes','Files','FicheiroMaisRecente','TopCategory','Complete',
      'Area','ResponsibleTeam','ResponsiblePerson','Decision','DestinationPath','Notes')

Export-Resumo -Root $root -CsvPath $csvFull -CsvHash $hash `
    -Areas $rAreas -Frio $rFrio -Complexo $rComplexo -Pistas $rPistas -Parcial $rParcial `
    -Corte $FrioAntesDe
Write-Host ("  {0,-32} {1}" -f 'resumo.html', '(rankings lado a lado)')

# Registo de reproducibilidade
$params = @(
    "dirsize diagnose v$($script:DiagVersion)"
    "gerado          : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    "csv_entrada     : $csvFull"
    "csv_sha256      : $hash"
    "csv_pastas      : $($rows.Count)"
    "raiz            : $($root.Path)"
    "raiz_bytes      : $($root.SizeBytes)"
    "raiz_complete   : $($root.Complete)   # False -> totais e % do Pareto sao MINIMOS/provisorios"
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
