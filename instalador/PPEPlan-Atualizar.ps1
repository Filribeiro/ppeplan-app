# ============================================================
#  PPEPlan — atualização automática dos scripts (chamado pelo agendador)
#  Lê <appUrl>/instalador/versao.json (publicado pelo Publicar-App.ps1),
#  descarrega os ficheiros cujo SHA-256 difere do instalado, confirma o
#  hash e só depois substitui. O oauth-client.json nunca é publicado.
#  Devolve $true se atualizou.
#  -Force  verifica já (ignora o intervalo de 1 hora)
# ============================================================
param([switch]$Force)

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')

$config = Get-PPEConfig
$now = Get-Date
$last = (Get-PPEState).updateCheckedAt
if (-not $Force -and $last -and ($now - [DateTime]::Parse($last, $script:INV)).TotalMinutes -lt 60) { return $false }
Set-PPEStateValue 'updateCheckedAt' $now.ToString('o')

$base = $config.appUrl.TrimEnd('/') + '/instalador/'
$nc = '?t=' + $now.Ticks
$manifest = Invoke-RestMethod -Uri ($base + 'versao.json' + $nc) -UseBasicParsing -TimeoutSec 30

$tmp = Join-Path $script:PPE_StateDir 'atualizacao'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tmp | Out-Null

$changed = @()
try {
    foreach ($f in $manifest.files.PSObject.Properties) {
        $name = $f.Name; $hash = ([string]$f.Value).ToUpperInvariant()
        if ($name -notmatch '^[A-Za-z0-9._-]+\.(ps1|json)$' -or $name -eq 'oauth-client.json') { continue }
        $local = Join-Path $PSScriptRoot $name
        if ((Test-Path -LiteralPath $local) -and (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -eq $hash) { continue }
        $out = Join-Path $tmp $name
        Invoke-WebRequest -Uri ($base + $name + $nc) -OutFile $out -UseBasicParsing -TimeoutSec 60
        if ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -ne $hash) { throw "Hash inválido em $name (publicação a meio?)" }
        $changed += $name
    }
    if ($changed.Count -eq 0) { return $false }

    # Só substitui depois de todos descarregados e verificados
    foreach ($name in $changed) { Copy-Item -LiteralPath (Join-Path $tmp $name) -Destination (Join-Path $PSScriptRoot $name) -Force }
    Write-PPELog "Atualizado ($($manifest.published)): $($changed -join ', ')"

    # Configurar.ps1 mudou (ex.: definição da tarefa agendada): aplica neste PC sem perguntas
    if ($changed -contains 'Configurar.ps1') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Configurar.ps1') -Silencioso | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-PPELog 'Aviso: Configurar.ps1 -Silencioso falhou depois da atualização' }
    }
    return $true
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
