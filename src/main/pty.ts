import { BrowserWindow } from 'electron';
import { randomUUID } from 'crypto';
import { IPty, spawn } from 'node-pty';

export interface PtyRequest {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
  id?: string;
}

export interface PtyResult {
  id: string;
  pid: number;
}

export class PtyManager {
  private processes = new Map<string, IPty>();
  private window: BrowserWindow | null = null;

  bindWindow(window: BrowserWindow | null) {
    this.window = window;
  }

  spawn(request: PtyRequest): PtyResult {
    const id = request.id ?? randomUUID();
    const { command, args = [], cwd = process.cwd(), env = {}, cols = 80, rows = 30 } = request;
    const shellEnv = { ...process.env, ...env };
    const defaultName = process.platform === 'win32' ? 'windows' : 'xterm-color';

    const pty = spawn(command, args, {
      name: defaultName,
      cols,
      rows,
      cwd,
      env: shellEnv,
      useConpty: process.platform === 'win32'
    });

    this.processes.set(id, pty);

    pty.onData(data => {
      this.window?.webContents.send('pty:data', { id, data });
    });

    pty.onExit(event => {
      this.window?.webContents.send('pty:exit', { id, code: event.exitCode, signal: event.signal });
      this.processes.delete(id);
    });

    return { id, pid: pty.pid };
  }

  kill(id: string) {
    const process = this.processes.get(id);
    if (process) {
      try {
        process.kill();
      } catch (error) {
        console.error('Failed to kill process', error);
      }
      this.processes.delete(id);
    }
  }

  dispose() {
    for (const [id] of this.processes) {
      this.kill(id);
    }
  }
}
