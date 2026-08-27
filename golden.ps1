# Aparelho de regressao para o refactor do dirsize.ps1
#   .\golden.ps1 -Mode capture   -> grava saida de referencia + MANIFEST.csv
#   .\golden.ps1 -Mode verify    -> re-corre e compara com o MANIFEST
# Compara a saida NORMALIZADA (sem tempos/datas/caminhos volateis).
param(
    [ValidateSet('capture','verify')] [string] $Mode = 'verify',
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
$out  = Join-Path $Root $Mode
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
    Write-Host 'SAIDA IDENTICA - refactor nao alterou comportamento' -ForegroundColor Green
    exit 0
}
Write-Host "$bad ficheiro(s) diferem. Para ver onde:" -ForegroundColor Red
Write-Host "  Compare-Object (gc '$Root\capture\<f>') (gc '$out\<f>')" -ForegroundColor DarkGray
exit 1
