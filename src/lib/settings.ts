import { writable } from 'svelte/store';

export type Theme = 'light' | 'dark' | 'darkblue';

export interface Settings {
  theme: Theme;
  modsDir: string;
  steamcmd: string;
  nexusKey: string;
  community: string;
}

const defaults: Settings = {
  theme: 'dark',
  modsDir: '',
  steamcmd: 'steamcmd',
  nexusKey: '',
  community: 'lethal-company'
};

function read(): Settings {
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem('settings') || '{}') };
  } catch {
    return defaults;
  }
}

export const settings = writable<Settings>(defaults);

export function initSettings() {
  settings.set(read());
  settings.subscribe((s) => {
    localStorage.setItem('settings', JSON.stringify(s));
    document.documentElement.dataset.theme = s.theme;
  });
}
