import React, { useCallback } from 'react';

type Props = {
  projectPath: string | null;
  onProjectSelected: (path: string | null) => void;
  recentProjects: string[];
  projectMeta: { hasPackageSwift: boolean; hasXtoolConfig: boolean } | null;
};

const ProjectPicker: React.FC<Props> = ({ projectPath, onProjectSelected, recentProjects, projectMeta }) => {
  const handleBrowse = useCallback(async () => {
    const selected = await window.bridge.selectDirectory();
    if (selected) {
      onProjectSelected(selected);
    }
  }, [onProjectSelected]);

  return (
    <div className="panel">
      <h2>Project Picker</h2>
      <p>Select your project directory. Recent projects are stored locally for quick access.</p>
      <div className="form-grid">
        <label>
          Current project
          <input type="text" value={projectPath ?? ''} readOnly placeholder="No project selected" />
        </label>
        <div style={{ display: 'flex', gap: '0.75rem' }}>
          <button className="primary" onClick={handleBrowse}>Choose Directory</button>
          <button className="secondary" onClick={() => onProjectSelected(null)}>Clear</button>
        </div>
      </div>
      {projectMeta && (
        <div className="tag-cloud">
          <span className="tag">Package.swift: {projectMeta.hasPackageSwift ? 'Found' : 'Missing'}</span>
          <span className="tag">xtool config: {projectMeta.hasXtoolConfig ? 'Found' : 'Missing'}</span>
        </div>
      )}
      <div className="panel" style={{ marginTop: '1rem' }}>
        <h3>Recent Projects</h3>
        {recentProjects.length === 0 && <p>No recent projects yet.</p>}
        {recentProjects.map(project => (
          <div key={project} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.5rem' }}>
            <span style={{ fontSize: '0.85rem' }}>{project}</span>
            <div style={{ display: 'flex', gap: '0.5rem' }}>
              <button className="secondary" onClick={() => onProjectSelected(project)}>Open</button>
              <button className="secondary" onClick={() => window.bridge.openPath(project)}>Reveal</button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default ProjectPicker;
