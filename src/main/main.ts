import { app, BrowserWindow, dialog, ipcMain, shell } from 'electron';
import path from 'path';
import Store from 'electron-store';
import keytar from 'keytar';
import fs from 'fs';
import { spawn as spawnChild } from 'child_process';
import { PtyManager, PtyRequest } from './pty';

const isDev = !app.isPackaged;
const store = new Store({
  name: 'xtool-studio',
  defaults: {
    recentProjects: [] as string[],
    globalSettings: {
      xtoolPath: process.platform === 'win32' ? 'xtool.exe' : 'xtool'
    },
    projectSettings: {} as Record<string, any>
  }
});

let mainWindow: BrowserWindow | null = null;
const ptyManager = new PtyManager();

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    title: 'Xtool Studio',
    webPreferences: {
      preload: path.join(__dirname, '../preload/preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false
    }
  });

  ptyManager.bindWindow(mainWindow);

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

ipcMain.handle('dialog:selectDirectory', async () => {
  if (!mainWindow) return null;
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory']
  });
  if (result.canceled || result.filePaths.length === 0) {
    return null;
  }
  return result.filePaths[0];
});

ipcMain.handle('projects:getRecent', () => {
  return store.get('recentProjects', []) as string[];
});


ipcMain.handle('project:analyze', async (_event, projectPath: string) => {
  if (!projectPath) {
    return null;
  }
  const hasPackageSwift = fs.existsSync(path.join(projectPath, 'Package.swift'));
  const hasXtoolConfig = fs.existsSync(path.join(projectPath, 'xtool.json')) || fs.existsSync(path.join(projectPath, 'xtool.yaml')) || fs.existsSync(path.join(projectPath, 'xtool.yml'));
  return { hasPackageSwift, hasXtoolConfig };
});

ipcMain.handle('projects:addRecent', (_event, projectPath: string) => {
  const recents = new Set(store.get('recentProjects', []) as string[]);
  if (projectPath) {
    recents.delete(projectPath);
    recents.add(projectPath);
  }
  const ordered = Array.from(recents).slice(-10).reverse();
  store.set('recentProjects', ordered);
  return ordered;
});

ipcMain.handle('settings:get', (_event, payload: { scope: 'global' | 'project'; key?: string; projectPath?: string; }) => {
  if (payload.scope === 'global') {
    const all = store.get('globalSettings', {});
    return payload.key ? (all as any)[payload.key] : all;
  }
  const projectSettings = store.get('projectSettings', {}) as Record<string, any>;
  const project = payload.projectPath ? projectSettings[payload.projectPath] ?? {} : {};
  return payload.key ? project?.[payload.key] : project;
});

ipcMain.handle('settings:set', (_event, payload: { scope: 'global' | 'project'; key: string; value: any; projectPath?: string; }) => {
  if (payload.scope === 'global') {
    const current = store.get('globalSettings', {});
    (current as any)[payload.key] = payload.value;
    store.set('globalSettings', current);
    return current;
  }
  const projectSettings = store.get('projectSettings', {}) as Record<string, any>;
  const projectPath = payload.projectPath ?? 'default';
  const project = projectSettings[projectPath] ?? {};
  project[payload.key] = payload.value;
  projectSettings[projectPath] = project;
  store.set('projectSettings', projectSettings);
  return project;
});

const KEYTAR_SERVICE = 'Xtool Studio';

ipcMain.handle('secret:get', async (_event, payload: { account: string }) => {
  if (!payload.account) return null;
  return keytar.getPassword(KEYTAR_SERVICE, payload.account);
});

ipcMain.handle('secret:set', async (_event, payload: { account: string; secret: string | null }) => {
  const { account, secret } = payload;
  if (!account) return false;
  if (!secret) {
    await keytar.deletePassword(KEYTAR_SERVICE, account);
    return true;
  }
  await keytar.setPassword(KEYTAR_SERVICE, account, secret);
  return true;
});

ipcMain.handle('xtool:run', async (_event, request: PtyRequest) => {
  return ptyManager.spawn(request);
});

ipcMain.handle('xtool:kill', (_event, id: string) => {
  ptyManager.kill(id);
});

ipcMain.handle('xtool:exec', async (_event, request: { command: string; args?: string[]; cwd?: string; env?: Record<string, string>; timeoutMs?: number }) => {
  const { command, args = [], cwd = process.cwd(), env = {}, timeoutMs = 120000 } = request;
  return new Promise<{ stdout: string; stderr: string; exitCode: number }>((resolve, reject) => {
    const child = spawnChild(command, args, {
      cwd,
      env: { ...process.env, ...env },
      shell: process.platform === 'win32'
    });
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error('Command timed out'));
    }, timeoutMs);
    let stdout = '';
    let stderr = '';
    child.stdout?.on('data', chunk => {
      stdout += chunk.toString();
    });
    child.stderr?.on('data', chunk => {
      stderr += chunk.toString();
    });
    child.on('error', err => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', code => {
      clearTimeout(timer);
      resolve({ stdout, stderr, exitCode: code ?? 0 });
    });
  });
});

ipcMain.handle('sim:remote', async (_event, payload: {
  host: string;
  user: string;
  sshKeyPath?: string;
  bundleId: string;
  appPath?: string;
  deviceName: string;
  action: 'boot' | 'install' | 'terminate' | 'launch' | 'screenshot';
  screenshotPath?: string;
}) => {
  const { host, user, sshKeyPath, bundleId, appPath, deviceName, action, screenshotPath } = payload;
  if (!host || !user) {
    throw new Error('Missing SSH host or user');
  }
  const baseArgs = ['-o', 'StrictHostKeyChecking=no'];
  if (sshKeyPath) {
    baseArgs.push('-i', sshKeyPath);
  }
  const commandFragments: Record<typeof action, string> = {
    boot: `xcrun simctl boot "${deviceName}" || true`,
    install: `xcrun simctl install booted ${appPath ?? ''}`.trim(),
    terminate: `xcrun simctl terminate booted ${bundleId} || true`,
    launch: `xcrun simctl launch booted ${bundleId}`,
    screenshot: `xcrun simctl io booted screenshot ${screenshotPath ?? '/tmp/xtool-sim.png'}`
  };
  const remoteCommand = commandFragments[action];
  if (!remoteCommand) {
    throw new Error('Unsupported action');
  }
  const sshArgs = [...baseArgs, `${user}@${host}`, remoteCommand];
  const output = await runCommand('ssh', sshArgs);

  if (action === 'screenshot' && screenshotPath) {
    const scpArgs = [...baseArgs, `${user}@${host}:${screenshotPath}`, screenshotPath];
    await runCommand('scp', scpArgs);
  }

  return output;
});


ipcMain.handle('problems:open', (_event, payload: { projectPath?: string; file: string; line: number; column: number }) => {
  const { projectPath, file, line, column } = payload;
  const absolute = path.isAbsolute(file) ? file : (projectPath ? path.join(projectPath, file) : file);
  const vscodeUrl = `vscode://file/${absolute}:${line}:${column}`;
  shell.openExternal(vscodeUrl);
});

ipcMain.handle('shell:openPath', (_event, targetPath: string) => {
  if (targetPath) {
    shell.openPath(targetPath);
  }
});

function runCommand(command: string, args: string[]) {
  return new Promise<{ stdout: string; stderr: string; exitCode: number }>((resolve, reject) => {
    const child = spawnChild(command, args, {
      env: process.env,
      shell: process.platform === 'win32'
    });
    let stdout = '';
    let stderr = '';
    child.stdout?.on('data', data => {
      stdout += data.toString();
    });
    child.stderr?.on('data', data => {
      stderr += data.toString();
    });
    child.on('error', reject);
    child.on('close', code => {
      resolve({ stdout, stderr, exitCode: code ?? 0 });
    });
  });
}

app.on('before-quit', () => {
  ptyManager.dispose();
});
