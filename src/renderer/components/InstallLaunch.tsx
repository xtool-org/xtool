import React, { useState } from 'react';

type Props = {
  bundleId: string;
  teamId: string;
  installArgs: string;
  launchArgs: string;
  defaultDevice: string;
  onBundleChange: (value: string) => void;
  onTeamChange: (value: string) => void;
  onInstallArgsChange: (value: string) => void;
  onLaunchArgsChange: (value: string) => void;
  onInstall: () => Promise<any>;
  onLaunch: () => Promise<any>;
  onTerminate: () => Promise<any>;
};

const InstallLaunchPanel: React.FC<Props> = ({
  bundleId,
  teamId,
  installArgs,
  launchArgs,
  defaultDevice,
  onBundleChange,
  onTeamChange,
  onInstallArgsChange,
  onLaunchArgsChange,
  onInstall,
  onLaunch,
  onTerminate
}) => {
  const [installing, setInstalling] = useState(false);
  const [launching, setLaunching] = useState(false);
  const [terminating, setTerminating] = useState(false);

  const handleInstall = async () => {
    setInstalling(true);
    try {
      const result = await onInstall();
      if (result?.completion) {
        await result.completion;
      }
    } finally {
      setInstalling(false);
    }
  };

  const handleLaunch = async () => {
    setLaunching(true);
    try {
      const result = await onLaunch();
      if (result?.completion) {
        await result.completion;
      }
    } finally {
      setLaunching(false);
    }
  };

  const handleTerminate = async () => {
    setTerminating(true);
    try {
      await onTerminate();
    } finally {
      setTerminating(false);
    }
  };

  return (
    <div className="panel">
      <h2>Install & Launch</h2>
      <p>Install and launch your app on the selected device. Configure identifiers and arguments below.</p>
      <div className="form-grid">
        <label>
          Bundle Identifier
          <input type="text" value={bundleId} onChange={event => onBundleChange(event.target.value)} placeholder="com.example.app" />
        </label>
        <label>
          Team ID
          <input type="text" value={teamId} onChange={event => onTeamChange(event.target.value)} placeholder="ABCDE12345" />
        </label>
        <label>
          Install arguments
          <input type="text" value={installArgs} onChange={event => onInstallArgsChange(event.target.value)} placeholder="--force" />
        </label>
        <label>
          Launch arguments
          <input type="text" value={launchArgs} onChange={event => onLaunchArgsChange(event.target.value)} placeholder="--clean" />
        </label>
      </div>
      <div className="tag-cloud">
        <span className="tag">Default device: {defaultDevice || 'Not set'}</span>
      </div>
      <div style={{ display: 'flex', gap: '0.75rem', marginTop: '1rem' }}>
        <button className="primary" onClick={handleInstall} disabled={installing}>
          {installing ? 'Installing…' : 'Install'}
        </button>
        <button className="primary" onClick={handleLaunch} disabled={launching}>
          {launching ? 'Launching…' : 'Launch'}
        </button>
        <button className="secondary" onClick={handleTerminate} disabled={terminating}>
          {terminating ? 'Terminating…' : 'Terminate app'}
        </button>
      </div>
    </div>
  );
};

export default InstallLaunchPanel;
