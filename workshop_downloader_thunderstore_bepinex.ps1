# Steam Workshop Downloader (PowerShell, ничего ставить вручную не нужно)
# Встроенный браузер со страницами мастерской Steam, профили модов (как в Gale),
# подписка на коллекции с синхронизацией и обновлениями.
# Запускать через run.bat

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base       = Join-Path $env:USERPROFILE 'WorkshopDownloader'
$ScDir      = Join-Path $Base 'steamcmd'
$ScExe      = Join-Path $ScDir 'steamcmd.exe'
$WvDir      = Join-Path $Base 'webview2'
$WvData     = Join-Path $Base 'browser-profile'
$WvVer      = '1.0.2592.51'
$DefaultOut = Join-Path $env:USERPROFILE 'Downloads\SteamWorkshop'
$DefaultZom = Join-Path $env:USERPROFILE 'Zomboid\mods'
$DefaultCache = Join-Path $Base 'data'
$DefaultTsData = Join-Path $Base 'thunderstore'

$Games = @(
    @{ Name = 'Project Zomboid'; App = '108600' },
    @{ Name = 'RimWorld';        App = '294100' },
    @{ Name = 'Другая игра (App ID)'; App = '' }
)

# Скрипт, который браузер добавляет на страницы модов и коллекций
$InjectJs = @'
(function () {
  function steamSetup() {
    var old = document.getElementById('wsdl-btn');
    if (old) old.remove();
    var m = location.search.match(/[?&]id=(\d+)/);
    if (!m || !/\/(sharedfiles|workshop)\/filedetails/.test(location.pathname)) return;
    var b = document.createElement('div');
    b.id = 'wsdl-btn';
    b.textContent = '>> Установить / подписаться';
    b.style.cssText = 'position:fixed;top:80px;right:20px;z-index:2147483647;padding:12px 18px;background:#5ba32b;color:#fff;font:bold 14px Arial,sans-serif;border-radius:4px;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.5)';
    b.onclick = function () { window.chrome.webview.postMessage('install:' + m[1]); };
    document.body.appendChild(b);
  }

  function thunderSetup() {
    // Thunderstore's native "Install with App" button is handled by the launcher.
    // We intercept it before the website opens/downloads anything itself.
    if (!window.__wdThunderstoreHook) {
      window.__wdThunderstoreHook = true;
      document.addEventListener('click', function (ev) {
        var el = ev.target;
        if (!el || !el.closest) return;
        var hit = el.closest('button,a,[role="button"]');
        if (!hit) return;

        var label = (hit.innerText || hit.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
        if (label.indexOf('install with app') === -1) return;

        var m = location.pathname.match(/\/c\/([^\/]+)\/p\/([^\/]+)\/([^\/]+)\/?/i);
        if (!m) return;

        ev.preventDefault();
        ev.stopPropagation();
        if (ev.stopImmediatePropagation) ev.stopImmediatePropagation();

        window.chrome.webview.postMessage(
          'tsinstall:' + decodeURIComponent(m[1]) + '|' +
          decodeURIComponent(m[2]) + '|' +
          decodeURIComponent(m[3])
        );
      }, true);
    }

    // Fallback button for pages where Thunderstore does not render its native button.
    var old = document.getElementById('tsdl-btn');
    if (old) old.remove();
    var m = location.pathname.match(/\/c\/([^\/]+)\/p\/([^\/]+)\/([^\/]+)\/?/i);
    if (!m) return;

    var b = document.createElement('div');
    b.id = 'tsdl-btn';
    b.textContent = '>> Установить в мой лаунчер';
    b.style.cssText = 'position:fixed;top:80px;right:20px;z-index:2147483647;padding:12px 18px;background:#5b8cff;color:#fff;font:bold 14px Arial,sans-serif;border-radius:5px;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.5)';
    b.onclick = function () {
      window.chrome.webview.postMessage('tsinstall:' + m[1] + '|' + m[2] + '|' + m[3]);
    };
    document.body.appendChild(b);
  }

  function setup() {
    steamSetup();
    thunderSetup();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', setup);
  else setup();
})();
'@

# ------------------------------------------------------------ общие функции (нужны и окну, и фоновой работе)
$CommonFns = {
    function To-Hash($o) {
        if ($null -eq $o) { return $null }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $h = @{}
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = To-Hash $p.Value }
            return $h
        }
        if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [string])) {
            $a = @()
            foreach ($i in $o) { $a += ,(To-Hash $i) }
            return ,$a
        }
        return $o
    }

    function Safe-Name($t) {
        $t = ($t -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim(' ', '.')
        if ($t.Length -gt 80) { $t = $t.Substring(0, 80) }
        if (-not $t) { $t = 'mod' }
        return $t
    }

    function Api($url, $fields) {
        Invoke-RestMethod -Uri $url -Method Post -Body $fields -TimeoutSec 30
    }

    function Parse-Ids($text) {
        $ids = @()
        foreach ($line in ($text -split "`r?`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            if ($line -match '[?&]id=(\d+)') { $ids += $Matches[1]; continue }
            if ($line -match 'sharedfiles/filedetails/(\d+)') { $ids += $Matches[1]; continue }
            foreach ($m in [regex]::Matches($line, '(?<!\d)\d{6,}(?!\d)')) { $ids += $m.Value }
        }
        $seen = @{}
        $out = @()
        foreach ($i in $ids) { if (-not $seen.ContainsKey($i)) { $seen[$i] = 1; $out += $i } }
        return ,$out
    }

    function Get-Details($ids) {
        $res = @()
        for ($s = 0; $s -lt $ids.Count; $s += 50) {
            $last = [Math]::Min($s + 49, $ids.Count - 1)
            $chunk = @($ids[$s..$last])
            $f = @{ itemcount = $chunk.Count }
            for ($i = 0; $i -lt $chunk.Count; $i++) { $f["publishedfileids[$i]"] = [string]$chunk[$i] }
            $r = Api 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/' $f
            $res += @($r.response.publishedfiledetails)
        }
        return ,$res
    }

    function Get-Children($id) {
        $r = Api 'https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/' @{ collectioncount = 1; 'publishedfileids[0]' = [string]$id }
        $d = @($r.response.collectiondetails)
        $kids = @()
        if ($d.Count -gt 0) {
            foreach ($c in $d[0].children) { $kids += [string]$c.publishedfileid }
        }
        return ,$kids
    }

    # Краткие данные о моде или коллекции (для окна)
    function Get-FileInfo($id) {
        $dd = Get-Details @([string]$id)
        if ($dd.Count -eq 0) { return $null }
        $x = $dd[0]
        if ($x.result -ne 1) { return $null }
        $info = @{
            id      = [string]$x.publishedfileid
            title   = [string]$x.title
            app     = [string]$x.consumer_app_id
            type    = [int]$x.file_type
            updated = [int64]$x.time_updated
            count   = 0
        }
        if ($info.type -eq 2) {
            $kids = Get-Children $info.id
            $info.count = $kids.Count
        }
        return $info
    }

    # ---- настройки
    function Load-Cfg($base) {
        $path = Join-Path $base 'config.json'
        $c = $null
        if (Test-Path $path) { try { $c = To-Hash (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $c = $null } }
        if ($c -isnot [hashtable]) { $c = @{} }
        return $c
    }
    function Update-Cfg($base, $changes) {
        $c = Load-Cfg $base
        foreach ($k in $changes.Keys) { $c[$k] = $changes[$k] }
        try {
            New-Item -ItemType Directory -Force $base | Out-Null
            $c | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $base 'config.json') -Encoding UTF8
        } catch {}
    }

    # ---- профили и учёт установленного
    # store = @{ profiles = @(@{name; app; mods=@(@{id,title,enabled,updated,source}); collections=@(@{id,title})});
    #            active = @{ '<app>' = 'имя профиля' }; installed = @{ '<app>' = @{ '<id>' = @('путь', ...) } } }
    function Load-Store($base) {
        $path = Join-Path $base 'profiles.json'
        $s = $null
        if (Test-Path $path) { try { $s = To-Hash (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $s = $null } }
        if ($s -isnot [hashtable]) { $s = @{} }
        if ($null -eq $s.profiles)  { $s.profiles = @() }
        if ($null -eq $s.active)    { $s.active = @{} }
        if ($null -eq $s.installed) { $s.installed = @{} }
        $s.profiles = @($s.profiles)
        return $s
    }
    function Save-Store($base, $store) {
        New-Item -ItemType Directory -Force $base | Out-Null
        $store | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $base 'profiles.json') -Encoding UTF8
    }
    function Find-Prof($store, $app, $name) {
        foreach ($p in $store.profiles) {
            if (($p.app -eq [string]$app) -and ($p.name -eq $name)) { return $p }
        }
        return $null
    }
    function New-Prof($store, $app, $name) {
        $p = @{ name = $name; app = [string]$app; mods = @(); collections = @() }
        # Для Thunderstore каждый новый профиль сразу получает BepInEx как
        # обязательную основу загрузки Unity-модов. Точный пакет определяется
        # по индексу конкретного Thunderstore-сообщества при первом применении.
        if ([string]$app -like 'ts:*') {
            $p.mods = @(, @{
                id = '__framework_bepinex__'
                title = 'BepInEx (основа для модов)'
                enabled = $true
                updated = 0
                source = 'framework'
            })
        }
        $store.profiles = @($store.profiles) + @(, $p)
        return $p
    }
    function Ensure-TsFrameworkMarker($prof) {
        if (-not $prof) { return }
        if (-not (@($prof.mods) | Where-Object { [string]$_.id -eq '__framework_bepinex__' -or [string]$_.source -eq 'framework' })) {
            $prof.mods = @($prof.mods) + @(, @{
                id = '__framework_bepinex__'
                title = 'BepInEx (основа для модов)'
                enabled = $true
                updated = 0
                source = 'framework'
            })
        }
    }
    function Get-OrMake-Prof($store, $app, $name) {
        if (-not $name) { $name = $store.active[[string]$app] }
        if (-not $name) { $name = 'Основной' }
        $p = Find-Prof $store $app $name
        if (-not $p) { $p = New-Prof $store $app $name }
        if ([string]$app -like 'ts:*') { Ensure-TsFrameworkMarker $p }
        $store.active[[string]$app] = $name
        return $p
    }
    function Find-Mod($prof, $id) {
        foreach ($m in @($prof.mods)) { if ([string]$m.id -eq [string]$id) { return $m } }
        return $null
    }

    # ---- Thunderstore
    function Ts-IndexUrl($community) {
        return ('https://thunderstore.io/c/{0}/api/v1/package/' -f $community)
    }

    function Ts-LoadIndex($community, $cacheDir) {
        $safe = Safe-Name $community
        $dir = Join-Path $cacheDir 'thunderstore\index'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $path = Join-Path $dir ($safe + '.json')
        try {
            $r = Invoke-RestMethod -Uri (Ts-IndexUrl $community) -Method Get -Headers @{ Accept = 'application/json'; 'User-Agent' = 'WorkshopDownloader/1.0' } -TimeoutSec 30
            $r | ConvertTo-Json -Depth 20 | Set-Content $path -Encoding UTF8
            return @($r)
        } catch {
            if (Test-Path $path) {
                return @((Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json))
            }
            throw
        }
    }

    function Ts-ResolvePackage($community, $owner, $name, $cacheDir) {
        $index = Ts-LoadIndex $community $cacheDir
        foreach ($p in $index) {
            if ([string]$p.owner -ieq $owner -and [string]$p.name -ieq $name) {
                return $p
            }
        }
        return $null
    }

    function Ts-ResolveBepInEx($community, $cacheDir, $gameDir) {
        $index = Ts-LoadIndex $community $cacheDir
        $il2cpp = Test-Path (Join-Path $gameDir 'GameAssembly.dll')
        $names = if ($il2cpp) { @('BepInExPack_IL2CPP', 'BepInExPack') } else { @('BepInExPack', 'BepInExPack_IL2CPP') }
        $owners = @('BepInEx','bbepis','RiskOfThunder')
        foreach ($wantName in $names) {
            foreach ($owner in $owners) {
                foreach ($p in $index) {
                    if ([string]$p.owner -ieq $owner -and [string]$p.name -ieq $wantName) {
                        $v = @($p.versions | Where-Object { $_.is_active -ne $false } | Select-Object -First 1)
                        if ($v.Count -gt 0) {
                            return [pscustomobject]@{
                                FullName = [string]$v[0].full_name
                                Owner = [string]$p.owner
                                Name = [string]$p.name
                                Package = $p
                                Version = $v[0]
                            }
                        }
                    }
                }
            }
        }
        return $null
    }

    function Ts-ResolveFullName($community, $fullName, $cacheDir) {
        $index = Ts-LoadIndex $community $cacheDir
        foreach ($p in $index) {
            foreach ($v in @($p.versions)) {
                if ([string]$v.full_name -ieq $fullName -and $v.is_active -ne $false) {
                    return [pscustomobject]@{
                        Owner = [string]$p.owner
                        Name = [string]$p.name
                        Package = $p
                        Version = $v
                    }
                }
            }
        }
        return $null
    }

    function Ts-ResolveGraph($community, $rootOwner, $rootName, $cacheDir) {
        $seen = @{}
        $result = @()
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@($rootOwner, $rootName))
        while ($queue.Count -gt 0) {
            $pair = $queue.Dequeue()
            $owner = [string]$pair[0]
            $name = [string]$pair[1]
            $key = ($owner + '/' + $name).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            $p = Ts-ResolvePackage $community $owner $name $cacheDir
            if (-not $p) { throw ("Thunderstore не нашёл пакет {0}/{1}" -f $owner, $name) }
            $v = @($p.versions | Where-Object { $_.is_active -ne $false } | Select-Object -First 1)
            if ($v.Count -eq 0) { throw ("У пакета {0} нет активной версии" -f $p.full_name) }
            $ver = $v[0]
            $result += [pscustomobject]@{ FullName = [string]$ver.full_name; Owner = $owner; Name = $name; Package = $p; Version = $ver; Source = '' }
            foreach ($dep in @($ver.dependencies)) {
                $depInfo = Ts-ResolveFullName $community ([string]$dep) $cacheDir
                if (-not $depInfo) { throw ("Не удалось разрешить зависимость: " + $dep) }
                $queue.Enqueue(@([string]$depInfo.Owner, [string]$depInfo.Name))
            }
        }
        return ,$result
    }

    function Ts-DownloadAndExtract($community, $pkg, $gameDir, $cacheDir) {
        if (-not $gameDir) { throw 'Не указана папка игры для Thunderstore.' }
        New-Item -ItemType Directory -Force $gameDir | Out-Null
        $zipDir = Join-Path $cacheDir ('thunderstore\downloads\' + (Safe-Name $community))
        New-Item -ItemType Directory -Force $zipDir | Out-Null
        $zip = Join-Path $zipDir ((Safe-Name $pkg.FullName) + '.zip')
        $url = [string]$pkg.Version.download_url
        if (-not $url) { throw ("У пакета нет download_url: " + $pkg.FullName) }
        if (-not (Test-Path $zip)) {
            Log ("Скачиваю " + $pkg.FullName)
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'WorkshopDownloader/1.0' } -TimeoutSec 120
        } else {
            Log ("Кеш: " + $pkg.FullName)
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmp = Join-Path $zipDir ((Safe-Name $pkg.FullName) + '.extract')
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        New-Item -ItemType Directory -Force $tmp | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)

        $paths = @()
        $sourceRoot = $tmp
        # BepInExPack архивы содержат внутреннюю папку BepInExPack.
        # Её содержимое должно попасть прямо в корень игры, иначе winhttp.dll
        # и папка BepInEx окажутся на один уровень глубже и загрузчик не стартует.
        if ([string]$pkg.Name -match '^BepInExPack(?:_IL2CPP)?$') {
            $nested = Join-Path $tmp [string]$pkg.Name
            if (Test-Path $nested -PathType Container) { $sourceRoot = $nested }
            else {
                $nested2 = Join-Path $tmp 'BepInExPack'
                if (Test-Path $nested2 -PathType Container) { $sourceRoot = $nested2 }
            }
        }
        foreach ($f in Get-ChildItem $sourceRoot -File -Recurse) {
            $rel = $f.FullName.Substring($sourceRoot.Length).TrimStart('\','/')
            if ($rel -match '(^|[\\/])\.\.([\\/]|$)') { continue }
            $dst = Join-Path $gameDir $rel
            $parent = Split-Path $dst -Parent
            New-Item -ItemType Directory -Force $parent | Out-Null
            Copy-Item $f.FullName $dst -Force
            $paths += $dst
        }
        Remove-Item $tmp -Recurse -Force
        return ,$paths
    }
}
. $CommonFns
$CommonText = $CommonFns.ToString()

# ------------------------------------------------------------ фоновая работа (скачать / применить / синхронизировать)
# mode: install/apply/sync = Steam Workshop
#       tsinstall/tsapply/tssync = Thunderstore
$worker = {
    param($q, $common, $base, $mode, $raw, $profileName, $appArg)

    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    . ([scriptblock]::Create($common))

    function Log($t)  { $q.Enqueue([pscustomobject]@{ k = 'log';  v = [string]$t }) }
    function Prog($n) { $q.Enqueue([pscustomobject]@{ k = 'prog'; v = [int]$n }) }

    $cfg = Load-Cfg $base
    $outDir   = if ($cfg.out) { [string]$cfg.out } else { Join-Path $env:USERPROFILE 'Downloads\SteamWorkshop' }
    $user     = if ($cfg.user) { [string]$cfg.user } else { '' }
    $dataDir  = if ($cfg.cache) { [string]$cfg.cache } else { Join-Path $base 'data' }
    $zomRoot  = if ($cfg.zomboidMods) { [string]$cfg.zomboidMods } else { Join-Path $env:USERPROFILE 'Zomboid\mods' }
    $rwCfg    = if ($cfg.rimworldDir) { [string]$cfg.rimworldDir } else { '' }
    $tsCommunity = if ($cfg.tsCommunity) { [string]$cfg.tsCommunity } else { 'lethal-company' }
    $tsGameDir = if ($cfg.tsGameDir) { [string]$cfg.tsGameDir } else { '' }
    $tsData = if ($cfg.tsData) { [string]$cfg.tsData } else { Join-Path $base 'thunderstore' }
    $scDir    = Join-Path $base 'steamcmd'
    $exe      = Join-Path $scDir 'steamcmd.exe'
    $cnt      = @{ done = 0; total = 1 }
    $store    = $null
    $remote   = @{}
    $force    = @{}

    # Ищет папку игры в библиотеках Steam
    function Find-GameDir($folder) {
        $steam = $null
        try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
        $libs = @()
        if ($steam) {
            $steam = $steam -replace '/', '\'
            $libs += $steam
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                }
            }
        }
        foreach ($l in $libs) {
            $p = Join-Path $l ("steamapps\common\" + $folder)
            if (Test-Path $p) { return $p }
        }
        return $null
    }

    function Cache-Path($it) {
        return (Join-Path $dataDir ("steamapps\workshop\content\{0}\{1}" -f $it.App, $it.Id))
    }

    # Ставит мод из кеша туда, где его ждёт игра. Возвращает список созданных путей.
    function Install-Item($it, $src) {
        $title = Safe-Name $it.Title
        $paths = @()

        if ($it.App -eq '108600') {
            # Project Zomboid: <id>\mods\<ИмяМода>\ копируем в папку Zomboid\mods
            $inner = Join-Path $src 'mods'
            if (Test-Path $inner) {
                New-Item -ItemType Directory -Force $zomRoot | Out-Null
                $names = @()
                foreach ($d in Get-ChildItem $inner -Directory) {
                    Copy-Item -Path $d.FullName -Destination $zomRoot -Recurse -Force
                    $paths += (Join-Path $zomRoot $d.Name)
                    $names += $d.Name
                }
                Log ("[OK] " + $it.Title + " -> " + $zomRoot + " (" + ($names -join ', ') + ")")
                return ,$paths
            }
        }
        elseif ($it.App -eq '294100') {
            # RimWorld: папка мода целиком в <игра>\Mods
            $gd = $null
            if ($rwCfg -and (Test-Path $rwCfg)) { $gd = $rwCfg } else { $gd = Find-GameDir 'RimWorld' }
            if ($gd) {
                $dst = Join-Path $gd ("Mods\" + $title + " [" + $it.Id + "]")
                New-Item -ItemType Directory -Force $dst | Out-Null
                Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
                $paths += $dst
                Log ("[OK] " + $it.Title + " -> " + $dst)
                return ,$paths
            }
            Log '   Папку RimWorld не нашёл, кладу мод в общую папку (можно указать путь в "Настройках").'
        }

        # остальные игры: папка мода в общей папке
        $dst = Join-Path $outDir ($title + " [" + $it.Id + "]")
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        $paths += $dst
        Log ("[OK] " + $it.Title + " -> " + $dst)
        return ,$paths
    }

    # Удаляет только то, что программа сама ставила
    function Remove-Installed($paths) {
        foreach ($p in $paths) {
            if (-not $p) { continue }
            $p = [string]$p
            if ($p.Length -lt 12) { continue }
            $ok = ($p -like '*\Zomboid\mods\*') -or ($p -like '*\Mods\*') -or $p.StartsWith($outDir) -or $p.StartsWith($zomRoot) -or ($tsGameDir -and $p.StartsWith($tsGameDir, [System.StringComparison]::OrdinalIgnoreCase))
            if ($ok -and (Test-Path $p)) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    function Paths-Exist($paths) {
        $list = @($paths)
        if ($list.Count -eq 0) { return $false }
        foreach ($p in $list) { if (-not (Test-Path ([string]$p))) { return $false } }
        return $true
    }

    function Ensure-Installed($app) {
        if (-not $store.installed.ContainsKey($app)) { $store.installed[$app] = @{} }
    }

    function Fill-Remote($ids) {
        $need = @()
        foreach ($i in $ids) { if (-not $remote.ContainsKey($i)) { $need += $i } }
        if ($need.Count -eq 0) { return }
        $dd = Get-Details $need
        foreach ($d in $dd) {
            if ($d.result -eq 1) { $remote[[string]$d.publishedfileid] = [int64]$d.time_updated }
        }
    }

    function Stamp-Updated($it) {
        $pn = $store.active[$it.App]
        if (-not $pn) { return }
        $pf = Find-Prof $store $it.App $pn
        if (-not $pf) { return }
        $m = Find-Mod $pf $it.Id
        if ($m -and $remote.ContainsKey($it.Id)) { $m.updated = $remote[$it.Id] }
    }

    function OnLine($line) {
        Log $line
        if ($line -match 'Success\. Downloaded item') {
            $cnt.done++
            Prog ([int]($cnt.done * 80 / $cnt.total))
        }
        elseif (($line -match 'ERROR!') -and ($line -match 'Download item')) {
            $cnt.done++
            Prog ([int]($cnt.done * 80 / $cnt.total))
            if ($line -match 'Access Denied|No subscription') {
                Log '   ^ Для этого мода нужна игра на аккаунте. Впиши аккаунт Steam в "Настройках" и нажми "Войти (консоль)".'
            }
        }
    }

    function Run-Steam($argList) {
        $quoted = foreach ($a in $argList) { if ($a -match '\s') { '"' + $a + '"' } else { $a } }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ($quoted -join ' ')
        $psi.WorkingDirectory = $scDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            $line = $line.Trim()
            if ($line) { OnLine $line }
        }
        $p.WaitForExit()
        return $p.ExitCode
    }

    function Ensure-Steam {
        if (-not (Test-Path $exe)) {
            New-Item -ItemType Directory -Force $scDir | Out-Null
            Log 'Скачиваю SteamCMD (один раз)...'
            $zip = Join-Path $scDir 'steamcmd.zip'
            Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing
            Expand-Archive $zip -DestinationPath $scDir -Force
            Remove-Item $zip -Force
        }
        if (-not (Test-Path (Join-Path $scDir 'package'))) {
            Log 'Обновляю SteamCMD при первом запуске (минута-две)...'
            [void](Run-Steam @('+quit'))
        }
    }

    function Download-Items($list) {
        if ($list.Count -eq 0) { return }
        Ensure-Steam
        New-Item -ItemType Directory -Force $dataDir | Out-Null
        $login = if ($user) { $user } else { 'anonymous' }
        $argList = @('+force_install_dir', $dataDir, '+login', $login)
        foreach ($it in $list) { $argList += @('+workshop_download_item', $it.App, $it.Id, 'validate') }
        $argList += '+quit'
        $cnt.done = 0
        $cnt.total = [Math]::Max(1, $list.Count)
        Log ("Скачиваю через SteamCMD: " + $list.Count + " шт...")
        $code = Run-Steam $argList
        if ($code -ne 0 -and $code -ne 7) { Log "SteamCMD завершился с кодом $code" }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\WorkshopDownloaderSteamCmd')
    $haveMutex = $false
    try {
        $store = Load-Store $base
        $items = @()
        $prof = $null

        if ($mode -eq 'tsinstall' -or $mode -eq 'tsapply' -or $mode -eq 'tssync') {
            # ---------- Thunderstore
            $tsKey = [string]$appArg
            $prof = Find-Prof $store $tsKey $profileName
            if (-not $prof) { $prof = Get-OrMake-Prof $store $tsKey $profileName }
            Ensure-TsFrameworkMarker $prof
            $store.active[$tsKey] = $prof.name
            if (-not $tsGameDir) { throw 'В настройках не указана папка игры для Thunderstore.' }

            $packages = @()
            if ($mode -eq 'tsinstall') {
                $parts = $raw -split '\|'
                if ($parts.Count -lt 3) { throw 'Неверная ссылка Thunderstore.' }
                $tsCommunity = [string]$parts[0]
                $owner = $parts[1]
                $name = $parts[2]
                Log ("Thunderstore: " + $tsCommunity + " / " + $owner + "/" + $name)

                $frameworkMarker = Find-Mod $prof '__framework_bepinex__'
                if ($frameworkMarker -and $frameworkMarker.enabled -and $frameworkMarker.id -eq '__framework_bepinex__') {
                    $bep = Ts-ResolveBepInEx $tsCommunity $tsData $tsGameDir
                    if ($bep) {
                        $frameworkMarker.id = $bep.FullName
                        $frameworkMarker.title = $bep.Name + ' ' + [string]$bep.Version.version_number + ' (основа для модов)'
                        $frameworkMarker.updated = [string]$bep.Version.version_number
                    } else {
                        Log 'BepInExPack не найден в этом Thunderstore-сообществе; устанавливаю остальные моды.'
                    }
                }
                $packages = Ts-ResolveGraph $tsCommunity $owner $name $tsData

                $frameworkMarker = Find-Mod $prof '__framework_bepinex__'
                if ($frameworkMarker -and $frameworkMarker.enabled -and $frameworkMarker.id -ne '__framework_bepinex__') {
                    $fi = Ts-ResolveFullName $tsCommunity ([string]$frameworkMarker.id) $tsData
                    if ($fi) {
                        $fv = @($fi.Package.versions | Where-Object { $_.full_name -ieq [string]$frameworkMarker.id } | Select-Object -First 1)
                        if ($fv.Count -gt 0) {
                            $packages += [pscustomobject]@{ FullName = [string]$fv[0].full_name; Owner = [string]$fi.Owner; Name = [string]$fi.Name; Package = $fi.Package; Version = $fv[0]; Source = 'framework' }
                        }
                    }
                }

                foreach ($pkg in $packages) {
                    $m = Find-Mod $prof $pkg.FullName
                    if (-not $m) {
                        $prof.mods = @($prof.mods) + @(, @{
                            id = $pkg.FullName
                            title = $pkg.Name + ' ' + [string]$pkg.Version.version_number
                            enabled = $true
                            updated = 0
                            source = $pkg.Source
                        })
                    } else {
                        $m.enabled = $true
                        $m.title = $pkg.Name + ' ' + [string]$pkg.Version.version_number
                    }
                    $force[$pkg.FullName] = 1
                    $remote[$pkg.FullName] = [string]$pkg.Version.version_number
                }
            } else {
                $frameworkMarker = Find-Mod $prof '__framework_bepinex__'
                if ($frameworkMarker -and $frameworkMarker.enabled -and $frameworkMarker.id -eq '__framework_bepinex__') {
                    $bep = Ts-ResolveBepInEx $tsCommunity $tsData $tsGameDir
                    if ($bep) {
                        $frameworkMarker.id = $bep.FullName
                        $frameworkMarker.title = $bep.Name + ' ' + [string]$bep.Version.version_number + ' (основа для модов)'
                        $frameworkMarker.updated = [string]$bep.Version.version_number
                    } else {
                        Log 'BepInExPack не найден в этом Thunderstore-сообществе; устанавливаю остальные моды.'
                    }
                }
                if ($mode -eq 'tssync') {
                    # Обновляем каждый пакет до последней активной версии и заново разрешаем его зависимости.
                    $current = @($prof.mods | Where-Object { $_.enabled })
                    foreach ($m in $current) {
                        $info = Ts-ResolveFullName $tsCommunity ([string]$m.id) $tsData
                        if ($info) {
                            $latest = @($info.Package.versions | Where-Object { $_.is_active -ne $false } | Select-Object -First 1)
                            if ($latest.Count -gt 0 -and [string]$latest[0].full_name -ne [string]$m.id) {
                                Log ("  ^ обновление: " + $m.title + " -> " + $latest[0].version_number)
                                $m.id = [string]$latest[0].full_name
                                $m.title = [string]$latest[0].name + ' ' + [string]$latest[0].version_number
                                $force[$m.id] = 1
                            }
                        }
                    }
                }

                foreach ($m in @($prof.mods)) {
                    if (-not $m.enabled) { continue }
                    if ([string]$m.id -eq '__framework_bepinex__') { continue }
                    $info = Ts-ResolveFullName $tsCommunity ([string]$m.id) $tsData
                    if (-not $info) {
                        Log ("[X] Не найден пакет: " + $m.id)
                        continue
                    }
                    $v = @($info.Package.versions | Where-Object { $_.full_name -ieq [string]$m.id } | Select-Object -First 1)
                    if ($v.Count -eq 0) { continue }
                    $packages += [pscustomobject]@{
                        FullName = [string]$v[0].full_name
                        Owner = [string]$info.Owner
                        Name = [string]$info.Name
                        Package = $info.Package
                        Version = $v[0]
                        Source = [string]$m.source
                    }
                    $remote[[string]$v[0].full_name] = [string]$v[0].version_number
                }

                $frameworkMarker = Find-Mod $prof '__framework_bepinex__'
                if ($frameworkMarker -and $frameworkMarker.enabled -and $frameworkMarker.id -ne '__framework_bepinex__') {
                    $fi = Ts-ResolveFullName $tsCommunity ([string]$frameworkMarker.id) $tsData
                    if ($fi) {
                        $fv = @($fi.Package.versions | Where-Object { $_.full_name -ieq [string]$frameworkMarker.id } | Select-Object -First 1)
                        if ($fv.Count -gt 0) {
                            $already = $false
                            foreach ($x in $packages) { if ([string]$x.FullName -ieq [string]$fv[0].full_name) { $already = $true; break } }
                            if (-not $already) {
                                $packages += [pscustomobject]@{ FullName = [string]$fv[0].full_name; Owner = [string]$fi.Owner; Name = [string]$fi.Name; Package = $fi.Package; Version = $fv[0]; Source = 'framework' }
                            }
                        }
                    }
                }
            }

            # Добавляем зависимости для профиля, если они ещё не были добавлены.
            if ($packages.Count -gt 0) {
                $expanded = @()
                foreach ($pkg in $packages) {
                    $expanded += $pkg
                    foreach ($dep in @($pkg.Version.dependencies)) {
                        $di = Ts-ResolveFullName $tsCommunity ([string]$dep) $tsData
                        if (-not $di) { throw ("Не удалось разрешить зависимость: " + $dep) }
                        $dv = @($di.Package.versions | Where-Object { $_.full_name -ieq [string]$dep } | Select-Object -First 1)
                        if ($dv.Count -eq 0) { continue }
                        $depPkg = [pscustomobject]@{
                            FullName = [string]$dv[0].full_name
                            Owner = [string]$di.Owner
                            Name = [string]$di.Name
                            Package = $di.Package
                            Version = $dv[0]
                            Source = 'dependency'
                        }
                        $expanded += $depPkg
                        if (-not (Find-Mod $prof $depPkg.FullName)) {
                            $prof.mods = @($prof.mods) + @(, @{
                                id = $depPkg.FullName
                                title = $depPkg.Name + ' ' + [string]$depPkg.Version.version_number
                                enabled = $true
                                updated = 0
                                source = 'dependency'
                            })
                        }
                    }
                }
                $uniq = @{}
                $packages2 = @()
                foreach ($pkg in $expanded) {
                    if (-not $uniq.ContainsKey($pkg.FullName)) {
                        $uniq[$pkg.FullName] = 1
                        $packages2 += $pkg
                    }
                }
                $packages = $packages2
            }

            Ensure-Installed $tsKey
            $want = @{}
            foreach ($pkg in $packages) {
                $want[$pkg.FullName] = 1
                if (-not $force.ContainsKey($pkg.FullName) -and $store.installed[$tsKey].ContainsKey($pkg.FullName)) {
                    if (Paths-Exist $store.installed[$tsKey][$pkg.FullName]) { continue }
                }
                if ($store.installed[$tsKey].ContainsKey($pkg.FullName)) {
                    Remove-Installed @($store.installed[$tsKey][$pkg.FullName])
                }
                Log ("Устанавливаю: " + $pkg.FullName)
                $paths = Ts-DownloadAndExtract $tsCommunity $pkg $tsGameDir $tsData
                $store.installed[$tsKey][$pkg.FullName] = @($paths)
                $m = Find-Mod $prof $pkg.FullName
                if ($m) { $m.updated = [string]$pkg.Version.version_number }
            }
            foreach ($k in @($store.installed[$tsKey].Keys)) {
                if (-not $want.ContainsKey($k)) {
                    Remove-Installed @($store.installed[$tsKey][$k])
                    $store.installed[$tsKey].Remove($k)
                    Log ("Убран из игры: " + $k)
                }
            }
            Prog 100
            Log ("Thunderstore готов: " + $packages.Count + " пакетов.")
            return
        }

        if ($mode -eq 'install') {
            # ---------- установка по ссылкам / ID
            $ids = Parse-Ids $raw
            if ($ids.Count -eq 0) { Log 'Не нашёл ни одной ссылки или ID.'; return }
            $details = Get-Details $ids
            foreach ($d in $details) {
                $mid = [string]$d.publishedfileid
                if ($d.result -ne 1) { Log "Пропускаю ${mid}: Steam не нашёл такой мод (удалён или скрыт)"; continue }
                if ($d.file_type -eq 2) {
                    Log "Коллекция "$($d.title)", загружаю список модов..."
                    $kids = Get-Children $mid
                    foreach ($c in (Get-Details $kids)) {
                        if ($c.result -eq 1) {
                            $items += [pscustomobject]@{ Id = [string]$c.publishedfileid; Title = [string]$c.title; App = [string]$c.consumer_app_id; Updated = [int64]$c.time_updated }
                        }
                    }
                }
                else {
                    $items += [pscustomobject]@{ Id = $mid; Title = [string]$d.title; App = [string]$d.consumer_app_id; Updated = [int64]$d.time_updated }
                }
            }
            $seen = @{}
            $uniq = @()
            foreach ($it in $items) { if (-not $seen.ContainsKey($it.Id)) { $seen[$it.Id] = 1; $uniq += $it } }
            $items = $uniq
            if ($items.Count -eq 0) { Log 'Скачивать нечего.'; return }

            foreach ($it in $items) {
                $pn = ''
                if ($it.App -eq $appArg) { $pn = $profileName }
                $pf = Get-OrMake-Prof $store $it.App $pn
                $m = Find-Mod $pf $it.Id
                if ($null -eq $m) {
                    $pf.mods = @($pf.mods) + @(, @{ id = $it.Id; title = $it.Title; enabled = $true; updated = 0; source = '' })
                } else {
                    $m.title = $it.Title
                    $m.enabled = $true
                }
                $remote[$it.Id] = $it.Updated
                $force[$it.Id] = 1
                Log ('  - ' + $it.Title + ' (мод ' + $it.Id + ', профиль "' + $store.active[$it.App] + '")')
            }
        }
        else {
            # ---------- применить / синхронизировать профиль
            $prof = Find-Prof $store $appArg $profileName
            if (-not $prof) { Log 'Профиль не найден.'; return }
            $store.active[$prof.app] = $prof.name
            Log ('Профиль "' + $prof.name + '"')

            if ($mode -eq 'sync') {
                foreach ($c in @($prof.collections)) {
                    Log ('Проверяю коллекцию "' + $c.title + '"...')
                    $kids = Get-Children $c.id
                    $kd = Get-Details $kids
                    $inColl = @{}
                    foreach ($d in $kd) {
                        if ($d.result -ne 1) { continue }
                        $kid = [string]$d.publishedfileid
                        $inColl[$kid] = 1
                        $remote[$kid] = [int64]$d.time_updated
                        $m = Find-Mod $prof $kid
                        if ($null -eq $m) {
                            Log ("  + новый в коллекции: " + $d.title)
                            $prof.mods = @($prof.mods) + @(, @{ id = $kid; title = [string]$d.title; enabled = $true; updated = 0; source = [string]$c.id })
                        } else {
                            $m.title = [string]$d.title
                        }
                    }
                    $keep = @()
                    foreach ($m in @($prof.mods)) {
                        if (($m.source -eq [string]$c.id) -and (-not $inColl.ContainsKey([string]$m.id))) {
                            Log ("  - убран из коллекции: " + $m.title)
                        } else {
                            $keep += $m
                        }
                    }
                    $prof.mods = $keep
                }

                # какие моды вышли в новой версии
                $allIds = @()
                foreach ($m in @($prof.mods)) { if ($m.enabled) { $allIds += [string]$m.id } }
                Fill-Remote $allIds
                foreach ($m in @($prof.mods)) {
                    $mid = [string]$m.id
                    if ($m.enabled -and $remote.ContainsKey($mid) -and ([int64]$remote[$mid] -gt [int64]$m.updated) -and ([int64]$m.updated -gt 0)) {
                        $force[$mid] = 1
                        Log ("  ^ есть обновление: " + $m.title)
                    }
                }
            }

            foreach ($m in @($prof.mods)) {
                if ($m.enabled) {
                    $items += [pscustomobject]@{ Id = [string]$m.id; Title = [string]$m.title; App = [string]$prof.app; Updated = 0 }
                }
            }

            # убрать из игры то, чего нет в профиле (только поставленное этой программой)
            Ensure-Installed $prof.app
            $want = @{}
            foreach ($it in $items) { $want[$it.Id] = 1 }
            foreach ($k in @($store.installed[$prof.app].Keys)) {
                if (-not $want.ContainsKey($k)) {
                    Remove-Installed @($store.installed[$prof.app][$k])
                    $store.installed[$prof.app].Remove($k)
                    Log ("Убран из игры мод " + $k)
                }
            }
        }

        # ---------- скачать то, чего нет в кеше или что обновилось
        $dl = @()
        foreach ($it in $items) {
            if ($force.ContainsKey($it.Id) -or (-not (Test-Path (Cache-Path $it)))) { $dl += $it }
        }

        if ($dl.Count -gt 0) {
            $dlIds = @()
            foreach ($it in $dl) { $dlIds += $it.Id }
            try { Fill-Remote $dlIds } catch {}

            if (-not $mutex.WaitOne(0)) {
                Log 'Жду, пока закончится другая загрузка...'
                [void]$mutex.WaitOne()
            }
            $haveMutex = $true
            Download-Items $dl
        }
        Prog 85

        # ---------- поставить в игру
        $ok = 0
        $fail = 0
        $same = 0
        foreach ($it in $items) {
            Ensure-Installed $it.App
            $have = $store.installed[$it.App][$it.Id]
            $redo = $force.ContainsKey($it.Id) -or ($null -eq $have) -or (-not (Paths-Exist $have))
            if (-not $redo) { $same++; continue }
            $src = Cache-Path $it
            if (-not (Test-Path $src)) { Log ("[X] Не скачан: " + $it.Title + " (" + $it.Id + ")"); $fail++; continue }
            if ($null -ne $have) { Remove-Installed @($have) }
            $paths = Install-Item $it $src
            $store.installed[$it.App][$it.Id] = @($paths)
            Stamp-Updated $it
            $ok++
        }
        Prog 100
        Log ("Готово: установлено или обновлено " + $ok + ", без изменений " + $same + ", не удалось " + $fail + ".")
    }
    catch {
        Log "ОШИБКА: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $store) { try { Save-Store $base $store } catch { Log ("Не смог сохранить профили: " + $_.Exception.Message) } }
        if ($haveMutex) { try { $mutex.ReleaseMutex() } catch {} }
    }
}

# ------------------------------------------------------------ вспомогательное для окон
function New-Ctl($type, $text, $x, $y, $w, $h) {
    $c = New-Object $type
    if ($text) { $c.Text = $text }
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    return $c
}

function Ask-Text($title, $prompt, $default) {
    $f = New-Ctl 'System.Windows.Forms.Form' $title 0 0 420 150
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $l = New-Ctl 'System.Windows.Forms.Label' $prompt 12 12 380 20
    $t = New-Ctl 'System.Windows.Forms.TextBox' $default 12 38 380 24
    $ok = New-Ctl 'System.Windows.Forms.Button' 'ОК' 212 76 80 28
    $ok.DialogResult = 'OK'
    $cn = New-Ctl 'System.Windows.Forms.Button' 'Отмена' 302 76 90 28
    $cn.DialogResult = 'Cancel'
    $f.AcceptButton = $ok
    $f.CancelButton = $cn
    $f.Controls.AddRange(@($l, $t, $ok, $cn))
    if ($f.ShowDialog() -eq 'OK') { return $t.Text.Trim() }
    return $null
}

# Окно с ходом работы
function Show-JobWindow($mode, $raw, $profileName, $appArg) {
    $titles = @{ install = 'Установка'; apply = 'Применение профиля'; sync = 'Синхронизация профиля'; tsinstall = 'Установка Thunderstore'; tsapply = 'Применение Thunderstore-профиля'; tssync = 'Синхронизация Thunderstore' }
    $f = New-Ctl 'System.Windows.Forms.Form' $titles[$mode] 0 0 700 460
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $bar = New-Ctl 'System.Windows.Forms.ProgressBar' '' 12 12 660 20
    $bar.Anchor = 'Top,Left,Right'
    $log = New-Ctl 'System.Windows.Forms.TextBox' '' 12 42 660 340
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.BackColor = [System.Drawing.Color]::White
    $log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $log.Anchor = 'Top,Bottom,Left,Right'
    $btn = New-Ctl 'System.Windows.Forms.Button' 'Закрыть' 572 390 100 30
    $btn.Anchor = 'Bottom,Right'
    $f.Controls.AddRange(@($bar, $log, $btn))
    $btn.Add_Click({ $f.Close() }.GetNewClosure())

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $job = @{ handle = $null; done = $false }
    $job.rs = [runspacefactory]::CreateRunspace()
    $job.rs.ApartmentState = 'STA'
    $job.rs.Open()
    $job.ps = [powershell]::Create()
    $job.ps.Runspace = $job.rs
    [void]$job.ps.AddScript($worker.ToString())
    [void]$job.ps.AddArgument($queue)
    [void]$job.ps.AddArgument($CommonText)
    [void]$job.ps.AddArgument($Base)
    [void]$job.ps.AddArgument($mode)
    [void]$job.ps.AddArgument($raw)
    [void]$job.ps.AddArgument($profileName)
    [void]$job.ps.AddArgument($appArg)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $tick = {
        $finished = $false
        if ($job.handle -and $job.handle.IsCompleted -and (-not $job.done)) { $finished = $true }
        $item = $null
        while ($queue.TryDequeue([ref]$item)) {
            if ($item.k -eq 'log') { $log.AppendText($item.v + "`r`n") }
            elseif ($item.k -eq 'prog') { $bar.Value = [Math]::Max(0, [Math]::Min(100, $item.v)) }
        }
        if ($finished) {
            $job.done = $true
            try { [void]$job.ps.EndInvoke($job.handle) } catch { $log.AppendText('ОШИБКА: ' + $_.Exception.Message + "`r`n") }
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $f.Add_FormClosed({
        $timer.Stop()
        if ($job.done) { try { $job.ps.Dispose(); $job.rs.Close() } catch {} }
    }.GetNewClosure())

    $job.handle = $job.ps.BeginInvoke()
    $timer.Start()
    [void]$f.ShowDialog()
}

# ------------------------------------------------------------ компонент встроенного браузера (WebView2)
function Sdk-Ready {
    return ((Test-Path (Join-Path $WvDir 'Microsoft.Web.WebView2.Core.dll')) -and
            (Test-Path (Join-Path $WvDir 'Microsoft.Web.WebView2.WinForms.dll')) -and
            (Test-Path (Join-Path $WvDir 'x64\WebView2Loader.dll')) -and
            (Test-Path (Join-Path $WvDir 'x86\WebView2Loader.dll')))
}

function Ensure-WebView2Sdk {
    $core = Join-Path $WvDir 'Microsoft.Web.WebView2.Core.dll'
    $wf   = Join-Path $WvDir 'Microsoft.Web.WebView2.WinForms.dll'
    if (-not (Sdk-Ready)) {
        New-Item -ItemType Directory -Force $WvDir | Out-Null
        $tmp = Join-Path $WvDir 'pkg'
        $zip = Join-Path $WvDir 'pkg.zip'
        Invoke-WebRequest ("https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/" + $WvVer) -OutFile $zip -UseBasicParsing
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive $zip -DestinationPath $tmp -Force
        function Pick($name, $hint) {
            $f = Get-ChildItem $tmp -Recurse -Filter $name | Where-Object { $_.FullName -match $hint } | Select-Object -First 1
            if (-not $f) { throw ("В пакете WebView2 не найден файл " + $name) }
            return $f.FullName
        }
        Copy-Item (Pick 'Microsoft.Web.WebView2.Core.dll' 'net4') $core -Force
        Copy-Item (Pick 'Microsoft.Web.WebView2.WinForms.dll' 'net4') $wf -Force
        New-Item -ItemType Directory -Force (Join-Path $WvDir 'x64') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $WvDir 'x86') | Out-Null
        Copy-Item (Pick 'WebView2Loader.dll' 'win-x64') (Join-Path $WvDir 'x64\WebView2Loader.dll') -Force
        Copy-Item (Pick 'WebView2Loader.dll' 'win-x86') (Join-Path $WvDir 'x86\WebView2Loader.dll') -Force
        Remove-Item $tmp -Recurse -Force
        Remove-Item $zip -Force
    }
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    $env:PATH = (Join-Path $WvDir $arch) + ';' + $env:PATH
    Add-Type -Path $core
    Add-Type -Path $wf
}

$splash = $null
if (-not (Sdk-Ready)) {
    $splash = New-Ctl 'System.Windows.Forms.Form' 'Workshop Downloader' 0 0 420 90
    $splash.StartPosition = 'CenterScreen'
    $splash.FormBorderStyle = 'FixedDialog'
    $splash.ControlBox = $false
    $sl = New-Ctl 'System.Windows.Forms.Label' 'Первый запуск: скачиваю компонент браузера (один раз)...' 16 28 390 24
    $splash.Controls.Add($sl)
    $splash.Show()
    [System.Windows.Forms.Application]::DoEvents()
}
try {
    Ensure-WebView2Sdk
}
catch {
    if ($splash) { $splash.Close() }
    [void][System.Windows.Forms.MessageBox]::Show("Не удалось подготовить встроенный браузер:`n" + $_.Exception.Message + "`n`nПроверь интернет и запусти программу ещё раз.", 'Workshop Downloader')
    exit
}
if ($splash) { $splash.Close() }

# ------------------------------------------------------------ главное окно
$cfg0 = Load-Cfg $Base

# ------------------------------------------------------------ темы интерфейса
function Get-ThemeColors($name) {
    switch ([string]$name) {
        'black' {
            return @{ Name='black'; Form=[System.Drawing.Color]::FromArgb(18,18,18); Panel=[System.Drawing.Color]::FromArgb(24,24,24); Text=[System.Drawing.Color]::FromArgb(235,235,235); Control=[System.Drawing.Color]::FromArgb(35,35,35); ControlText=[System.Drawing.Color]::White; Border=[System.Drawing.Color]::FromArgb(75,75,75); Button=[System.Drawing.Color]::FromArgb(48,48,48) }
        }
        'darkblue' {
            return @{ Name='darkblue'; Form=[System.Drawing.Color]::FromArgb(15,25,42); Panel=[System.Drawing.Color]::FromArgb(20,34,56); Text=[System.Drawing.Color]::FromArgb(235,241,250); Control=[System.Drawing.Color]::FromArgb(27,43,67); ControlText=[System.Drawing.Color]::White; Border=[System.Drawing.Color]::FromArgb(62,86,116); Button=[System.Drawing.Color]::FromArgb(34,57,88) }
        }
        default {
            return @{ Name='white'; Form=[System.Drawing.Color]::FromArgb(245,245,245); Panel=[System.Drawing.Color]::FromArgb(235,235,235); Text=[System.Drawing.Color]::FromArgb(30,30,30); Control=[System.Drawing.Color]::White; ControlText=[System.Drawing.Color]::FromArgb(25,25,25); Border=[System.Drawing.Color]::FromArgb(190,190,190); Button=[System.Drawing.Color]::FromArgb(235,235,235) }
        }
    }
}
function Apply-ThemeToControl($ctrl, $theme) {
    if ($null -eq $ctrl) { return }
    try {
        if ($ctrl -is [System.Windows.Forms.Form]) { $ctrl.BackColor = $theme.Form; $ctrl.ForeColor = $theme.Text }
        elseif ($ctrl -is [System.Windows.Forms.Panel]) { $ctrl.BackColor = $theme.Panel; $ctrl.ForeColor = $theme.Text }
        elseif ($ctrl -is [System.Windows.Forms.Label]) { $ctrl.BackColor = [System.Drawing.Color]::Transparent; $ctrl.ForeColor = $theme.Text }
        elseif ($ctrl -is [System.Windows.Forms.CheckBox]) { $ctrl.BackColor = [System.Drawing.Color]::Transparent; $ctrl.ForeColor = $theme.Text }
        elseif ($ctrl -is [System.Windows.Forms.TextBox] -or $ctrl -is [System.Windows.Forms.ComboBox] -or $ctrl -is [System.Windows.Forms.ListBox] -or $ctrl -is [System.Windows.Forms.CheckedListBox]) { $ctrl.BackColor = $theme.Control; $ctrl.ForeColor = $theme.ControlText }
        elseif ($ctrl -is [System.Windows.Forms.Button]) {
            if ($ctrl.Tag -ne 'accent') { $ctrl.BackColor = $theme.Button; $ctrl.ForeColor = $theme.ControlText; try { $ctrl.FlatAppearance.BorderColor = $theme.Border } catch {} }
        }
        foreach ($child in $ctrl.Controls) { Apply-ThemeToControl $child $theme }
    } catch {}
}
function Apply-ThemeToForm($targetForm, $name) {
    if ($null -eq $targetForm) { return }
    Apply-ThemeToControl $targetForm (Get-ThemeColors $name)
}
$script:themeName = if ($cfg0.theme) { [string]$cfg0.theme } else { 'white' }
if ($script:themeName -notin @('white','black','darkblue')) { $script:themeName = 'white' }

$startGame = 0
if ($null -ne $cfg0.game) { try { $startGame = [int]$cfg0.game } catch {} }
if ($startGame -lt 0 -or $startGame -ge $Games.Count) { $startGame = 0 }

$W = 1400
$form = New-Ctl 'System.Windows.Forms.Form' 'Workshop / Thunderstore Manager' 0 0 $W 800
$form.ClientSize = New-Object System.Drawing.Size($W, 780)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1000, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:ready = $false
$script:busy = $false
$script:pendingId = $null
$script:pendingTs = $null
$script:tsMode = $false
$script:startupSync = $false
$script:tsMode = ($cfg0.source -eq 'thunderstore')

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Top'
$panel.Height = 44

$btnPlay   = New-Ctl 'System.Windows.Forms.Button' '▶ Играть' 8 6 90 32
$btnPlay.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnPlay.ForeColor = [System.Drawing.Color]::White
$btnPlay.FlatStyle = 'Flat'
$btnBack   = New-Ctl 'System.Windows.Forms.Button' '←' 104 8 34 28
$btnFwd    = New-Ctl 'System.Windows.Forms.Button' '→' 142 8 34 28
$btnReload = New-Ctl 'System.Windows.Forms.Button' 'Обновить' 182 8 80 28
$cmbGame   = New-Ctl 'System.Windows.Forms.ComboBox' '' 270 10 190 24
$cmbGame.DropDownStyle = 'DropDownList'
foreach ($g in $Games) { [void]$cmbGame.Items.Add($g.Name) }
$lblApp    = New-Ctl 'System.Windows.Forms.Label' 'App ID:' 468 14 50 20
$txtApp    = New-Ctl 'System.Windows.Forms.TextBox' '' 518 10 80 24
$btnWs     = New-Ctl 'System.Windows.Forms.Button' 'Steam Workshop' 606 8 110 28
$btnTs     = New-Ctl 'System.Windows.Forms.Button' 'Thunderstore' 724 8 110 28
$btnProf   = New-Ctl 'System.Windows.Forms.Button' 'Профили' 842 8 82 28
$btnGameDir = New-Ctl 'System.Windows.Forms.Button' 'Папка игры' 930 8 100 28
$btnSet    = New-Ctl 'System.Windows.Forms.Button' '⚙ Настройки' 1036 8 114 28
$btnSet.Anchor = 'Top,Left'
$txtAddr   = New-Ctl 'System.Windows.Forms.TextBox' '' 1158 10 124 24
$txtAddr.ReadOnly = $true
$txtAddr.Anchor = 'Top,Left'
$btnInstall = New-Ctl 'System.Windows.Forms.Button' 'Установить' 1290 6 100 32
$btnInstall.Anchor = 'Top,Right'
$btnInstall.BackColor = [System.Drawing.Color]::FromArgb(91, 163, 43)
$btnInstall.ForeColor = [System.Drawing.Color]::White
$btnInstall.FlatStyle = 'Flat'
$btnInstall.Enabled = $false
if ($cfg0.tsGameDir -and (Test-Path ([string]$cfg0.tsGameDir))) { $btnGameDir.Text = 'Папка игры ✓' }
if ($cfg0.tsGameExe -and (Test-Path ([string]$cfg0.tsGameExe))) { $btnPlay.Text = '▶ Играть' }
$btnSet.Anchor = 'Top,Right'
$btnPlay.Tag = 'accent'
$btnInstall.Tag = 'accent'
$panel.Controls.AddRange(@($btnPlay, $btnBack, $btnFwd, $btnReload, $cmbGame, $lblApp, $txtApp, $btnWs, $btnTs, $btnProf, $btnGameDir, $txtAddr, $btnInstall, $btnSet))
Apply-ThemeToForm $form $script:themeName

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = 'Fill'
$props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$props.UserDataFolder = $WvData
try { $props.Language = 'ru' } catch {}
$wv.CreationProperties = $props

$form.Controls.Add($wv)
$form.Controls.Add($panel)

function Get-CurApp {
    $i = $cmbGame.SelectedIndex
    if ($i -ge 0 -and $i -lt ($Games.Count - 1)) { return $Games[$i].App }
    return $txtApp.Text.Trim()
}

function Get-CurAppName {
    $i = $cmbGame.SelectedIndex
    if ($i -ge 0 -and $i -lt ($Games.Count - 1)) { return $Games[$i].Name }
    return ('Игра ' + $txtApp.Text.Trim())
}

function Save-Now {
    Update-Cfg $Base @{ game = $cmbGame.SelectedIndex; source = $(if ($script:tsMode) { 'thunderstore' } else { 'steam' }) }
}

function Select-GameExe {
    $c = Load-Cfg $Base
    $gameDir = if ($c.tsGameDir) { [string]$c.tsGameDir } else { '' }
    $current = if ($c.tsGameExe) { [string]$c.tsGameExe } else { '' }
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Title = 'Выбери EXE-файл игры'
    $fd.Filter = 'Исполняемые файлы (*.exe)|*.exe|Все файлы (*.*)|*.*'
    $fd.CheckFileExists = $true
    if ($gameDir -and (Test-Path $gameDir -PathType Container)) { $fd.InitialDirectory = $gameDir }
    if ($current -and (Test-Path $current -PathType Leaf)) { $fd.FileName = [System.IO.Path]::GetFileName($current) }
    if ($fd.ShowDialog($form) -ne 'OK') { return }
    $exePath = [System.IO.Path]::GetFullPath($fd.FileName)
    $dir = [System.IO.Path]::GetDirectoryName($exePath)
    Update-Cfg $Base @{ tsGameDir = $dir; tsGameExe = $exePath }
    $btnGameDir.Text = 'Папка игры ✓'
    [void][System.Windows.Forms.MessageBox]::Show(('EXE игры сохранён:`n' + $exePath), 'Запуск игры')
}

function Start-ConfiguredGame {
    $c = Load-Cfg $Base
    $exe = if ($c.tsGameExe) { [string]$c.tsGameExe } else { '' }
    $dir = if ($c.tsGameDir) { [string]$c.tsGameDir } else { '' }

    if (-not $exe -or -not (Test-Path $exe -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show('Сначала выбери EXE игры.`n`nНажми «Настройки» и выбери «EXE игры», либо выбери его через кнопку «Папка игры».', 'Запуск игры')
        Show-Settings
        return
    }
    if (-not $dir -or -not (Test-Path $dir -PathType Container)) {
        $dir = [System.IO.Path]::GetDirectoryName($exe)
    }
    try {
        Start-Process -FilePath $exe -WorkingDirectory $dir
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('Не удалось запустить игру:`n' + $_.Exception.Message), 'Запуск игры')
    }
}

function Select-TsGameFolder {
    $c = Load-Cfg $Base
    $current = if ($c.tsGameDir) { [string]$c.tsGameDir } else { '' }
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Выбери папку установленной игры для Thunderstore'
    $fb.ShowNewFolderButton = $false
    if ($current -and (Test-Path $current)) { $fb.SelectedPath = $current }
    if ($fb.ShowDialog($form) -ne 'OK') { return }
    $path = $fb.SelectedPath.Trim()
    if (-not (Test-Path $path -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('Выбранная папка не существует.', 'Папка игры')
        return
    }
    Update-Cfg $Base @{ tsGameDir = $path }
    $btnGameDir.Text = 'Папка игры ✓'
    [void][System.Windows.Forms.MessageBox]::Show(('Папка игры сохранена:`n' + $path), 'Thunderstore')
}

function Get-ProfileKey {
    if ($script:tsMode) {
        $c = Load-Cfg $Base
        $slug = if ($c.tsCommunity) { [string]$c.tsCommunity } else { 'lethal-company' }
        return ('ts:' + $slug)
    }
    return (Get-CurApp)
}

function Get-ProfileAppName {
    if ($script:tsMode) {
        $c = Load-Cfg $Base
        $slug = if ($c.tsCommunity) { [string]$c.tsCommunity } else { 'lethal-company' }
        return ('Thunderstore / ' + $slug)
    }
    return (Get-CurAppName)
}

function Update-Title {
    $t = if ($script:tsMode) { 'Thunderstore Mod Manager' } else { 'Steam Workshop Downloader' }
    $app = Get-ProfileKey
    if ($app) {
        $t += ' - ' + (Get-ProfileAppName)
        $s = Load-Store $Base
        $n = $s.active[$app]
        if ($n) { $t += ' / профиль "' + $n + '"' }
    }
    $form.Text = $t
}

function Current-ModId {
    if (-not $script:ready) { return $null }
    $u = [string]$wv.CoreWebView2.Source
    if ($u -match 'filedetails' -and $u -match '[?&]id=(\d+)') { return $Matches[1] }
    return $null
}

function Current-TsPackage {
    if (-not $script:ready) { return $null }
    $u = [string]$wv.CoreWebView2.Source
    if ($u -match '/c/([^/]+)/p/([^/]+)/([^/?#]+)/?') {
        return ($Matches[1] + '|' + $Matches[2] + '|' + $Matches[3])
    }
    return $null
}

function Update-Ui {
    if (-not $script:ready) { return }
    $txtAddr.Text = [string]$wv.CoreWebView2.Source
    $btnInstall.Enabled = if ($script:tsMode) { [bool](Current-TsPackage) } else { [bool](Current-ModId) }
    $btnBack.Enabled = $wv.CoreWebView2.CanGoBack
    $btnFwd.Enabled = $wv.CoreWebView2.CanGoForward
    Update-Title
}

function Go-Workshop {
    if (-not $script:ready) { return }
    $script:tsMode = $false
    Update-Cfg $Base @{ source = 'steam' }
    $app = Get-CurApp
    if ($app -notmatch '^\d+$') {
        [void][System.Windows.Forms.MessageBox]::Show('Впиши числовой App ID игры (он есть в адресе страницы игры в Steam).', 'Нужен App ID')
        return
    }
    Save-Now
    Update-Title
    $wv.CoreWebView2.Navigate('https://steamcommunity.com/app/' + $app + '/workshop/')
}

function Go-Thunderstore {
    if (-not $script:ready) { return }
    $c = Load-Cfg $Base
    $slug = if ($c.tsCommunity) { [string]$c.tsCommunity } else { 'lethal-company' }
    if ($slug -notmatch '^[a-z0-9-]+$') {
        [void][System.Windows.Forms.MessageBox]::Show('Неверный slug сообщества Thunderstore. Например: lethal-company', 'Thunderstore')
        return
    }
    Update-Cfg $Base @{ tsCommunity = $slug }
    $script:tsMode = $true
    Update-Cfg $Base @{ source = 'thunderstore' }
    $wv.CoreWebView2.Navigate('https://thunderstore.io/c/' + $slug + '/')
    Update-Title
}

function Start-TSInstallFlow($raw) {
    $parts = $raw -split '\|'
    if ($parts.Count -lt 3) { return }
    $community = [string]$parts[0]
    $owner = [string]$parts[1]
    $name = [string]$parts[2]

    $cfg = Load-Cfg $Base
    $gameDir = if ($cfg.tsGameDir) { [string]$cfg.tsGameDir } else { '' }
    if (-not $gameDir -or -not (Test-Path $gameDir -PathType Container)) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Сначала выбери папку установленной игры.`n`nНажми «Настройки» → «Выбрать папку...» или верхнюю кнопку «Папка игры».',
            'Thunderstore — папка игры', 'OKCancel')
        if ($r -eq 'OK') { Show-Settings }
        return
    }

    $store = Load-Store $Base
    $key = 'ts:' + $community
    $pname = $store.active[$key]
    if (-not $pname) {
        $pname = 'Основной'
    }

    # "Install with App" means: install into this launcher, not into a browser/downloads folder.
    # The worker resolves dependencies, downloads the package(s), extracts them into the
    # configured game/profile directory and records them in profiles.json.
    Show-JobWindow 'tsinstall' $raw $pname $key
}

# Нажали "Установить" на странице мода или коллекции
function Start-InstallFlow($id) {
    $info = $null
    try { $info = Get-FileInfo $id }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show('Не смог получить данные из Steam: ' + $_.Exception.Message, 'Workshop Downloader')
        return
    }
    if (-not $info) {
        [void][System.Windows.Forms.MessageBox]::Show('Steam не нашёл такой мод (он удалён или скрыт).', 'Workshop Downloader')
        return
    }
    $app = $info.app
    $store = Load-Store $Base
    $pname = $store.active[$app]
    if (-not $pname) { $pname = '' }
    $shown = if ($pname) { $pname } else { 'Основной' }

    if ($info.type -eq 2) {
        $msg = 'Это коллекция "' + $info.title + '" (модов: ' + $info.count + ').' + "`n`n" +
               'ДА: подписаться на коллекцию. Моды установятся в профиль "' + $shown + '", а при синхронизации новые добавятся, убранные из коллекции исчезнут, обновлённые перекачаются.' + "`n" +
               'НЕТ: установить моды один раз, без подписки.' + "`n" +
               'ОТМЕНА: ничего не делать.'
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Коллекция', 'YesNoCancel')
        if ($r -eq 'Yes') {
            $p = Get-OrMake-Prof $store $app $pname
            $exists = $false
            foreach ($c in @($p.collections)) { if ([string]$c.id -eq $info.id) { $exists = $true } }
            if (-not $exists) { $p.collections = @($p.collections) + @(, @{ id = $info.id; title = $info.title }) }
            Save-Store $Base $store
            Show-JobWindow 'sync' '' $p.name $app
        }
        elseif ($r -eq 'No') {
            Show-JobWindow 'install' $info.id $pname $app
        }
    }
    else {
        Show-JobWindow 'install' $info.id $pname $app
    }
    Update-Title
}

function Start-SyncActive {
    if ($script:tsMode) {
        $key = Get-ProfileKey
        $s = Load-Store $Base
        $n = $s.active[$key]
        if (-not $n) { return }
        $p = Find-Prof $s $key $n
        if (-not $p -or @($p.mods).Count -eq 0) { return }
        Show-JobWindow 'tssync' '' $n $key
        return
    }
    $app = Get-CurApp
    if ($app -notmatch '^\d+$') { return }
    $s = Load-Store $Base
    $n = $s.active[$app]
    if (-not $n) { return }
    $p = Find-Prof $s $app $n
    if (-not $p) { return }
    if ((@($p.mods).Count -eq 0) -and (@($p.collections).Count -eq 0)) { return }
    Show-JobWindow 'sync' '' $n $app
}

$wv.Add_CoreWebView2InitializationCompleted({
    param($s, $e)
    if (-not $e.IsSuccess) {
        $msg = "Не удалось запустить встроенный браузер (WebView2).`n" + $e.InitializationException.Message +
               "`n`nНа Windows 10 может понадобиться WebView2 Runtime от Microsoft. Открыть страницу загрузки?"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Workshop Downloader', 'YesNo')
        if ($r -eq 'Yes') { Start-Process 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' }
        return
    }
    $core = $wv.CoreWebView2
    $core.add_NewWindowRequested({
        param($s2, $e2)
        $e2.Handled = $true
        $wv.CoreWebView2.Navigate($e2.Uri)
    })
    $core.add_SourceChanged({ Update-Ui })
    $core.add_WebMessageReceived({
        param($s3, $e3)
        $m = $e3.TryGetWebMessageAsString()
        if ($m -like 'install:*') { $script:pendingId = $m.Substring(8) }
        elseif ($m -like 'tsinstall:*') { $script:pendingTs = $m.Substring(10) }
    })
    [void]$core.AddScriptToExecuteOnDocumentCreatedAsync($InjectJs)
    $script:ready = $true
    if ($script:tsMode) { Go-Thunderstore } else { Go-Workshop }
    $c = Load-Cfg $Base
    if ($c.autoUpdate -eq $true) { $script:startupSync = $true }
})

$cmbGame.Add_SelectedIndexChanged({
    $script:tsMode = $false
    $other = ($cmbGame.SelectedIndex -eq ($Games.Count - 1))
    $txtApp.Enabled = $other
    if (-not $other) { $txtApp.Text = $Games[$cmbGame.SelectedIndex].App; Go-Workshop }
    else { [void]$txtApp.Focus() }
    Update-Title
})
$cmbGame.SelectedIndex = $startGame
if ($startGame -ne ($Games.Count - 1)) { $txtApp.Text = $Games[$startGame].App; $txtApp.Enabled = $false }

$txtApp.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Go-Workshop }
})
$btnWs.Add_Click({ $script:tsMode = $false; Go-Workshop; Update-Ui })
$btnTs.Add_Click({ Go-Thunderstore; Update-Ui })
$btnBack.Add_Click({ if ($script:ready -and $wv.CoreWebView2.CanGoBack) { $wv.CoreWebView2.GoBack() } })
$btnFwd.Add_Click({ if ($script:ready -and $wv.CoreWebView2.CanGoForward) { $wv.CoreWebView2.GoForward() } })
$btnReload.Add_Click({ if ($script:ready) { $wv.CoreWebView2.Reload() } })
$btnInstall.Add_Click({
    if ($script:tsMode) {
        $x = Current-TsPackage
        if ($x) { $script:pendingTs = $x }
    } else {
        $id = Current-ModId
        if ($id) { $script:pendingId = $id }
    }
})

# Очередь действий: установка из кнопки, автосинхронизация при запуске
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 200
$poll.Add_Tick({
    if ($script:busy) { return }
    if ($script:pendingTs) {
        $x = $script:pendingTs
        $script:pendingTs = $null
        $script:busy = $true
        try { Start-TSInstallFlow $x }
        finally { $script:busy = $false }
    }
    elseif ($script:pendingId) {
        $id = $script:pendingId
        $script:pendingId = $null
        $script:busy = $true
        try { Save-Now; Start-InstallFlow $id }
        finally { $script:busy = $false }
    }
    elseif ($script:startupSync) {
        $script:startupSync = $false
        $script:busy = $true
        try { Start-SyncActive; Update-Title }
        finally { $script:busy = $false }
    }
})
$poll.Start()

# ------------------------------------------------------------ окно профилей
function Pm-Profs {
    $r = @()
    foreach ($p in $script:pmStore.profiles) { if ($p.app -eq $script:pmApp) { $r += $p } }
    return ,$r
}
function Pm-Cur {
    if (-not $script:pmSel) { return $null }
    return (Find-Prof $script:pmStore $script:pmApp $script:pmSel)
}
function Pm-Save { Save-Store $Base $script:pmStore }

function Pm-ShowMods {
    $script:pmLoading = $true
    $script:pmMods.Items.Clear()
    $script:pmCols.Items.Clear()
    $p = Pm-Cur
    if ($p) {
        foreach ($m in @($p.mods)) {
            $t = [string]$m.title + ' [' + $m.id + ']'
            if ($m.source -and $m.source -ne 'dependency' -and $m.source -ne 'framework') { $t += '   (из коллекции)' }
            [void]$script:pmMods.Items.Add($t, [bool]$m.enabled)
        }
        foreach ($c in @($p.collections)) { [void]$script:pmCols.Items.Add([string]$c.title + ' [' + $c.id + ']') }
    }
    $script:pmLoading = $false
}

function Pm-Reload {
    $script:pmStore = Load-Store $Base
    $profs = Pm-Profs
    $act = $script:pmStore.active[$script:pmApp]
    $script:pmLoading = $true
    $script:pmList.Items.Clear()
    $script:pmNames = @()
    $sel = -1
    $i = 0
    foreach ($p in $profs) {
        $script:pmNames += [string]$p.name
        $label = [string]$p.name
        if ($p.name -eq $act) { $label += '   [OK] активный' }
        [void]$script:pmList.Items.Add($label)
        if ($p.name -eq $script:pmSel) { $sel = $i }
        $i++
    }
    if ($sel -lt 0 -and $act) {
        for ($j = 0; $j -lt $script:pmNames.Count; $j++) { if ($script:pmNames[$j] -eq $act) { $sel = $j } }
    }
    if ($sel -lt 0 -and $script:pmNames.Count -gt 0) { $sel = 0 }
    if ($sel -ge 0) { $script:pmList.SelectedIndex = $sel; $script:pmSel = $script:pmNames[$sel] } else { $script:pmSel = $null }
    $script:pmLoading = $false
    Pm-ShowMods
}

function Pm-UniqueName($base0) {
    $n = $base0
    $k = 2
    while (Find-Prof $script:pmStore $script:pmApp $n) { $n = $base0 + ' ' + $k; $k++ }
    return $n
}

function Show-Profiles($app, $appName) {
    $script:pmApp = [string]$app
    $script:pmSel = $null
    $script:pmLoading = $false
    $script:pmNames = @()

    $f = New-Ctl 'System.Windows.Forms.Form' ('Профили: ' + $appName + ' (' + $app + ')') 0 0 880 590
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $l1 = New-Ctl 'System.Windows.Forms.Label' 'Профили:' 12 10 200 20
    $script:pmList = New-Ctl 'System.Windows.Forms.ListBox' '' 12 32 240 330
    $bNew  = New-Ctl 'System.Windows.Forms.Button' 'Создать' 12 370 112 28
    $bRen  = New-Ctl 'System.Windows.Forms.Button' 'Переименовать' 130 370 122 28
    $bCopy = New-Ctl 'System.Windows.Forms.Button' 'Копия' 12 404 112 28
    $bDel  = New-Ctl 'System.Windows.Forms.Button' 'Удалить' 130 404 122 28

    $l2 = New-Ctl 'System.Windows.Forms.Label' 'Моды профиля (галочка = включён):' 266 10 400 20
    $script:pmMods = New-Ctl 'System.Windows.Forms.CheckedListBox' '' 266 32 596 240
    $script:pmMods.CheckOnClick = $true
    $bRm = New-Ctl 'System.Windows.Forms.Button' 'Убрать из профиля' 266 280 160 28
    $l3 = New-Ctl 'System.Windows.Forms.Label' 'Подписки на коллекции:' 266 322 300 20
    $script:pmCols = New-Ctl 'System.Windows.Forms.ListBox' '' 266 344 596 80
    $bUn = New-Ctl 'System.Windows.Forms.Button' 'Отписаться' 266 430 130 28

    $hintText = if ([string]$app -like 'ts:*') {
        'Применить: распаковывает включённые пакеты Thunderstore в папку игры. Синхронизировать: проверяет новые версии и зависимости.'
    } else {
        'Применить: ставит включённые моды профиля в игру и убирает моды других профилей (только те, что ставила эта программа). ' +
        'Синхронизировать: ещё и подтягивает изменения в подписанных коллекциях и перекачивает обновлённые моды.'
    }
    $hint = New-Ctl 'System.Windows.Forms.Label' $hintText 12 466 850 36
    $hint.ForeColor = [System.Drawing.Color]::Gray

    $bApply = New-Ctl 'System.Windows.Forms.Button' 'Применить профиль' 12 512 170 34
    $bSync  = New-Ctl 'System.Windows.Forms.Button' 'Синхронизировать' 190 512 170 34
    $bExp   = New-Ctl 'System.Windows.Forms.Button' 'Экспорт кода' 368 512 130 34
    $bImp   = New-Ctl 'System.Windows.Forms.Button' 'Импорт кода' 506 512 130 34
    $bClose = New-Ctl 'System.Windows.Forms.Button' 'Закрыть' 762 512 100 34

    $f.Controls.AddRange(@($l1, $script:pmList, $bNew, $bRen, $bCopy, $bDel, $l2, $script:pmMods, $bRm, $l3, $script:pmCols, $bUn, $hint, $bApply, $bSync, $bExp, $bImp, $bClose))

    if ([string]$app -like 'ts:*') {
        $l3.Text = 'Thunderstore: зависимости добавляются автоматически'
        $script:pmCols.Visible = $false
        $bUn.Visible = $false
    }

    $script:pmList.Add_SelectedIndexChanged({
        if ($script:pmLoading) { return }
        $i = $script:pmList.SelectedIndex
        if ($i -ge 0 -and $i -lt $script:pmNames.Count) { $script:pmSel = $script:pmNames[$i] }
        Pm-ShowMods
    })

    $script:pmMods.Add_ItemCheck({
        param($s, $e)
        if ($script:pmLoading) { return }
        $p = Pm-Cur
        if (-not $p) { return }
        $mods = @($p.mods)
        if ($e.Index -ge 0 -and $e.Index -lt $mods.Count) {
            if ([string]$mods[$e.Index].source -eq 'framework') {
                # BepInEx — обязательная основа Thunderstore-профиля.
                $e.NewValue = 'Checked'
                return
            }
            $mods[$e.Index].enabled = ($e.NewValue -eq 'Checked')
            Pm-Save
        }
    })

    $bNew.Add_Click({
        $n = Ask-Text 'Новый профиль' 'Название профиля:' ''
        if (-not $n) { return }
        if (Find-Prof $script:pmStore $script:pmApp $n) {
            [void][System.Windows.Forms.MessageBox]::Show('Профиль с таким названием уже есть.', 'Профили')
            return
        }
        $newProf = New-Prof $script:pmStore $script:pmApp $n
        if ([string]$script:pmApp -like 'ts:*') { Ensure-TsFrameworkMarker $newProf }
        Pm-Save
        $script:pmSel = $n
        Pm-Reload
    })

    $bRen.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        $n = Ask-Text 'Переименовать' 'Новое название:' ([string]$p.name)
        if (-not $n -or $n -eq $p.name) { return }
        if (Find-Prof $script:pmStore $script:pmApp $n) {
            [void][System.Windows.Forms.MessageBox]::Show('Профиль с таким названием уже есть.', 'Профили')
            return
        }
        if ($script:pmStore.active[$script:pmApp] -eq $p.name) { $script:pmStore.active[$script:pmApp] = $n }
        $p.name = $n
        Pm-Save
        $script:pmSel = $n
        Pm-Reload
    })

    $bCopy.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        $c = To-Hash (($p | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
        $c.name = Pm-UniqueName ([string]$p.name + ' (копия)')
        $script:pmStore.profiles = @($script:pmStore.profiles) + @(, $c)
        Pm-Save
        $script:pmSel = $c.name
        Pm-Reload
    })

    $bDel.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        $r = [System.Windows.Forms.MessageBox]::Show(('Удалить профиль "' + $p.name + '"?') + "`nМоды, уже стоящие в игре, останутся, пока ты не применишь другой профиль.", 'Удаление', 'YesNo')
        if ($r -ne 'Yes') { return }
        $name = [string]$p.name
        $keep = @()
        foreach ($x in $script:pmStore.profiles) {
            if (-not (($x.app -eq $script:pmApp) -and ($x.name -eq $name))) { $keep += $x }
        }
        $script:pmStore.profiles = $keep
        if ($script:pmStore.active[$script:pmApp] -eq $name) { $script:pmStore.active.Remove($script:pmApp) }
        Pm-Save
        $script:pmSel = $null
        Pm-Reload
    })

    $bRm.Add_Click({
        $p = Pm-Cur
        $i = $script:pmMods.SelectedIndex
        if (-not $p -or $i -lt 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Выбери мод в списке.', 'Профили')
            return
        }
        $mods = @($p.mods)
        if ([string]$mods[$i].source -eq 'framework') {
            [void][System.Windows.Forms.MessageBox]::Show('BepInEx — обязательная основа для модов Thunderstore. Его нельзя убрать из профиля.', 'Профили')
            return
        }
        if ($mods[$i].source) {
            [void][System.Windows.Forms.MessageBox]::Show('Этот мод пришёл из подписки на коллекцию и вернётся при синхронизации. Сними галочку, чтобы отключить его.', 'Профили')
            return
        }
        $new = @()
        for ($j = 0; $j -lt $mods.Count; $j++) { if ($j -ne $i) { $new += $mods[$j] } }
        $p.mods = $new
        Pm-Save
        Pm-ShowMods
    })

    $bUn.Add_Click({
        $p = Pm-Cur
        $i = $script:pmCols.SelectedIndex
        if (-not $p -or $i -lt 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Выбери коллекцию в списке подписок.', 'Профили')
            return
        }
        $cols = @($p.collections)
        $cid = [string]$cols[$i].id
        $new = @()
        for ($j = 0; $j -lt $cols.Count; $j++) { if ($j -ne $i) { $new += $cols[$j] } }
        $p.collections = $new
        foreach ($m in @($p.mods)) { if ([string]$m.source -eq $cid) { $m.source = '' } }
        Pm-Save
        Pm-ShowMods
    })

    $bApply.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        Pm-Save
        $mode = if ([string]$script:pmApp -like 'ts:*') { 'tsapply' } else { 'apply' }
        Show-JobWindow $mode '' ([string]$p.name) $script:pmApp
        Update-Title
        Pm-Reload
    })

    $bSync.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        Pm-Save
        $mode = if ([string]$script:pmApp -like 'ts:*') { 'tssync' } else { 'sync' }
        Show-JobWindow $mode '' ([string]$p.name) $script:pmApp
        Update-Title
        Pm-Reload
    })

    $bExp.Add_Click({
        $p = Pm-Cur
        if (-not $p) { return }
        $mods = @()
        foreach ($m in @($p.mods)) { $mods += @{ id = [string]$m.id; title = [string]$m.title; enabled = [bool]$m.enabled; source = [string]$m.source } }
        $cols = @()
        foreach ($c in @($p.collections)) { $cols += @{ id = [string]$c.id; title = [string]$c.title } }
        $o = @{ v = 1; name = [string]$p.name; app = [string]$p.app; mods = $mods; collections = $cols }
        $json = $o | ConvertTo-Json -Depth 6 -Compress
        $code = 'WSDL1:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        Set-Clipboard -Value $code
        [void][System.Windows.Forms.MessageBox]::Show('Код профиля скопирован в буфер обмена.' + "`n" + 'Отправь его другу: он нажмёт "Импорт кода" и получит такой же набор модов.', 'Экспорт')
    })

    $bImp.Add_Click({
        $t = Get-Clipboard -Raw
        if (-not $t -or (-not $t.Trim().StartsWith('WSDL1:'))) {
            [void][System.Windows.Forms.MessageBox]::Show('В буфере обмена нет кода профиля. Скопируй код (он начинается с WSDL1:) и нажми снова.', 'Импорт')
            return
        }
        try {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t.Trim().Substring(6)))
            $o = To-Hash ($json | ConvertFrom-Json)
            $app = [string]$o.app
            if (($app -notmatch '^\d+$') -and ($app -notlike 'ts:*')) { throw 'в коде нет корректного идентификатора игры' }
            $name = [string]$o.name
            if (-not $name) { $name = 'Импорт' }
            $n = $name
            $k = 2
            while (Find-Prof $script:pmStore $app $n) { $n = $name + ' ' + $k; $k++ }
            $p = New-Prof $script:pmStore $app $n
            foreach ($m in @($o.mods)) {
                $p.mods = @($p.mods) + @(, @{ id = [string]$m.id; title = [string]$m.title; enabled = [bool]$m.enabled; updated = 0; source = [string]$m.source })
            }
            foreach ($c in @($o.collections)) {
                $p.collections = @($p.collections) + @(, @{ id = [string]$c.id; title = [string]$c.title })
            }
            Pm-Save
            if ($app -eq $script:pmApp) {
                $script:pmSel = $n
                Pm-Reload
                [void][System.Windows.Forms.MessageBox]::Show(('Профиль "' + $n + '" создан. Нажми "Синхронизировать", чтобы скачать и поставить его моды.'), 'Импорт')
            } else {
                [void][System.Windows.Forms.MessageBox]::Show(('Профиль "' + $n + '" создан для другой игры/сообщества (' + $app + '). Переключись на соответствующий источник и открой "Профили".'), 'Импорт')
            }
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show('Не получилось прочитать код: ' + $_.Exception.Message, 'Импорт')
        }
    })

    $bClose.Add_Click({ $script:pmForm.Close() })
    Apply-ThemeToForm $f $script:themeName
    $script:pmForm = $f

    Pm-Reload
    [void]$f.ShowDialog($form)
}

$btnProf.Add_Click({
    $app = Get-ProfileKey
    if ($script:tsMode) {
        $c = Load-Cfg $Base
        $slug = if ($c.tsCommunity) { [string]$c.tsCommunity } else { 'lethal-company' }
        Show-Profiles $app ('Thunderstore / ' + $slug)
    } else {
        if ($app -notmatch '^\d+$') {
            [void][System.Windows.Forms.MessageBox]::Show('Сначала выбери игру или впиши App ID.', 'Профили')
            return
        }
        Show-Profiles $app (Get-CurAppName)
    }
    Update-Title
})

# ------------------------------------------------------------ настройки
function Add-PathRow($form, $label, $y, $value, $extraText) {
    $l = New-Ctl 'System.Windows.Forms.Label' $label 12 $y 440 20
    $t = New-Ctl 'System.Windows.Forms.TextBox' $value 12 ($y + 22) 440 24
    $b = New-Ctl 'System.Windows.Forms.Button' 'Обзор...' 462 ($y + 20) 84 27
    $b.Tag = $t
    $b.Add_Click({
        param($s, $e)
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $tb = $s.Tag
        if ($tb.Text -and (Test-Path $tb.Text)) { $fb.SelectedPath = $tb.Text }
        if ($fb.ShowDialog() -eq 'OK') { $tb.Text = $fb.SelectedPath }
    })
    $form.Controls.AddRange(@($l, $t, $b))
    return $t
}

function Show-Settings {
    $c = Load-Cfg $Base
    $d = New-Ctl 'System.Windows.Forms.Form' 'Настройки' 0 0 720 720
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:setDlg = $d

    $vOut   = if ($c.out) { [string]$c.out } else { $DefaultOut }
    $vZom   = if ($c.zomboidMods) { [string]$c.zomboidMods } else { $DefaultZom }
    $vRw    = if ($c.rimworldDir) { [string]$c.rimworldDir } else { '' }
    $vCache = if ($c.cache) { [string]$c.cache } else { $DefaultCache }
    $vUser  = if ($c.user) { [string]$c.user } else { '' }
    $vTsCommunity = if ($c.tsCommunity) { [string]$c.tsCommunity } else { 'lethal-company' }
    $vTsGame = if ($c.tsGameDir) { [string]$c.tsGameDir } else { '' }
    $vTsExe = if ($c.tsGameExe) { [string]$c.tsGameExe } else { '' }
    $vTsData = if ($c.tsData) { [string]$c.tsData } else { $DefaultTsData }

    $script:stOut   = Add-PathRow $d 'Папка для модов других игр:' 12 $vOut $null
    $script:stZom   = Add-PathRow $d 'Project Zomboid: папка модов:' 68 $vZom $null
    $script:stRw    = Add-PathRow $d 'RimWorld: папка игры:' 124 $vRw $null
    $script:stCache = Add-PathRow $d 'Кеш Steam Workshop:' 180 $vCache $null

    $lTs = New-Ctl 'System.Windows.Forms.Label' 'Thunderstore' 12 236 300 22
    $lTs.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $d.Controls.Add($lTs)

    $lSlug = New-Ctl 'System.Windows.Forms.Label' 'Community slug:' 12 266 180 20
    $script:stTsCommunity = New-Ctl 'System.Windows.Forms.TextBox' $vTsCommunity 12 288 420 24
    $d.Controls.AddRange(@($lSlug, $script:stTsCommunity))

    $lGame = New-Ctl 'System.Windows.Forms.Label' 'Папка игры Thunderstore:' 12 326 300 20
    $script:stTsGame = New-Ctl 'System.Windows.Forms.TextBox' $vTsGame 12 348 520 26
    $bTsGame = New-Ctl 'System.Windows.Forms.Button' 'Выбрать папку...' 542 346 130 30
    $bTsGame.Tag = $script:stTsGame
    $bTsGame.Add_Click({
        param($sender, $e)
        $tb = $sender.Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Выбери папку установленной игры для Thunderstore'
        $fb.ShowNewFolderButton = $false
        if ($tb.Text -and (Test-Path $tb.Text)) { $fb.SelectedPath = $tb.Text }
        if ($fb.ShowDialog($d) -eq 'OK') { $tb.Text = $fb.SelectedPath }
    })
    $d.Controls.AddRange(@($lGame, $script:stTsGame, $bTsGame))

    $lExe = New-Ctl 'System.Windows.Forms.Label' 'EXE игры для кнопки «Играть»:' 12 390 400 20
    $script:stTsExe = New-Ctl 'System.Windows.Forms.TextBox' $vTsExe 12 412 520 26
    $bTsExe = New-Ctl 'System.Windows.Forms.Button' 'Выбрать EXE...' 542 410 130 30
    $bTsExe.Tag = $script:stTsExe
    $bTsExe.Add_Click({
        param($sender, $e)
        $tb = $sender.Tag
        $fd = New-Object System.Windows.Forms.OpenFileDialog
        $fd.Title = 'Выбери EXE-файл игры'
        $fd.Filter = 'Исполняемые файлы (*.exe)|*.exe|Все файлы (*.*)|*.*'
        $fd.CheckFileExists = $true
        $gameDir = $script:stTsGame.Text.Trim()
        if ($gameDir -and (Test-Path $gameDir -PathType Container)) { $fd.InitialDirectory = $gameDir }
        if ($tb.Text -and (Test-Path $tb.Text -PathType Leaf)) { $fd.FileName = [System.IO.Path]::GetFileName($tb.Text) }
        if ($fd.ShowDialog($d) -eq 'OK') {
            $tb.Text = [System.IO.Path]::GetFullPath($fd.FileName)
            $script:stTsGame.Text = [System.IO.Path]::GetDirectoryName($tb.Text)
        }
    })
    $d.Controls.AddRange(@($lExe, $script:stTsExe, $bTsExe))

    $lData = New-Ctl 'System.Windows.Forms.Label' 'Thunderstore: кеш и индекс пакетов:' 12 454 400 20
    $script:stTsData = New-Ctl 'System.Windows.Forms.TextBox' $vTsData 12 476 520 26
    $bTsData = New-Ctl 'System.Windows.Forms.Button' 'Выбрать папку...' 542 474 130 30
    $bTsData.Tag = $script:stTsData
    $bTsData.Add_Click({
        param($sender, $e)
        $tb = $sender.Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Выбери папку для кеша Thunderstore'
        if ($tb.Text -and (Test-Path $tb.Text)) { $fb.SelectedPath = $tb.Text }
        if ($fb.ShowDialog($d) -eq 'OK') { $tb.Text = $fb.SelectedPath }
    })
    $d.Controls.AddRange(@($lData, $script:stTsData, $bTsData))

    $bClr = New-Ctl 'System.Windows.Forms.Button' 'Очистить кеш' 12 518 120 30
    $d.Controls.Add($bClr)

    $lTheme = New-Ctl 'System.Windows.Forms.Label' 'Тема интерфейса:' 350 518 200 20
    $cmbTheme = New-Ctl 'System.Windows.Forms.ComboBox' '' 350 542 260 26
    $cmbTheme.DropDownStyle = 'DropDownList'
    [void]$cmbTheme.Items.Add('Белая')
    [void]$cmbTheme.Items.Add('Чёрная')
    [void]$cmbTheme.Items.Add('Тёмно-синяя')
    switch ($script:themeName) {
        'black' { $cmbTheme.SelectedIndex = 1 }
        'darkblue' { $cmbTheme.SelectedIndex = 2 }
        default { $cmbTheme.SelectedIndex = 0 }
    }
    $d.Controls.AddRange(@($lTheme, $cmbTheme))
    $cmbTheme.Add_SelectedIndexChanged({
        $names = @('white','black','darkblue')
        if ($cmbTheme.SelectedIndex -ge 0) {
            $script:themeName = $names[$cmbTheme.SelectedIndex]
            Apply-ThemeToForm $d $script:themeName
            Apply-ThemeToForm $form $script:themeName
        }
    })

    $l5 = New-Ctl 'System.Windows.Forms.Label' 'Аккаунт Steam:' 12 564 300 20
    $script:stUser = New-Ctl 'System.Windows.Forms.TextBox' $vUser 12 586 250 24
    $bLogin = New-Ctl 'System.Windows.Forms.Button' 'Войти (консоль)' 272 584 130 27
    $script:stAuto = New-Object System.Windows.Forms.CheckBox
    $script:stAuto.Text = 'При запуске проверять обновления активного профиля'
    $script:stAuto.Location = New-Object System.Drawing.Point(12, 622)
    $script:stAuto.Size = New-Object System.Drawing.Size(500, 24)
    $script:stAuto.Checked = ($c.autoUpdate -eq $true)
    $d.Controls.AddRange(@($l5, $script:stUser, $bLogin, $script:stAuto))

    $bOk = New-Ctl 'System.Windows.Forms.Button' 'Сохранить' 508 666 100 30
    $bCancel = New-Ctl 'System.Windows.Forms.Button' 'Отмена' 618 666 82 30
    $d.Controls.AddRange(@($bOk, $bCancel))

    $bClr.Add_Click({
        $dir1 = Join-Path $script:stCache.Text.Trim() 'steamapps\workshop'
        $dir2 = $script:stTsData.Text.Trim()
        $r = [System.Windows.Forms.MessageBox]::Show("Удалить кеш Steam Workshop и Thunderstore?`nУже установленные в игру файлы не пострадают, недостающее скачается заново.", 'Очистка кеша', 'YesNo')
        if ($r -ne 'Yes') { return }
        try {
            if (Test-Path $dir1) { Remove-Item $dir1 -Recurse -Force }
            if ($dir2 -and (Test-Path $dir2)) {
                Remove-Item (Join-Path $dir2 'downloads') -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $dir2 'index') -Recurse -Force -ErrorAction SilentlyContinue
            }
            [void][System.Windows.Forms.MessageBox]::Show('Кеш очищен.', 'Очистка кеша')
        } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка') }
    })

    $bLogin.Add_Click({
        $u = $script:stUser.Text.Trim()
        if (-not $u) { [void][System.Windows.Forms.MessageBox]::Show('Сначала впиши имя аккаунта Steam.', 'Вход'); return }
        try {
            if (-not (Test-Path $ScExe)) {
                New-Item -ItemType Directory -Force $ScDir | Out-Null
                $zip = Join-Path $ScDir 'steamcmd.zip'
                Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing
                Expand-Archive $zip -DestinationPath $ScDir -Force
                Remove-Item $zip -Force
            }
            $cache = $script:stCache.Text.Trim()
            New-Item -ItemType Directory -Force $cache | Out-Null
            [void][System.Windows.Forms.MessageBox]::Show("Откроется консоль SteamCMD. Введи пароль и код Steam Guard.`nПосле успешного входа введи quit.", 'Вход')
            Start-Process -FilePath $ScExe -WorkingDirectory $ScDir -ArgumentList @('+force_install_dir', ('"' + $cache + '"'), '+login', $u)
        } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка') }
    })

    $bOk.Add_Click({
        $gameDir = $script:stTsGame.Text.Trim()
        if ($gameDir -and -not (Test-Path $gameDir -PathType Container)) {
            $r = [System.Windows.Forms.MessageBox]::Show('Папка Thunderstore не существует. Создать её?', 'Папка игры', 'YesNo')
            if ($r -eq 'Yes') { New-Item -ItemType Directory -Force $gameDir | Out-Null }
            else { return }
        }
        if (-not $gameDir) {
            $r = [System.Windows.Forms.MessageBox]::Show('Папка игры Thunderstore не выбрана. Без неё моды устанавливать нельзя. Сохранить настройки всё равно?', 'Папка игры', 'YesNo')
            if ($r -ne 'Yes') { return }
        }
        Update-Cfg $Base @{
            out = $script:stOut.Text.Trim()
            zomboidMods = $script:stZom.Text.Trim()
            rimworldDir = $script:stRw.Text.Trim()
            cache = $script:stCache.Text.Trim()
            user = $script:stUser.Text.Trim()
            autoUpdate = [bool]$script:stAuto.Checked
            tsCommunity = $script:stTsCommunity.Text.Trim().ToLowerInvariant()
            tsGameDir = $gameDir
            tsGameExe = $script:stTsExe.Text.Trim()
            tsData = $script:stTsData.Text.Trim()
            theme = $script:themeName
        }
        if ($gameDir) { $btnGameDir.Text = 'Папка игры ✓' }
        if ($script:stTsExe.Text.Trim() -and (Test-Path $script:stTsExe.Text.Trim() -PathType Leaf)) { $btnPlay.Text = '▶ Играть' }
        $script:setDlg.Close()
    })
    $bCancel.Add_Click({ $script:setDlg.Close() })
    Apply-ThemeToForm $d $script:themeName
    [void]$d.ShowDialog($form)
}
$btnPlay.Add_Click({ Start-ConfiguredGame })
$btnGameDir.Add_Click({ Select-TsGameFolder })
$btnSet.Add_Click({ Show-Settings })

$form.Add_Shown({ [void]$wv.EnsureCoreWebView2Async($null); Update-Title })
$form.Add_FormClosing({ Update-Cfg $Base @{ theme = $script:themeName }; Save-Now })

try {
    [void]$form.ShowDialog()
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка')
}
