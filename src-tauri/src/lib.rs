use serde::Serialize;
use std::{
    collections::HashSet,
    io::Cursor,
    path::{Path, PathBuf},
};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_deep_link::DeepLinkExt;
use url::Url;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent("mod-manager/0.1")
        .build()
        .map_err(err)
}

/// Пустая строка в настройках = папка по умолчанию в данных пользователя.
fn resolve_dir(s: &str) -> PathBuf {
    if s.trim().is_empty() {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("ModManager")
            .join("mods")
    } else {
        PathBuf::from(s.trim())
    }
}

async fn fetch_bytes(url: &str) -> Result<Vec<u8>, String> {
    let resp = client()?.get(url).send().await.map_err(err)?;
    if !resp.status().is_success() {
        return Err(format!("Сервер ответил {} на {}", resp.status(), url));
    }
    Ok(resp.bytes().await.map_err(err)?.to_vec())
}

fn extract_zip(bytes: Vec<u8>, dest: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dest).map_err(err)?;
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).map_err(err)?;
    archive.extract(dest).map_err(err)
}

// ---------- разбор ссылок ----------

#[derive(Serialize)]
struct LinkInfo {
    /// "thunderstore" | "steam" | "nexus" | "nexus_page"
    source: String,
    id: String,
    game: Option<String>,
}

#[tauri::command]
fn parse_link(link: String) -> Result<LinkInfo, String> {
    let link = link.trim();
    let u = Url::parse(link).map_err(|_| "Это не похоже на ссылку".to_string())?;
    let host = u.host_str().unwrap_or("").to_string();
    let segs: Vec<String> = u
        .path_segments()
        .map(|s| s.filter(|x| !x.is_empty()).map(String::from).collect())
        .unwrap_or_default();

    match u.scheme() {
        // nxm://lethalcompany/mods/123/files/456?key=...&expires=...
        "nxm" => Ok(LinkInfo { source: "nexus".into(), id: link.into(), game: Some(host) }),
        // ror2mm://v1/install/thunderstore.io/Owner/Name/1.0.0/
        "ror2mm" => {
            if segs.len() >= 4 && segs[0] == "install" {
                Ok(LinkInfo {
                    source: "thunderstore".into(),
                    id: format!("{}-{}", segs[2], segs[3]),
                    game: None,
                })
            } else {
                Err("Не удалось разобрать ссылку Thunderstore".into())
            }
        }
        "http" | "https" => {
            if host.ends_with("steamcommunity.com") {
                let id = u
                    .query_pairs()
                    .find(|(k, _)| k == "id")
                    .map(|(_, v)| v.to_string())
                    .filter(|v| v.chars().all(|c| c.is_ascii_digit()))
                    .ok_or("В ссылке Steam нет id мода")?;
                Ok(LinkInfo { source: "steam".into(), id, game: None })
            } else if host.ends_with("thunderstore.io") {
                // /c/<community>/p/<owner>/<name>/
                if segs.len() >= 5 && segs[0] == "c" && segs[2] == "p" {
                    Ok(LinkInfo {
                        source: "thunderstore".into(),
                        id: format!("{}-{}", segs[3], segs[4]),
                        game: Some(segs[1].clone()),
                    })
                } else {
                    Err("Нужна ссылка на страницу конкретного мода Thunderstore".into())
                }
            } else if host.ends_with("nexusmods.com") {
                Ok(LinkInfo { source: "nexus_page".into(), id: link.into(), game: segs.first().cloned() })
            } else {
                Err("Поддерживаются Steam Workshop, Thunderstore и Nexus Mods".into())
            }
        }
        _ => Err("Неизвестный тип ссылки".into()),
    }
}

// ---------- Thunderstore ----------

#[derive(Serialize)]
struct Mod {
    full_name: String,
    owner: String,
    name: String,
    description: String,
    icon: String,
    version: String,
    downloads: u64,
    url: String,
}

#[tauri::command]
async fn thunderstore_search(community: String, query: String) -> Result<Vec<Mod>, String> {
    let url = format!("https://thunderstore.io/c/{community}/api/v1/package/");
    let list: Vec<serde_json::Value> = client()?
        .get(url)
        .send()
        .await
        .map_err(err)?
        .json()
        .await
        .map_err(err)?;

    let q = query.trim().to_lowercase();
    let s = |v: &serde_json::Value| v.as_str().unwrap_or("").to_string();

    let mut out: Vec<Mod> = list
        .iter()
        .filter(|p| !p["is_deprecated"].as_bool().unwrap_or(false))
        .filter(|p| q.is_empty() || s(&p["full_name"]).to_lowercase().contains(&q))
        .map(|p| {
            let latest = &p["versions"][0];
            let downloads = p["versions"]
                .as_array()
                .map(|v| v.iter().filter_map(|x| x["downloads"].as_u64()).sum())
                .unwrap_or(0);
            Mod {
                full_name: s(&p["full_name"]),
                owner: s(&p["owner"]),
                name: s(&p["name"]),
                description: s(&latest["description"]),
                icon: s(&latest["icon"]),
                version: s(&latest["version_number"]),
                downloads,
                url: s(&p["package_url"]),
            }
        })
        .collect();

    out.sort_by(|a, b| b.downloads.cmp(&a.downloads));
    out.truncate(40);
    Ok(out)
}

/// "Owner-Name-1.2.3" -> ("Owner", "Name", "1.2.3")
fn split_dep(dep: &str) -> Option<(String, String, String)> {
    let (rest, version) = dep.rsplit_once('-')?;
    let (owner, name) = rest.split_once('-')?;
    Some((owner.into(), name.into(), version.into()))
}

#[tauri::command]
async fn thunderstore_install(full_name: String, mods_dir: String) -> Result<Vec<String>, String> {
    let (owner, name) = full_name
        .split_once('-')
        .ok_or("Ожидался формат Автор-Название")?;

    // последняя версия и зависимости
    let info: serde_json::Value = client()?
        .get(format!("https://thunderstore.io/api/experimental/package/{owner}/{name}/"))
        .send()
        .await
        .map_err(err)?
        .json()
        .await
        .map_err(|_| format!("Мод {full_name} не найден на Thunderstore"))?;
    let version = info["latest"]["version_number"]
        .as_str()
        .ok_or("Не удалось узнать версию мода")?
        .to_string();

    let root = resolve_dir(&mods_dir);
    let mut stack = vec![(owner.to_string(), name.to_string(), version)];
    let mut seen: HashSet<String> = HashSet::new();
    let mut done = vec![];

    while let Some((o, n, v)) = stack.pop() {
        let key = format!("{o}-{n}");
        if !seen.insert(key.clone()) {
            continue;
        }
        let bytes = fetch_bytes(&format!("https://thunderstore.io/package/download/{o}/{n}/{v}/")).await?;

        // зависимости читаем из manifest.json внутри архива
        let manifest = read_manifest(&bytes);
        extract_zip(bytes, &root.join(&key))?;
        done.push(format!("{key} {v}"));

        for dep in manifest {
            if let Some(d) = split_dep(&dep) {
                stack.push(d);
            }
        }
    }
    Ok(done)
}

fn read_manifest(bytes: &[u8]) -> Vec<String> {
    use std::io::Read;
    let Ok(mut z) = zip::ZipArchive::new(Cursor::new(bytes)) else { return vec![] };
    let Ok(mut f) = z.by_name("manifest.json") else { return vec![] };
    let mut text = String::new();
    if f.read_to_string(&mut text).is_err() {
        return vec![];
    }
    // manifest.json иногда начинается с BOM
    let text = text.trim_start_matches('\u{feff}');
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v["dependencies"].as_array().cloned())
        .map(|a| a.iter().filter_map(|d| d.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

// ---------- Steam Workshop ----------

#[derive(Serialize)]
struct SteamItem {
    title: String,
    app_id: String,
}

async fn steam_info(id: &str) -> Result<SteamItem, String> {
    let res: serde_json::Value = client()?
        .post("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")
        .form(&[("itemcount", "1"), ("publishedfileids[0]", id)])
        .send()
        .await
        .map_err(err)?
        .json()
        .await
        .map_err(err)?;
    let d = &res["response"]["publishedfiledetails"][0];
    let app_id = d["consumer_app_id"].as_u64().ok_or("Мод не найден в Мастерской Steam")?;
    Ok(SteamItem {
        title: d["title"].as_str().unwrap_or("").into(),
        app_id: app_id.to_string(),
    })
}

#[tauri::command]
async fn steam_download(id: String, steamcmd: String, mods_dir: String) -> Result<String, String> {
    let info = steam_info(&id).await?;
    let dest = resolve_dir(&mods_dir).join("steam");
    tokio::fs::create_dir_all(&dest).await.map_err(err)?;

    let out = tokio::process::Command::new(steamcmd.trim())
        .arg("+force_install_dir")
        .arg(&dest)
        .args(["+login", "anonymous", "+workshop_download_item", &info.app_id, &id, "+quit"])
        .output()
        .await
        .map_err(|e| format!("Не удалось запустить SteamCMD ({e}). Укажи путь к нему в настройках."))?;

    let stdout = String::from_utf8_lossy(&out.stdout);
    if !stdout.contains("Success") {
        let tail: Vec<&str> = stdout.lines().rev().take(3).collect();
        return Err(format!(
            "SteamCMD не смог скачать «{}». Для некоторых игр нужен вход с аккаунтом, который владеет игрой. {}",
            info.title,
            tail.into_iter().rev().collect::<Vec<_>>().join(" | ")
        ));
    }
    Ok(dest
        .join("steamapps/workshop/content")
        .join(&info.app_id)
        .join(&id)
        .display()
        .to_string())
}

const WORKSHOP_JS: &str = r#"
(function () {
  function inject() {
    if (document.getElementById('mm-add')) return;
    var sub = document.getElementById('SubscribeItemBtn');
    var id = new URLSearchParams(location.search).get('id');
    if (!sub || !id) return;
    var b = document.createElement('a');
    b.id = 'mm-add';
    b.textContent = 'Добавить в менеджер';
    b.style.cssText = 'display:inline-block;margin-left:8px;padding:8px 14px;border-radius:3px;' +
      'background:#e3a72f;color:#1a1405;font-weight:600;cursor:pointer;';
    b.onclick = function () { location.href = 'modmanager://add?id=' + encodeURIComponent(id); };
    sub.parentNode.insertBefore(b, sub.nextSibling);
  }
  setInterval(inject, 700);
})();
"#;

#[tauri::command]
fn open_workshop_browser(app: AppHandle) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("workshop") {
        return w.set_focus().map_err(err);
    }
    let handle = app.clone();
    WebviewWindowBuilder::new(
        &app,
        "workshop",
        WebviewUrl::External("https://steamcommunity.com/workshop/".parse().map_err(err)?),
    )
    .title("Мастерская Steam")
    .inner_size(1100.0, 800.0)
    .initialization_script(WORKSHOP_JS)
    .on_navigation(move |url| {
        if url.scheme() == "modmanager" {
            if let Some((_, id)) = url.query_pairs().find(|(k, _)| k == "id") {
                let _ = handle.emit("workshop-add", id.to_string());
            }
            return false;
        }
        true
    })
    .build()
    .map(|_| ())
    .map_err(err)
}

// ---------- Nexus Mods ----------

#[tauri::command]
async fn nexus_download(nxm: String, api_key: String, mods_dir: String) -> Result<String, String> {
    if api_key.trim().is_empty() {
        return Err("Укажи API-ключ Nexus в настройках".into());
    }
    let u = Url::parse(&nxm).map_err(err)?;
    let game = u.host_str().ok_or("В ссылке нет названия игры")?.to_string();
    let segs: Vec<&str> = u.path_segments().map(|s| s.collect()).unwrap_or_default();
    // mods/<mod_id>/files/<file_id>
    if segs.len() < 4 || segs[0] != "mods" || segs[2] != "files" {
        return Err("Не удалось разобрать nxm-ссылку".into());
    }
    let (mod_id, file_id) = (segs[1], segs[3]);
    let q = |k: &str| u.query_pairs().find(|(a, _)| a == k).map(|(_, v)| v.to_string());

    let mut api = format!(
        "https://api.nexusmods.com/v1/games/{game}/mods/{mod_id}/files/{file_id}/download_link.json"
    );
    if let (Some(key), Some(expires)) = (q("key"), q("expires")) {
        api = format!("{api}?key={key}&expires={expires}");
    }
    let links: serde_json::Value = client()?
        .get(api)
        .header("apikey", api_key.trim())
        .header("Application-Name", "mod-manager")
        .header("Application-Version", "0.1.0")
        .send()
        .await
        .map_err(err)?
        .json()
        .await
        .map_err(err)?;
    let uri = links[0]["URI"]
        .as_str()
        .ok_or_else(|| format!("Nexus не дал ссылку на скачивание: {links}"))?
        .to_string();

    let bytes = fetch_bytes(&uri).await?;
    let dest = resolve_dir(&mods_dir).join("nexus").join(format!("{game}-{mod_id}-{file_id}"));
    let file_name = Url::parse(&uri)
        .ok()
        .and_then(|x| x.path_segments().and_then(|s| s.last().map(String::from)))
        .unwrap_or_else(|| "mod.bin".into());

    if file_name.to_lowercase().ends_with(".zip") {
        extract_zip(bytes, &dest)?;
    } else {
        // 7z/rar без внешних библиотек не распаковать — сохраняем как есть
        tokio::fs::create_dir_all(&dest).await.map_err(err)?;
        tokio::fs::write(dest.join(&file_name), bytes).await.map_err(err)?;
    }
    Ok(dest.display().to_string())
}

// ---------- запуск ----------

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            #[cfg(any(windows, target_os = "linux"))]
            app.deep_link().register_all()?;
            let _ = app;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            parse_link,
            thunderstore_search,
            thunderstore_install,
            steam_download,
            open_workshop_browser,
            nexus_download
        ])
        .run(tauri::generate_context!())
        .expect("ошибка при запуске приложения");
}
