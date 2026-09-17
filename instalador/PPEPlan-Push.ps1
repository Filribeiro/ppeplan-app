# ============================================================
#  PPEPlan — notificações no telemóvel (Web Push)
#  A app, num telemóvel Android, subscreve as notificações e guarda a
#  subscrição em ppeplan-push.json no Drive (com as chaves VAPID da conta).
#  O PC que envia o email envia também a notificação para cada dispositivo:
#  mensagem encriptada (RFC 8291, aes128gcm) e assinada com VAPID (RFC 8292).
#
#  O .NET Framework do PowerShell 5.1 não tem AES-GCM nem ECDH "raw": vão
#  implementados abaixo (validados com o exemplo do RFC 8291, Anexo A).
#
#  ppeplan-push.json:
#  { "vapid": { "publicKey": "<b64url 65 bytes>", "privateKey": "<b64url 32 bytes>" },
#    "dispositivos": [ { id, nome, endpoint, p256dh, auth, criado, ultimoEnvio, ultimoErro } ],
#    "testePedido": "<iso>" }
# ============================================================

if (-not ('PPEWebPush' -as [type])) {
    Add-Type -ReferencedAssemblies System.Numerics -TypeDefinition @'
using System;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

public static class PPEWebPush
{
    // ---------- P-256 ----------
    static readonly BigInteger P  = Hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF");
    static readonly BigInteger N  = Hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
    static readonly BigInteger B  = Hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B");
    static readonly BigInteger Gx = Hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296");
    static readonly BigInteger Gy = Hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5");

    static BigInteger Hex(string h) { return BigInteger.Parse("0" + h, System.Globalization.NumberStyles.HexNumber); }
    static BigInteger Mod(BigInteger x) { x = x % P; return x.Sign < 0 ? x + P : x; }
    static BigInteger Inv(BigInteger x) { return BigInteger.ModPow(Mod(x), P - 2, P); }

    static BigInteger FromBytes(byte[] be, int offset, int len)
    {
        byte[] le = new byte[len + 1];
        for (int i = 0; i < len; i++) le[i] = be[offset + len - 1 - i];
        return new BigInteger(le);
    }
    static byte[] ToBytes32(BigInteger v)
    {
        byte[] le = v.ToByteArray();
        byte[] be = new byte[32];
        for (int i = 0; i < 32 && i < le.Length; i++) be[31 - i] = le[i];
        return be;
    }

    // Pontos em coordenadas afins; null = ponto no infinito
    static BigInteger[] Add(BigInteger[] a, BigInteger[] b)
    {
        if (a == null) return b;
        if (b == null) return a;
        BigInteger l;
        if (a[0] == b[0])
        {
            if (Mod(a[1] + b[1]).IsZero) return null;
            l = Mod(3 * a[0] * a[0] - 3) * Inv(2 * a[1]);
        }
        else l = Mod(b[1] - a[1]) * Inv(b[0] - a[0]);
        l = Mod(l);
        BigInteger x = Mod(l * l - a[0] - b[0]);
        return new BigInteger[] { x, Mod(l * (a[0] - x) - a[1]) };
    }
    static BigInteger[] Mul(BigInteger k, BigInteger[] pt)
    {
        BigInteger[] r = null;
        for (int i = 256; i >= 0; i--)
        {
            r = Add(r, r);
            if (((k >> i) & 1) == 1) r = Add(r, pt);
        }
        return r;
    }
    static BigInteger[] Decode(byte[] pub)
    {
        if (pub == null || pub.Length != 65 || pub[0] != 4) throw new ArgumentException("Chave pública P-256 inválida");
        BigInteger x = FromBytes(pub, 1, 32), y = FromBytes(pub, 33, 32);
        if (x >= P || y >= P || Mod(y * y - (x * x * x - 3 * x + B)) != 0) throw new ArgumentException("Chave pública fora da curva P-256");
        return new BigInteger[] { x, y };
    }
    static byte[] Encode(BigInteger[] pt)
    {
        byte[] r = new byte[65];
        r[0] = 4;
        Buffer.BlockCopy(ToBytes32(pt[0]), 0, r, 1, 32);
        Buffer.BlockCopy(ToBytes32(pt[1]), 0, r, 33, 32);
        return r;
    }
    public static byte[] PublicKeyOf(byte[] privateKey)
    {
        return Encode(Mul(FromBytes(privateKey, 0, 32), new BigInteger[] { Gx, Gy }));
    }
    static byte[] NewPrivateKey()
    {
        byte[] d = new byte[32];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
        {
            while (true)
            {
                rng.GetBytes(d);
                BigInteger v = FromBytes(d, 0, 32);
                if (!v.IsZero && v < N) return d;
            }
        }
    }

    // ---------- AES-128-GCM (NIST SP 800-38D) sobre AES-ECB ----------
    static void GfMul(ref ulong xh, ref ulong xl, ulong yh, ulong yl)
    {
        ulong zh = 0, zl = 0, vh = yh, vl = yl;
        for (int i = 0; i < 128; i++)
        {
            ulong bit = i < 64 ? (xh >> (63 - i)) & 1 : (xl >> (127 - i)) & 1;
            if (bit == 1) { zh ^= vh; zl ^= vl; }
            bool lsb = (vl & 1) == 1;
            vl = (vl >> 1) | ((vh & 1) << 63);
            vh >>= 1;
            if (lsb) vh ^= 0xE100000000000000UL;
        }
        xh = zh; xl = zl;
    }
    static ulong Be64(byte[] b, int o)
    {
        ulong v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | b[o + i];
        return v;
    }
    static void PutBe64(byte[] b, int o, ulong v)
    {
        for (int i = 7; i >= 0; i--) { b[o + i] = (byte)v; v >>= 8; }
    }
    public static byte[] AesGcmEncrypt(byte[] key, byte[] nonce, byte[] plain)
    {
        using (Aes aes = Aes.Create())
        {
            aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None; aes.Key = key;
            using (ICryptoTransform enc = aes.CreateEncryptor())
            {
                byte[] h = new byte[16];
                enc.TransformBlock(new byte[16], 0, 16, h, 0);
                ulong hh = Be64(h, 0), hl = Be64(h, 8);

                byte[] counter = new byte[16];
                Buffer.BlockCopy(nonce, 0, counter, 0, 12);
                counter[15] = 1;
                byte[] ekj0 = new byte[16];
                enc.TransformBlock(counter, 0, 16, ekj0, 0);

                byte[] output = new byte[plain.Length + 16];
                byte[] ks = new byte[16];
                ulong gh = 0, gl = 0;
                byte[] block = new byte[16];
                for (int off = 0; off < plain.Length; off += 16)
                {
                    for (int i = 15; i >= 12; i--) { if (++counter[i] != 0) break; }
                    enc.TransformBlock(counter, 0, 16, ks, 0);
                    int n = Math.Min(16, plain.Length - off);
                    Array.Clear(block, 0, 16);
                    for (int i = 0; i < n; i++) { output[off + i] = (byte)(plain[off + i] ^ ks[i]); block[i] = output[off + i]; }
                    gh ^= Be64(block, 0); gl ^= Be64(block, 8);
                    GfMul(ref gh, ref gl, hh, hl);
                }
                // Blocos de comprimento: AAD vazio, texto cifrado em bits
                gl ^= (ulong)plain.Length * 8;
                GfMul(ref gh, ref gl, hh, hl);
                byte[] tag = new byte[16];
                PutBe64(tag, 0, gh); PutBe64(tag, 8, gl);
                for (int i = 0; i < 16; i++) output[plain.Length + i] = (byte)(tag[i] ^ ekj0[i]);
                return output;
            }
        }
    }

    // ---------- RFC 8291 ----------
    static byte[] Hmac(byte[] key, params byte[][] parts)
    {
        using (HMACSHA256 h = new HMACSHA256(key))
        {
            int len = 0;
            foreach (byte[] p in parts) len += p.Length;
            byte[] all = new byte[len];
            int o = 0;
            foreach (byte[] p in parts) { Buffer.BlockCopy(p, 0, all, o, p.Length); o += p.Length; }
            return h.ComputeHash(all);
        }
    }
    static byte[] Take(byte[] b, int n) { byte[] r = new byte[n]; Buffer.BlockCopy(b, 0, r, 0, n); return r; }

    public static byte[] Encrypt(byte[] plaintext, byte[] uaPublic, byte[] authSecret)
    {
        byte[] salt = new byte[16];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
        return Encrypt(plaintext, uaPublic, authSecret, NewPrivateKey(), salt);
    }

    // asPrivate e salt fixos só nos testes (RFC 8291, Anexo A)
    public static byte[] Encrypt(byte[] plaintext, byte[] uaPublic, byte[] authSecret, byte[] asPrivate, byte[] salt)
    {
        BigInteger[] ua = Decode(uaPublic);
        byte[] asPublic = PublicKeyOf(asPrivate);
        BigInteger[] shared = Mul(FromBytes(asPrivate, 0, 32), ua);
        byte[] ecdhSecret = ToBytes32(shared[0]);

        byte[] prkKey = Hmac(authSecret, ecdhSecret);
        byte[] ikm = Hmac(prkKey, Encoding.ASCII.GetBytes("WebPush: info\0"), uaPublic, asPublic, new byte[] { 1 });
        byte[] prk = Hmac(salt, ikm);
        byte[] cek = Take(Hmac(prk, Encoding.ASCII.GetBytes("Content-Encoding: aes128gcm\0"), new byte[] { 1 }), 16);
        byte[] nonce = Take(Hmac(prk, Encoding.ASCII.GetBytes("Content-Encoding: nonce\0"), new byte[] { 1 }), 12);

        // Um único registo: conteúdo + delimitador 0x02
        byte[] padded = new byte[plaintext.Length + 1];
        Buffer.BlockCopy(plaintext, 0, padded, 0, plaintext.Length);
        padded[plaintext.Length] = 2;
        byte[] cipher = AesGcmEncrypt(cek, nonce, padded);

        int rs = 4096;
        if (cipher.Length > rs) throw new ArgumentException("Notificação demasiado grande");
        byte[] body = new byte[16 + 4 + 1 + 65 + cipher.Length];
        Buffer.BlockCopy(salt, 0, body, 0, 16);
        body[16] = (byte)(rs >> 24); body[17] = (byte)(rs >> 16); body[18] = (byte)(rs >> 8); body[19] = (byte)rs;
        body[20] = 65;
        Buffer.BlockCopy(asPublic, 0, body, 21, 65);
        Buffer.BlockCopy(cipher, 0, body, 86, cipher.Length);
        return body;
    }

    // ---------- VAPID (RFC 8292): JWT ES256 ----------
    public static string B64Url(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
    public static byte[] FromB64Url(string s)
    {
        s = s.Trim().Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; }
        return Convert.FromBase64String(s);
    }

    public static string VapidJwt(string audience, string subject, long expUnix, byte[] privateKey, byte[] publicKey)
    {
        string header = B64Url(Encoding.UTF8.GetBytes("{\"typ\":\"JWT\",\"alg\":\"ES256\"}"));
        string claims = B64Url(Encoding.UTF8.GetBytes("{\"aud\":\"" + audience + "\",\"exp\":" + expUnix + ",\"sub\":\"" + subject + "\"}"));
        byte[] input = Encoding.ASCII.GetBytes(header + "." + claims);

        // BCRYPT_ECCKEY_BLOB: "ECS2", 32, X, Y, D
        byte[] blob = new byte[8 + 96];
        Buffer.BlockCopy(BitConverter.GetBytes(0x32534345), 0, blob, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(32), 0, blob, 4, 4);
        Buffer.BlockCopy(publicKey, 1, blob, 8, 64);
        Buffer.BlockCopy(privateKey, 0, blob, 72, 32);
        using (CngKey key = CngKey.Import(blob, CngKeyBlobFormat.EccPrivateBlob))
        using (ECDsaCng dsa = new ECDsaCng(key))
        {
            dsa.HashAlgorithm = CngAlgorithm.Sha256;
            // ECDsaCng devolve r||s (64 bytes), o formato que o JWT usa
            return header + "." + claims + "." + B64Url(dsa.SignData(input));
        }
    }
}
'@
}

# ---------- Ficheiro de dispositivos no Drive ----------

function Get-PPEPushFile {
    $file = Find-PPEDriveStateFile $script:PPE_PushFileName
    if (-not $file) { return $null }
    $text = Read-PPEDriveText $file.id
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# Reescreve só os campos de envio dos dispositivos (e o que vier em $Extra),
# relendo o ficheiro antes: a app pode ter acrescentado um dispositivo entretanto.
function Save-PPEPushResults([hashtable]$Results, [string[]]$Remove = @(), [hashtable]$Extra = @{}) {
    $push = Get-PPEPushFile
    if (-not $push) { return }
    $devices = @($push.dispositivos | Where-Object { $_ -and $Remove -notcontains $_.id })
    foreach ($d in $devices) {
        if (-not $Results.ContainsKey([string]$d.id)) { continue }
        $r = $Results[[string]$d.id]
        foreach ($k in $r.Keys) { $d | Add-Member -NotePropertyName $k -NotePropertyValue $r[$k] -Force }
    }
    $push | Add-Member -NotePropertyName dispositivos -NotePropertyValue @($devices) -Force
    foreach ($k in $Extra.Keys) { $push | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force }
    Write-PPEDriveText $script:PPE_PushFileName ($push | ConvertTo-Json -Depth 6)
}

# ---------- Envio ----------

# Devolve o código HTTP (201 = entregue ao serviço de push)
function Send-PPEPushMessage($Device, $Vapid, [string]$Json, [string]$Subject, [int]$TtlSeconds = 43200) {
    $private = [PPEWebPush]::FromB64Url([string]$Vapid.privateKey)
    $public  = [PPEWebPush]::FromB64Url([string]$Vapid.publicKey)
    $body = [PPEWebPush]::Encrypt([Text.Encoding]::UTF8.GetBytes($Json),
        [PPEWebPush]::FromB64Url([string]$Device.p256dh), [PPEWebPush]::FromB64Url([string]$Device.auth))

    $uri = [Uri][string]$Device.endpoint
    if ($uri.Scheme -ne 'https') { throw 'Endpoint de push inválido' }
    $exp = [DateTimeOffset]::UtcNow.AddHours(12).ToUnixTimeSeconds()
    $jwt = [PPEWebPush]::VapidJwt("$($uri.Scheme)://$($uri.Authority)", $Subject, $exp, $private, $public)

    $req = [Net.HttpWebRequest]::Create($uri)
    $req.Method = 'POST'
    $req.Timeout = 30000
    $req.ContentType = 'application/octet-stream'
    $req.Headers.Add('Content-Encoding', 'aes128gcm')
    $req.Headers.Add('TTL', [string]$TtlSeconds)
    # "high": o Android entrega logo, mesmo com o telemóvel em repouso
    $req.Headers.Add('Urgency', 'high')
    $req.Headers.Add('Authorization', "vapid t=$jwt, k=$($Vapid.publicKey)")
    $req.ContentLength = $body.Length
    $stream = $req.GetRequestStream()
    try { $stream.Write($body, 0, $body.Length) } finally { $stream.Close() }
    try {
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return [pscustomobject]@{ Code = $code; Detail = '' }
    }
    catch [Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $detail = ''
        try { $detail = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
        $code = [int]$resp.StatusCode
        $resp.Close()
        return [pscustomobject]@{ Code = $code; Detail = $detail }
    }
}

# Envia { title, body, tag, url } a todos os dispositivos. Devolve quantos receberam.
# Subscrições que o serviço de push dá como terminadas (404/410) saem da lista.
function Send-PPEPush([string]$Title, [string]$Body, [string]$Tag = 'ppeplan', [string]$Url = '', [hashtable]$Extra = @{}) {
    $push = Get-PPEPushFile
    $devices = @(if ($push) { $push.dispositivos | Where-Object { $_ -and $_.endpoint } })
    if ($devices.Count -eq 0 -or -not $push.vapid -or -not $push.vapid.privateKey) {
        if ($Extra.Count -gt 0 -and $push) { Save-PPEPushResults @{} @() $Extra }
        return 0
    }

    # O corpo encriptado tem de caber num registo de 4096 bytes
    $maxBody = 3000
    while ([Text.Encoding]::UTF8.GetByteCount($Body) -gt $maxBody) {
        $cut = $Body.LastIndexOf("`n", [Math]::Max(0, $Body.Length - 2))
        $Body = if ($cut -gt 0) { $Body.Substring(0, $cut) + "`n…" } else { $Body.Substring(0, [Math]::Min($Body.Length, 1000)) + '…' }
    }
    $json = @{ title = $Title; body = $Body; tag = $Tag; url = $Url } | ConvertTo-Json -Compress
    $subject = "mailto:$((Get-PPEGoogleAccount).Email)"

    $results = @{}; $remove = @(); $ok = 0
    $now = [DateTime]::UtcNow.ToString('o')
    foreach ($d in $devices) {
        try {
            $r = Send-PPEPushMessage $d $push.vapid $json $subject
            if ($r.Code -ge 200 -and $r.Code -lt 300) {
                $ok++
                $results[[string]$d.id] = @{ ultimoEnvio = $now; ultimoErro = '' }
            }
            elseif ($r.Code -eq 404 -or $r.Code -eq 410) {
                $remove += [string]$d.id
                Write-PPELog "Push: $($d.nome) já não está subscrito ($($r.Code)), removido"
            }
            else {
                $msg = "HTTP $($r.Code) $($r.Detail)".Trim()
                if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
                $results[[string]$d.id] = @{ ultimoErro = "$now $msg" }
                Write-PPELog "Push: falhou para $($d.nome): $msg"
            }
        }
        catch {
            $results[[string]$d.id] = @{ ultimoErro = "$now $($_.Exception.Message)" }
            Write-PPELog "Push: falhou para $($d.nome): $($_.Exception.Message)"
        }
    }
    try { Save-PPEPushResults $results $remove $Extra }
    catch { Write-PPELog "Aviso: não foi possível registar os envios push no Drive: $($_.Exception.Message)" }
    return $ok
}

# "Enviar teste" nas Definições da app grava testePedido no ficheiro; o primeiro
# PC ligado marca-o como tratado e envia. Pedidos com mais de 30 min já não saem.
function Invoke-PPEPushTest($Push, $Config) {
    $pedido = [string]$Push.testePedido
    if (-not $pedido -or [string]$Push.testeEnviado -eq $pedido) { return }
    try { $idade = ([DateTime]::UtcNow - (ConvertFrom-PPEUtcText $pedido)).TotalMinutes } catch { return }
    $me = (Get-PPEInstallId).Name
    Save-PPEPushResults @{} @() @{ testeEnviado = $pedido; testeEnviadoPor = $me }
    if ($idade -gt 30) { return }
    $sent = Send-PPEPush -Title 'PPEPlan — notificação de teste' `
        -Body "Se estás a ler isto, os resumos da manhã e do fim do dia vão chegar a este telemóvel.`nEnviada pelo PC $me." `
        -Tag 'teste' -Url ([string]$Config.appUrl)
    Write-PPELog "Push de teste enviado para $sent dispositivo(s)"
}
