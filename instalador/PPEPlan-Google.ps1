# ============================================================
#  PPEPlan — conta Google (login, Drive e Gmail)
#  Login OAuth "aplicação instalada": abre o browser, recebe o código
#  num porto local (127.0.0.1) e guarda o refresh token cifrado com
#  DPAPI em %LOCALAPPDATA%\PPEPlan\google-token.xml (só este
#  utilizador Windows, neste PC, o consegue ler).
#
#  Usa o cliente "Desktop" do mesmo projeto Google Cloud da app web:
#  com drive.file, o acesso aos ficheiros é por projeto, por isso
#  estes scripts veem o ppeplan-data.json que a app criou.
# ============================================================

$script:PPE_DataFileName  = 'ppeplan-data.json'
$script:PPE_EmailStateName = 'ppeplan-emails-enviados.json'
$script:PPE_PcsFileName    = 'ppeplan-pcs.json'
$script:PPE_TokenPath = Join-Path $env:LOCALAPPDATA 'PPEPlan\google-token.xml'
$script:PPE_Scopes = @(
    'openid', 'email',
    'https://www.googleapis.com/auth/drive.file',
    'https://www.googleapis.com/auth/gmail.send'
)
$script:PPE_AccessToken = $null
$script:PPE_AccessTokenExpires = [DateTime]::MinValue

function Get-PPEOAuthClient {
    $c = Get-Content -LiteralPath (Join-Path $script:PPE_Root 'oauth-client.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $c.client_id -or $c.client_id -like 'COLAR*') { throw 'oauth-client.json não está preenchido (client_id/client_secret do cliente Desktop).' }
    return $c
}

function ConvertTo-PPEBase64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-PPERandomString([int]$ByteCount = 32) {
    $bytes = New-Object byte[] $ByteCount
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ConvertTo-PPEBase64Url $bytes
}

# Mensagem de erro legível a partir de uma resposta de erro da Google
function Get-PPEGoogleError($ErrorRecord) {
    $msg = $ErrorRecord.Exception.Message
    $detail = if ($ErrorRecord.ErrorDetails) { $ErrorRecord.ErrorDetails.Message } else { $null }
    # No PowerShell 5.1 o ErrorDetails vem muitas vezes vazio: ler o corpo da resposta
    if (-not $detail -and $ErrorRecord.Exception.Response) {
        try { $detail = (New-Object IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
    }
    if ($detail) {
        try {
            $j = $detail | ConvertFrom-Json
            if ($j.error.message) { return $j.error.message }
            if ($j.error_description) { return "$($j.error): $($j.error_description)" }
            if ($j.error) { return [string]$j.error }
        } catch { $msg += ' | ' + $detail }
    }
    return $msg
}

function Get-PPEGoogleAccount {
    if (-not (Test-Path -LiteralPath $script:PPE_TokenPath)) { return $null }
    $cred = Import-Clixml -LiteralPath $script:PPE_TokenPath
    [pscustomobject]@{ Email = $cred.UserName; RefreshToken = $cred.GetNetworkCredential().Password }
}

function Send-PPEHttpResponse($Stream, [int]$Status, [string]$Html) {
    $body = [Text.Encoding]::UTF8.GetBytes($Html)
    $reason = if ($Status -eq 200) { 'OK' } else { 'Not Found' }
    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

# Abre o browser para escolher a conta Google e guarda o token. Devolve o email.
function Connect-PPEGoogle([int]$TimeoutMinutes = 5) {
    $client = Get-PPEOAuthClient
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $redirect = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        $verifier = New-PPERandomString 32
        $challenge = ConvertTo-PPEBase64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
        $state = New-PPERandomString 16
        $query = @{
            client_id = $client.client_id; redirect_uri = $redirect; response_type = 'code'
            scope = ($script:PPE_Scopes -join ' '); code_challenge = $challenge; code_challenge_method = 'S256'
            state = $state; access_type = 'offline'; prompt = 'consent select_account'
        }
        $qs = ($query.GetEnumerator() | ForEach-Object { $_.Key + '=' + [Uri]::EscapeDataString($_.Value) }) -join '&'
        Start-Process "https://accounts.google.com/o/oauth2/v2/auth?$qs"

        # Espera pelo redirect do browser (ignora ligações sem código, ex.: favicon ou pré-ligações)
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $params = $null
        while (-not $params) {
            $accept = $listener.AcceptTcpClientAsync()
            while (-not $accept.Wait(500)) {
                if ((Get-Date) -gt $deadline) { throw 'Tempo esgotado à espera do login Google.' }
            }
            $tcp = $accept.Result
            try {
                $tcp.ReceiveTimeout = 5000
                $stream = $tcp.GetStream()
                $line = (New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)).ReadLine()
                if ($line -match '^GET /\?([^ ]*)') {
                    $p = @{}
                    foreach ($pair in $Matches[1] -split '&') {
                        $kv = $pair -split '=', 2
                        if ($kv.Count -eq 2) { $p[$kv[0]] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
                    }
                    if ($p.code -or $p.error) {
                        $ok = [bool]$p.code
                        $title = if ($ok) { 'Sessão iniciada' } else { 'Login cancelado' }
                        $text = if ($ok) { 'Já podes fechar esta janela e voltar ao instalador do PPEPlan.' } else { 'Volta ao instalador do PPEPlan para tentar outra vez.' }
                        Send-PPEHttpResponse $stream 200 "<!doctype html><meta charset=utf-8><title>PPEPlan</title><body style=`"font-family:Segoe UI,Arial;text-align:center;padding-top:80px;color:#1B1F2A`"><h2 style=`"color:#C73943`">$title</h2><p>$text</p></body>"
                        $params = $p
                        continue
                    }
                }
                Send-PPEHttpResponse $stream 404 ''
            }
            catch [IO.IOException] { }
            finally { $tcp.Close() }
        }
    }
    finally { $listener.Stop() }

    if ($params.error) { throw "Login Google recusado: $($params.error)" }
    if ($params.state -ne $state) { throw 'Resposta de login inválida (state não corresponde).' }

    try {
        $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
            code = $params.code; client_id = $client.client_id; client_secret = $client.client_secret
            redirect_uri = $redirect; grant_type = 'authorization_code'; code_verifier = $verifier
        }
    } catch { throw "Falhou a troca do código de login: $(Get-PPEGoogleError $_)" }

    # O ecrã de consentimento da Google deixa desmarcar permissões
    $granted = @(([string]$tok.scope) -split ' ')
    $missing = @($script:PPE_Scopes | Where-Object { $_ -like 'https://*' -and $granted -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Faltam permissões ($($missing -join ', ')). Repete o login e deixa todas as caixas marcadas."
    }
    if (-not $tok.refresh_token) { throw 'A Google não devolveu refresh token. Repete o login.' }

    $info = Invoke-RestMethod -Uri 'https://openidconnect.googleapis.com/v1/userinfo' -Headers @{ Authorization = "Bearer $($tok.access_token)" }
    $secure = ConvertTo-SecureString $tok.refresh_token -AsPlainText -Force
    New-Object Management.Automation.PSCredential($info.email, $secure) | Export-Clixml -LiteralPath $script:PPE_TokenPath

    $script:PPE_AccessToken = $tok.access_token
    $script:PPE_AccessTokenExpires = (Get-Date).AddSeconds([int]$tok.expires_in - 60)
    return $info.email
}

function Get-PPEAccessToken {
    if ($script:PPE_AccessToken -and (Get-Date) -lt $script:PPE_AccessTokenExpires) { return $script:PPE_AccessToken }
    $account = Get-PPEGoogleAccount
    if (-not $account) { throw 'Sem conta Google neste PC. Abre "PPEPlan - Mudar conta Google" no menu Iniciar.' }
    $client = Get-PPEOAuthClient
    try {
        $tok = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
            client_id = $client.client_id; client_secret = $client.client_secret
            refresh_token = $account.RefreshToken; grant_type = 'refresh_token'
        }
    }
    catch {
        $err = Get-PPEGoogleError $_
        if ($err -match 'invalid_grant') { throw 'A sessão Google expirou ou foi revogada. Abre "PPEPlan - Mudar conta Google" no menu Iniciar.' }
        throw "Falhou a renovação do login Google: $err"
    }
    $script:PPE_AccessToken = $tok.access_token
    $script:PPE_AccessTokenExpires = (Get-Date).AddSeconds([int]$tok.expires_in - 60)
    return $script:PPE_AccessToken
}

function Invoke-PPEGoogleApi {
    param([Parameter(Mandatory)] [string]$Uri, [string]$Method = 'Get', [string]$Json, [switch]$Raw)
    $req = @{ Uri = $Uri; Method = $Method; Headers = @{ Authorization = "Bearer $(Get-PPEAccessToken)" }; UseBasicParsing = $true }
    # Corpo em bytes UTF-8: o PowerShell 5.1 estraga acentos em corpos string
    if ($PSBoundParameters.ContainsKey('Json')) { $req.Body = [Text.Encoding]::UTF8.GetBytes($Json); $req.ContentType = 'application/json; charset=utf-8' }
    try { $r = Invoke-WebRequest @req }
    catch { throw "Google API ($Method $(([Uri]$Uri).AbsolutePath)): $(Get-PPEGoogleError $_)" }
    # Descodifica sempre como UTF-8 (o Drive devolve JSON sem charset)
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    if ($Raw) { return $text }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# ---------- Drive ----------

# O mais recente com esse nome (a app procura pelo mesmo nome)
function Find-PPEDriveFile([string]$Name) {
    $q = [Uri]::EscapeDataString("name='$Name' and trashed=false")
    $r = Invoke-PPEGoogleApi "https://www.googleapis.com/drive/v3/files?q=$q&orderBy=modifiedTime%20desc&fields=files(id,name,modifiedTime)"
    return @($r.files) | Select-Object -First 1
}

# Ficheiros de controlo da conta (ex.: registo de envios): manda o mais antigo.
# Se dois PCs o criaram ao mesmo tempo, os restantes vão para o lixo — senão
# cada PC ficava a ler o seu e o registo deixava de ser partilhado.
function Find-PPEDriveStateFile([string]$Name) {
    $q = [Uri]::EscapeDataString("name='$Name' and trashed=false")
    $r = Invoke-PPEGoogleApi "https://www.googleapis.com/drive/v3/files?q=$q&orderBy=createdTime&fields=files(id,name,createdTime)"
    $files = @($r.files)
    if ($files.Count -eq 0) { return $null }
    foreach ($extra in @($files | Select-Object -Skip 1)) {
        try {
            Invoke-PPEGoogleApi "https://www.googleapis.com/drive/v3/files/$($extra.id)" -Method Patch -Json '{"trashed":true}' | Out-Null
            Write-PPELog "$Name duplicado no Drive movido para o lixo ($($extra.id))"
        } catch { }
    }
    return $files[0]
}

function Read-PPEDriveText([string]$FileId) {
    Invoke-PPEGoogleApi "https://www.googleapis.com/drive/v3/files/$($FileId)?alt=media" -Raw
}

function Write-PPEDriveText([string]$Name, [string]$Text) {
    $file = Find-PPEDriveStateFile $Name
    if (-not $file) {
        $file = Invoke-PPEGoogleApi 'https://www.googleapis.com/drive/v3/files' -Method Post -Json (@{ name = $Name; mimeType = 'application/json' } | ConvertTo-Json)
    }
    Invoke-PPEGoogleApi "https://www.googleapis.com/upload/drive/v3/files/$($file.id)?uploadType=media" -Method Patch -Json $Text | Out-Null
}

# ---------- Gmail ----------

function Send-PPEGmail([string]$To, [string]$Subject, [string]$Html) {
    $from = (Get-PPEGoogleAccount).Email
    $b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
    $recipients = (@([string]$To -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join ', '
    if (-not $recipients) { throw 'Sem destinatário para o email.' }
    $body = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Html), [Base64FormattingOptions]::InsertLineBreaks)
    $mime = "From: =?UTF-8?B?$(& $b64 'PPEPlan')?= <$from>`r`n" +
            "To: $recipients`r`n" +
            "Subject: =?UTF-8?B?$(& $b64 $Subject)?=`r`n" +
            "MIME-Version: 1.0`r`n" +
            "Content-Type: text/html; charset=UTF-8`r`n" +
            "Content-Transfer-Encoding: base64`r`n`r`n" + $body
    $raw = ConvertTo-PPEBase64Url ([Text.Encoding]::ASCII.GetBytes($mime))
    Invoke-PPEGoogleApi 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send' -Method Post -Json (@{ raw = $raw } | ConvertTo-Json) | Out-Null
}
