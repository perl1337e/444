<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
  import { settings } from '$lib/settings';
  import type { Theme } from '$lib/settings';

  type Tab = 'add' | 'ts' | 'settings';
  type Mod = {
    full_name: string; owner: string; name: string; description: string;
    icon: string; version: string; downloads: number; url: string;
  };
  type Line = { kind: 'ok' | 'err' | 'info'; text: string };
  type LinkInfo = { source: string; id: string; game?: string };

  const themes: { id: Theme; label: string }[] = [
    { id: 'light', label: 'Белая' },
    { id: 'dark', label: 'Тёмная' },
    { id: 'darkblue', label: 'Тёмно-синяя' }
  ];

  let tab: Tab = 'add';
  let link = '';
  let query = '';
  let mods: Mod[] = [];
  let searching = false;
  let loadedOnce = false;
  let busy = false;
  let log: Line[] = [];

  function say(kind: Line['kind'], text: string) {
    log = [{ kind, text }, ...log].slice(0, 50);
  }

  async function run(label: string, job: () => Promise<string>) {
    busy = true;
    say('info', label);
    try {
      say('ok', await job());
    } catch (e) {
      say('err', String(e));
    } finally {
      busy = false;
    }
  }

  const installTs = (fullName: string) =>
    run(`Thunderstore: скачиваю ${fullName}…`, async () => {
      const done = await invoke<string[]>('thunderstore_install', {
        fullName, modsDir: $settings.modsDir
      });
      return `Установлено: ${done.join(', ')}`;
    });

  const addSteam = (id: string) =>
    run(`Мастерская Steam: скачиваю мод ${id}…`, async () => {
      const path = await invoke<string>('steam_download', {
        id, steamcmd: $settings.steamcmd, modsDir: $settings.modsDir
      });
      return `Готово: ${path}`;
    });

  const addNexus = (nxm: string) =>
    run('Nexus: скачиваю файл…', async () => {
      const path = await invoke<string>('nexus_download', {
        nxm, apiKey: $settings.nexusKey, modsDir: $settings.modsDir
      });
      return `Готово: ${path}`;
    });

  async function addLink(raw: string) {
    const value = raw.trim();
    if (!value) return;
    let info: LinkInfo;
    try {
      info = await invoke<LinkInfo>('parse_link', { link: value });
    } catch (e) {
      say('err', String(e));
      return;
    }
    if (info.source === 'thunderstore') return installTs(info.id);
    if (info.source === 'steam') return addSteam(info.id);
    if (info.source === 'nexus') return addNexus(value);
    say('info', 'Для Nexus нажми «Download with manager» на странице мода — ссылка откроется здесь.');
  }

  async function submitLink() {
    const value = link;
    link = '';
    await addLink(value);
  }

  async function search() {
    searching = true;
    try {
      mods = await invoke<Mod[]>('thunderstore_search', {
        community: $settings.community, query
      });
    } catch (e) {
      say('err', String(e));
    } finally {
      searching = false;
      loadedOnce = true;
    }
  }

  function openTs() {
    tab = 'ts';
    if (!loadedOnce) search();
  }

  const openWorkshop = () =>
    invoke('open_workshop_browser').catch((e) => say('err', String(e)));

  onMount(() => {
    const subs = [
      listen<string>('workshop-add', (e) => addSteam(e.payload)),
      onOpenUrl((urls) => urls.forEach(addLink))
    ];
    getCurrent().then((urls) => urls?.forEach(addLink)).catch(() => {});
    return () => subs.forEach((p) => p.then((off) => off()));
  });
</script>

<div class="app">
  <nav>
    <h1>Mod Manager</h1>
    <button class:on={tab === 'add'} on:click={() => (tab = 'add')}>Добавить по ссылке</button>
    <button class:on={tab === 'ts'} on:click={openTs}>Thunderstore</button>
    <button class:on={tab === 'settings'} on:click={() => (tab = 'settings')}>Настройки</button>
  </nav>

  <main>
    {#if tab === 'add'}
      <h2>Добавить мод</h2>
      <p class="hint">Вставь ссылку на мод из Мастерской Steam, Thunderstore или Nexus.</p>
      <form on:submit|preventDefault={submitLink}>
        <input bind:value={link} placeholder="https://steamcommunity.com/sharedfiles/filedetails/?id=…" />
        <button class="primary" disabled={busy || !link.trim()}>Добавить</button>
      </form>
      <p class="hint">
        Или открой <button class="linklike" on:click={openWorkshop}>браузер Мастерской Steam</button>:
        на странице мода рядом с «Подписаться» появится кнопка «Добавить в менеджер».
      </p>

      <h3>Журнал</h3>
      {#if log.length === 0}
        <p class="hint">Пока пусто. Добавленные моды появятся здесь.</p>
      {:else}
        <ul class="log">
          {#each log as l}<li class={l.kind}>{l.text}</li>{/each}
        </ul>
      {/if}
    {:else if tab === 'ts'}
      <h2>Thunderstore · {$settings.community}</h2>
      <form on:submit|preventDefault={search}>
        <input bind:value={query} placeholder="Название мода или автор" />
        <button class="primary" disabled={searching}>{searching ? 'Ищу…' : 'Найти'}</button>
      </form>
      <ul class="mods">
        {#each mods as m (m.full_name)}
          <li>
            <img src={m.icon} alt="" width="56" height="56" />
            <div class="info">
              <strong>{m.name}</strong> <span class="hint">{m.version} · {m.owner}</span>
              <p>{m.description}</p>
              <span class="hint">{m.downloads.toLocaleString('ru')} скачиваний</span>
            </div>
            <button class="primary" disabled={busy} on:click={() => installTs(m.full_name)}>Добавить</button>
          </li>
        {:else}
          {#if !searching}<li class="hint">Ничего не найдено.</li>{/if}
        {/each}
      </ul>
    {:else}
      <h2>Настройки</h2>

      <fieldset>
        <legend>Тема</legend>
        <div class="seg">
          {#each themes as t}
            <label class:on={$settings.theme === t.id}>
              <input type="radio" name="theme" value={t.id} bind:group={$settings.theme} />
              {t.label}
            </label>
          {/each}
        </div>
      </fieldset>

      <label class="field">Папка с модами
        <input bind:value={$settings.modsDir} placeholder="Пусто — папка приложения по умолчанию" />
      </label>
      <label class="field">Игра на Thunderstore (community)
        <input bind:value={$settings.community} placeholder="lethal-company" />
      </label>
      <label class="field">Путь к SteamCMD (для Мастерской)
        <input bind:value={$settings.steamcmd} placeholder="steamcmd" />
      </label>
      <label class="field">API-ключ Nexus Mods
        <input type="password" bind:value={$settings.nexusKey} placeholder="Личный ключ из настроек аккаунта Nexus" />
      </label>
    {/if}
  </main>
</div>

<style>
  .app { display: grid; grid-template-columns: 220px 1fr; height: 100vh; }
  nav {
    background: var(--panel); border-right: 1px solid var(--line);
    padding: 20px 12px; display: flex; flex-direction: column; gap: 4px;
  }
  nav h1 { font-size: 17px; margin: 0 8px 18px; }
  nav button {
    text-align: left; background: none; border: 0; border-radius: 6px;
    padding: 9px 10px; cursor: pointer; color: var(--muted);
  }
  nav button:hover { color: var(--text); }
  nav button.on { background: var(--bg); color: var(--text); box-shadow: inset 3px 0 var(--accent); }
  main { padding: 28px 36px; overflow-y: auto; max-width: 860px; }
  h2 { margin: 0 0 12px; font-size: 22px; }
  h3 { margin: 28px 0 8px; font-size: 16px; }
  .hint { color: var(--muted); font-size: 14px; }
  form { display: flex; gap: 8px; margin: 12px 0; }
  input:not([type='radio']) {
    flex: 1; width: 100%; background: var(--panel); border: 1px solid var(--line);
    border-radius: 6px; padding: 9px 11px;
  }
  .primary {
    background: var(--accent); color: var(--accent-text); border: 0;
    border-radius: 6px; padding: 9px 16px; font-weight: 600; cursor: pointer;
  }
  .primary:disabled { opacity: 0.5; cursor: default; }
  .linklike {
    background: none; border: 0; padding: 0; color: var(--accent);
    text-decoration: underline; cursor: pointer;
  }
  .log, .mods { list-style: none; padding: 0; margin: 0; }
  .log li { padding: 6px 0; border-bottom: 1px solid var(--line); word-break: break-word; }
  .log .ok { color: var(--ok); }
  .log .err { color: var(--err); }
  .mods li {
    display: flex; gap: 14px; align-items: center; padding: 12px 0;
    border-bottom: 1px solid var(--line);
  }
  .mods img { border-radius: 6px; background: var(--panel); flex: none; }
  .mods .info { flex: 1; min-width: 0; }
  .mods p {
    margin: 2px 0; color: var(--muted); font-size: 14px;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
  }
  fieldset { border: 0; padding: 0; margin: 0 0 18px; }
  legend { padding: 0; margin-bottom: 8px; }
  .seg { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
  .seg label { padding: 8px 16px; cursor: pointer; background: var(--panel); }
  .seg label.on { background: var(--accent); color: var(--accent-text); font-weight: 600; }
  .seg input { position: absolute; opacity: 0; pointer-events: none; }
  .seg label:has(input:focus-visible) { outline: 2px solid var(--accent); outline-offset: -2px; }
  .field { display: block; margin-bottom: 14px; }
  .field input { display: block; margin-top: 5px; }
</style>
