import React, { useMemo, useState } from 'react';

export type SimulatorConfig = {
  host: string;
  user: string;
  sshKeyPath?: string;
  deviceName: string;
  appPath?: string;
  screenshotPath?: string;
};

type Props = {
  config: SimulatorConfig;
  bundleId: string;
  onConfigChange: (config: SimulatorConfig) => void;
};

const SimulatorBridgePanel: React.FC<Props> = ({ config, bundleId, onConfigChange }) => {
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [output, setOutput] = useState<string>('');
  const [screenshotPreview, setScreenshotPreview] = useState<string | null>(null);

  const updateField = (key: keyof SimulatorConfig, value: string) => {
    onConfigChange({ ...config, [key]: value });
  };

  const canRun = useMemo(() => config.host && config.user && bundleId, [bundleId, config.host, config.user]);

  const runAction = async (action: 'boot' | 'install' | 'terminate' | 'launch' | 'screenshot') => {
    if (!canRun) return;
    setBusyAction(action);
    try {
      const response = await window.sim.remote({
        host: config.host,
        user: config.user,
        sshKeyPath: config.sshKeyPath,
        deviceName: config.deviceName,
        appPath: config.appPath,
        bundleId,
        action,
        screenshotPath: config.screenshotPath
      });
      const combined = [response.stdout, response.stderr].filter(Boolean).join('\n');
      setOutput(combined || `Command ${action} completed with exit code ${response.exitCode}`);
      if (action === 'screenshot' && config.screenshotPath) {
        setScreenshotPreview(`file://${config.screenshotPath}`);
      }
    } catch (error: any) {
      setOutput(`Failed to run ${action}: ${error.message ?? error}`);
    } finally {
      setBusyAction(null);
    }
  };

  return (
    <div className="panel">
      <h2>Remote Simulator Bridge</h2>
      <p>Optionally control a remote macOS simulator host over SSH.</p>
      <div className="form-grid">
        <label>
          Hostname / IP
          <input type="text" value={config.host} onChange={event => updateField('host', event.target.value)} placeholder="simulator.local" />
        </label>
        <label>
          SSH user
          <input type="text" value={config.user} onChange={event => updateField('user', event.target.value)} placeholder="devuser" />
        </label>
        <label>
          SSH key path
          <input type="text" value={config.sshKeyPath ?? ''} onChange={event => updateField('sshKeyPath', event.target.value)} placeholder="~/.ssh/id_ed25519" />
        </label>
        <label>
          Simulator device name
          <input type="text" value={config.deviceName} onChange={event => updateField('deviceName', event.target.value)} placeholder="iPhone 15" />
        </label>
        <label>
          App bundle path (.app)
          <input type="text" value={config.appPath ?? ''} onChange={event => updateField('appPath', event.target.value)} placeholder="/path/to/MyApp.app" />
        </label>
        <label>
          Screenshot path
          <input type="text" value={config.screenshotPath ?? ''} onChange={event => updateField('screenshotPath', event.target.value)} placeholder="/tmp/xtool-sim.png" />
        </label>
      </div>
      <div className="tag-cloud">
        <span className="tag">Bundle ID: {bundleId || 'Set in Install tab'}</span>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.5rem', marginTop: '1rem' }}>
        <button className="secondary" disabled={!canRun || busyAction === 'boot'} onClick={() => runAction('boot')}>
          {busyAction === 'boot' ? 'Booting…' : 'Boot Simulator'}
        </button>
        <button className="secondary" disabled={!canRun || busyAction === 'install'} onClick={() => runAction('install')}>
          {busyAction === 'install' ? 'Installing…' : 'Install .app'}
        </button>
        <button className="secondary" disabled={!canRun || busyAction === 'terminate'} onClick={() => runAction('terminate')}>
          {busyAction === 'terminate' ? 'Terminating…' : 'Terminate'}
        </button>
        <button className="secondary" disabled={!canRun || busyAction === 'launch'} onClick={() => runAction('launch')}>
          {busyAction === 'launch' ? 'Launching…' : 'Launch'}
        </button>
        <button className="secondary" disabled={!canRun || busyAction === 'screenshot'} onClick={() => runAction('screenshot')}>
          {busyAction === 'screenshot' ? 'Capturing…' : 'Screenshot'}
        </button>
      </div>
      {output && (
        <pre className="logs-container" style={{ marginTop: '1rem' }}>
          {output}
        </pre>
      )}
      {screenshotPreview && (
        <div className="remote-preview">
          <h3>Screenshot</h3>
          <img src={screenshotPreview} alt="Simulator screenshot" />
        </div>
      )}
    </div>
  );
};

export default SimulatorBridgePanel;
