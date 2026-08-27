<#
.SYNOPSIS
    Analisa o espaco ocupado por ficheiros/pastas numa localizacao de rede (ou local),
    de forma granular (por camadas), sem exigir privilegios de administrador e
    lidando com caminhos que ultrapassam o limite de 260 caracteres (long paths).

.DESCRIPTION
    - Nao precisa de admin: usa apenas PowerShell + .NET System.IO.
    - Long paths: usa o prefixo estendido \\?\ (\\?\UNC\ para rede) para ignorar o
      limite MAX_PATH. Ficheiros com caminho > 260 caracteres sao contados e podem
      ser listados.
    - Acessos negados sao apanhados e contados; o scan continua na mesma.
    - Faz UM scan (streaming, memoria baixa) e constoi uma arvore de tamanhos.
      Depois navegas granularmente: por omissao em modo interativo (afundas numa
      pasta so quando escolheres), ou em modo relatorio com profundidade fixa.
    - Sem semantica: para dar uma pista do "assunto" de cada pasta, mostra o
      breakdown por extensao (que TIPO de conteudo predomina).

.PARAMETER Path
    Localizacao a analisar. Ex: \\servidor\share\pasta  ou  D:\Dados

.PARAMETER Top
    Quantas pastas/itens mostrar por nivel (as maiores primeiro). Default: 15.

.PARAMETER Depth
    Modo relatorio: profundidade de camadas a imprimir de uma vez. Default: 1.
    (Ignorado quando -Interactive esta ativo.)

.PARAMETER Interactive
    Ativa a navegacao interativa (recomendado). Se nem -Interactive nem -Depth
    forem especificados, o modo interativo e usado por omissao.

.PARAMETER ShowExtensions
    Mostra o breakdown por extensao (top tipos de ficheiro) em cada pasta.

.PARAMETER Exclude
    Nomes de pasta a ignorar durante o scan (wildcards). Ex: -Exclude 'node_modules','.git'

.PARAMETER CsvOut
    Caminho para exportar a arvore completa (uma linha por pasta) em CSV.

.EXAMPLE
    .\Analyze-FolderSizes.ps1 -Path '\\servidor\share\Projetos'
    # scan + navegacao interativa

.EXAMPLE
    .\Analyze-FolderSizes.ps1 -Path '\\servidor\share' -Depth 2 -Top 10 -ShowExtensions
    # relatorio de 2 niveis, top 10 por nivel, com tipos de ficheiro

.EXAMPLE
    .\Analyze-FolderSizes.ps1 -Path '\\servidor\share' -CsvOut relatorio.csv
    # scan + exporta tudo para CSV
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [int]    $Top = 15,
    [int]    $Depth = 0,
    [switch] $Interactive,
    [switch] $ShowExtensions,
    [string[]] $Exclude = @(),
    [string] $CsvOut
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Converte um caminho normal no formato estendido \\?\  (ignora MAX_PATH).
function ConvertTo-ExtendedPath {
    param([string] $p)
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\'))   { return '\\?\UNC\' + $p.Substring(2) }  # rede
    return '\\?\' + $p                                                  # local
}

# Tamanho legivel
function Format-Size {
    param([int64] $b)
    if ($b -ge 1TB) { return ('{0:N2} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N2} KB' -f ($b / 1KB)) }
    return ("$b B")
}

function Test-Excluded {
    param([string] $name)
    foreach ($pat in $Exclude) { if ($name -like $pat) { return $true } }
    return $false
}

# Estado global do scan
$script:ErrCount   = 0
$script:Errors     = New-Object System.Collections.Generic.List[string]
$script:LongPaths  = New-Object System.Collections.Generic.List[object]
$script:Count      = 0
$script:LastReport = 0

# ----------------------------------------------------------------------------
# Scan recursivo -> devolve um no com tamanho/contagens CUMULATIVOS
#   Node = { Path; Name; Size; FileCount; DirCount; Children[]; Ext{ext->size} }
# ----------------------------------------------------------------------------
function Get-FolderNode {
    param([string] $DisplayPath)

    $node = [pscustomobject]@{
        Path      = $DisplayPath
        Name      = [System.IO.Path]::GetFileName($DisplayPath.TrimEnd('\'))
        Size      = [int64]0
        FileCount = 0
        DirCount  = 0
        Children  = (New-Object System.Collections.Generic.List[object])
        Ext       = @{}
    }
    if ([string]::IsNullOrEmpty($node.Name)) { $node.Name = $DisplayPath }

    $extPath = ConvertTo-ExtendedPath $DisplayPath
    try {
        $entries = [System.IO.Directory]::EnumerateFileSystemEntries(
            $extPath, '*', [System.IO.SearchOption]::TopDirectoryOnly)
    }
    catch {
        $script:ErrCount++
        $script:Errors.Add("[enum] $DisplayPath :: $($_.Exception.Message)")
        return $node
    }

    foreach ($entry in $entries) {
        $leaf = [System.IO.Path]::GetFileName($entry)
        $childDisplay = $DisplayPath.TrimEnd('\') + '\' + $leaf

        $script:Count++
        if (($script:Count - $script:LastReport) -ge 500) {
            $script:LastReport = $script:Count
            Write-Progress -Activity 'A analisar...' `
                -Status "$($script:Count) itens | erros: $($script:ErrCount) | $childDisplay"
        }

        $isDir = $false
        try {
            $attr  = [System.IO.File]::GetAttributes($entry)
            $isDir = (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)
            # ignora reparse points (junctions/symlinks) para nao contar em duplicado / loops
            if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        }
        catch {
            $script:ErrCount++
            $script:Errors.Add("[attr] $childDisplay :: $($_.Exception.Message)")
            continue
        }

        if ($isDir) {
            if (Test-Excluded $leaf) { continue }
            $child = Get-FolderNode -DisplayPath $childDisplay
            $node.Children.Add($child)
            $node.Size      += $child.Size
            $node.FileCount += $child.FileCount
            $node.DirCount  += ($child.DirCount + 1)
            foreach ($k in $child.Ext.Keys) {
                if ($node.Ext.ContainsKey($k)) { $node.Ext[$k] += $child.Ext[$k] }
                else { $node.Ext[$k] = $child.Ext[$k] }
            }
        }
        else {
            $len = [int64]0
            try { $len = ([System.IO.FileInfo] $entry).Length }
            catch {
                $script:ErrCount++
                $script:Errors.Add("[size] $childDisplay :: $($_.Exception.Message)")
            }
            $node.Size += $len
            $node.FileCount++

            $ext = [System.IO.Path]::GetExtension($leaf)
            if ([string]::IsNullOrEmpty($ext)) { $ext = '(sem ext)' } else { $ext = $ext.ToLowerInvariant() }
            if ($node.Ext.ContainsKey($ext)) { $node.Ext[$ext] += $len } else { $node.Ext[$ext] = $len }

            if ($childDisplay.Length -gt 260) {
                $script:LongPaths.Add([pscustomobject]@{
                    Length = $childDisplay.Length; Size = $len; Path = $childDisplay })
            }
        }
    }
    return $node
}

# ----------------------------------------------------------------------------
# Impressao
# ----------------------------------------------------------------------------
function Show-Ext {
    param($node, [int]$pad = 0)
    if (-not $ShowExtensions -or $node.Ext.Count -eq 0) { return }
    $prefix = (' ' * $pad)
    $tops = $node.Ext.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    $parts = foreach ($e in $tops) { "$($e.Key) $(Format-Size $e.Value)" }
    Write-Host ("$prefix    tipos: " + ($parts -join '  |  ')) -ForegroundColor DarkGray
}

function Show-Children {
    param($node, [int]$top, [int]$indent = 0, [switch]$Numbered)

    $pad = ' ' * ($indent * 2)
    $sorted = $node.Children | Sort-Object Size -Descending
    $shown  = $sorted | Select-Object -First $top
    $i = 0
    foreach ($c in $shown) {
        $i++
        $pct = 0.0
        if ($node.Size -gt 0) { $pct = ($c.Size / $node.Size) * 100 }
        $bar = ('#' * [int][math]::Round($pct / 5)).PadRight(20)
        $tag = if ($Numbered) { ('[{0,2}] ' -f $i) } else { '' }
        Write-Host ('{0}{1}{2,10}  {3,6:N1}%  |{4}|  {5}  ({6} fich.)' -f `
            $pad, $tag, (Format-Size $c.Size), $pct, $bar, $c.Name, $c.FileCount)
        Show-Ext -node $c -pad ($indent * 2)
    }
    $rest = $sorted.Count - $shown.Count
    if ($rest -gt 0) {
        $restSize = ($sorted | Select-Object -Skip $top | Measure-Object Size -Sum).Sum
        Write-Host ('{0}     ... + {1} outras pastas ({2})' -f $pad, $rest, (Format-Size $restSize)) -ForegroundColor DarkGray
    }
    return $shown
}

# Modo relatorio: imprime ate -Depth niveis (so as maiores de cada nivel)
function Show-Report {
    param($node, [int]$top, [int]$depth, [int]$indent = 0)
    $shown = Show-Children -node $node -top $top -indent $indent
    if ($depth -gt 1) {
        foreach ($c in $shown) {
            if ($c.Children.Count -gt 0) {
                Show-Report -node $c -top $top -depth ($depth - 1) -indent ($indent + 1)
            }
        }
    }
}

# Modo interativo: afundas numa pasta so quando escolheres
function Start-Interactive {
    param($root, [int]$top)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $current = $root
    while ($true) {
        Write-Host ''
        Write-Host ('=== ' + $current.Path + ' ===') -ForegroundColor Cyan
        Write-Host ('Total: {0}  |  {1} ficheiros  |  {2} subpastas' -f `
            (Format-Size $current.Size), $current.FileCount, $current.DirCount) -ForegroundColor Yellow
        if ($current.Children.Count -eq 0) {
            Write-Host '(sem subpastas)' -ForegroundColor DarkGray
        } else {
            $shown = Show-Children -node $current -top $top -Numbered
        }
        Write-Host ''
        Write-Host 'Comandos: [n] afundar na pasta n | [u] subir | [e] ligar/desligar tipos | [q] sair' -ForegroundColor DarkGray
        $ans = (Read-Host 'Escolha').Trim().ToLower()

        if     ($ans -eq 'q') { break }
        elseif ($ans -eq 'u') {
            if ($stack.Count -gt 0) { $current = $stack.Pop() } else { Write-Host 'Ja estas no topo.' -ForegroundColor DarkGray }
        }
        elseif ($ans -eq 'e') {
            $script:ShowExtensions = -not $script:ShowExtensions
            Set-Variable -Name ShowExtensions -Value $script:ShowExtensions -Scope 1 -ErrorAction SilentlyContinue
        }
        elseif ($ans -match '^\d+$') {
            $idx = [int]$ans
            $sorted = $current.Children | Sort-Object Size -Descending | Select-Object -First $top
            if ($idx -ge 1 -and $idx -le $sorted.Count) {
                $stack.Push($current)
                $current = $sorted[$idx - 1]
            } else { Write-Host 'Numero fora do intervalo.' -ForegroundColor Red }
        }
        else { Write-Host 'Comando invalido.' -ForegroundColor Red }
    }
}

# ----------------------------------------------------------------------------
# Execucao
# ----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) {
    # Test-Path pode falhar em long paths; tenta enumerar a raiz na mesma
    try { [System.IO.Directory]::EnumerateFileSystemEntries((ConvertTo-ExtendedPath $Path)) | Out-Null }
    catch { Write-Error "Nao consigo aceder a '$Path'. Verifica a localizacao/permissoes."; exit 1 }
}

Write-Host "A analisar '$Path' ... (isto pode demorar em shares grandes)" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$root = Get-FolderNode -DisplayPath $Path
$sw.Stop()
Write-Progress -Activity 'A analisar...' -Completed

# Resumo
Write-Host ''
Write-Host '================= RESUMO =================' -ForegroundColor Green
Write-Host ("Caminho        : $($root.Path)")
Write-Host ("Tamanho total  : $(Format-Size $root.Size)")
Write-Host ("Ficheiros      : $($root.FileCount)")
Write-Host ("Subpastas      : $($root.DirCount)")
Write-Host ("Long paths >260: $($script:LongPaths.Count)")
Write-Host ("Erros/negados  : $($script:ErrCount)")
Write-Host ("Tempo          : $([math]::Round($sw.Elapsed.TotalSeconds,1))s")
Write-Host '=========================================' -ForegroundColor Green

# Export CSV opcional (uma linha por pasta, achatando a arvore)
if ($CsvOut) {
    $rows = New-Object System.Collections.Generic.List[object]
    function Flatten($n) {
        $rows.Add([pscustomobject]@{
            Path = $n.Path; SizeBytes = $n.Size; Size = (Format-Size $n.Size)
            Files = $n.FileCount; SubDirs = $n.DirCount })
        foreach ($c in $n.Children) { Flatten $c }
    }
    Flatten $root
    $rows | Sort-Object SizeBytes -Descending | Export-Csv -LiteralPath $CsvOut -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exportado: $CsvOut" -ForegroundColor Green
}

# Long paths (mostra os primeiros)
if ($script:LongPaths.Count -gt 0) {
    Write-Host ''
    Write-Host "--- Ficheiros com caminho > 260 caracteres (top 20 por tamanho) ---" -ForegroundColor Magenta
    $script:LongPaths | Sort-Object Size -Descending | Select-Object -First 20 |
        ForEach-Object { Write-Host ('  {0,10}  len={1}  {2}' -f (Format-Size $_.Size), $_.Length, $_.Path) }
    Write-Host "  (usa -CsvOut para exportar a arvore completa)" -ForegroundColor DarkGray
}

# Visualizacao granular
Write-Host ''
if ($Interactive -or $Depth -le 0) {
    Start-Interactive -root $root -top $Top
} else {
    Write-Host "--- Top $Top pastas ($Depth nivel(is)) ---" -ForegroundColor Cyan
    Show-Report -node $root -top $Top -depth $Depth
    Write-Host ''
    Write-Host 'Dica: corre com -Interactive para afundares camada a camada so onde quiseres.' -ForegroundColor DarkGray
}

# Erros detalhados (opcional, no fim)
if ($script:ErrCount -gt 0) {
    Write-Host ''
    Write-Host "Nota: $($script:ErrCount) itens nao puderam ser lidos (permissoes/etc). Primeiros 10:" -ForegroundColor DarkYellow
    $script:Errors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}
