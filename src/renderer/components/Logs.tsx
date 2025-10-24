import React, { useMemo, useState } from 'react';
import AnsiUp from 'ansi_up';

export type LogEntry = {
  id: string;
  message: string;
  level: 'info' | 'warning' | 'error' | 'test';
  timestamp: number;
  processId: string;
};

export type LogFilter = 'all' | 'warning' | 'error' | 'test';

export type Problem = {
  file: string;
  line: number;
  column: number;
  level: 'warning' | 'error';
  message: string;
};

type Props = {
  logs: LogEntry[];
  filter: LogFilter;
  search: string;
  onFilterChange: (filter: LogFilter) => void;
  onSearchChange: (value: string) => void;
  onClear: () => void;
  problems: Problem[];
  onOpenProblem: (problem: Problem) => void;
};

const ansi = new AnsiUp();

const LogsPanel: React.FC<Props> = ({ logs, filter, search, onFilterChange, onSearchChange, onClear, problems, onOpenProblem }) => {
  const [showProblems, setShowProblems] = useState(true);

  const renderedLogs = useMemo(() => {
    return logs.map(entry => ({
      ...entry,
      html: ansi.ansi_to_html(entry.message)
    }));
  }, [logs]);

  return (
    <div className="panel">
      <h2>Logs</h2>
      <div className="logs-toolbar">
        <select value={filter} onChange={event => onFilterChange(event.target.value as LogFilter)}>
          <option value="all">All</option>
          <option value="warning">Warnings</option>
          <option value="error">Errors</option>
          <option value="test">Tests</option>
        </select>
        <input type="search" placeholder="Search logs" value={search} onChange={event => onSearchChange(event.target.value)} />
        <button className="secondary" onClick={onClear}>
          Clear
        </button>
      </div>
      <div className="logs-container">
        {renderedLogs.map(entry => (
          <div key={entry.id} className={`log-entry ${entry.level}`} dangerouslySetInnerHTML={{ __html: entry.html }} />
        ))}
        {renderedLogs.length === 0 && <div>No logs yet.</div>}
      </div>
      <div className="problems-list">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3>Problems</h3>
          <button className="secondary" onClick={() => setShowProblems(value => !value)}>
            {showProblems ? 'Hide' : 'Show'}
          </button>
        </div>
        {showProblems && (
          <ul>
            {problems.map((problem, index) => (
              <li key={`${problem.file}-${problem.line}-${index}`} onClick={() => onOpenProblem(problem)}>
                <strong>{problem.level.toUpperCase()}</strong> {problem.file}:{problem.line}:{problem.column} – {problem.message}
              </li>
            ))}
            {problems.length === 0 && <li>No problems detected.</li>}
          </ul>
        )}
      </div>
    </div>
  );
};

export default LogsPanel;
