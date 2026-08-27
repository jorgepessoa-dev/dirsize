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
    Ativa a navegacao interativa na consola. Se nem -Gui, nem -Interactive, nem
    -Depth forem especificados, o modo interativo de consola e usado por omissao.

.PARAMETER Gui
    Abre uma JANELA GRAFICA (WinForms) para navegar a arvore por duplo-clique,
    estilo TreeSize. A navegacao e instantanea (usa a arvore ja em memoria).
    Nao precisa de admin; funciona em consola local ou RDP (nao em SSH puro).

.PARAMETER ShowExtensions
    Mostra o breakdown por extensao (top tipos de ficheiro) em cada pasta.

.PARAMETER Exclude
    Nomes de pasta a ignorar durante o scan (wildcards). Ex: -Exclude 'node_modules','.git'

.PARAMETER CsvOut
    Caminho para exportar a arvore completa (uma linha por pasta) em CSV.

.EXAMPLE
    .\Analyze-FolderSizes.ps1 -Path '\\servidor\share\Projetos'
    # scan + navegacao interativa na consola

.EXAMPLE
    .\Analyze-FolderSizes.ps1 -Path '\\servidor\share\Projetos' -Gui
    # scan + JANELA GRAFICA: duplo-clique para entrar nas pastas (estilo TreeSize)

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
    [switch] $Gui,
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

# Mapa extensao -> categoria legivel (sem semantica: so classificacao por tipo).
$script:CategoryMap = @{}
$defs = @{
    'Video'          = '.mp4 .mov .avi .mkv .wmv .flv .m4v .mpg .mpeg .webm .vob .m2ts'
    'Imagem'         = '.jpg .jpeg .png .gif .bmp .tif .tiff .heic .webp .raw .cr2 .nef .arw .dng .psd .ai .svg'
    'Documento'      = '.doc .docx .odt .rtf .txt .pdf .md .pages .wpd'
    'Folha calculo'  = '.xls .xlsx .xlsm .xlsb .csv .ods'
    'Apresentacao'   = '.ppt .pptx .odp .key'
    'Email'          = '.pst .ost .msg .eml .mbox .nsf'
    'Comprimido/Bkp' = '.zip .rar .7z .tar .gz .bz2 .xz .bak .bkf .vhd .vhdx .iso .cab .arc'
    'Audio'          = '.mp3 .wav .flac .aac .wma .ogg .m4a .aiff'
    'CAD/Eng'        = '.dwg .dxf .step .stp .iges .igs .stl .sldprt .sldasm .ipt .iam .rvt .catpart .prt'
    'Base de dados'  = '.mdb .accdb .db .sqlite .mdf .ldf .dbf .frm .myd'
    'Codigo/Dev'     = '.cs .js .ts .py .java .cpp .c .h .php .rb .go .rs .ps1 .sh .html .css .json .xml .yml .yaml .sql'
    'Instalador/Bin' = '.exe .msi .msu .msp .appx .dll .sys .bin'
    'Fonte'          = '.ttf .otf .woff .woff2 .fon'
}
foreach ($cat in $defs.Keys) {
    foreach ($e in ($defs[$cat] -split '\s+')) { if ($e) { $script:CategoryMap[$e] = $cat } }
}

function Get-Category {
    param([string] $ext)
    if ($null -eq $ext -or $ext -eq '(sem ext)') { return 'Sem extensao' }
    $c = $script:CategoryMap[$ext.ToLowerInvariant()]
    if ($c) { return $c }
    return 'Outro'
}

# Agrega o hashtable Ext (ext->bytes) de um no em categorias (categoria->bytes),
# devolvendo pares ordenados por tamanho desc.
function Get-CategoryBreakdown {
    param($node)
    $cats = @{}
    foreach ($k in $node.Ext.Keys) {
        $cat = Get-Category $k
        if ($cats.ContainsKey($cat)) { $cats[$cat] += $node.Ext[$k] } else { $cats[$cat] = $node.Ext[$k] }
    }
    return ($cats.GetEnumerator() | Sort-Object Value -Descending)
}

# Texto curto com as top categorias de um no (ex.: "Video 4.20 GB | Imagem 900 MB").
function Get-CategoryText {
    param($node, [int] $top = 3)
    $bd = Get-CategoryBreakdown $node | Select-Object -First $top
    $parts = foreach ($e in $bd) { "$($e.Key) $(Format-Size $e.Value)" }
    return ($parts -join '  |  ')
}

# Regra de Pareto: quantas das maiores criancas somam >= $fraction do total,
# e que fatia essas representam. Devolve [pscustomobject]{ Count; Share }.
function Get-ParetoInfo {
    param($node, [double] $fraction = 0.8)
    $total = $node.Size
    if ($total -le 0) { return [pscustomobject]@{ Count = 0; Share = 0.0 } }
    $sorted = $node.Children | Sort-Object Size -Descending
    $acc = [int64]0; $n = 0
    foreach ($c in $sorted) {
        $acc += $c.Size; $n++
        if ($acc / $total -ge $fraction) { break }
    }
    return [pscustomobject]@{ Count = $n; Share = [math]::Round(($acc / $total) * 100, 1) }
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
    Write-Host ("$prefix    tipos: " + (Get-CategoryText -node $node -top 4)) -ForegroundColor DarkGray
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
    if ($sorted.Count -gt 1) {
        $p = Get-ParetoInfo -node $node -fraction 0.8
        Write-Host ('{0}     >> Pareto: as {1} maiores pastas = {2}% do espaco (foca aqui)' -f `
            $pad, $p.Count, $p.Share) -ForegroundColor Yellow
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

# Achata a arvore e exporta para CSV (uma linha por pasta, maiores primeiro).
# Iterativo (sem recursao) para aguentar arvores muito profundas.
function Export-TreeCsv {
    param($node, [string] $CsvPath)
    $rows  = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($node)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        $rows.Add([pscustomobject]@{
            Path = $n.Path; SizeBytes = $n.Size; Size = (Format-Size $n.Size)
            Files = $n.FileCount; SubDirs = $n.DirCount })
        foreach ($c in $n.Children) { $stack.Push($c) }
    }
    $rows | Sort-Object SizeBytes -Descending |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
}

# Reconstroi a grelha a partir do no atual (instantaneo: a arvore ja esta em
# memoria). Funcao de TOPO + estado em $script: -> chamavel dos event handlers
# do WinForms sem os problemas de scope das funcoes aninhadas.
function Update-GuiGrid {
    $node = $script:GuiCurrent
    $script:GuiNodes = @($node.Children | Sort-Object Size -Descending)

    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('Nome', [string])
    [void]$dt.Columns.Add('Tamanho', [string])
    [void]$dt.Columns.Add('%', [double])
    [void]$dt.Columns.Add('Ficheiros', [int])
    [void]$dt.Columns.Add('Subpastas', [int])
    [void]$dt.Columns.Add('Conteudo', [string])
    [void]$dt.Columns.Add('Idx', [int])

    $i = 0
    foreach ($c in $script:GuiNodes) {
        $pct = 0.0
        if ($node.Size -gt 0) { $pct = [math]::Round(($c.Size / $node.Size) * 100, 1) }
        $conteudo = ''
        if ($c.Ext.Count -gt 0) { $conteudo = Get-CategoryText -node $c -top 3 }
        [void]$dt.Rows.Add($c.Name, (Format-Size $c.Size), $pct, $c.FileCount, $c.DirCount, $conteudo, $i)
        $i++
    }

    $script:GuiGrid.DataSource = $dt
    if ($script:GuiGrid.Columns['Idx'])      { $script:GuiGrid.Columns['Idx'].Visible = $false }
    if ($script:GuiGrid.Columns['Nome'])     { $script:GuiGrid.Columns['Nome'].FillWeight = 220 }
    if ($script:GuiGrid.Columns['Conteudo']) { $script:GuiGrid.Columns['Conteudo'].FillWeight = 260 }

    $p = Get-ParetoInfo -node $node -fraction 0.8
    $pareto = ''
    if ($node.Children.Count -gt 1) { $pareto = ('   —   Pareto: {0} maiores = {1}% do espaco' -f $p.Count, $p.Share) }
    $script:GuiLbl.Text = ('{0}    —    Total: {1}  |  {2} fich.  |  {3} subpastas{4}' -f `
        $node.Path, (Format-Size $node.Size), $node.FileCount, $node.DirCount, $pareto)
    $script:GuiBtnUp.Enabled = ($script:GuiStack.Count -gt 0)
}

# Entra no no correspondente a uma linha da grelha (via coluna Idx -> robusto a ordenacao).
function Enter-GuiRow {
    param([int] $rowIndex)
    if ($rowIndex -lt 0) { return }
    $idx = [int]$script:GuiGrid.Rows[$rowIndex].Cells['Idx'].Value
    $target = $script:GuiNodes[$idx]
    if ($target.Children.Count -gt 0) {
        $script:GuiStack.Push($script:GuiCurrent)
        $script:GuiCurrent = $target
        Update-GuiGrid
    }
}

# ----------------------------------------------------------------------------
# Janela grafica (WinForms) sobre a arvore JA em memoria -> navegacao instantanea.
# Nao precisa de admin. Funciona em PowerShell 5.1 e 7+ num ambiente com desktop
# (consola local ou sessao RDP). Nao funciona em SSH puro sem interface grafica.
# ----------------------------------------------------------------------------
function Show-Gui {
    param($root)

    # Toda a construcao da janela protegida: numa maquina sem subsistema grafico
    # (ex.: Server Core) qualquer passo pode falhar -> cai para o modo consola.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $script:GuiCurrent = $root
        $script:GuiStack   = New-Object System.Collections.Generic.Stack[object]
        $script:GuiNodes   = @()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Folder Size Analyzer'
        $form.Size = New-Object System.Drawing.Size(1120, 700)
        $form.StartPosition = 'CenterScreen'

        $script:GuiLbl = New-Object System.Windows.Forms.Label
        $script:GuiLbl.Location = New-Object System.Drawing.Point(12, 12)
        $script:GuiLbl.Size = New-Object System.Drawing.Size(1080, 40)
        $script:GuiLbl.Anchor = 'Top,Left,Right'
        $script:GuiLbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

        $script:GuiGrid = New-Object System.Windows.Forms.DataGridView
        $script:GuiGrid.Location = New-Object System.Drawing.Point(12, 58)
        $script:GuiGrid.Size = New-Object System.Drawing.Size(1080, 552)
        $script:GuiGrid.Anchor = 'Top,Bottom,Left,Right'
        $script:GuiGrid.ReadOnly = $true
        $script:GuiGrid.AllowUserToAddRows = $false
        $script:GuiGrid.AllowUserToDeleteRows = $false
        $script:GuiGrid.RowHeadersVisible = $false
        $script:GuiGrid.MultiSelect = $false
        $script:GuiGrid.SelectionMode = 'FullRowSelect'
        $script:GuiGrid.AutoSizeColumnsMode = 'Fill'

        $script:GuiBtnUp = New-Object System.Windows.Forms.Button
        $script:GuiBtnUp.Text = 'Subir'
        $script:GuiBtnUp.Size = New-Object System.Drawing.Size(110, 30)
        $script:GuiBtnUp.Location = New-Object System.Drawing.Point(12, 622)
        $script:GuiBtnUp.Anchor = 'Bottom,Left'

        $btnCsv = New-Object System.Windows.Forms.Button
        $btnCsv.Text = 'Exportar CSV'
        $btnCsv.Size = New-Object System.Drawing.Size(130, 30)
        $btnCsv.Location = New-Object System.Drawing.Point(130, 622)
        $btnCsv.Anchor = 'Bottom,Left'

        $btnExit = New-Object System.Windows.Forms.Button
        $btnExit.Text = 'Sair'
        $btnExit.Size = New-Object System.Drawing.Size(90, 30)
        $btnExit.Location = New-Object System.Drawing.Point(268, 622)
        $btnExit.Anchor = 'Bottom,Left'

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = 'Duplo-clique (ou Enter) numa pasta para entrar. Abre ordenada por tamanho.'
        $hint.AutoSize = $true
        $hint.ForeColor = [System.Drawing.Color]::Gray
        $hint.Location = New-Object System.Drawing.Point(380, 629)
        $hint.Anchor = 'Bottom,Left'

        $form.Controls.AddRange(@($script:GuiLbl, $script:GuiGrid, $script:GuiBtnUp, $btnCsv, $btnExit, $hint))

        $script:GuiGrid.Add_CellDoubleClick({ param($s, $e) Enter-GuiRow $e.RowIndex })
        $script:GuiGrid.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $script:GuiGrid.CurrentRow) {
                Enter-GuiRow $script:GuiGrid.CurrentRow.Index
                $e.Handled = $true
            }
        })
        $script:GuiBtnUp.Add_Click({
            if ($script:GuiStack.Count -gt 0) {
                $script:GuiCurrent = $script:GuiStack.Pop()
                Update-GuiGrid
            }
        })
        $btnCsv.Add_Click({
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = 'CSV (*.csv)|*.csv'
            $sfd.FileName = 'FolderSizes.csv'
            if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Export-TreeCsv -node $script:GuiCurrent -CsvPath $sfd.FileName
                [System.Windows.Forms.MessageBox]::Show("Exportado para:`n$($sfd.FileName)", 'CSV') | Out-Null
            }
        })
        $btnExit.Add_Click({ $form.Close() })

        Update-GuiGrid
        [void]$form.ShowDialog()
    }
    catch {
        Write-Warning "Interface grafica indisponivel ($($_.Exception.Message)). A usar o modo consola."
        Start-Interactive -root $root -top $Top
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
if ($root.Ext.Count -gt 0) {
    Write-Host ("Conteudo       : " + (Get-CategoryText -node $root -top 6))
}
Write-Host '=========================================' -ForegroundColor Green

# Export CSV opcional (uma linha por pasta, achatando a arvore)
if ($CsvOut) {
    Export-TreeCsv -node $root -CsvPath $CsvOut
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
if ($Gui) {
    Show-Gui -root $root
} elseif ($Interactive -or $Depth -le 0) {
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
