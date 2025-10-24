import React, { useState } from 'react';

type Props = {
  buildArgs: string;
  envVars: string;
  onBuildArgsChange: (value: string) => void;
  onEnvVarsChange: (value: string) => void;
  onRunBuild: () => Promise<any>;
};

const BuildPanel: React.FC<Props> = ({ buildArgs, envVars, onBuildArgsChange, onEnvVarsChange, onRunBuild }) => {
  const [isRunning, setIsRunning] = useState(false);

  const handleRun = async () => {
    setIsRunning(true);
    try {
      const result = await onRunBuild();
      if (result?.completion) {
        await result.completion;
      }
    } finally {
      setIsRunning(false);
    }
  };

  return (
    <div className="panel">
      <h2>Build</h2>
      <p>Configure build arguments and environment variables. Builds run via <code>xtool dev</code>.</p>
      <div className="form-grid">
        <label>
          Extra build arguments
          <input type="text" value={buildArgs} onChange={event => onBuildArgsChange(event.target.value)} placeholder="--verbose" />
        </label>
        <label>
          Environment variables (KEY=VALUE per line)
          <textarea value={envVars} onChange={event => onEnvVarsChange(event.target.value)} placeholder={'TEAM_ID=XXXXXX\nCUSTOM_FLAG=1'} />
        </label>
      </div>
      <button className="primary" onClick={handleRun} disabled={isRunning}>
        {isRunning ? 'Building…' : 'Build'}
      </button>
    </div>
  );
};

export default BuildPanel;
