# Aparelho de regressao para o dirsize.ps1
#   .\golden.ps1 -Mode capture   -> grava saida de referencia + MANIFEST.csv
#   .\golden.ps1 -Mode verify    -> re-corre e compara com o MANIFEST
#   .\golden.ps1 -Mode gui       -> exercita as accoes da grelha sem abrir janela
#   .\golden.ps1 -Mode all       -> verify + gui
# 'capture'/'verify' comparam a saida NORMALIZADA (sem tempos/datas/caminhos
# volateis). 'gui' faz asserts sobre uma DataGridView real que nunca e mostrada.
param(
    [ValidateSet('capture','verify','gui','all')] [string] $Mode = 'verify',
    [string] $Script = (Join-Path $PSScriptRoot 'dirsize.ps1'),
    [string] $Root   = (Join-Path $env:TEMP 'dirsize_golden'),
    [switch] $Rebuild   # forca reconstrucao da arvore de teste
)
$ErrorActionPreference = 'Stop'

$tree = Join-Path $Root 'tree'

# --- arvore de teste: fixa e deterministica (datas congeladas) ---------------
# Cobre: pasta sem acesso, junction, caminho >260, varias categorias, pasta vazia.
if ($Rebuild -and (Test-Path $tree)) {
    # 1) levantar o Deny, senao nao se apaga; 2) remover a junction como link
    #    (Directory.Delete recursivo rebenta em reparse points).
    $priv = Join-Path $tree 'Docs\Priv'
    if (Test-Path $priv) {
        $a = Get-Acl $priv
        $a.Access | Where-Object { $_.AccessControlType -eq 'Deny' } | ForEach-Object { [void]$a.RemoveAccessRule($_) }
        Set-Acl $priv $a
    }
    $link = Join-Path $tree 'Link'
    if (Test-Path $link) { [System.IO.Directory]::Delete($link, $false) }
    [System.IO.Directory]::Delete($tree, $true)
}
if (-not (Test-Path $tree)) {
    $seg = 'd' * 40
    $deep = $tree
    1..8 | ForEach-Object { $deep = Join-Path $deep $seg }
    $null = New-Item -ItemType Directory -Force -Path `
        (Join-Path $tree 'Fotos\2023'), (Join-Path $tree 'Fotos\2024'),
        (Join-Path $tree 'Docs\Priv'),  (Join-Path $tree 'Backups'),
        (Join-Path $tree 'Vazia'),      $deep
    Set-Content (Join-Path $tree 'Fotos\2023\a.jpg')      ('x' * 300000)
    Set-Content (Join-Path $tree 'Fotos\2024\b.png')      ('x' * 120000)
    Set-Content (Join-Path $tree 'Docs\readme.txt')       ('x' * 2000)
    Set-Content (Join-Path $tree 'Docs\Priv\secreto.pdf') ('x' * 50000)
    Set-Content (Join-Path $tree 'Backups\big.zip')       ('x' * 900000)
    Set-Content (Join-Path $tree 'Backups\setup.msi')     ('x' * 250000)
    Set-Content (Join-Path $deep 'fundo.dat')             ('x' * 1234)
    # nomes com caracteres especiais do LIKE do DataView -> sem estes, um filtro
    # sem escape passaria despercebido (ver golden.ps1 -Mode gui).
    # -LiteralPath obrigatorio: '[' e '%' sao wildcards para o provider.
    foreach ($nome in '50% desconto', 'entre [colchetes]') {
        $d = Join-Path $tree $nome
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $d) -ErrorAction SilentlyContinue
        [void][System.IO.Directory]::CreateDirectory($d)
        [System.IO.File]::WriteAllText((Join-Path $d 'nota.txt'), ('x' * 5000))
    }
    $null = New-Item -ItemType Junction -Path (Join-Path $tree 'Link') -Target (Join-Path $tree 'Fotos')
    $priv = Join-Path $tree 'Docs\Priv'
    $acl = Get-Acl $priv
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'ListDirectory', 'Deny')))
    Set-Acl $priv $acl
    Get-ChildItem $tree -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.LastWriteTimeUtc = [datetime]'2025-03-14T10:00:00Z' } catch { } }
    Write-Host "arvore de teste criada: $tree" -ForegroundColor DarkGray
}
# ============================================================================
# MODO gui - accoes da grelha, sem abrir janela
# ============================================================================
# Carrega SO as funcoes do dirsize.ps1 (via AST, sem executar a seccao de
# execucao no fim do ficheiro), monta o estado a mao e opera sobre uma
# DataGridView real que nunca e mostrada. Cobre o que o diff de ficheiros nao
# alcanca: navegacao, filtro, ordenacao, Top global e seleccao.
function Invoke-GuiTests {
    param([string] $ScriptPath, [string] $Tree)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $fns = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }

    # parametros que as funcoes leem do scope do script
    $script:Exclude        = @()
    $script:ShowExtensions = $false
    $Exclude = @(); $ShowExtensions = $false
    $script:CategoryMap = @{}
    $defs = @{ 'Imagem' = '.jpg .png'; 'Comprimido/Bkp' = '.zip'; 'Instalador/Bin' = '.msi'; 'Documento' = '.txt .pdf' }
    foreach ($cat in $defs.Keys) { foreach ($e in ($defs[$cat] -split '\s+')) { if ($e) { $script:CategoryMap[$e] = $cat } } }

    $script:Scan = [pscustomobject]@{
        ErrCount = 0; Errors = (New-Object System.Collections.Generic.List[string])
        DeniedDirs = (New-Object System.Collections.Generic.List[string])
        DeniedItems = (New-Object System.Collections.Generic.List[string])
        LongPaths = (New-Object System.Collections.Generic.List[object])
        Count = 0; LastReport = 0; SkipReparse = 0; CancelRequested = $false; Partial = $false
    }
    $script:Prog = [pscustomobject]@{ Form=$null; LblPath=$null; LblStats=$null; Sw=$null; Closing=$false }
    $script:Ui = [pscustomobject]@{
        Root=$null; Current=$null; Stack=$null; Nodes=@(); Flat=$false; FlatN=50
        Grid=$null; Lbl=$null; BtnUp=$null; FilterBox=$null
    }

    $root = Get-FolderNode -DisplayPath $Tree
    $script:Ui.Root = $root; $script:Ui.Current = $root
    $script:Ui.Stack = New-Object System.Collections.Generic.Stack[object]
    $script:Ui.Grid      = New-Object System.Windows.Forms.DataGridView
    $script:Ui.Lbl       = New-Object System.Windows.Forms.Label
    $script:Ui.BtnUp     = New-Object System.Windows.Forms.Button
    $script:Ui.FilterBox = New-Object System.Windows.Forms.TextBox
    $script:Ui.Grid.AllowUserToAddRows = $false
    # A grelha so gera colunas/linhas depois de o handle existir. Damos-lhe um
    # Form que NUNCA e mostrado (sem ShowDialog) e forcamos a criacao.
    $hidden = New-Object System.Windows.Forms.Form
    $hidden.Controls.Add($script:Ui.Grid)
    $hidden.CreateControl()
    $script:Ui.Grid.CreateControl()

    $pass = 0; $fail = 0
    function Assert-That {
        param([string] $Name, [bool] $Cond, [string] $Detail = '')
        if ($Cond) { Write-Host "  ok    $Name" -ForegroundColor Green; $script:__p++ }
        else       { Write-Host "  FALHA $Name $Detail" -ForegroundColor Red; $script:__f++ }
    }
    $script:__p = 0; $script:__f = 0

    Write-Host 'GUI - accoes da grelha' -ForegroundColor Cyan

    # --- render inicial ---
    Update-GuiGrid
    $rows = $script:Ui.Grid.DataSource.DefaultView.Count
    Assert-That 'render inicial produz linhas' ($rows -gt 0) "(linhas=$rows)"
    Assert-That "coluna 'Nome' na vista de navegacao" ($null -ne $script:Ui.Grid.Columns['Nome'])
    Assert-That "coluna 'Bytes' oculta" ($script:Ui.Grid.Columns['Bytes'] -and -not $script:Ui.Grid.Columns['Bytes'].Visible)
    Assert-That "coluna 'Idx' oculta"   ($script:Ui.Grid.Columns['Idx']   -and -not $script:Ui.Grid.Columns['Idx'].Visible)
    Assert-That 'ordenado por tamanho desc por omissao' `
        ([int64]$script:Ui.Grid.DataSource.DefaultView[0]['Bytes'] -ge [int64]$script:Ui.Grid.DataSource.DefaultView[$rows-1]['Bytes'])

    # --- ordenacao pela coluna Tamanho (texto) usa a coluna Bytes ---
    Invoke-GuiSortBySize
    $v = $script:Ui.Grid.DataSource.DefaultView
    $asc = @(0..($v.Count-1) | ForEach-Object { [int64]$v[$_]['Bytes'] })
    Assert-That '1o clique em Tamanho -> maiores primeiro' `
        (($v.Sort -eq 'Bytes DESC') -and ($asc[0] -ge $asc[-1])) "(sort=$($v.Sort))"
    Invoke-GuiSortBySize
    $v = $script:Ui.Grid.DataSource.DefaultView
    $asc2 = @(0..($v.Count-1) | ForEach-Object { [int64]$v[$_]['Bytes'] })
    Assert-That '2o clique inverte' (($v.Sort -eq 'Bytes ASC') -and ($asc2[0] -le $asc2[-1])) "(sort=$($v.Sort))"
    Invoke-GuiSortBySize   # repor

    # --- filtro ---
    $antes = $script:Ui.Grid.DataSource.DefaultView.Count
    $script:Ui.FilterBox.Text = 'Fotos'; Invoke-GuiFilter
    $dep = $script:Ui.Grid.DataSource.DefaultView.Count
    Assert-That 'filtro restringe as linhas' ($dep -lt $antes -and $dep -ge 1) "(antes=$antes depois=$dep)"
    $script:Ui.FilterBox.Text = 'zzz-nao-existe'; Invoke-GuiFilter
    Assert-That 'filtro sem correspondencia -> 0 linhas' ($script:Ui.Grid.DataSource.DefaultView.Count -eq 0)

    # Caracteres especiais do LIKE: nao basta "nao rebentar" -- tem de encontrar
    # a linha certa, senao um filtro sem escape passava (o erro cai no catch e o
    # RowFilter fica como estava, sem excepcao visivel).
    foreach ($caso in @(
            @{ Termo = '50%';         Esperado = '50% desconto' },
            @{ Termo = '[colchetes]'; Esperado = 'entre [colchetes]' })) {
        $script:Ui.FilterBox.Text = ''; Invoke-GuiFilter
        $script:Ui.FilterBox.Text = $caso.Termo; Invoke-GuiFilter
        $vw = $script:Ui.Grid.DataSource.DefaultView
        $nomes = @(0..([math]::Max($vw.Count-1,0)) | Where-Object { $vw.Count -gt 0 } | ForEach-Object { [string]$vw[$_]['Nome'] })
        Assert-That "filtro '$($caso.Termo)' encontra exactamente '$($caso.Esperado)'" `
            ($vw.Count -eq 1 -and $nomes[0] -eq $caso.Esperado) "(obteve $($vw.Count): $($nomes -join ','))"
    }
    # apostrofo: nao ha linha correspondente, mas o filtro tem de EXCLUIR tudo
    # (um apostrofo por escapar produz SQL invalido -> filtro fica por aplicar)
    $script:Ui.FilterBox.Text = ''; Invoke-GuiFilter
    $script:Ui.FilterBox.Text = "a'b"; Invoke-GuiFilter
    Assert-That "apostrofo escapado (filtro aplicado, 0 linhas)" `
        ($script:Ui.Grid.DataSource.DefaultView.Count -eq 0) "(obteve $($script:Ui.Grid.DataSource.DefaultView.Count))"

    $script:Ui.FilterBox.Text = ''; Invoke-GuiFilter
    Assert-That 'limpar filtro repoe todas as linhas' ($script:Ui.Grid.DataSource.DefaultView.Count -eq $antes)

    # --- navegacao: entrar e subir ---
    # IMPORTANTE: inverter a ordem primeiro. Com a grelha na ordem por omissao,
    # posicao-da-linha == Idx, e um Enter-GuiRow que usasse a posicao em vez da
    # coluna Idx passaria despercebido. Invertida, as duas divergem.
    $script:Ui.Grid.DataSource.DefaultView.Sort = 'Bytes ASC'   # setup, nao assert
    Assert-That 'grelha invertida para o teste de mapeamento' `
        ([string]$script:Ui.Grid.DataSource.DefaultView.Sort -eq 'Bytes ASC')

    $alvo = @($script:Ui.Nodes | Where-Object { $_.Children.Count -gt 0 } | Select-Object -First 1)[0]
    if ($alvo) {
        $linha = @(0..($script:Ui.Grid.Rows.Count-1) |
            Where-Object { $script:Ui.Nodes[[int]$script:Ui.Grid.Rows[$_].Cells['Idx'].Value].Path -eq $alvo.Path })[0]
        $idxAlvo = [int]$script:Ui.Grid.Rows[$linha].Cells['Idx'].Value
        Assert-That 'posicao da linha difere do Idx (mutacao seria detectavel)' `
            ($linha -ne $idxAlvo) "(linha=$linha idx=$idxAlvo)"
        $antesPath = $script:Ui.Current.Path
        Enter-GuiRow $linha
        Assert-That 'duplo-clique entra na pasta' ($script:Ui.Current.Path -eq $alvo.Path) "(em $($script:Ui.Current.Path))"
        Assert-That 'pilha cresce ao entrar' ($script:Ui.Stack.Count -eq 1)
        Assert-That 'BtnUp fica activo' ($script:Ui.BtnUp.Enabled)
        Assert-That 'subir volta ao anterior' ((Invoke-GuiUp) -and $script:Ui.Current.Path -eq $antesPath)
        Assert-That 'BtnUp inactivo no topo' (-not $script:Ui.BtnUp.Enabled)
        Assert-That 'subir no topo nao faz nada' (-not (Invoke-GuiUp))
    } else { Assert-That 'arvore de teste tem subpastas' $false }

    # --- Top global ---
    [void](Set-GuiFlat $true)
    Assert-That "Top global muda coluna para 'Caminho'" ($null -ne $script:Ui.Grid.Columns['Caminho'])
    Assert-That 'Top global desactiva BtnUp' (-not $script:Ui.BtnUp.Enabled)
    $script:Ui.FilterBox.Text = 'Fotos'; Invoke-GuiFilter
    Assert-That 'filtro no Top global usa Caminho' ($script:Ui.Grid.DataSource.DefaultView.Count -ge 1)
    $script:Ui.FilterBox.Text = ''; Invoke-GuiFilter
    [void](Set-GuiFlat $false)
    Assert-That "voltar a navegar repoe 'Nome'" ($null -ne $script:Ui.Grid.Columns['Nome'])

    # --- seleccao (clique direito) e mapeamento linha->no ---
    if ($script:Ui.Grid.Rows.Count -gt 1) {
        Select-GuiRow 1
        $n = Get-GuiSelectedNode
        Assert-That 'clique direito selecciona a linha certa' `
            ($n -and $n.Path -eq $script:Ui.Nodes[[int]$script:Ui.Grid.Rows[1].Cells['Idx'].Value].Path)
        # mapeamento tem de resistir a reordenacao
        Invoke-GuiSortBySize; Invoke-GuiSortBySize
        Select-GuiRow 0
        $n0 = Get-GuiSelectedNode
        Assert-That 'linha->no correcto apos reordenar' `
            ($n0 -and $n0.Path -eq $script:Ui.Nodes[[int]$script:Ui.Grid.Rows[0].Cells['Idx'].Value].Path)
    }

    Write-Host ''
    if ($script:__f -eq 0) { Write-Host "GUI: $($script:__p) asserts, todos ok" -ForegroundColor Green; return $true }
    Write-Host "GUI: $($script:__f) de $($script:__p + $script:__f) asserts falharam" -ForegroundColor Red
    return $false
}

if ($Mode -eq 'gui') {
    if (Invoke-GuiTests -ScriptPath $Script -Tree $tree) { exit 0 } else { exit 1 }
}

$out  = Join-Path $Root ($(if ($Mode -eq 'all') { 'verify' } else { $Mode }))
if (Test-Path $out) { [System.IO.Directory]::Delete($out, $true) }
$null = New-Item -ItemType Directory -Force $out

# --- corridas que exercitam todas as vistas e exportadores ---
& $Script -Path $tree -Depth 3 -Top 20 -FlatTop 30 -ShowExtensions -NoProgressGui `
    -CsvOut (Join-Path $out 'gold.csv') -SnapshotOut (Join-Path $out 'gold.json') `
    -HtmlOut (Join-Path $out 'gold.html') *>&1 |
    Out-String | Set-Content (Join-Path $out 'console.txt') -Encoding UTF8

& $Script -Path $tree -Depth 1 -NoProgressGui -CompareWith (Join-Path $out 'gold.json') *>&1 |
    Out-String | Set-Content (Join-Path $out 'compare.txt') -Encoding UTF8

& $Script -Path $tree -Depth 2 -Top 5 -NoProgressGui *>&1 |
    Out-String | Set-Content (Join-Path $out 'report.txt') -Encoding UTF8

# --- normalizacao: remove tudo o que varia entre corridas ---
function Get-Norm {
    param([string] $Path, [string] $OutDir)
    $s = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $s = $s -replace [regex]::Escape($OutDir), '<OUT>'          # pasta de saida
    $s = $s -replace [regex]::Escape($env:TEMP), '<TEMP>'       # raiz temporaria
    $s = $s -replace '\d{4}-\d\d-\d\dT[\d:.]+Z', '<ISO>'        # timestamps ISO
    $s = $s -replace '\d{4}-\d\d-\d\d \d\d:\d\d', '<STAMP>'     # data/hora do HTML
    $s = $s -replace '(?m)Tempo\s+:.*$', 'Tempo: <T>'           # duracao do scan
    $s = $s -replace '\d+[.,]\d+s', '<T>'                       # duracao inline
    return $s
}

$rows = foreach ($f in (Get-ChildItem $out -File | Sort-Object Name)) {
    $norm = Get-Norm -Path $f.FullName -OutDir $out
    $sha  = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($norm))).Replace('-','')
    [pscustomobject]@{ File = $f.Name; Sha256 = $sha }
}

$manifest = Join-Path $Root 'MANIFEST.csv'
if ($Mode -eq 'capture') {
    $rows | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8
    $rows | Format-Table -Auto
    Write-Host "MANIFEST gravado: $manifest" -ForegroundColor Green
    exit 0
}

$base = Import-Csv -LiteralPath $manifest
$bad  = 0
foreach ($b in $base) {
    $now = $rows | Where-Object { $_.File -eq $b.File }
    if (-not $now)                    { Write-Host "FALTA   $($b.File)" -ForegroundColor Red;    $bad++ }
    elseif ($now.Sha256 -ne $b.Sha256) { Write-Host "DIFERE  $($b.File)" -ForegroundColor Red;   $bad++ }
    else                               { Write-Host "ok      $($b.File)" -ForegroundColor Green }
}
Write-Host ''
if ($bad -eq 0) {
    Write-Host 'SAIDA IDENTICA - comportamento inalterado' -ForegroundColor Green
} else {
    Write-Host "$bad ficheiro(s) diferem. Para ver onde:" -ForegroundColor Red
    Write-Host "  Compare-Object (gc '$Root\capture\<f>') (gc '$out\<f>')" -ForegroundColor DarkGray
}

if ($Mode -eq 'all') {
    Write-Host ''
    if (-not (Invoke-GuiTests -ScriptPath $Script -Tree $tree)) { $bad++ }
}
if ($bad -eq 0) { exit 0 } else { exit 1 }
