export {};

declare global {
  interface Window {
    xtool: {
      run: (cwd: string, argv: string[], env?: Record<string, string>) => Promise<{ id: string; pid: number }>;
      exec: (argv: string[], options: { cwd?: string; env?: Record<string, string>; timeoutMs?: number }) => Promise<{ stdout: string; stderr: string; exitCode: number }>;
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
