<#
.SYNOPSIS
    Bootstrapper for Scrap Mechanic Survival mods that need to extend vanilla data files.

.DESCRIPTION
    Scrap Mechanic Survival mods sometimes need to register content in shared vanilla files
    such as shapesets.json, RecipeManager.lua or the inventory icon atlas. If every mod ships
    its own installer and edits those files independently, mods can overwrite each other.

    This bootstrapper solves that by treating each participating mod as declarative input:
    every mod contains a bootstrap.json describing the files and registrations it needs.

    On each launch the bootstrapper:

      1. Detects the installed Scrap Mechanic version
      2. Creates or restores a version-specific vanilla baseline for the shared files
      3. Discovers all bootstrap.json manifests in the configured mod roots
      4. Checks resource claims such as UUIDs for collisions
      5. Applies all operations in a deterministic order
      6. Allocates icon-atlas slots centrally
      7. Invalidates Cache\Bundle\core_data.cbo when the generated result changed
      8. Starts Scrap Mechanic unless -NoLaunch was specified

    IMPORTANT:
    The Backup-<version> directory must be created from a clean Steam-verified installation.
    Never delete Scrap Mechanic's complete Cache directory. Only core_data.cbo is intentionally
    invalidated by this bootstrapper.

.NOTES
    Designed for Windows PowerShell 5.1 compatibility.
#>

param(
    [string]$GamePath,
    [switch]$NoLaunch,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$GameCommand
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Log([string]$s) { Write-Host "[SM bootstrap] $s" }
function HashFile([string]$p) { if(Test-Path -LiteralPath $p){ (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } else { $null } }
function EnsureDir([string]$p) { if($p -and !(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Full([string]$base,[string]$rel) { [IO.Path]::GetFullPath((Join-Path $base ($rel -replace '/','\'))) }

# Scrap Mechanic uses JSON files containing // and /* ... */ comments.
# Windows PowerShell 5.1 ConvertFrom-Json cannot parse those comments, so they
# are stripped before parsing. The implementation preserves comment markers
# occurring inside quoted JSON strings.
function Remove-SmJsonComments([string]$text) {
    $sb = New-Object Text.StringBuilder
    $inString = $false; $escaped = $false; $lineComment = $false; $blockComment = $false
    for($i=0; $i -lt $text.Length; $i++) {
        $c=$text[$i]; $n=if($i+1 -lt $text.Length){$text[$i+1]}else{[char]0}
        if($lineComment) { if($c -eq "`r" -or $c -eq "`n"){ $lineComment=$false; [void]$sb.Append($c) }; continue }
        if($blockComment) { if($c -eq '*' -and $n -eq '/'){ $blockComment=$false; $i++ } elseif($c -eq "`r" -or $c -eq "`n"){[void]$sb.Append($c)}; continue }
        if($inString) {
            [void]$sb.Append($c)
            if($escaped){$escaped=$false} elseif($c -eq '\\'){$escaped=$true} elseif($c -eq '"'){$inString=$false}
            continue
        }
        if($c -eq '"'){ $inString=$true; [void]$sb.Append($c); continue }
        if($c -eq '/' -and $n -eq '/'){ $lineComment=$true; $i++; continue }
        if($c -eq '/' -and $n -eq '*'){ $blockComment=$true; $i++; continue }
        [void]$sb.Append($c)
    }
    $sb.ToString()
}
# Read Scrap Mechanic JSON through the comment-tolerant parser above.
function Read-SmJson([string]$p) {
    if(!(Test-Path -LiteralPath $p)){ throw "JSON file not found: $p" }
    $raw=[IO.File]::ReadAllText($p)
    try { (Remove-SmJsonComments $raw) | ConvertFrom-Json }
    catch { throw "Invalid Scrap Mechanic JSON '$p': $($_.Exception.Message)" }
}

if(!$GamePath -and $GameCommand -and $GameCommand.Count -gt 0) {
    $candidate = $GameCommand[0].Trim('"')
    if(Test-Path -LiteralPath $candidate) { $GamePath = Split-Path -Parent $candidate }
}
if(!$GamePath) {
    $default = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Scrap Mechanic"
    if(Test-Path -LiteralPath $default){ $GamePath=$default }
}
if(!$GamePath -or !(Test-Path -LiteralPath (Join-Path $GamePath 'Release\ScrapMechanic.exe'))) {
    throw "Scrap Mechanic executable not found: $(Join-Path $GamePath 'Release\ScrapMechanic.exe')"
}

$LogFile = Join-Path $PSScriptRoot 'bootstrapper.log'
try {
    Start-Transcript -LiteralPath $LogFile -Append | Out-Null
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host "[SM bootstrap] Started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "[SM bootstrap] GamePath: $GamePath"
} catch {
    Write-Warning "Could not start bootstrapper log: $($_.Exception.Message)"
}



$GamePath = (Resolve-Path -LiteralPath $GamePath).Path

# Use the executable's file version as the baseline namespace.
$exePath = Join-Path $GamePath 'Release\ScrapMechanic.exe'
$versionInfo = (Get-Item -LiteralPath $exePath).VersionInfo
$gameVersion = $versionInfo.ProductVersion
if([string]::IsNullOrWhiteSpace($gameVersion)){ $gameVersion = $versionInfo.FileVersion }
if([string]::IsNullOrWhiteSpace($gameVersion)){ throw "Could not determine Scrap Mechanic version from $exePath" }
$gameVersion = ($gameVersion -split '\s')[0]
$gameVersionSafe = $gameVersion -replace '[^0-9A-Za-z._-]','_'

$backupRoot = Join-Path $PSScriptRoot ("Backup-" + $gameVersionSafe)

# Only files which are merge targets need a vanilla baseline.
# New files/directories supplied by mods are copied fresh by the operations themselves.
$baselineTargets = @(
    'Survival\Objects\Database\shapesets.json',
    'Survival\Gui\Language\English\inventoryDescriptions.json',
    'Survival\Gui\Language\German\inventoryDescriptions.json',
    'Survival\CraftingRecipes\craftbot\craftbot_pipes.json',
    'Survival\Scripts\game\managers\RecipeManager.lua',
    'Survival\Gui\IconMapSurvival.xml',
    'Survival\Gui\IconMapSurvival.png'
)

Log "Scrap Mechanic version: $gameVersion"

if(!(Test-Path -LiteralPath $backupRoot)) {
    Log "Creating vanilla baseline: $backupRoot"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach($rel in $baselineTargets) {
        $src = Join-Path $GamePath $rel
        if(!(Test-Path -LiteralPath $src)){ throw "Baseline target not found: $src" }
        $dst = Join-Path $backupRoot $rel
        $parent = Split-Path -Parent $dst
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Log "Backed up: $rel"
    }
    Set-Content -LiteralPath (Join-Path $backupRoot 'version.txt') -Value $gameVersion -Encoding ASCII
} else {
    Log "Restoring vanilla merge targets from: $backupRoot"
    foreach($rel in $baselineTargets) {
        $src = Join-Path $backupRoot $rel
        if(!(Test-Path -LiteralPath $src)){ throw "Baseline file missing: $src" }
        $dst = Join-Path $GamePath $rel
        $parent = Split-Path -Parent $dst
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}


# PowerShell 5.1-safe dynamic property access for PSCustomObject values.
function GetProp($Object, [string]$Name, $Default=$null) {
    if($null -eq $Object){ return $Default }
    $prop = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if($prop.Count -eq 0){ return $Default }
    return $prop[0].Value
}


# Serialize a modified JSON object back to disk as UTF-8 without BOM.
# Formatting/comments of generated target files are not preserved; the versioned
# baseline is restored before the next merge.
function SaveJson([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if(!(Test-Path -LiteralPath $parent)){
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}


function EnsureParent([string]$Path) {
    $parent = Split-Path -Parent $Path
    if($parent -and !(Test-Path -LiteralPath $parent)){
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}


function WriteUtf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if($parent -and !(Test-Path -LiteralPath $parent)){
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Mod discovery
# ---------------------------------------------------------------------------
# Search the supported mod roots for bootstrap.json. A manifest is deliberately
# kept inside the mod so the bootstrapper does not need hard-coded knowledge of
# individual mods.
# Discover manifests: Workshop, local user mods, and folders next to this bootstrapper.
$roots = New-Object System.Collections.Generic.List[string]
$steamapps = Split-Path -Parent (Split-Path -Parent $GamePath)
$workshop = Join-Path $steamapps 'workshop\content\387990'
if(Test-Path $workshop){ $roots.Add($workshop) }
$userRoot=Join-Path $env:APPDATA 'Axolot Games\Scrap Mechanic\User'
if(Test-Path $userRoot){ Get-ChildItem $userRoot -Directory -Filter 'User_*' | ForEach-Object { $m=Join-Path $_.FullName 'Mods'; if(Test-Path $m){$roots.Add($m)} } }
$roots.Add((Split-Path -Parent $PSScriptRoot))

$manifestFiles=@()
foreach($root in $roots | Select-Object -Unique){
    Get-ChildItem -LiteralPath $root -Filter bootstrap.json -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $manifestFiles += $_.FullName }
}
$manifestFiles=$manifestFiles | Select-Object -Unique
$mods=@()
foreach($mf in $manifestFiles){
    try { $m=Get-Content $mf -Raw | ConvertFrom-Json; if($m.schemaVersion -eq 1 -and $m.operations){ $mods += [pscustomobject]@{Root=(Split-Path -Parent $mf); Manifest=$m; File=$mf} } }
    catch { throw "Invalid manifest $mf : $($_.Exception.Message)" }
}
Log "Found $($mods.Count) bootstrap mod(s)."

# Claims make collisions explicit instead of silently overwriting each other.
$claims=@{}
foreach($mod in $mods){ foreach($c in @($mod.Manifest.claims)){ if($claims.ContainsKey($c)){ throw "Collision: '$c' claimed by '$($claims[$c])' and '$($mod.Manifest.name)'" }; $claims[$c]=$mod.Manifest.name } }

# File-copy collisions are allowed only when bytes are identical.
$copyClaims=@{}
function CopyOne([string]$src,[string]$dst,[string]$modName){
    if(!(Test-Path $src)){ throw "Missing source: $src" }
    $h=HashFile $src
    if($copyClaims.ContainsKey($dst) -and $copyClaims[$dst].Hash -ne $h){ throw "File collision at $dst between '$($copyClaims[$dst].Mod)' and '$modName'" }
    $copyClaims[$dst]=@{Hash=$h;Mod=$modName}
    EnsureDir (Split-Path -Parent $dst); Copy-Item -LiteralPath $src -Destination $dst -Force
}

foreach($mod in $mods){
    $name=$mod.Manifest.name; Log "Applying $name"
    foreach($op in $mod.Manifest.operations){
        switch($op.type){
            # Copy one mod-owned file into the Survival tree.
        'copy' { CopyOne (Full $mod.Root $op.source) (Full $GamePath $op.target) $name }
            # Copy a complete mod-owned asset directory (meshes, textures, renderables, ...).
        'copyTree' {
                $srcRoot=Full $mod.Root $op.source; $dstRoot=Full $GamePath $op.target
                Get-ChildItem -LiteralPath $srcRoot -File -Recurse | ForEach-Object { $rel=$_.FullName.Substring($srcRoot.Length).TrimStart('\'); CopyOne $_.FullName (Join-Path $dstRoot $rel) $name }
            }
            # Append one value to a JSON array, rejecting a conflicting duplicate.
        'jsonArrayAdd' {
                $dst=Full $GamePath $op.target; $j=Read-SmJson $dst; $arr=@(GetProp $j $op.path); if($arr -notcontains $op.value){ $arr += $op.value; $j.($op.path)=$arr }; SaveJson $dst $j
            }
            # Merge object properties from a mod JSON file into a shared vanilla JSON object.
        'jsonObjectMergeFile' {
                $dst=Full $GamePath $op.target; $j=Read-SmJson $dst; $add=Read-SmJson (Full $mod.Root $op.source)
                foreach($p in $add.PSObject.Properties){
        if($j.PSObject.Properties.Name -contains $p.Name){
            $existing=$j.PSObject.Properties[$p.Name].Value|ConvertTo-Json -Depth 50 -Compress
            $incoming=$p.Value|ConvertTo-Json -Depth 50 -Compress
            if($existing -eq $incoming){ Write-Host "[SM bootstrap] Already applied JSON key $($p.Name)"; continue }
            throw "JSON key collision '$($p.Name)' in $dst (different content)"
        }
        $j|Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
    }
                SaveJson $dst $j
            }
            # Merge keyed recipe-style objects into a shared vanilla JSON array.
        'jsonArrayMergeFile' {
                $dst=Full $GamePath $op.target; $j=@((Read-SmJson $dst) | ForEach-Object { $_ }); $add=@((Read-SmJson (Full $mod.Root $op.source)) | ForEach-Object { $_ }); $key=[string]$op.key
                $arrayItems = @()
    foreach($candidate in $add) {
        if($candidate -is [System.Array]) { $arrayItems += @($candidate) }
        else { $arrayItems += $candidate }
    }
    foreach($x in $arrayItems){
        $val = GetProp $x $key $null
        if($null -eq $val){ throw "Incoming JSON array item has no key '$key' while merging into $dst" }
        $matches=@($j | Where-Object {
            $existingVal = GetProp $_ $key $null
            ($null -ne $existingVal) -and ($existingVal -eq $val)
        })
        if($matches.Count -gt 0){
            $incomingJson=$x | ConvertTo-Json -Depth 50 -Compress
            $same=$false
            foreach($match in $matches){
                if(($match | ConvertTo-Json -Depth 50 -Compress) -eq $incomingJson){ $same=$true; break }
            }
            if($same){ Write-Host "[SM bootstrap] Already applied JSON array item $key=$val"; continue }
            throw "JSON array collision '$key=$val' in $dst (different content)"
        }
        $j += $x
    }; SaveJson $dst $j
            }
            # Insert one Lua expression into a known vanilla list at a stable marker.
        'luaListAdd' {
                $dst=Full $GamePath $op.target; $raw=[IO.File]::ReadAllText($dst); if($raw -notmatch [regex]::Escape([string]$op.value)){ $i=$raw.IndexOf([string]$op.marker); if($i -lt 0){throw "Lua marker not found in $dst"}; $i += ([string]$op.marker).Length; $raw=$raw.Insert($i,[Environment]::NewLine+"`t"+[string]$op.value); WriteUtf8 $dst $raw }
            }
            # Allocate an icon slot centrally and update both XML metadata and the atlas PNG.
        'iconAtlasAdd' {
                Add-Type -AssemblyName System.Drawing
                $xmlPath=Full $GamePath $op.xml; $pngPath=Full $GamePath $op.png; 
                [xml]$xml=[IO.File]::ReadAllText($xmlPath); $group=$xml.SelectSingleNode("//Group[@name='$($op.group)']"); if(!$group){throw "Icon group '$($op.group)' not found"}
                $uuids=@($op.uuids); foreach($u in $uuids){ if($xml.SelectSingleNode("//Index[@name='$u']")){ throw "Icon UUID collision: $u" } }
                $size=([string]$group.size).Split(' '); $cw=[int]$size[0]; $ch=[int]$size[1]
                $bmp=[Drawing.Bitmap]::FromFile($pngPath); try { $cols=[math]::Floor($bmp.Width/$cw); $rows=[math]::Floor($bmp.Height/$ch) } finally {$bmp.Dispose()}
                $max=-1; foreach($f in $xml.SelectNodes('//Frame[@point]')){ $xy=([string]$f.point).Split(' '); if($xy.Count -eq 2){$x=[int]$xy[0];$y=[int]$xy[1]; if($x%$cw -eq 0 -and $y%$ch -eq 0){$n=($y/$ch)*$cols+($x/$cw);if($n -gt $max){$max=$n}}} }
                $slot=$max+1; if($slot -ge $cols*$rows){throw 'Icon atlas is full'}; $x=($slot%$cols)*$cw; $y=[math]::Floor($slot/$cols)*$ch
                foreach($u in $uuids){ $idx=$xml.CreateElement('Index');$idx.SetAttribute('name',$u);$frame=$xml.CreateElement('Frame');$frame.SetAttribute('point',"$x $y");[void]$idx.AppendChild($frame);[void]$group.AppendChild($idx) }
                $xml.Save($xmlPath)
                $src=[Drawing.Bitmap]::FromFile((Full $mod.Root $op.source)); $atlas=[Drawing.Bitmap]::FromFile($pngPath); $tmp=$pngPath+'.bootstrap.tmp.png'
                try{$g=[Drawing.Graphics]::FromImage($atlas);try{$g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy;$g.DrawImage($src,[Drawing.Rectangle]::new($x,$y,$cw,$ch))}finally{$g.Dispose()};$atlas.Save($tmp,[Drawing.Imaging.ImageFormat]::Png)}finally{$atlas.Dispose();$src.Dispose()}; Move-Item $tmp $pngPath -Force
                Log "Icon slot $x $y -> $name"
            }
            default { throw "Unknown operation '$($op.type)' in $($mod.File)" }
        }
    }
}

Log 'Bootstrap v14 complete.'


$generatedRows = foreach($rel in $baselineTargets) {
    $file=Join-Path $GamePath $rel
    "$rel=$((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)"
}
$generatedBytes=[Text.Encoding]::UTF8.GetBytes(($generatedRows -join "`n"))
$generatedSha=[Security.Cryptography.SHA256]::Create()
try { $generatedHash=([BitConverter]::ToString($generatedSha.ComputeHash($generatedBytes))).Replace('-','') }
finally { $generatedSha.Dispose() }
$hashFile = Join-Path $PSScriptRoot '.generated-state.sha256'
$previousHash = if(Test-Path -LiteralPath $hashFile){ (Get-Content -LiteralPath $hashFile -Raw).Trim() } else { $null }

if($previousHash -ne $generatedHash) {
    $coreData = Join-Path $GamePath 'Cache\Bundle\core_data.cbo'
    if(Test-Path -LiteralPath $coreData) {
        Remove-Item -LiteralPath $coreData -Force
        Log 'Content changed -> deleted Cache\Bundle\core_data.cbo'
    } else {
        Log 'Content changed -> core_data.cbo already absent'
    }
    Set-Content -LiteralPath $hashFile -Value $generatedHash -Encoding ASCII
} else {
    Log 'Content unchanged -> keeping core_data.cbo'
}

Log 'Bootstrap v14 complete.'

if(!$NoLaunch){
    if($GameCommand -and $GameCommand.Count -gt 0){
        $exe=$GameCommand[0].Trim('"')
        $args=@()
        if($GameCommand.Count -gt 1){$args=$GameCommand[1..($GameCommand.Count-1)]}
        Start-Process -FilePath $exe -ArgumentList $args
    } else {
        Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath)
    }
}

try { Stop-Transcript | Out-Null } catch {}
