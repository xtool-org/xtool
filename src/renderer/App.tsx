import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import ProjectPicker from './components/ProjectPicker';
import DevicesPanel, { Device } from './components/Devices';
import BuildPanel from './components/Build';
import InstallLaunchPanel from './components/InstallLaunch';
import LogsPanel, { LogEntry, LogFilter, Problem } from './components/Logs';
import SettingsPanel, { GlobalSettings, ProjectSettings } from './components/Settings';
import SimulatorBridgePanel, { SimulatorConfig } from './components/SimulatorBridge';

const tabs = [
  { id: 'project', label: 'Project' },
  { id: 'devices', label: 'Devices' },
  { id: 'build', label: 'Build' },
  { id: 'install', label: 'Install & Launch' },
  { id: 'logs', label: 'Logs' },
  { id: 'settings', label: 'Settings' },
  { id: 'simulator', label: 'Simulator' }
] as const;

const logLevels = {
  info: 'info',
  warning: 'warning',
  error: 'error',
  test: 'test'
} as const;

const defaultGlobalSettings: GlobalSettings = {
  xtoolPath: typeof process !== 'undefined' && process.platform === 'win32' ? 'xtool.exe' : 'xtool',
  defaultArgs: '',
  defaultEnv: ''
};

const defaultProjectSettings: ProjectSettings = {
  buildArgs: '',
  installArgs: '',
  launchArgs: '',
  envVars: '',
  bundleId: '',
  teamId: '',
  defaultDevice: '',
  simulator: {
    host: '',
    user: '',
    sshKeyPath: '',
    deviceName: 'iPhone 15',
    appPath: '',
    screenshotPath: '/tmp/xtool-sim.png'
  }
};

type Toast = {
  id: string;
  message: string;
  level: 'error' | 'success';
};

type RunningProcess = {
  id: string;
  label: string;
  startedAt: number;
  args: string[];
};

type TabId = typeof tabs[number]['id'];

type ProjectMeta = {
  hasPackageSwift: boolean;
  hasXtoolConfig: boolean;
} | null;

const parseEnv = (envText: string): Record<string, string> => {
  const env: Record<string, string> = {};
  envText
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .forEach(line => {
      const [key, ...rest] = line.split('=');
      if (key) {
        env[key.trim()] = rest.join('=').trim();
      }
    });
  return env;
};

const mergeEnv = (globalEnv: string, projectEnv: string, overrides?: Record<string, string>) => ({
  ...parseEnv(globalEnv),
  ...parseEnv(projectEnv),
  ...(overrides ?? {})
});

const App: React.FC = () => {
  const [activeTab, setActiveTab] = useState<TabId>('project');
  const [projectPath, setProjectPath] = useState<string | null>(null);
  const [projectMeta, setProjectMeta] = useState<ProjectMeta>(null);
  const [recentProjects, setRecentProjects] = useState<string[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [devicesLoading, setDevicesLoading] = useState(false);
  const [defaultDevice, setDefaultDevice] = useState<string>('');
  const [globalSettings, setGlobalSettings] = useState<GlobalSettings>(defaultGlobalSettings);
  const [projectSettings, setProjectSettings] = useState<ProjectSettings>(defaultProjectSettings);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [logFilter, setLogFilter] = useState<LogFilter>('all');
  const [logSearch, setLogSearch] = useState('');
  const [problems, setProblems] = useState<Problem[]>([]);
  const [status, setStatus] = useState<{ cwd: string; device: string; lastExitCode: number | null }>(
    { cwd: '', device: '', lastExitCode: null }
  );
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [isLoopRunning, setIsLoopRunning] = useState(false);
  const runningProcesses = useRef<Record<string, RunningProcess>>({});
  const pendingResolvers = useRef<Record<string, (code: number) => void>>({});
  const partialLogs = useRef<Record<string, string>>({});

  const appendToast = useCallback((message: string, level: 'error' | 'success') => {
    const id = window.crypto?.randomUUID ? window.crypto.randomUUID() : Math.random().toString(36).slice(2);
    setToasts(prev => [...prev, { id, message, level }]);
  }, []);

  useEffect(() => {
    const cleanupData = window.bridge.onPtyData(({ id, data }) => {
      partialLogs.current[id] = (partialLogs.current[id] ?? '') + data;
      const chunks = partialLogs.current[id].split(/\r?\n/);
      partialLogs.current[id] = chunks.pop() ?? '';
      const entries: LogEntry[] = [];
      const newProblems: Problem[] = [];
      chunks.forEach(chunk => {
        if (!chunk.trim()) return;
        const level = inferLogLevel(chunk);
        const entry: LogEntry = {
          id: window.crypto?.randomUUID ? window.crypto.randomUUID() : Math.random().toString(36).slice(2),
          message: chunk,
          level,
          timestamp: Date.now(),
          processId: id
        };
        entries.push(entry);
        const problem = parseProblem(chunk);
        if (problem) {
          newProblems.push(problem);
        }
      });
      if (entries.length) {
        setLogs(prev => [...prev, ...entries]);
      }
      if (newProblems.length) {
        setProblems(prev => [...prev, ...newProblems]);
      }
    });

    const cleanupExit = window.bridge.onPtyExit(({ id, code }) => {
      const resolver = pendingResolvers.current[id];
      if (resolver) {
        resolver(code);
        delete pendingResolvers.current[id];
      }
      const proc = runningProcesses.current[id];
      if (proc) {
        setStatus(prev => ({ ...prev, lastExitCode: code }));
        if (code !== 0) {
          appendToast(`${proc.label} failed (exit code ${code})`, 'error');
        }
        delete runningProcesses.current[id];
      }
    });

    return () => {
      cleanupData();
      cleanupExit();
    };
  }, [appendToast]);

  useEffect(() => {
    window.bridge.getRecentProjects().then(setRecentProjects);
  }, []);

  const inferLogLevel = useCallback((line: string): LogEntry['level'] => {
    if (/error:/i.test(line)) return logLevels.error;
    if (/warning:/i.test(line)) return logLevels.warning;
    if (/test/i.test(line)) return logLevels.test;
    return logLevels.info;
  }, []);

  const parseProblem = useCallback((line: string): Problem | null => {
    const match = line.match(/([^\s:]+\.swift):(\d+):(\d+):(error|warning):\s*(.*)/i);
    if (!match) return null;
    return {
      file: match[1],
      line: Number(match[2]),
      column: Number(match[3]),
      level: match[4].toLowerCase() as Problem['level'],
      message: match[5]
    };
  }, []);

  const loadGlobalSettings = useCallback(async () => {
    const stored = await window.settings.get('global');
    setGlobalSettings(prev => ({ ...prev, ...(stored ?? {}) }));
  }, []);

  const loadProjectSettings = useCallback(async (selectedPath: string) => {
    const stored = (await window.settings.get('project', undefined, selectedPath)) ?? {};
    const merged = {
      ...defaultProjectSettings,
      ...stored,
      simulator: { ...defaultProjectSettings.simulator, ...(stored.simulator ?? {}) }
    };
    setProjectSettings(merged);
    setDefaultDevice(merged.defaultDevice ?? '');
    setStatus(prev => ({ ...prev, cwd: selectedPath, device: merged.defaultDevice ?? '' }));
  }, []);

  useEffect(() => {
    loadGlobalSettings();
  }, [loadGlobalSettings]);

  const handleProjectSelect = useCallback(
    async (selected: string | null) => {
      setProjectPath(selected);
      if (selected) {
        const meta = await window.bridge.analyzeProject(selected);
        setProjectMeta(meta);
        const updated = await window.bridge.addRecentProject(selected);
        setRecentProjects(updated);
        await loadProjectSettings(selected);
      } else {
        setProjectMeta(null);
        setProjectSettings({ ...defaultProjectSettings, simulator: { ...defaultProjectSettings.simulator } });
        setDefaultDevice('');
        setStatus(prev => ({ ...prev, cwd: '', device: '', lastExitCode: null }));
      }
    },
    [loadProjectSettings]
  );

  const runCommand = useCallback(
    async (label: string, args: string[], envOverrides?: Record<string, string>) => {
      if (!projectPath) {
        appendToast('Select a project before running commands.', 'error');
        throw new Error('No project selected');
      }
      const env = mergeEnv(globalSettings.defaultEnv ?? '', projectSettings.envVars ?? '', envOverrides);
      const response = await window.xtool.run(projectPath, [...(globalSettings.defaultArgs?.split(' ').filter(Boolean) ?? []), ...args], env);
      runningProcesses.current[response.id] = {
        id: response.id,
        label,
        startedAt: Date.now(),
        args
      };
      setStatus(prev => ({ ...prev, lastExitCode: null }));
      const completion = new Promise<number>(resolve => {
        pendingResolvers.current[response.id] = resolve;
      });
      return { id: response.id, completion };
    },
    [appendToast, globalSettings.defaultArgs, globalSettings.defaultEnv, projectPath, projectSettings.envVars]
  );

  const fetchDevices = useCallback(async () => {
    if (!projectPath) return;
    try {
      setDevicesLoading(true);
      const result = await window.xtool.exec(['devices'], { cwd: projectPath });
      const parsed = parseDevices(result.stdout || result.stderr);
      setDevices(parsed);
      if (!defaultDevice && parsed.length) {
        setDefaultDevice(parsed[0].udid);
        await window.settings.set('project', 'defaultDevice', parsed[0].udid, projectPath);
      }
      setStatus(prev => ({ ...prev, device: projectSettings.defaultDevice ?? parsed[0]?.udid ?? '' }));
    } catch (error: any) {
      appendToast(`Failed to load devices: ${error.message ?? error}`, 'error');
    } finally {
      setDevicesLoading(false);
    }
  }, [appendToast, defaultDevice, projectPath, projectSettings.defaultDevice]);

  const parseDevices = useCallback((output: string): Device[] => {
    const lines = output.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
    const list: Device[] = [];
    lines.forEach(line => {
      const match = line.match(/^(.*?) \(([^)]+)\) \[(.*?)\]$/);
      if (match) {
        list.push({ name: match[1], platform: match[2], udid: match[3] });
      }
    });
    return list;
  }, []);

  useEffect(() => {
    if (projectPath) {
      fetchDevices();
    }
  }, [projectPath, fetchDevices]);

  const handleSetDefaultDevice = useCallback(async (deviceId: string) => {
    if (!projectPath) return;
    setDefaultDevice(deviceId);
    setProjectSettings(prev => ({ ...prev, defaultDevice: deviceId }));
    setStatus(prev => ({ ...prev, device: deviceId }));
    await window.settings.set('project', 'defaultDevice', deviceId, projectPath);
  }, [projectPath]);

  const handleBuild = useCallback(async () => {
    const buildArgs = projectSettings.buildArgs?.split(' ').filter(Boolean) ?? [];
    return runCommand('xtool dev', ['dev', ...buildArgs]);
  }, [projectSettings.buildArgs, runCommand]);

  const handleInstall = useCallback(async () => {
    const installArgs = projectSettings.installArgs?.split(' ').filter(Boolean) ?? [];
    const env: Record<string, string> = {};
    if (defaultDevice) {
      env.XTOOL_DEVICE = defaultDevice;
    }
    return runCommand('xtool install', ['install', ...installArgs], env);
  }, [defaultDevice, projectSettings.installArgs, runCommand]);

  const handleLaunch = useCallback(async () => {
    const launchArgs = projectSettings.launchArgs?.split(' ').filter(Boolean) ?? [];
    const env: Record<string, string> = {};
    if (projectSettings.bundleId) {
      env.XTOOL_BUNDLE_ID = projectSettings.bundleId;
    }
    if (projectPath) {
      await window.xtool.exec(['launch', '--terminate'], { cwd: projectPath });
    }
    return runCommand('xtool launch', ['launch', ...launchArgs], env);
  }, [projectPath, projectSettings.bundleId, projectSettings.launchArgs, runCommand]);

  const runLoop = useCallback(async () => {
    try {
      setIsLoopRunning(true);
      const build = await handleBuild();
      const buildCode = await build.completion;
      if (buildCode !== 0) return;
      const install = await handleInstall();
      const installCode = await install.completion;
      if (installCode !== 0) return;
      const launch = await handleLaunch();
      await launch.completion;
    } finally {
      setIsLoopRunning(false);
    }
  }, [handleBuild, handleInstall, handleLaunch]);

  const clearLogs = useCallback(() => {
    partialLogs.current = {};
    setLogs([]);
    setProblems([]);
  }, []);

  const filteredLogs = useMemo(() => {
    return logs.filter(entry => {
      if (logFilter !== 'all' && entry.level !== logFilter) return false;
      if (logSearch && !entry.message.toLowerCase().includes(logSearch.toLowerCase())) return false;
      return true;
    });
  }, [logFilter, logSearch, logs]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const isMac = navigator.platform.toLowerCase().includes('mac');
      const meta = isMac ? event.metaKey : event.ctrlKey;
      if (!meta) return;
      if (event.key.toLowerCase() === 'b') {
        event.preventDefault();
        handleBuild();
      }
      if (event.key.toLowerCase() === 'l') {
        event.preventDefault();
        handleLaunch();
      }
      if (event.key.toLowerCase() === 'k') {
        event.preventDefault();
        clearLogs();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [clearLogs, handleBuild, handleLaunch]);

  const updateGlobalSetting = useCallback(async (key: keyof GlobalSettings, value: any) => {
    setGlobalSettings(prev => ({ ...prev, [key]: value }));
    await window.settings.set('global', key, value);
  }, []);

  const updateProjectSetting = useCallback(async (key: keyof ProjectSettings, value: any) => {
    if (!projectPath) return;
    setProjectSettings(prev => ({ ...prev, [key]: value }));
    await window.settings.set('project', key, value, projectPath);
  }, [projectPath]);

  const updateSimulatorConfig = useCallback(async (config: SimulatorConfig) => {
    await updateProjectSetting('simulator', config);
  }, [updateProjectSetting]);

  const handleToastDismiss = useCallback((toastId: string) => {
    setToasts(prev => prev.filter(t => t.id !== toastId));
  }, []);

  const content = useMemo(() => {
    switch (activeTab) {
      case 'project':
        return (
          <ProjectPicker
            projectPath={projectPath}
            onProjectSelected={handleProjectSelect}
            recentProjects={recentProjects}
            projectMeta={projectMeta}
          />
        );
      case 'devices':
        return (
          <DevicesPanel
            devices={devices}
            loading={devicesLoading}
            defaultDevice={defaultDevice}
            onRefresh={fetchDevices}
            onSetDefault={handleSetDefaultDevice}
          />
        );
      case 'build':
        return (
          <BuildPanel
            buildArgs={projectSettings.buildArgs}
            envVars={projectSettings.envVars}
            onBuildArgsChange={value => updateProjectSetting('buildArgs', value)}
            onEnvVarsChange={value => updateProjectSetting('envVars', value)}
            onRunBuild={handleBuild}
          />
        );
      case 'install':
        return (
          <InstallLaunchPanel
            bundleId={projectSettings.bundleId}
            teamId={projectSettings.teamId}
            installArgs={projectSettings.installArgs}
            launchArgs={projectSettings.launchArgs}
            defaultDevice={defaultDevice}
            onBundleChange={value => updateProjectSetting('bundleId', value)}
            onTeamChange={value => updateProjectSetting('teamId', value)}
            onInstallArgsChange={value => updateProjectSetting('installArgs', value)}
            onLaunchArgsChange={value => updateProjectSetting('launchArgs', value)}
            onInstall={handleInstall}
            onLaunch={handleLaunch}
            onTerminate={async () => {
              if (!projectPath) return;
              await window.xtool.exec(['launch', '--terminate'], { cwd: projectPath });
            }}
          />
        );
      case 'logs':
        return (
          <LogsPanel
            logs={filteredLogs}
            filter={logFilter}
            onFilterChange={setLogFilter}
            search={logSearch}
            onSearchChange={setLogSearch}
            onClear={clearLogs}
            problems={problems}
            onOpenProblem={problem => {
              window.bridge.openProblem({ projectPath: projectPath ?? undefined, ...problem });
            }}
          />
        );
      case 'settings':
        return (
          <SettingsPanel
            projectPath={projectPath}
            globalSettings={globalSettings}
            projectSettings={projectSettings}
            onGlobalChange={updateGlobalSetting}
            onProjectChange={updateProjectSetting}
          />
        );
      case 'simulator':
        return (
          <SimulatorBridgePanel
            config={projectSettings.simulator}
            bundleId={projectSettings.bundleId}
            onConfigChange={updateSimulatorConfig}
          />
        );
      default:
        return null;
    }
  }, [activeTab, clearLogs, devices, devicesLoading, defaultDevice, fetchDevices, filteredLogs, globalSettings, handleBuild, handleInstall, handleLaunch, handleProjectSelect, handleSetDefaultDevice, logFilter, logSearch, problems, projectPath, projectMeta, projectSettings, recentProjects, updateGlobalSetting, updateProjectSetting, updateSimulatorConfig]);

  return (
    <div className="app-shell">
      <div className="top-bar">
        <div>
          <h1>Xtool Studio</h1>
          <div className="project-path">{projectPath ?? 'No project selected'}</div>
        </div>
        <button disabled={!projectPath || isLoopRunning} onClick={runLoop}>
          {isLoopRunning ? 'Running…' : 'One-Click Loop'}
        </button>
      </div>
      <div className="main-content">
        <div className="sidebar">
          {tabs.map(tab => (
            <button
              key={tab.id}
              className={tab.id === activeTab ? 'active' : ''}
              onClick={() => setActiveTab(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>
        <div className="content-area">{content}</div>
      </div>
      <div className="status-bar">
        <span>Project: {status.cwd || '—'}</span>
        <span>Device: {defaultDevice || '—'}</span>
        <span>Last exit code: {status.lastExitCode ?? '—'}</span>
      </div>
      <div className="toast-container" style={{ position: 'fixed', bottom: 20, right: 20, display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
        {toasts.map(toast => (
          <div
            key={toast.id}
            style={{
              background: toast.level === 'error' ? 'rgba(248,113,113,0.2)' : 'rgba(34,197,94,0.2)',
              border: '1px solid rgba(148,163,184,0.3)',
              borderRadius: 6,
              padding: '0.75rem 1rem',
              color: '#f8fafc',
              minWidth: '240px'
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '0.5rem' }}>
              <span>{toast.message}</span>
              <button className="secondary" style={{ padding: '0.2rem 0.4rem' }} onClick={() => handleToastDismiss(toast.id)}>
                ×
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default App;
