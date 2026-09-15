# ============================================================
#  PPEPlan — liga/desliga as notificações do Windows SÓ NESTE PC
#  (menu Iniciar → PPEPlan). Os emails não são afetados.
#  Guarda em %LOCALAPPDATA%\PPEPlan\config.json → notifications.enabled
# ============================================================

. (Join-Path $PSScriptRoot 'PPEPlan-Common.ps1')
Add-Type -AssemblyName System.Windows.Forms

$path = Join-Path $script:PPE_StateDir 'config.json'
$user = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $user.notifications) { $user | Add-Member -NotePropertyName notifications -NotePropertyValue ([pscustomobject]@{}) -Force }

$enabled = -not [bool](Get-PPEConfig).notifications.enabled
$user.notifications | Add-Member -NotePropertyName enabled -NotePropertyValue $enabled -Force
$user | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
Write-PPELog "Notificações neste PC: $(if ($enabled) { 'ligadas' } else { 'desligadas' })"

$text = if ($enabled) {
    "Notificações do PPEPlan LIGADAS neste PC.`n`nAs horas definem-se na ⚙ da app PPEPlan."
} else {
    "Notificações do PPEPlan DESLIGADAS neste PC.`n`nOs emails continuam a ser enviados. Para voltar a ligar, abre de novo este atalho."
}
[void][Windows.Forms.MessageBox]::Show($text, 'PPEPlan', 'OK', 'Information')
