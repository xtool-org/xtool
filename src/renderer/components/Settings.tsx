import React, { useEffect, useState } from 'react';

export type GlobalSettings = {
  xtoolPath: string;
  defaultArgs?: string;
  defaultEnv?: string;
};

export type ProjectSettings = {
  buildArgs: string;
  installArgs: string;
  launchArgs: string;
  envVars: string;
  bundleId: string;
  teamId: string;
  defaultDevice?: string;
  simulator: {
    host: string;
    user: string;
    sshKeyPath?: string;
    deviceName: string;
    appPath?: string;
    screenshotPath?: string;
  };
};

type Props = {
  projectPath: string | null;
  globalSettings: GlobalSettings;
  projectSettings: ProjectSettings;
  onGlobalChange: (key: keyof GlobalSettings, value: any) => void;
  onProjectChange: (key: keyof ProjectSettings, value: any) => void;
};

const SettingsPanel: React.FC<Props> = ({ projectPath, globalSettings, projectSettings, onGlobalChange, onProjectChange }) => {
  const [appleToken, setAppleToken] = useState('');
  const [tokenLoaded, setTokenLoaded] = useState(false);
  const [tokenStatus, setTokenStatus] = useState<string | null>(null);

  useEffect(() => {
    window.secret.get('apple-api-token').then(token => {
      setAppleToken(token ?? '');
      setTokenLoaded(true);
    });
  }, []);

  const handleTokenSave = async () => {
    await window.secret.set('apple-api-token', appleToken.trim() ? appleToken.trim() : null);
    setTokenStatus('Saved');
    setTimeout(() => setTokenStatus(null), 2500);
  };

  return (
    <div className="panel">
      <h2>Settings</h2>
      <p>Configure global and per-project defaults. Settings are persisted using electron-store and secrets via keytar.</p>
      <div className="panel" style={{ marginTop: '1rem' }}>
        <h3>Global</h3>
        <div className="form-grid">
          <label>
            xtool path
            <input type="text" value={globalSettings.xtoolPath ?? ''} onChange={event => onGlobalChange('xtoolPath', event.target.value)} />
          </label>
          <label>
            Default arguments
            <input type="text" value={globalSettings.defaultArgs ?? ''} onChange={event => onGlobalChange('defaultArgs', event.target.value)} />
          </label>
          <label>
            Default environment (KEY=VALUE per line)
            <textarea value={globalSettings.defaultEnv ?? ''} onChange={event => onGlobalChange('defaultEnv', event.target.value)} />
          </label>
        </div>
        <div className="form-grid">
          <label>
            Apple API token
            <input
              type="password"
              value={appleToken}
              placeholder={tokenLoaded ? '••••••' : 'Loading…'}
              onChange={event => setAppleToken(event.target.value)}
            />
          </label>
          <button className="secondary" onClick={handleTokenSave} disabled={!tokenLoaded}>
            Save token
          </button>
          {tokenStatus && <span className="tag">{tokenStatus}</span>}
        </div>
      </div>

      <div className="panel" style={{ marginTop: '1rem' }}>
        <h3>Per Project</h3>
        {projectPath ? <p>Project: {projectPath}</p> : <p>Select a project to edit project-specific settings.</p>}
        {projectPath && (
          <div className="form-grid">
            <label>
              Bundle ID
              <input type="text" value={projectSettings.bundleId} onChange={event => onProjectChange('bundleId', event.target.value)} />
            </label>
            <label>
              Team ID
              <input type="text" value={projectSettings.teamId} onChange={event => onProjectChange('teamId', event.target.value)} />
            </label>
            <label>
              Default build args
              <input type="text" value={projectSettings.buildArgs} onChange={event => onProjectChange('buildArgs', event.target.value)} />
            </label>
            <label>
              Default install args
              <input type="text" value={projectSettings.installArgs} onChange={event => onProjectChange('installArgs', event.target.value)} />
            </label>
            <label>
              Default launch args
              <input type="text" value={projectSettings.launchArgs} onChange={event => onProjectChange('launchArgs', event.target.value)} />
            </label>
            <label>
              Environment overrides
              <textarea value={projectSettings.envVars} onChange={event => onProjectChange('envVars', event.target.value)} />
            </label>
          </div>
        )}
      </div>
    </div>
  );
};

export default SettingsPanel;
