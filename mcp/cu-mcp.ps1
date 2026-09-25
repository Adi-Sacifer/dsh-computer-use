# cu-mcp.ps1 - an MCP (stdio) server that wraps the existing computer-use toolkit cu.ps1.
#
# Why this exists: every direct `pwsh -File cu.ps1 <action>` costs ~2.4 s, almost all of it
# process start + the Add-Type compile of the P/Invoke block. PowerShell 7 dedupes an identical
# Add-Type inside one process (786 ms first time, ~3 ms after), so this server keeps ONE pwsh
# alive, loads cu.ps1 once, and then re-invokes the very same script in-process - same code,
# same behaviour, ~90-150 ms per action instead of ~2400 ms.
#
# Protocol: MCP over stdio, newline-delimited JSON-RPC 2.0. stdout carries protocol lines ONLY;
# every diagnostic goes to stderr and to the log file next to this script.
#
# Tools: one tool named `cu`, whose `action` mirrors cu.ps1's -Action, with the same optional
# arguments. `shot` additionally returns the screenshot as an MCP image block.

[CmdletBinding()]
param(
    [string]$CuPath = 'C:\Users\Administrator\.dsh\skills\computer-use\scripts\cu.ps1',
    [string]$LogPath = (Join-Path $PSScriptRoot 'cu-mcp.log'),
    [int]$MaxImageWidth = 1920,
    [int]$ImageByteCap = 1200000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
# First thing that happens: a raw append, so a boot that dies before the helpers exist still
# leaves a trace in the log (this cost one debug cycle when the harness-spawned instances
# vanished without a single log line).
try { Add-Content -LiteralPath $LogPath -Value ('[{0}] BOOT pid={1} host={2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $PID, $PSVersionTable.PSVersion) -Encoding UTF8 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# Input matters as much as output: the MCP client writes UTF-8, and without this the reader
# decoded it with the ANSI codepage, so a non-ASCII argument arrived as mojibake, the JSON
# failed to parse, and the caller waited for a reply that never came. Measured: that request
# died at the 90 s client timeout while the same call in ASCII returned in 218 ms, and the
# server log showed a `bad json: ...` line for the mangled payload.
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:Out = [Console]::Out
$script:In = [Console]::In

function Write-Log([string]$msg) {
    try {
        $line = ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $msg)
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine($line)
    } catch { }
}

function Send-Json($obj) {
    try {
        $json = $obj | ConvertTo-Json -Depth 20 -Compress
        Send-Reply $json
    } catch {
        Write-Log ("Send-Json failed: " + $_.Exception.Message)
    }
}

function Send-Result($id, $result) { Send-Json @{ jsonrpc = '2.0'; id = $id; result = $result } }
function Send-Error($id, [int]$code, [string]$message) {
    Send-Json @{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $message } }
}

# --------------------------------------------------------------------------- tool definitions
$actions = @('info','shot','cursor','move','click','drag','scroll','type','paste','key','windows','focus','clip','wtext','uia','wake','status','sleep','start','stop','fxon','fxoff','fxstatus')
$props = [ordered]@{
    dimPct = @{ type = 'integer'; minimum = 0; maximum = 100; description = 'Ambient edge opacity percent, default 10.' }
    dimAfter = @{ type = 'integer'; minimum = 0; description = 'Seconds before edges dim, default 6.' }
    action  = @{ type = 'string'; enum = $actions; description = 'start/stop own the CU task session. Work actions auto-start; fxstatus is a read-only probe. Use stop in task cleanup.' }
    x       = @{ type = 'integer'; description = 'Pointer/target X (physical pixel).' }
    y       = @{ type = 'integer'; description = 'Pointer/target Y (physical pixel).' }
    x1      = @{ type = 'integer'; description = 'drag start X.' }
    y1      = @{ type = 'integer'; description = 'drag start Y.' }
    x2      = @{ type = 'integer'; description = 'drag end X.' }
    y2      = @{ type = 'integer'; description = 'drag end Y.' }
    w       = @{ type = 'integer'; description = 'shot region width.' }
    h       = @{ type = 'integer'; description = 'shot region height.' }
    hwnd    = @{ type = 'integer'; description = 'Target window handle (preferred over title).' }
    title   = @{ type = 'string';  description = 'Target window title substring.' }
    path    = @{ type = 'string';  description = 'Output PNG path for shot.' }
    text    = @{ type = 'string';  description = 'Text for type/paste/clip/status, or settext payload for uia.' }
    keys    = @{ type = 'string';  description = 'Key chord, e.g. ctrl+s, enter, f5.' }
    button  = @{ type = 'string';  enum = @('left','right','middle'); description = 'Mouse button.' }
    double  = @{ type = 'boolean'; description = 'Double click.' }
    count   = @{ type = 'integer'; description = 'Click repeat count.' }
    amount  = @{ type = 'integer'; description = 'Wheel notches (negative scrolls down).' }
    mode    = @{ type = 'string';  enum = @('tree','find','click','settext','focus'); description = 'uia mode.' }
    name    = @{ type = 'string';  description = 'uia control name (substring).' }
    index   = @{ type = 'integer'; description = 'uia: which ranked match to act on (1-based).' }
    exact   = @{ type = 'boolean'; description = 'uia: require a whole-name match.' }
    depth   = @{ type = 'integer'; description = 'uia tree depth.' }
    all     = @{ type = 'boolean'; description = 'windows -All / uia tree -All.' }
    noWake  = @{ type = 'boolean'; description = 'uia: skip the accessibility wake.' }
    json    = @{ type = 'boolean'; description = 'windows: emit NDJSON.' }
    grid    = @{ type = 'integer'; description = 'shot: overlay a labelled coordinate grid.' }
    delayMs = @{ type = 'integer'; description = 'sleep delay, or type inter-key delay.' }
    state   = @{ type = 'string'; enum = @('busy','note','ok','err','done'); description = 'status chip state.' }
    noChip  = @{ type = 'boolean'; description = 'Suppress the activity chip for this call.' }
}
$tool = @{
    name        = 'cu'
    description = 'Windows desktop control (screenshot, mouse, keyboard, clipboard, window/UIA) via the cu.ps1 toolkit, served from one warm process. Coordinates are physical pixels on the 3840x2160 desktop. Returns the toolkit''s own report text; action=shot also returns the screenshot as an image.'
    inputSchema = @{ type = 'object'; properties = $props; required = @('action'); additionalProperties = $false }
}

# Warm only the API/types. MCP discovery/probes never start or kill visible UI.
$bootSw = [Diagnostics.Stopwatch]::StartNew()
$null = & $CuPath -Action cursor -NoChip *>&1 | Out-String
. (Join-Path (Split-Path -Parent $CuPath) 'cu-session.ps1')
Write-Log ('warm-up ok in {0:N0} ms (no UI; process reused for all calls)' -f $bootSw.Elapsed.TotalMilliseconds)

# ------------------------------------------------------------------------------ arg plumbing
# map JSON argument name -> cu.ps1 parameter name (same spelling, different case only)
$paramNames = @{
    action='Action'; x='X'; y='Y'; x1='X1'; y1='Y1'; x2='X2'; y2='Y2'; w='W'; h='H';
    hwnd='Hwnd'; title='Title'; path='Path'; text='Text'; keys='Keys'; button='Button';
    double='Double'; count='Count'; amount='Amount'; mode='Mode'; name='Name'; index='Index';
    exact='Exact'; depth='Depth'; all='All'; noWake='NoWake'; json='Json'; grid='Grid';
    dimPct='DimPct'; dimAfter='DimAfter'; delayMs='DelayMs'; state='State'; noChip='NoChip'; expect='Expect'
}
$switchNames = @('double','exact','all','noWake','json','noChip')

function Get-ImageBlock([string]$file) {
    try {
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $img = [System.Drawing.Image]::FromFile($file)
        try {
            $scale = [Math]::Min(1.0, $MaxImageWidth / [double]$img.Width)
            $nw = [int][Math]::Max(1, [Math]::Round($img.Width * $scale))
            $nh = [int][Math]::Max(1, [Math]::Round($img.Height * $scale))
            $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $nw, $nh)
            $g.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $mime = 'image/png'
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            if ($ms.Length -gt $ImageByteCap) {
                $ms.SetLength(0)
                $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
                if ($enc) {
                    $ps = New-Object System.Drawing.Imaging.EncoderParameters(1)
                    $ps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]88)
                    $bmp.Save($ms, $enc, $ps)
                    $mime = 'image/jpeg'
                }
            }
            $bmp.Dispose(); $ms.Dispose()
            $bytes = $ms.ToArray()
            return @{ type = 'image'; data = [Convert]::ToBase64String($bytes); mimeType = $mime }
        } finally { $img.Dispose() }
    } catch {
        Write-Log ('image block failed: ' + $_.Exception.Message)
        return $null
    }
}

function Invoke-CuAction($argObj) {
    # NB: do not name this parameter $args - PowerShell reserves that automatic variable and
    # the parameter silently never binds (cost one debug cycle).
    if ($null -eq $argObj) { throw 'arguments object is required' }
    $names = @($argObj.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'action') { throw 'arguments.action is required' }
    $p = @{}
    foreach ($n in $names) {
        if (-not $paramNames.ContainsKey($n)) { throw ("unknown argument: " + $n) }
        $v = $argObj.$n
        if ($null -eq $v) { continue }
        $pn = $paramNames[$n]
        if ($switchNames -contains $n) {
            if ([bool]$v) { $p[$pn] = $true }
        } elseif ($pn -eq 'Action') {
            $p['Action'] = [string]$v
        } else {
            $p[$pn] = $v
        }
    }
    $p['SessionOwnerPid'] = $PID
    if ($p['Action'] -eq 'shot' -and -not $p['Path']) { $p['Path'] = Join-Path $env:TEMP ('cu-shot-' + [guid]::NewGuid().ToString('N') + '.png') }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $text = & $CuPath @p *>&1 | Out-String
    $sw.Stop()
    return @{ text = $text.TrimEnd(); ms = [int]$sw.Elapsed.TotalMilliseconds; params = $p }
}

# ------------------------------------------------------------------------------- server loop
# Framing: MCP stdio is normally newline-delimited JSON, but the official SDK has shipped
# Content-Length framing too. Detect what the client uses, answer in the same style, and log
# every inbound line so a handshake failure is diagnosable instead of silent.
$script:Framing = 'line'

function Send-Reply([string]$json) {
    if ($script:Framing -eq 'content-length') {
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        $script:Out.Write('Content-Length: ' + $bytes + "`r`n`r`n" + $json)
    } else {
        $script:Out.Write($json + "`n")
    }
    $script:Out.Flush()
}

Write-Log ("cu-mcp listening (pid $PID)")
try {
while ($true) {
    $line = $null
    try { $line = $script:In.ReadLine() } catch { break }
    if ($null -eq $line) { break }
    $payload = $line.Trim()
    if ($payload -eq '') { continue }

    # Do not log typed text, clipboard contents or other argument payloads.

    # A malformed line must still get an ANSWER. Logging it and continuing - which is what this
    # did - leaves the client waiting for a response that never arrives: the caller sees a hang,
    # not an error, and the real cause (an undecodable argument) is invisible from the outside.
    $msg = $null
    try { $msg = $payload | ConvertFrom-Json } catch {
        Write-Log 'bad json (request payload omitted)'
        $idPart = 0
        if ($payload -match '"id"\s*:\s*(\d+)') { $idPart = [int]$Matches[1] }
        Send-Error $idPart -32700 'parse error: the request line was not valid JSON (check the server console encoding for non-ASCII arguments)'
        continue
    }
    if ($null -eq $msg.method) { continue }
    Write-Log ('request method=' + [string]$msg.method + ' id=' + [string]$msg.id)

    switch ([string]$msg.method) {
        'initialize' {
            $v = '2025-06-18'
            # Do not claim future revisions whose wire protocol this server does not implement.
            Send-Result $msg.id @{
                protocolVersion = $v
                capabilities    = @{ tools = @{ listChanged = $false } }
                serverInfo      = @{ name = 'cu'; version = '2.0.0' }
                instructions    = 'Prefer the target application MCP tools when available. For desktop fallback, use this persistent cu tool directly, never launch PowerShell per screenshot or use cu-batch when this tool is available. action=start begins a task; GUI actions auto-start the session too. One overlay and bottom progress pill follow the session; edges dim after six seconds. Post status text for task phases. Always call action=stop when CU finishes, fails or is cancelled. status state=done also stops both. Repeated start is idempotent. shot returns an image even without path; coordinates are physical screen pixels, not downscaled preview pixels.'
            }
        }
        'notifications/initialized' { }
        'notifications/cancelled'   { }
        'ping'                      { Send-Result $msg.id @{} }
        'tools/list'                { Send-Result $msg.id @{ tools = @($tool) } }
        'resources/list'            { Send-Result $msg.id @{ resources = @() } }
        'resources/templates/list'  { Send-Result $msg.id @{ resourceTemplates = @() } }
        'prompts/list'              { Send-Result $msg.id @{ prompts = @() } }
        'tools/call' {
            $id = $msg.id
            $name = [string]$msg.params.name
            if ($name -ne 'cu') { Send-Error $id -32602 ("unknown tool: " + $name); break }
            try {
                $r = Invoke-CuAction $msg.params.arguments
                $blocks = @()
                $rt = [string]$r.text
                if ($rt.Length -gt 0) { $blocks += @{ type = 'text'; text = $rt } }
                if ($r.params['Action'] -eq 'shot') {
                    $img = Get-ImageBlock ([string]$r.params['Path'])
                    if ($img) { $blocks += $img } else { $blocks += @{ type = 'text'; text = '(screenshot file was not readable; check the path above)' } }
                }
                if ($blocks.Count -eq 0) { $blocks += @{ type = 'text'; text = '(no output)' } }
                Send-Result $id @{ content = $blocks }
                Write-Log ("cu {0} -> {1} ms, {2} bytes" -f $r.params['Action'], $r.ms, $rt.Length)
            } catch {
                $m = $_.Exception.Message
                Write-Log ('call failed: ' + $m)
                Send-Result $id @{ content = @(@{ type = 'text'; text = ('ERROR: ' + $m) }); isError = $true }
            }
        }
        default {
            if ($msg.id) { Send-Error $msg.id -32601 ('method not found: ' + [string]$msg.method) }
        }
    }
}
} finally {
    Stop-CuSession -OwnOnly
    Write-Log 'stdin closed - session cleaned up'
}
