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
    Se for OMITIDO, abre uma janela para escolher a pasta (colar \\servidor\share
    ou navegar com "Procurar..."), e os resultados aparecem tambem em janela.

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

.PARAMETER HtmlOut
    Caminho para exportar um relatorio HTML autonomo (resumo + Pareto + top pastas
    + categorias + pastas sem acesso). Ideal para enviar a alguem.

.PARAMETER SnapshotOut
    Caminho para gravar um snapshot JSON (lista plana de pastas + tamanhos).
    Base para comparar com scans futuros (-CompareWith).

.PARAMETER CompareWith
    Caminho de um snapshot JSON anterior. Mostra o que cresceu/encolheu desde
    entao (top variacoes, pastas novas e removidas). Entra tambem no HTML.

.PARAMETER FlatTop
    Numero de pastas a listar na vista "Top de TODA a arvore" (lista plana, nao
    por nivel). 0 (default) = nao mostra na consola. A janela grafica tem sempre
    o botao "Top global".

.PARAMETER NoProgressGui
    Nao mostra a janela de progresso durante o scan (usa so a barra da consola).

.PARAMETER Version
    Mostra a versao e sai.

.EXAMPLE
    .\dirsize.ps1
    # sem argumentos: janela para ESCOLHER a pasta (com historico) e resultados em janela

.EXAMPLE
    .\dirsize.ps1 -Path '\\servidor\share' -Gui
    # scan (com janela de progresso + Cancelar) + JANELA GRAFICA para navegar

.EXAMPLE
    .\dirsize.ps1 -Path '\\servidor\share' -Depth 2 -Top 20 -FlatTop 50
    # relatorio de 2 niveis + as 50 maiores pastas de toda a arvore

.EXAMPLE
    .\dirsize.ps1 -Path '\\servidor\share' -HtmlOut rel.html -SnapshotOut hoje.json
    # relatorio HTML + snapshot para comparar no futuro

.EXAMPLE
    .\dirsize.ps1 -Path '\\servidor\share' -CompareWith mes-passado.json -HtmlOut evolucao.html
    # o que mudou desde o snapshot anterior
#>
[CmdletBinding()]
param(
    [string]   $Path,
    [int]      $Top = 15,
    [int]      $Depth = 0,
    [switch]   $Interactive,
    [switch]   $Gui,
    [switch]   $ShowExtensions,
    [string[]] $Exclude = @(),
    [string]   $CsvOut,
    [string]   $HtmlOut,
    [string]   $SnapshotOut,
    [string]   $CompareWith,
    [int]      $FlatTop = 0,
    [switch]   $NoProgressGui,
    [switch]   $Version
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '2.1'

if ($Version) { Write-Host "dirsize v$($script:AppVersion)"; exit 0 }

#region Definicoes da aplicacao (%APPDATA%)
# ----------------------------------------------------------------------------
# Definicoes / estado da app (historico de caminhos, tamanho da janela),
# guardados em %APPDATA%\dirsize. Tudo tolera falha (devolve default).
# Alvo: Windows PowerShell 5.1 (o que vem no Windows 11). Nao requer PS 7.
# ----------------------------------------------------------------------------
function Get-AppDataDir {
    try {
        $d = Join-Path $env:APPDATA 'dirsize'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        return $d
    } catch { return $null }
}

function Get-RecentPaths {
    try {
        $d = Get-AppDataDir; if (-not $d) { return @() }
        $f = Join-Path $d 'recent.txt'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() })
    } catch { return @() }
}

function Add-RecentPath {
    param([string] $p)
    try {
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $d = Get-AppDataDir; if (-not $d) { return }
        $f = Join-Path $d 'recent.txt'
        $list = @(Get-RecentPaths | Where-Object { $_ -ne $p -and $_.ToLower() -ne $p.ToLower() })
        $list = @($p) + $list | Select-Object -First 8
        Set-Content -LiteralPath $f -Value $list -Encoding UTF8
    } catch { }
}

function Get-AppSettings {
    try {
        $d = Get-AppDataDir; if (-not $d) { return $null }
        $f = Join-Path $d 'settings.json'
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Save-AppSettings {
    param($form)
    try {
        $d = Get-AppDataDir; if (-not $d) { return }
        $f = Join-Path $d 'settings.json'
        $cur = Get-AppSettings
        $obj = [ordered]@{}
        if ($cur) { foreach ($pp in $cur.PSObject.Properties) { $obj[$pp.Name] = $pp.Value } }
        if ($form.WindowState -eq 'Normal') {
            $obj['winW'] = [int]$form.Size.Width
            $obj['winH'] = [int]$form.Size.Height
            $obj['winX'] = [int]$form.Location.X
            $obj['winY'] = [int]$form.Location.Y
        }
        ($obj | ConvertTo-Json) | Set-Content -LiteralPath $f -Encoding UTF8
    } catch { }
}

# ----------------------------------------------------------------------------
#endregion

#region Helpers - caminhos, formatacao, categorias
# Helpers
# ----------------------------------------------------------------------------

# Converte um caminho normal no formato estendido \\?\  (ignora MAX_PATH).
function ConvertTo-ExtendedPath {
    param([string] $p)
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\'))   { return '\\?\UNC\' + $p.Substring(2) }  # rede
    return '\\?\' + $p                                                  # local
}

# ----------------------------------------------------------------------------
# Deteccao do TIPO de reparse point (tag), via FindFirstFileW.
# Precisamos de distinguir:
#   - junctions / symlinks  -> IGNORAR (causam loops e dupla contagem)
#   - placeholders da cloud -> PERCORRER como ficheiros/pastas normais
#     (OneDrive/Dropbox/etc. marcam TODAS as entradas como reparse points; se
#      as ignorassemos, o scan de uma pasta sincronizada daria sempre 0).
# Funciona em Windows PowerShell 5.1 e PowerShell 7+.
# ----------------------------------------------------------------------------
if (-not ('FsReparse.Native' -as [type])) {
    Add-Type -Namespace FsReparse -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public struct WIN32_FIND_DATA {
    public uint dwFileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
    public uint nFileSizeHigh;
    public uint nFileSizeLow;
    public uint dwReserved0;
    public uint dwReserved1;
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 260)]
    public string cFileName;
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 14)]
    public string cAlternateFileName;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATA lpFindFileData);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FindClose(System.IntPtr hFindFile);
'@
}

$script:TagMountPoint = [uint32] 2684354563   # 0xA0000003  IO_REPARSE_TAG_MOUNT_POINT (junction)
$script:TagSymlink    = [uint32] 2684354572   # 0xA000000C  IO_REPARSE_TAG_SYMLINK

# $ExtendedPath deve ja vir no formato \\?\ . Devolve $true so para junctions/symlinks.
function Test-IsJunctionOrSymlink {
    param([string] $ExtendedPath)
    try {
        $data = New-Object 'FsReparse.Native+WIN32_FIND_DATA'
        $h = [FsReparse.Native]::FindFirstFileW($ExtendedPath, [ref] $data)
        if ($h -eq [System.IntPtr]::Zero -or $h -eq [System.IntPtr] (-1)) { return $false }
        [void][FsReparse.Native]::FindClose($h)
        return ($data.dwReserved0 -eq $script:TagMountPoint -or $data.dwReserved0 -eq $script:TagSymlink)
    }
    catch { return $false }
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

# Tamanho de um no, com marcador de LIMITE INFERIOR quando a subarvore nao foi
# lida por completo (Complete = $false). Estilo por destino, porque cada um tem
# a sua convencao: consola '>=', GUI '>= ' (sinal Unicode), HTML '&ge; '.
function Format-SizeQualified {
    param($node, [ValidateSet('Console','Gui','Html')] [string] $Style = 'Console')
    $sz = Format-Size $node.Size
    if ($node.Complete) { return $sz }
    switch ($Style) {
        'Gui'  { return ([char]0x2265 + ' ' + $sz) }
        'Html' { return ('&ge; ' + $sz) }
        default { return ('>=' + $sz) }
    }
}

function Test-Excluded {
    param([string] $name)
    foreach ($pat in $Exclude) { if ($name -like $pat) { return $true } }
    return $false
}

function Format-Date {
    param($d)
    if ($null -eq $d -or $d -eq [datetime]::MinValue) { return '-' }
    try { return ([datetime]$d).ToLocalTime().ToString('yyyy-MM-dd') } catch { return '-' }
}

function ConvertTo-HtmlText {
    param([string] $s)
    if ($null -eq $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
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

#endregion

#region Estado global
# Estado global do scan
$script:Scan = [pscustomobject]@{
    ErrCount        = 0
    Errors          = (New-Object System.Collections.Generic.List[string])
    DeniedDirs      = (New-Object System.Collections.Generic.List[string])  # pastas que nao se conseguiu enumerar
    DeniedItems     = (New-Object System.Collections.Generic.List[string])  # ficheiros/entradas sem acesso a metadados
    LongPaths       = (New-Object System.Collections.Generic.List[object])
    Count           = 0
    LastReport      = 0
    SkipReparse     = 0        # junctions/symlinks ignorados (nao inclui placeholders da cloud)
    CancelRequested = $false
    Partial         = $false
}

# Janela de progresso (WinForms). Separada do estado do scan porque e opcional:
# fica toda a $null quando se corre com -NoProgressGui ou sem subsistema grafico.
$script:Prog = [pscustomobject]@{
    Form     = $null
    LblPath  = $null
    LblStats = $null
    Sw       = $null
    Closing  = $false
}

# Estado da janela de navegacao. Vive em $script: (e nao em variaveis locais de
# Show-Gui) porque os event handlers do WinForms correm fora do scope da funcao.
# Root/Current/Stack/Nodes = navegacao; Flat/FlatN = vista "Top global";
# Grid/Lbl/BtnUp/FilterBox = controlos que os handlers precisam de alcancar.
$script:Ui = [pscustomobject]@{
    Root      = $null
    Current   = $null
    Stack     = $null
    Nodes     = @()
    Flat      = $false
    FlatN     = 50
    Grid      = $null
    Lbl       = $null
    BtnUp     = $null
    FilterBox = $null
}

# Regista um erro de scan. tag 'enum*' = ao nivel da pasta; 'attr'/'size' = entrada.
# So os erros de acesso vao para as listas Denied (cobertura); os restantes ficam
# apenas em $script:Scan.Errors (indisponibilidade transitoria, I/O, etc.).
function Add-ScanError {
    param([string] $tag, [string] $path, $err)
    $script:Scan.ErrCount++
    $script:Scan.Errors.Add("[$tag] $path :: $($err.Exception.Message)")
    $ex = $err.Exception
    $denied = ($ex -is [System.UnauthorizedAccessException] -or
               $ex.InnerException -is [System.UnauthorizedAccessException] -or
               $ex.Message -match 'negad|denied|Acesso|Access is denied')
    if (-not $denied) { return }
    if ($tag -like 'enum*') { $script:Scan.DeniedDirs.Add($path) }
    else                    { $script:Scan.DeniedItems.Add($path) }
}

# ----------------------------------------------------------------------------
#endregion

#region Scan
# Scan recursivo -> devolve um no com tamanho/contagens CUMULATIVOS
#   Node = { Path; Name; Size; FileCount; DirCount; Children[]; Ext{ext->size}; MaxMtime; Complete }
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
        MaxMtime  = [datetime]::MinValue
        # $true so se ESTA pasta e toda a subarvore foram lidas por completo.
        # $false -> Size/FileCount/... sao MINIMOS conhecidos, nao totais.
        Complete  = $true
    }
    if ([string]::IsNullOrEmpty($node.Name)) { $node.Name = $DisplayPath }

    if ($script:Scan.CancelRequested) { $node.Complete = $false; return $node }

    $extPath = ConvertTo-ExtendedPath $DisplayPath
    try {
        $enum = [System.IO.Directory]::EnumerateFileSystemEntries(
            $extPath, '*', [System.IO.SearchOption]::TopDirectoryOnly)
    }
    catch {
        # Falha imediata: pasta inacessivel / inexistente -> pasta nao medida.
        Add-ScanError 'enum-dir' $DisplayPath $_
        $node.Complete = $false
        return $node
    }

    # A enumeracao e lazy: uma falha (blip de rede, pasta apagada a meio) pode
    # surgir DENTRO do foreach, fora do try acima. Este try garante que so se
    # perde o resto DESTA pasta -- o scan global continua.
    try {
      foreach ($entry in $enum) {
        if ($script:Scan.CancelRequested) { break }

        $leaf = [System.IO.Path]::GetFileName($entry)
        $childDisplay = $DisplayPath.TrimEnd('\') + '\' + $leaf

        $script:Scan.Count++
        if (($script:Scan.Count - $script:Scan.LastReport) -ge 400) {
            $script:Scan.LastReport = $script:Scan.Count
            if ($script:Prog.Form) { Update-ProgressWindow $childDisplay }
            else {
                Write-Progress -Activity 'A analisar...' `
                    -Status "$($script:Scan.Count) itens | erros: $($script:Scan.ErrCount) | $childDisplay"
            }
        }

        $isDir = $false
        try {
            $attr  = [System.IO.File]::GetAttributes($entry)
            $isDir = (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)
            # Reparse points: so ignoramos junctions/symlinks REAIS (loops / dupla
            # contagem). Placeholders da cloud (OneDrive etc.) tambem sao reparse
            # points, mas tem de ser percorridos como ficheiros/pastas normais.
            if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (Test-IsJunctionOrSymlink $entry) { $script:Scan.SkipReparse++; continue }
            }
        }
        catch {
            Add-ScanError 'attr' $childDisplay $_
            $node.Complete = $false   # entrada vista mas nao classificada
            continue
        }

        if ($isDir) {
            if (Test-Excluded $leaf) { continue }
            $child = Get-FolderNode -DisplayPath $childDisplay
            $node.Children.Add($child)
            $node.Size      += $child.Size
            $node.FileCount += $child.FileCount
            $node.DirCount  += ($child.DirCount + 1)
            if (-not $child.Complete) { $node.Complete = $false }
            if ($child.MaxMtime -gt $node.MaxMtime) { $node.MaxMtime = $child.MaxMtime }
            foreach ($k in $child.Ext.Keys) {
                if ($node.Ext.ContainsKey($k)) { $node.Ext[$k] += $child.Ext[$k] }
                else { $node.Ext[$k] = $child.Ext[$k] }
            }
            if ($childDisplay.Length -gt 260) {
                $script:Scan.LongPaths.Add([pscustomobject]@{
                    Length = $childDisplay.Length; Size = $child.Size; Path = $childDisplay; Type = 'Pasta' })
            }
        }
        else {
            $len = [int64]0
            try {
                $fi  = [System.IO.FileInfo] $entry
                $len = $fi.Length
                $mt  = $fi.LastWriteTimeUtc
                if ($mt -gt $node.MaxMtime) { $node.MaxMtime = $mt }
            }
            catch {
                Add-ScanError 'size' $childDisplay $_
                $node.Complete = $false   # ficheiro contado mas tamanho desconhecido -> total e minimo
            }
            $node.Size += $len
            $node.FileCount++

            $ext = [System.IO.Path]::GetExtension($leaf)
            if ([string]::IsNullOrEmpty($ext)) { $ext = '(sem ext)' } else { $ext = $ext.ToLowerInvariant() }
            if ($node.Ext.ContainsKey($ext)) { $node.Ext[$ext] += $len } else { $node.Ext[$ext] = $len }

            if ($childDisplay.Length -gt 260) {
                $script:Scan.LongPaths.Add([pscustomobject]@{
                    Length = $childDisplay.Length; Size = $len; Path = $childDisplay; Type = 'Ficheiro' })
            }
        }
      }
    }
    catch {
        # Falha a meio da enumeracao desta pasta -> regista e segue em frente.
        # Nao sabemos quantas entradas ficaram por ler -> totais sao minimos.
        Add-ScanError 'enum-iter' $DisplayPath $_
        $node.Complete = $false
    }
    return $node
}

# Nº de pastas cujos totais sao MINIMOS (enumeracao incompleta algalgures na subarvore).
function Get-IncompleteCount {
    param($root)
    $c = 0
    $st = New-Object System.Collections.Generic.Stack[object]
    $st.Push($root)
    while ($st.Count -gt 0) {
        $x = $st.Pop()
        if (-not $x.Complete) { $c++ }
        foreach ($k in $x.Children) { $st.Push($k) }
    }
    return $c
}

# Lista plana de TODAS as pastas da arvore, maiores primeiro (iterativo).
function Get-FlatTop {
    param($root, [int] $n = 50, [switch] $IncludeRoot)
    $list  = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $x = $stack.Pop()
        if ($IncludeRoot -or -not [object]::ReferenceEquals($x, $root)) { $list.Add($x) }
        foreach ($c in $x.Children) { $stack.Push($c) }
    }
    return @($list | Sort-Object Size -Descending | Select-Object -First $n)
}

# ----------------------------------------------------------------------------
#endregion

#region Vistas de consola
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
        Write-Host ('{0}{1}{2,12}  {3,6:N1}%  |{4}|  {5}  ({6} fich., mod. {7})' -f `
            $pad, $tag, (Format-SizeQualified $c), $pct, $bar, $c.Name, $c.FileCount, (Format-Date $c.MaxMtime))
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

# Top de TODA a arvore (lista plana), independente da profundidade.
function Show-FlatTop {
    param($root, [int] $n = 50)
    $all = Get-FlatTop -root $root -n $n
    Write-Host ''
    Write-Host "--- Top $n pastas de TODA a arvore (por tamanho) ---" -ForegroundColor Cyan
    $rank = 0
    foreach ($x in $all) {
        $rank++
        $pct = 0.0
        if ($root.Size -gt 0) { $pct = ($x.Size / $root.Size) * 100 }
        $cat = ''
        if ($x.Ext.Count -gt 0) { $cat = (Get-CategoryText -node $x -top 1) }
        Write-Host ('{0,3}. {1,12}  {2,5:N1}%  fich+rec.{3}  {4,-16}  {5}' -f `
            $rank, (Format-SizeQualified $x), $pct, (Format-Date $x.MaxMtime), $cat, $x.Path)
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
        Write-Host ('Total: {0}  |  {1} ficheiros  |  {2} subpastas  |  mod. {3}' -f `
            (Format-Size $current.Size), $current.FileCount, $current.DirCount, (Format-Date $current.MaxMtime)) -ForegroundColor Yellow
        if ($current.Children.Count -eq 0) {
            Write-Host '(sem subpastas)' -ForegroundColor DarkGray
        } else {
            $shown = Show-Children -node $current -top $top -Numbered
        }
        Write-Host ''
        Write-Host 'Comandos: [n] afundar | [u] subir | [e] tipos on/off | [t] top global | [q] sair' -ForegroundColor DarkGray
        $ans = (Read-Host 'Escolha').Trim().ToLower()

        if     ($ans -eq 'q') { break }
        elseif ($ans -eq 'u') {
            if ($stack.Count -gt 0) { $current = $stack.Pop() } else { Write-Host 'Ja estas no topo.' -ForegroundColor DarkGray }
        }
        elseif ($ans -eq 'e') {
            $script:ShowExtensions = -not $script:ShowExtensions
            Set-Variable -Name ShowExtensions -Value $script:ShowExtensions -Scope 1 -ErrorAction SilentlyContinue
        }
        elseif ($ans -eq 't') {
            $n = if ($FlatTop -gt 0) { $FlatTop } else { 50 }
            Show-FlatTop -root $root -n $n
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

#endregion

#region Exportadores (CSV / JSON / HTML / comparacao)
# Achata a arvore numa lista de pastas (iterativo, sem recursao).
# Depth = nivel relativo a raiz (raiz = 0). NewestFile* = data do ficheiro mais
# recente da subarvore (NAO e "a pasta foi mexida agora").
function Get-FlatFolderList {
    param($root)
    $rootPath = $root.Path.TrimEnd('\')
    $rows  = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        $cat = ''
        if ($n.Ext.Count -gt 0) { $cat = ((Get-CategoryBreakdown $n | Select-Object -First 1).Key) }
        $p = $n.Path.TrimEnd('\')
        $rel = if ($p.StartsWith($rootPath)) { $p.Substring($rootPath.Length) } else { $p }
        $depth = @($rel -split '[\\/]' | Where-Object { $_ }).Count
        $rows.Add([pscustomobject]@{
            Path = $n.Path; Name = $n.Name
            ParentPath = [System.IO.Path]::GetDirectoryName($p); Depth = $depth
            SizeBytes = [int64]$n.Size; Size = (Format-Size $n.Size)
            Files = $n.FileCount; SubDirs = $n.DirCount
            NewestFileLocal = (Format-Date $n.MaxMtime)
            NewestFileUtc = $(if ($n.MaxMtime -eq [datetime]::MinValue) { '' } else { ([datetime]$n.MaxMtime).ToString('o') })
            TopCategory = $cat
            # $false -> os numeros desta linha sao MINIMOS (SizeBytes = "pelo menos")
            Complete = [bool]$n.Complete
        })
        foreach ($c in $n.Children) { $stack.Push($c) }
    }
    return $rows
}

function Export-TreeCsv {
    param($node, [string] $CsvPath)
    Get-FlatFolderList -root $node |
        Sort-Object SizeBytes -Descending |
        Select-Object Path, Name, Depth, ParentPath, SizeBytes, Size, Files, SubDirs, NewestFileLocal, NewestFileUtc, TopCategory, Complete |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
}

function Export-Snapshot {
    param($root, [string] $SnapPath)
    $folders = Get-FlatFolderList -root $root | ForEach-Object {
        [pscustomobject]@{ p = $_.Path; b = $_.SizeBytes; f = $_.Files; d = $_.SubDirs; m = $_.NewestFileUtc; c = $_.Complete }
    }
    $snap = [pscustomobject]@{
        meta = [pscustomobject]@{
            path       = $root.Path
            dateUtc    = (Get-Date).ToUniversalTime().ToString('o')
            version    = $script:AppVersion
            totalBytes = [int64]$root.Size
            files      = $root.FileCount
            subDirs    = $root.DirCount
            partial    = [bool]$script:Scan.Partial
        }
        folders = @($folders)
    }
    ($snap | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $SnapPath -Encoding UTF8
}

function Format-Delta {
    param([int64] $b)
    $sign = if ($b -ge 0) { '+' } else { '-' }
    return "$sign$(Format-Size ([math]::Abs([int64]$b)))"
}

function Compare-Snapshot {
    param($root, [string] $PrevPath)
    if (-not (Test-Path -LiteralPath $PrevPath)) {
        Write-Warning "Snapshot para comparar nao encontrado: $PrevPath"; return $null
    }
    try {
        $prev = Get-Content -LiteralPath $PrevPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "Nao consegui ler o snapshot '$PrevPath': $($_.Exception.Message)"; return $null
    }

    $prevMap = @{}
    foreach ($x in $prev.folders) { $prevMap[[string]$x.p] = [int64]$x.b }
    $curMap = @{}
    foreach ($x in (Get-FlatFolderList -root $root)) { $curMap[[string]$x.Path] = [int64]$x.SizeBytes }

    $changed = New-Object System.Collections.Generic.List[object]
    $added   = New-Object System.Collections.Generic.List[object]
    foreach ($k in $curMap.Keys) {
        if ($prevMap.ContainsKey($k)) {
            $delta = $curMap[$k] - $prevMap[$k]
            if ($delta -ne 0) {
                $changed.Add([pscustomobject]@{ Path = $k; Prev = $prevMap[$k]; Cur = $curMap[$k]; Delta = $delta })
            }
        } else {
            $added.Add([pscustomobject]@{ Path = $k; Prev = [int64]0; Cur = $curMap[$k]; Delta = $curMap[$k] })
        }
    }
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($k in $prevMap.Keys) {
        if (-not $curMap.ContainsKey($k)) {
            $removed.Add([pscustomobject]@{ Path = $k; Prev = $prevMap[$k]; Cur = [int64]0; Delta = - $prevMap[$k] })
        }
    }

    return [pscustomobject]@{
        PrevPath   = $PrevPath
        PrevDate   = $prev.meta.dateUtc
        PrevTotal  = [int64]$prev.meta.totalBytes
        CurTotal   = [int64]$root.Size
        Growers    = @($changed | Where-Object { $_.Delta -gt 0 } | Sort-Object Delta -Descending | Select-Object -First 20)
        Shrinkers  = @($changed | Where-Object { $_.Delta -lt 0 } | Sort-Object Delta | Select-Object -First 20)
        NewFolders = @($added   | Sort-Object Delta -Descending | Select-Object -First 20)
        RemFolders = @($removed | Sort-Object Delta | Select-Object -First 20)
    }
}

function Show-Compare {
    param($cmp)
    if (-not $cmp) { return }
    Write-Host ''
    Write-Host '--- EVOLUCAO desde o snapshot anterior ---' -ForegroundColor Cyan
    Write-Host ("  Snapshot base : $($cmp.PrevPath)  ($($cmp.PrevDate))")
    Write-Host ("  Total antes   : $(Format-Size $cmp.PrevTotal)")
    Write-Host ("  Total agora   : $(Format-Size $cmp.CurTotal)")
    Write-Host ("  Variacao      : $(Format-Delta ($cmp.CurTotal - $cmp.PrevTotal))") -ForegroundColor Yellow
    if ($cmp.Growers.Count -gt 0) {
        Write-Host '  Cresceram mais:' -ForegroundColor Green
        foreach ($g in ($cmp.Growers | Select-Object -First 10)) { Write-Host ('    {0,12}  {1}' -f (Format-Delta $g.Delta), $g.Path) }
    }
    if ($cmp.Shrinkers.Count -gt 0) {
        Write-Host '  Encolheram mais:' -ForegroundColor DarkGreen
        foreach ($s in ($cmp.Shrinkers | Select-Object -First 10)) { Write-Host ('    {0,12}  {1}' -f (Format-Delta $s.Delta), $s.Path) }
    }
    if ($cmp.NewFolders.Count -gt 0) {
        Write-Host '  Pastas novas:' -ForegroundColor Green
        foreach ($n in ($cmp.NewFolders | Select-Object -First 10)) { Write-Host ('    {0,12}  {1}' -f (Format-Size $n.Cur), $n.Path) }
    }
    if ($cmp.RemFolders.Count -gt 0) {
        Write-Host '  Pastas removidas:' -ForegroundColor DarkGray
        foreach ($n in ($cmp.RemFolders | Select-Object -First 10)) { Write-Host ('    {0,12}  {1}' -f (Format-Size $n.Prev), $n.Path) }
    }
}

function Export-HtmlReport {
    param($root, [string] $HtmlPath, [double] $Elapsed, $cmp, [int] $topN = 25)

    $sb = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    $css = @'
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1c1c1c;background:#fafafa}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:24px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
 h3{font-size:13px;margin:14px 0 4px}
 .muted{color:#666;font-size:12px} .cards{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}
 .card{background:#fff;border:1px solid #e2e2e2;border-radius:8px;padding:10px 14px;min-width:120px}
 .card .v{font-size:18px;font-weight:600} .card .l{font-size:11px;color:#777;text-transform:uppercase;letter-spacing:.04em}
 table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;margin-bottom:8px}
 th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eee} th{background:#f0f0f0}
 td.num{text-align:right;white-space:nowrap} .bar{background:#e8e8e8;border-radius:3px;height:12px;overflow:hidden}
 .bar>span{display:block;height:12px;background:#4a7fb5} .pos{color:#1a7f37} .neg{color:#b53a3a}
 .path{font-family:Consolas,monospace;font-size:12px;word-break:break-all}
</style>
'@

    & $add '<!doctype html><html lang="pt"><head><meta charset="utf-8">'
    & $add ("<title>Espaco - " + (ConvertTo-HtmlText $root.Path) + "</title>")
    & $add $css
    & $add '</head><body>'
    & $add "<h1>Relatorio de ocupacao de espaco</h1>"
    & $add ("<div class='muted'>" + (ConvertTo-HtmlText $root.Path) + " &mdash; " +
            (Get-Date).ToString('yyyy-MM-dd HH:mm') + " &mdash; v$($script:AppVersion)" +
            $(if ($script:Scan.Partial) { " &mdash; <b>SCAN PARCIAL (cancelado)</b>" } else { "" }) + "</div>")

    & $add "<div class='cards'>"
    & $add ("<div class='card'><div class='v'>" + (Format-SizeQualified $root -Style Html) + "</div><div class='l'>Total</div></div>")
    & $add ("<div class='card'><div class='v'>" + ('{0:N0}' -f $root.FileCount) + "</div><div class='l'>Ficheiros</div></div>")
    & $add ("<div class='card'><div class='v'>" + ('{0:N0}' -f $root.DirCount) + "</div><div class='l'>Subpastas</div></div>")
    & $add ("<div class='card'><div class='v'>" + (@($script:Scan.DeniedDirs | Select-Object -Unique).Count) + "</div><div class='l'>Pastas s/ acesso</div></div>")
    & $add ("<div class='card'><div class='v'>" + ('{0:N1}s' -f $Elapsed) + "</div><div class='l'>Tempo</div></div>")
    & $add "</div>"

    $incompleteN = Get-IncompleteCount -root $root
    if ($incompleteN -gt 0) {
        & $add ("<p style='background:#fff4d6;border:1px solid #e6c34d;border-radius:6px;padding:8px 12px'>" +
                "<b>Cobertura parcial.</b> $incompleteN pasta(s) nao foram lidas por completo (sem acesso ou " +
                "falha de enumeracao). Nessas pastas &mdash; e em todas as suas ascendentes, incluindo o Total &mdash; " +
                "os valores sao <b>minimos</b> (&ge;), nao totais. Linhas afetadas marcadas com &ge;.</p>")
    }

    $p = Get-ParetoInfo -node $root -fraction 0.8
    if ($p.Count -gt 0) {
        & $add ("<p><b>Pareto:</b> as " + $p.Count + " maiores pastas de 1&ordm; nivel = " + $p.Share + "% do espaco.</p>")
    }

    & $add "<h2>Top $topN pastas (toda a arvore)</h2>"
    & $add "<table><tr><th>#</th><th>Pasta</th><th class='num'>Tamanho</th><th class='num'>%</th><th></th><th class='num'>Ficheiros</th><th>Modif.</th><th>Conteudo</th></tr>"
    $rank = 0
    foreach ($x in (Get-FlatTop -root $root -n $topN)) {
        $rank++
        $pct = 0.0
        if ($root.Size -gt 0) { $pct = [math]::Round(($x.Size / $root.Size) * 100, 1) }
        $cat = ''
        if ($x.Ext.Count -gt 0) { $cat = Get-CategoryText -node $x -top 2 }
        & $add ("<tr><td>$rank</td><td class='path'>" + (ConvertTo-HtmlText $x.Path) + "</td>" +
                "<td class='num'>" + (Format-SizeQualified $x -Style Html) + "</td><td class='num'>$pct%</td>" +
                "<td style='width:110px'><div class='bar'><span style='width:$([math]::Min(100,$pct))%'></span></div></td>" +
                "<td class='num'>" + ('{0:N0}' -f $x.FileCount) + "</td><td>" + (Format-Date $x.MaxMtime) + "</td>" +
                "<td>" + (ConvertTo-HtmlText $cat) + "</td></tr>")
    }
    & $add "</table>"

    & $add "<h2>Conteudo por categoria (raiz)</h2>"
    & $add "<table><tr><th>Categoria</th><th class='num'>Tamanho</th><th class='num'>%</th><th></th></tr>"
    foreach ($e in (Get-CategoryBreakdown $root)) {
        $pct = 0.0
        if ($root.Size -gt 0) { $pct = [math]::Round(($e.Value / $root.Size) * 100, 1) }
        & $add ("<tr><td>" + (ConvertTo-HtmlText $e.Key) + "</td><td class='num'>" + (Format-Size $e.Value) + "</td>" +
                "<td class='num'>$pct%</td><td style='width:200px'><div class='bar'><span style='width:$([math]::Min(100,$pct))%'></span></div></td></tr>")
    }
    & $add "</table>"

    if ($cmp) {
        & $add "<h2>Evolucao desde o snapshot anterior</h2>"
        & $add ("<p class='muted'>Base: " + (ConvertTo-HtmlText $cmp.PrevPath) + " (" + (ConvertTo-HtmlText ([string]$cmp.PrevDate)) + ")</p>")
        $dTot = $cmp.CurTotal - $cmp.PrevTotal
        $cls = if ($dTot -ge 0) { 'pos' } else { 'neg' }
        & $add ("<p>Total: " + (Format-Size $cmp.PrevTotal) + " &rarr; " + (Format-Size $cmp.CurTotal) +
                " (<span class='$cls'>" + (Format-Delta $dTot) + "</span>)</p>")
        foreach ($sec in @(
                @{ t = 'Cresceram mais'; rows = $cmp.Growers },
                @{ t = 'Encolheram mais'; rows = $cmp.Shrinkers },
                @{ t = 'Pastas novas'; rows = $cmp.NewFolders },
                @{ t = 'Pastas removidas'; rows = $cmp.RemFolders })) {
            if ($sec.rows.Count -eq 0) { continue }
            & $add ("<h3>" + $sec.t + "</h3>")
            & $add "<table><tr><th>Pasta</th><th class='num'>Antes</th><th class='num'>Agora</th><th class='num'>Variacao</th></tr>"
            foreach ($r in $sec.rows) {
                $c2 = if ($r.Delta -ge 0) { 'pos' } else { 'neg' }
                & $add ("<tr><td class='path'>" + (ConvertTo-HtmlText $r.Path) + "</td><td class='num'>" + (Format-Size $r.Prev) +
                        "</td><td class='num'>" + (Format-Size $r.Cur) + "</td><td class='num $c2'>" + (Format-Delta $r.Delta) + "</td></tr>")
            }
            & $add "</table>"
        }
    }

    $ddirs  = @($script:Scan.DeniedDirs  | Select-Object -Unique)
    $ditems = @($script:Scan.DeniedItems | Select-Object -Unique)
    if ($ddirs.Count -gt 0 -or $ditems.Count -gt 0) {
        & $add "<h2>Nao medido (sem acesso) &mdash; $($ddirs.Count) pasta(s), $($ditems.Count) item(ns)</h2>"
        & $add "<p class='muted'>O espaco destas pastas NAO entra nos totais. Pede acesso antes de decidir a reorganizacao.</p>"
        if ($ddirs.Count -gt 0) {
            & $add "<ul class='path'>"
            foreach ($d in ($ddirs | Select-Object -First 200)) { & $add ("<li>" + (ConvertTo-HtmlText $d) + "</li>") }
            & $add "</ul>"
        }
    }

    if ($script:Scan.LongPaths.Count -gt 0) {
        & $add "<h2>Caminhos &gt; 260 caracteres &mdash; $($script:Scan.LongPaths.Count)</h2>"
        & $add "<table><tr><th>Tipo</th><th class='num'>Tamanho</th><th class='num'>Chars</th><th>Caminho</th></tr>"
        foreach ($l in ($script:Scan.LongPaths | Sort-Object Size -Descending | Select-Object -First 50)) {
            & $add ("<tr><td>" + (ConvertTo-HtmlText ([string]$l.Type)) + "</td><td class='num'>" + (Format-Size $l.Size) +
                    "</td><td class='num'>" + $l.Length + "</td><td class='path'>" + (ConvertTo-HtmlText $l.Path) + "</td></tr>")
        }
        & $add "</table>"
    }

    & $add '</body></html>'
    [System.IO.File]::WriteAllText($HtmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------------------
#endregion

#region GUI - janela de progresso
# Janela de progresso durante o scan (modeless + DoEvents). Botao Cancelar.
# ----------------------------------------------------------------------------
function Show-ProgressWindow {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'A analisar...'
        $f.Size = New-Object System.Drawing.Size(480, 210)
        $f.StartPosition = 'CenterScreen'
        $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox = $false
        $f.MinimizeBox = $false

        $script:Prog.LblPath = New-Object System.Windows.Forms.Label
        $script:Prog.LblPath.Location = New-Object System.Drawing.Point(14, 14)
        $script:Prog.LblPath.Size = New-Object System.Drawing.Size(440, 60)
        $script:Prog.LblPath.Text = 'A iniciar...'

        $script:Prog.LblStats = New-Object System.Windows.Forms.Label
        $script:Prog.LblStats.Location = New-Object System.Drawing.Point(14, 78)
        $script:Prog.LblStats.Size = New-Object System.Drawing.Size(440, 20)
        $script:Prog.LblStats.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Location = New-Object System.Drawing.Point(14, 104)
        $bar.Size = New-Object System.Drawing.Size(440, 18)
        $bar.Style = 'Marquee'
        $bar.MarqueeAnimationSpeed = 40

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Cancelar'
        $btn.Size = New-Object System.Drawing.Size(100, 30)
        $btn.Location = New-Object System.Drawing.Point(354, 132)
        $btn.Add_Click({
            $script:Scan.CancelRequested = $true
            $btn.Enabled = $false
            $btn.Text = 'A cancelar...'
        })

        $f.Controls.AddRange(@($script:Prog.LblPath, $script:Prog.LblStats, $bar, $btn))
        $f.Add_FormClosing({ if (-not $script:Prog.Closing) { $script:Scan.CancelRequested = $true } })

        $script:Prog.Closing = $false
        $script:Prog.Form = $f
        $script:Prog.Sw = [System.Diagnostics.Stopwatch]::StartNew()
        $f.Show(); $f.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        return $true
    }
    catch {
        $script:Prog.Form = $null
        return $false
    }
}

function Update-ProgressWindow {
    param([string] $currentPath)
    if (-not $script:Prog.Form) { return }
    try {
        $disp = $currentPath
        if ($disp.Length -gt 78) { $disp = '...' + $disp.Substring($disp.Length - 75) }
        $script:Prog.LblPath.Text = $disp
        $secs = if ($script:Prog.Sw) { $script:Prog.Sw.Elapsed.TotalSeconds } else { 0 }
        $script:Prog.LblStats.Text = ('{0:N0} itens   |   {1} erros   |   {2:N0}s' -f $script:Scan.Count, $script:Scan.ErrCount, $secs)
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch { }
}

function Close-ProgressWindow {
    if (-not $script:Prog.Form) { return }
    $script:Prog.Closing = $true
    try { $script:Prog.Form.Close(); $script:Prog.Form.Dispose() } catch { }
    $script:Prog.Form = $null
}

# ----------------------------------------------------------------------------
#endregion

#region GUI - helpers e grelha
# Janela de navegacao: helpers de acao + reconstrucao da grelha.
# Funcoes de TOPO + estado em $script: -> chamaveis dos event handlers WinForms.
# ----------------------------------------------------------------------------
function Invoke-OpenInExplorer {
    param([string] $p)
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$p`"" } catch { }
}

function Copy-PathToClipboard {
    param([string] $p)
    try { Set-Clipboard -Value $p } catch {
        try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText($p) } catch { }
    }
}

function Get-GuiSelectedNode {
    if (-not $script:Ui.Grid.CurrentRow) { return $null }
    try { return $script:Ui.Nodes[[int]$script:Ui.Grid.CurrentRow.Cells['Idx'].Value] } catch { return $null }
}

function Update-GuiGrid {
    $node = $script:Ui.Current

    if ($script:Ui.Flat) {
        $script:Ui.Nodes = Get-FlatTop -root $script:Ui.Root -n $script:Ui.FlatN
    } else {
        $script:Ui.Nodes = @($node.Children | Sort-Object Size -Descending)
    }

    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add($(if ($script:Ui.Flat) { 'Caminho' } else { 'Nome' }), [string])
    [void]$dt.Columns.Add('Tamanho', [string])
    [void]$dt.Columns.Add('Bytes', [int64])
    [void]$dt.Columns.Add('%', [double])
    [void]$dt.Columns.Add('Ficheiros', [int])
    [void]$dt.Columns.Add('Subpastas', [int])
    [void]$dt.Columns.Add('Fich. recente', [string])
    [void]$dt.Columns.Add('Conteudo', [string])
    [void]$dt.Columns.Add('Idx', [int])

    $refTotal = if ($script:Ui.Flat) { $script:Ui.Root.Size } else { $node.Size }
    $i = 0
    foreach ($c in $script:Ui.Nodes) {
        $pct = 0.0
        if ($refTotal -gt 0) { $pct = [math]::Round(($c.Size / $refTotal) * 100, 1) }
        $conteudo = ''
        if ($c.Ext.Count -gt 0) { $conteudo = Get-CategoryText -node $c -top 3 }
        $label = if ($script:Ui.Flat) { $c.Path } else { $c.Name }
        [void]$dt.Rows.Add($label, (Format-SizeQualified $c -Style Gui), [int64]$c.Size, $pct, $c.FileCount, $c.DirCount, (Format-Date $c.MaxMtime), $conteudo, $i)
        $i++
    }

    $script:Ui.Grid.DataSource = $dt
    if ($script:Ui.Grid.Columns['Idx'])      { $script:Ui.Grid.Columns['Idx'].Visible = $false }
    if ($script:Ui.Grid.Columns['Bytes'])    { $script:Ui.Grid.Columns['Bytes'].Visible = $false }
    if ($script:Ui.Grid.Columns['Nome'])     { $script:Ui.Grid.Columns['Nome'].FillWeight = 220 }
    if ($script:Ui.Grid.Columns['Caminho'])  { $script:Ui.Grid.Columns['Caminho'].FillWeight = 420 }
    if ($script:Ui.Grid.Columns['Conteudo']) { $script:Ui.Grid.Columns['Conteudo'].FillWeight = 240 }
    # "Tamanho" e texto formatado -> ordenacao gerida a mao (por 'Bytes') no
    # handler ColumnHeaderMouseClick, senao ordenava alfabeticamente.
    if ($script:Ui.Grid.Columns['Tamanho']) {
        $script:Ui.Grid.Columns['Tamanho'].SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Programmatic
        $script:Ui.Grid.Columns['Tamanho'].HeaderCell.SortGlyphDirection = 'None'
    }
    # cada pasta comeca sem filtro
    if ($script:Ui.FilterBox -and $script:Ui.FilterBox.Text -ne '') { $script:Ui.FilterBox.Text = '' }

    if ($script:Ui.Flat) {
        $script:Ui.Lbl.Text = ('TOP {0} pastas de TODA a arvore    (raiz: {1}  |  {2})' -f `
            $script:Ui.FlatN, $script:Ui.Root.Path, (Format-Size $script:Ui.Root.Size))
        $script:Ui.BtnUp.Enabled = $false
    } else {
        $p = Get-ParetoInfo -node $node -fraction 0.8
        $pareto = ''
        if ($node.Children.Count -gt 1) { $pareto = ('   -   Pareto: {0} maiores = {1}% do espaco' -f $p.Count, $p.Share) }
        $script:Ui.Lbl.Text = ('{0}    -    Total: {1}  |  {2} fich.  |  {3} subpastas  |  mod. {4}{5}' -f `
            $node.Path, (Format-Size $node.Size), $node.FileCount, $node.DirCount, (Format-Date $node.MaxMtime), $pareto)
        $script:Ui.BtnUp.Enabled = ($script:Ui.Stack.Count -gt 0)
    }
}

# Entra no no de uma linha (via coluna Idx -> robusto a reordenacao pelo utilizador).
function Enter-GuiRow {
    param([int] $rowIndex)
    if ($rowIndex -lt 0) { return }
    $idx = [int]$script:Ui.Grid.Rows[$rowIndex].Cells['Idx'].Value
    $target = $script:Ui.Nodes[$idx]
    if ($script:Ui.Flat) { Invoke-OpenInExplorer $target.Path; return }
    if ($target.Children.Count -gt 0) {
        $script:Ui.Stack.Push($script:Ui.Current)
        $script:Ui.Current = $target
        Update-GuiGrid
    } else {
        Invoke-OpenInExplorer $target.Path
    }
}

# ----------------------------------------------------------------------------
# Dialogo grafico para ESCOLHER a pasta/share a analisar (quando -Path e omitido).
# Campo para colar um caminho \\servidor\share + botao "Procurar..." para navegar.
# Devolve o caminho escolhido, ou $null se cancelado/indisponivel.
# ----------------------------------------------------------------------------
function Select-FolderGui {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $recent = Get-RecentPaths

        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Folder Size Analyzer - escolher pasta'
        $f.Size = New-Object System.Drawing.Size(640, 185)
        $f.StartPosition = 'CenterScreen'
        $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox = $false
        $f.MinimizeBox = $false

        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = 'Pasta ou share a analisar (cola \\servidor\share, ou escolhe do historico):'
        $lab.Location = New-Object System.Drawing.Point(12, 15)
        $lab.Size = New-Object System.Drawing.Size(610, 20)

        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.Location = New-Object System.Drawing.Point(12, 42)
        $cb.Size = New-Object System.Drawing.Size(500, 24)
        $cb.DropDownStyle = 'DropDown'
        $cb.AutoCompleteMode = 'SuggestAppend'
        $cb.AutoCompleteSource = 'ListItems'
        foreach ($r in $recent) { [void]$cb.Items.Add($r) }
        if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }

        $browse = New-Object System.Windows.Forms.Button
        $browse.Text = 'Procurar...'
        $browse.Location = New-Object System.Drawing.Point(520, 40)
        $browse.Size = New-Object System.Drawing.Size(95, 26)
        $browse.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = 'Escolhe a pasta, ou navega ate Rede -> servidor -> share'
            $d.ShowNewFolderButton = $false
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $cb.Text = $d.SelectedPath }
        })

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = 'Analisar'
        $ok.Location = New-Object System.Drawing.Point(420, 100)
        $ok.Size = New-Object System.Drawing.Size(95, 28)
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancelar'
        $cancel.Location = New-Object System.Drawing.Point(520, 100)
        $cancel.Size = New-Object System.Drawing.Size(95, 28)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

        $f.Controls.AddRange(@($lab, $cb, $browse, $ok, $cancel))
        $f.AcceptButton = $ok
        $f.CancelButton = $cancel

        if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $cb.Text.Trim()) {
            return $cb.Text.Trim()
        }
        return $null
    }
    catch {
        return $null
    }
}

# ----------------------------------------------------------------------------
# Janela grafica (WinForms) sobre a arvore JA em memoria -> navegacao instantanea.
# Nao precisa de admin. Funciona em PowerShell 5.1 e 7+ num ambiente com desktop
# (consola local ou sessao RDP). Nao funciona em SSH puro sem interface grafica.
#endregion

#region GUI - janela de navegacao
# ----------------------------------------------------------------------------
# Cria a janela e restaura tamanho/posicao guardados. Devolve o Form.
function New-GuiForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Folder Size Analyzer'
    $form.Size = New-Object System.Drawing.Size(1120, 700)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(760, 460)

    $st = Get-AppSettings
    if ($st) {
        try {
            if ([int]$st.winW -ge 700 -and [int]$st.winH -ge 440) {
                $form.Size = New-Object System.Drawing.Size([int]$st.winW, [int]$st.winH)
            }
            if ($null -ne $st.winX -and $null -ne $st.winY) {
                $form.StartPosition = 'Manual'
                $form.Location = New-Object System.Drawing.Point([int]$st.winX, [int]$st.winY)
            }
        } catch { }
    }
    return $form
}

# Controlos que os event handlers precisam de alcancar -> vao para $script:Ui.
function Initialize-GuiPanel {
    $script:Ui.Lbl = New-Object System.Windows.Forms.Label
    $script:Ui.Lbl.Location = New-Object System.Drawing.Point(12, 12)
    $script:Ui.Lbl.Size = New-Object System.Drawing.Size(760, 40)
    $script:Ui.Lbl.Anchor = 'Top,Left,Right'
    $script:Ui.Lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $script:Ui.FilterBox = New-Object System.Windows.Forms.TextBox
    $script:Ui.FilterBox.Location = New-Object System.Drawing.Point(842, 13)
    $script:Ui.FilterBox.Size = New-Object System.Drawing.Size(250, 24)
    $script:Ui.FilterBox.Anchor = 'Top,Right'

    $script:Ui.Grid = New-Object System.Windows.Forms.DataGridView
    $script:Ui.Grid.Location = New-Object System.Drawing.Point(12, 58)
    $script:Ui.Grid.Size = New-Object System.Drawing.Size(1080, 552)
    $script:Ui.Grid.Anchor = 'Top,Bottom,Left,Right'
    $script:Ui.Grid.ReadOnly = $true
    $script:Ui.Grid.AllowUserToAddRows = $false
    $script:Ui.Grid.AllowUserToDeleteRows = $false
    $script:Ui.Grid.RowHeadersVisible = $false
    $script:Ui.Grid.MultiSelect = $false
    $script:Ui.Grid.SelectionMode = 'FullRowSelect'
    $script:Ui.Grid.AutoSizeColumnsMode = 'Fill'

    $script:Ui.BtnUp = New-Object System.Windows.Forms.Button
    $script:Ui.BtnUp.Text = 'Subir'
    $script:Ui.BtnUp.Size = New-Object System.Drawing.Size(90, 30)
    $script:Ui.BtnUp.Location = New-Object System.Drawing.Point(12, 622)
    $script:Ui.BtnUp.Anchor = 'Bottom,Left'
}

# Botoes/etiquetas cujos handlers sao ligados em Show-Gui. Devolvidos (e nao
# postos em $script:) para que os handlers definidos la fechem sobre LOCAIS --
# mover a definicao dos handlers para outra funcao partiria esses closures.
function New-GuiButtons {
    $mk = {
        param($text, $w, $x)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Size = New-Object System.Drawing.Size($w, 30)
        $b.Location = New-Object System.Drawing.Point($x, 622)
        $b.Anchor = 'Bottom,Left'
        return $b
    }
    $lblFil = New-Object System.Windows.Forms.Label
    $lblFil.Text = 'Filtrar:'
    $lblFil.Location = New-Object System.Drawing.Point(792, 16)
    $lblFil.Size = New-Object System.Drawing.Size(48, 20)
    $lblFil.Anchor = 'Top,Right'

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Duplo-clique/Enter = entrar. Backspace = subir. Clique direito = mais opcoes.'
    $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $hint.Location = New-Object System.Drawing.Point(694, 629)
    $hint.Anchor = 'Bottom,Left'

    return @{
        Flat   = (& $mk 'Top global'          100 108)
        Open   = (& $mk 'Abrir no Explorador' 140 214)
        Copy   = (& $mk 'Copiar caminho'      120 360)
        Csv    = (& $mk 'Exportar CSV'        110 486)
        Exit   = (& $mk 'Sair'                 80 602)
        LblFil = $lblFil
        Hint   = $hint
    }
}

# Menu de contexto da grelha. Os handlers so usam funcoes de topo e
# Get-GuiSelectedNode -> nao dependem de locais, logo vivem bem aqui.
function New-GuiContextMenu {
    $ctx = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $ctx.Items.Add('Abrir no Explorador')
    $miCopy = $ctx.Items.Add('Copiar caminho')
    $miSub  = $ctx.Items.Add('Exportar esta sub-arvore (CSV)...')
    $miOpen.Add_Click({ $n = Get-GuiSelectedNode; if ($n) { Invoke-OpenInExplorer $n.Path } })
    $miCopy.Add_Click({ $n = Get-GuiSelectedNode; if ($n) { Copy-PathToClipboard $n.Path } })
    $miSub.Add_Click({
        $n = Get-GuiSelectedNode; if (-not $n) { return }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = 'CSV (*.csv)|*.csv'
        $sfd.FileName = ($n.Name -replace '[^\w\.-]', '_') + '.csv'
        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Export-TreeCsv -node $n -CsvPath $sfd.FileName
            [System.Windows.Forms.MessageBox]::Show("Exportado:`n$($sfd.FileName)", 'CSV') | Out-Null
        }
    })
    return $ctx
}

function Show-Gui {
    param($root)

    # Construcao protegida: numa maquina sem subsistema grafico (Server Core)
    # qualquer passo pode falhar -> cai para o modo consola.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $script:Ui.Root    = $root
        $script:Ui.Current = $root
        $script:Ui.Stack   = New-Object System.Collections.Generic.Stack[object]
        $script:Ui.Nodes   = @()
        $script:Ui.Flat    = $false
        $script:Ui.FlatN   = $(if ($FlatTop -gt 0) { $FlatTop } else { 50 })

        $form = New-GuiForm
        Initialize-GuiPanel
        $c = New-GuiButtons
        $btnFlat = $c.Flat; $btnOpen = $c.Open; $btnCopy = $c.Copy
        $btnCsv  = $c.Csv;  $btnExit = $c.Exit
        $lblFil  = $c.LblFil; $hint = $c.Hint

        $script:Ui.Grid.ContextMenuStrip = New-GuiContextMenu
        $script:Ui.Grid.Add_CellMouseDown({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
                $script:Ui.Grid.ClearSelection()
                $script:Ui.Grid.Rows[$e.RowIndex].Selected = $true
                $script:Ui.Grid.CurrentCell = $script:Ui.Grid.Rows[$e.RowIndex].Cells[0]
            }
        })

        $form.Controls.AddRange(@($script:Ui.Lbl, $lblFil, $script:Ui.FilterBox, $script:Ui.Grid, $script:Ui.BtnUp, $btnFlat, $btnOpen, $btnCopy, $btnCsv, $btnExit, $hint))

        # Filtro por nome (ou caminho, na vista Top global) sobre a lista atual.
        $script:Ui.FilterBox.Add_TextChanged({
            try {
                $view = $script:Ui.Grid.DataSource.DefaultView
                $v = $script:Ui.FilterBox.Text
                if ([string]::IsNullOrWhiteSpace($v)) { $view.RowFilter = '' ; return }
                $esc = $v -replace "'", "''" -replace '\[', '[[]' -replace '%', '[%]' -replace '\*', '[*]'
                $col = if ($script:Ui.Flat) { 'Caminho' } else { 'Nome' }
                $view.RowFilter = "[$col] LIKE '%$esc%'"
            } catch { }
        })

        $script:Ui.Grid.Add_CellDoubleClick({ param($s, $e) Enter-GuiRow $e.RowIndex })
        # Ordenacao correcta da coluna "Tamanho" (texto formatado) -> ordena pela
        # coluna oculta 'Bytes'. 1o clique = maiores primeiro; alterna depois.
        $script:Ui.Grid.Add_ColumnHeaderMouseClick({
            param($s, $e)
            if ($e.ColumnIndex -lt 0) { return }
            if ($script:Ui.Grid.Columns[$e.ColumnIndex].Name -ne 'Tamanho') { return }
            try {
                $cur = [string]$script:Ui.Grid.DataSource.DefaultView.Sort
                $new = if ($cur -eq 'Bytes DESC') { 'Bytes ASC' } else { 'Bytes DESC' }
                $script:Ui.Grid.DataSource.DefaultView.Sort = $new
                $glyph = if ($new -eq 'Bytes DESC') { 'Descending' } else { 'Ascending' }
#endregion

                $script:Ui.Grid.Columns['Tamanho'].HeaderCell.SortGlyphDirection = $glyph
            } catch { }
        })
        $script:Ui.Grid.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $script:Ui.Grid.CurrentRow) {
                Enter-GuiRow $script:Ui.Grid.CurrentRow.Index
                $e.Handled = $true
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Back) {
                if (-not $script:Ui.Flat -and $script:Ui.Stack.Count -gt 0) {
                    $script:Ui.Current = $script:Ui.Stack.Pop(); Update-GuiGrid
                }
                $e.Handled = $true
            }
        })
        $script:Ui.BtnUp.Add_Click({
            if ($script:Ui.Stack.Count -gt 0) {
                $script:Ui.Current = $script:Ui.Stack.Pop()
                Update-GuiGrid
            }
        })
        $btnFlat.Add_Click({
            $script:Ui.Flat = -not $script:Ui.Flat
            $btnFlat.Text = if ($script:Ui.Flat) { 'Navegar' } else { 'Top global' }
            Update-GuiGrid
        })
        $btnOpen.Add_Click({ $n = Get-GuiSelectedNode; if ($n) { Invoke-OpenInExplorer $n.Path } })
        $btnCopy.Add_Click({ $n = Get-GuiSelectedNode; if ($n) { Copy-PathToClipboard $n.Path } })
        $btnCsv.Add_Click({
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = 'CSV (*.csv)|*.csv'
            $sfd.FileName = 'FolderSizes.csv'
            if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Export-TreeCsv -node $script:Ui.Root -CsvPath $sfd.FileName
                [System.Windows.Forms.MessageBox]::Show("Exportado:`n$($sfd.FileName)", 'CSV') | Out-Null
            }
        })
        $btnExit.Add_Click({ $form.Close() })
        $form.Add_FormClosing({ Save-AppSettings $form })

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
# Sem -Path: abre o seletor grafico (fluxo totalmente grafico). Se a GUI nao
# estiver disponivel, pede o caminho na consola.
if ([string]::IsNullOrWhiteSpace($Path)) {
    $picked = Select-FolderGui
    if ($picked) {
        $Path = $picked
        $Gui  = $true   # escolheu graficamente -> resultados tambem em janela
    }
    else {
        $Path = Read-Host 'Indica a pasta ou share a analisar (ex: \\servidor\share)'
    }
}
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Error 'Nenhum caminho indicado. A sair.'; exit 1
}

# O prefixo estendido \\?\ exige um caminho ABSOLUTO. Caminhos relativos
# ('.', '..\x', 'sub') produziam '\\?\.' e rebentavam o scan -> normaliza aqui.
# .NET GetFullPath sozinho usa Environment.CurrentDirectory (dessincronizado da
# localizacao do PowerShell), por isso combinamos com $PWD explicitamente.
if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $Path = [System.IO.Path]::GetFullPath((Join-Path $PWD.ProviderPath $Path))
}
else {
    try { $Path = [System.IO.Path]::GetFullPath($Path) } catch { }  # resolve '.'/'..' internos
}

if (-not (Test-Path -LiteralPath $Path)) {
    # Test-Path pode falhar em long paths; tenta enumerar a raiz na mesma
    try { [System.IO.Directory]::EnumerateFileSystemEntries((ConvertTo-ExtendedPath $Path)) | Out-Null }
    catch { Write-Error "Nao consigo aceder a '$Path'. Verifica a localizacao/permissoes."; exit 1 }
}

Add-RecentPath $Path

Write-Host "A analisar '$Path' ... (isto pode demorar em shares grandes)" -ForegroundColor Cyan

$useProgressGui = ($Gui -and -not $NoProgressGui)
if ($useProgressGui) { [void](Show-ProgressWindow) }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$root = Get-FolderNode -DisplayPath $Path
$sw.Stop()
Write-Progress -Activity 'A analisar...' -Completed
if ($script:Scan.CancelRequested) { $script:Scan.Partial = $true }
Close-ProgressWindow

# Resumo
Write-Host ''
Write-Host '================= RESUMO =================' -ForegroundColor Green
if ($script:Scan.Partial) { Write-Host '  *** SCAN CANCELADO - resultados PARCIAIS ***' -ForegroundColor Red }
Write-Host ("Caminho        : $($root.Path)")
Write-Host ("Tamanho total  : $(Format-SizeQualified $root)")
Write-Host ("Ficheiros      : $($root.FileCount)")
Write-Host ("Subpastas      : $($root.DirCount)")
Write-Host ("Fich. + recente: $(Format-Date $root.MaxMtime) (data do ficheiro mais recente da arvore)")
Write-Host ("Caminhos >260  : $($script:Scan.LongPaths.Count)")
Write-Host ("Junctions/links: $($script:Scan.SkipReparse) (ignorados; placeholders da cloud sao percorridos)")
Write-Host ("Sem acesso     : $(@($script:Scan.DeniedDirs | Select-Object -Unique).Count) pasta(s), $(@($script:Scan.DeniedItems | Select-Object -Unique).Count) item(ns)")
Write-Host ("Erros no scan  : $($script:Scan.ErrCount)")
$incompleteN = Get-IncompleteCount -root $root
if ($incompleteN -eq 0) {
    Write-Host ("Cobertura      : COMPLETA")
} else {
    Write-Host ("Cobertura      : PARCIAL - $incompleteN pasta(s) nao lidas por completo; os seus totais (e os dos pais) sao MINIMOS. Ver coluna Complete no CSV.") -ForegroundColor DarkYellow
}
Write-Host ("Tempo          : $([math]::Round($sw.Elapsed.TotalSeconds,1))s")
if ($root.Ext.Count -gt 0) {
    Write-Host ("Conteudo       : " + (Get-CategoryText -node $root -top 6))
}
Write-Host '=========================================' -ForegroundColor Green

# Exportacoes
if ($CsvOut) {
    Export-TreeCsv -node $root -CsvPath $CsvOut
    Write-Host "CSV exportado: $CsvOut" -ForegroundColor Green
}
if ($SnapshotOut) {
    Export-Snapshot -root $root -SnapPath $SnapshotOut
    Write-Host "Snapshot gravado: $SnapshotOut" -ForegroundColor Green
}
$cmp = $null
if ($CompareWith) {
    $cmp = Compare-Snapshot -root $root -PrevPath $CompareWith
    Show-Compare -cmp $cmp
}
if ($HtmlOut) {
    Export-HtmlReport -root $root -HtmlPath $HtmlOut -Elapsed $sw.Elapsed.TotalSeconds -cmp $cmp
    Write-Host "Relatorio HTML: $HtmlOut" -ForegroundColor Green
}

# Pastas sem acesso (cobertura honesta do diagnostico)
$ddirs = @($script:Scan.DeniedDirs | Select-Object -Unique)
if ($ddirs.Count -gt 0) {
    Write-Host ''
    Write-Host "--- Pastas NAO medidas (sem acesso) - $($ddirs.Count) ---" -ForegroundColor DarkYellow
    Write-Host "    (o espaco destas pastas nao entra nos totais)" -ForegroundColor DarkGray
    $ddirs | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
    if ($ddirs.Count -gt 15) { Write-Host "  ... (+$($ddirs.Count - 15); lista completa no HTML)" -ForegroundColor DarkGray }
}

# Caminhos > 260
if ($script:Scan.LongPaths.Count -gt 0) {
    Write-Host ''
    Write-Host "--- Caminhos > 260 caracteres (top 20 por tamanho) ---" -ForegroundColor Magenta
    $script:Scan.LongPaths | Sort-Object Size -Descending | Select-Object -First 20 |
        ForEach-Object { Write-Host ('  {0,-9} {1,10}  len={2}  {3}' -f $_.Type, (Format-Size $_.Size), $_.Length, $_.Path) }
}

# Top global na consola (se pedido e nao for modo GUI)
if ($FlatTop -gt 0 -and -not $Gui) { Show-FlatTop -root $root -n $FlatTop }

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
    Write-Host 'Dica: -Interactive para navegar, -Gui para janela, -FlatTop N para as maiores de toda a arvore.' -ForegroundColor DarkGray
}

# Erros detalhados
if ($script:Scan.ErrCount -gt 0) {
    Write-Host ''
    Write-Host "Nota: $($script:Scan.ErrCount) itens nao puderam ser lidos (permissoes/etc). Primeiros 10:" -ForegroundColor DarkYellow
    $script:Scan.Errors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
}

if ($script:Scan.Partial) { exit 2 }
