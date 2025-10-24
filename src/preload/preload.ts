import { contextBridge, ipcRenderer } from 'electron';

type EnvMap = Record<string, string>;

declare global {
  interface Window {
    xtool: {
      run: (cwd: string, argv: string[], env?: EnvMap) => Promise<{ id: string; pid: number }>;
      exec: (argv: string[], options: { cwd?: string; env?: EnvMap; timeoutMs?: number }) => Promise<{ stdout: string; stderr: string; exitCode: number }>;
    };
    proc: {
      kill: (id: string) => Promise<void>;
    };
    settings: {
      get: (scope: 'global' | 'project', key?: string, projectPath?: string) => Promise<any>;
      set: (scope: 'global' | 'project', key: string, value: any, projectPath?: string) => Promise<any>;
    };
    secret: {
      get: (account: string) => Promise<string | null>;
      set: (account: string, secret: string | null) => Promise<boolean>;
    };
    sim: {
      remote: (cfg: any) => Promise<{ stdout: string; stderr: string; exitCode: number }>;
    };
    bridge: {
      onPtyData: (callback: (payload: { id: string; data: string }) => void) => () => void;
      onPtyExit: (callback: (payload: { id: string; code: number; signal?: number }) => void) => () => void;
      selectDirectory: () => Promise<string | null>;
      getRecentProjects: () => Promise<string[]>;
      addRecentProject: (projectPath: string) => Promise<string[]>;
      analyzeProject: (projectPath: string) => Promise<{ hasPackageSwift: boolean; hasXtoolConfig: boolean } | null>;
      openPath: (target: string) => Promise<void>;
      openProblem: (payload: { projectPath?: string; file: string; line: number; column: number }) => Promise<void>;
    };
  }
}

const run = async (cwd: string, argv: string[], env?: EnvMap) => {
  const xtoolPath = await ipcRenderer.invoke('settings:get', { scope: 'global', key: 'xtoolPath' });
  const command = xtoolPath || (process.platform === 'win32' ? 'xtool.exe' : 'xtool');
  return ipcRenderer.invoke('xtool:run', {
    command,
    args: argv,
    cwd,
    env
  });
};

const exec = async (argv: string[], options: { cwd?: string; env?: EnvMap; timeoutMs?: number }) => {
  const xtoolPath = await ipcRenderer.invoke('settings:get', { scope: 'global', key: 'xtoolPath' });
  const command = xtoolPath || (process.platform === 'win32' ? 'xtool.exe' : 'xtool');
  return ipcRenderer.invoke('xtool:exec', {
    command,
    args: argv,
    cwd: options.cwd,
    env: options.env,
    timeoutMs: options.timeoutMs
  });
};

contextBridge.exposeInMainWorld('xtool', {
  run,
  exec
});

contextBridge.exposeInMainWorld('proc', {
  kill: (id: string) => ipcRenderer.invoke('xtool:kill', id)
});

contextBridge.exposeInMainWorld('settings', {
  get: (scope: 'global' | 'project', key?: string, projectPath?: string) =>
    ipcRenderer.invoke('settings:get', { scope, key, projectPath }),
  set: (scope: 'global' | 'project', key: string, value: any, projectPath?: string) =>
    ipcRenderer.invoke('settings:set', { scope, key, value, projectPath })
});

contextBridge.exposeInMainWorld('secret', {
  get: (account: string) => ipcRenderer.invoke('secret:get', { account }),
  set: (account: string, secret: string | null) => ipcRenderer.invoke('secret:set', { account, secret })
});

contextBridge.exposeInMainWorld('sim', {
  remote: (cfg: any) => ipcRenderer.invoke('sim:remote', cfg)
});

contextBridge.exposeInMainWorld('bridge', {
  onPtyData: (callback: (payload: { id: string; data: string }) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: { id: string; data: string }) => callback(payload);
    ipcRenderer.on('pty:data', listener);
    return () => ipcRenderer.removeListener('pty:data', listener);
  },
  onPtyExit: (callback: (payload: { id: string; code: number; signal?: number }) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: { id: string; code: number; signal?: number }) => callback(payload);
    ipcRenderer.on('pty:exit', listener);
    return () => ipcRenderer.removeListener('pty:exit', listener);
  },
  selectDirectory: () => ipcRenderer.invoke('dialog:selectDirectory'),
  getRecentProjects: () => ipcRenderer.invoke('projects:getRecent'),
  addRecentProject: (projectPath: string) => ipcRenderer.invoke('projects:addRecent', projectPath),
  analyzeProject: (projectPath: string) => ipcRenderer.invoke('project:analyze', projectPath),
  openPath: (target: string) => ipcRenderer.invoke('shell:openPath', target),
  openProblem: (payload: { projectPath?: string; file: string; line: number; column: number }) => ipcRenderer.invoke('problems:open', payload)
});
