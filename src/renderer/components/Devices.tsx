import React from 'react';

export type Device = {
  name: string;
  platform: string;
  udid: string;
};

type Props = {
  devices: Device[];
  loading: boolean;
  defaultDevice: string;
  onRefresh: () => void;
  onSetDefault: (udid: string) => void;
};

const DevicesPanel: React.FC<Props> = ({ devices, loading, defaultDevice, onRefresh, onSetDefault }) => {
  return (
    <div className="panel">
      <h2>Connected Devices</h2>
      <p>Devices are fetched from <code>xtool devices</code>. Select a default device for install operations.</p>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.75rem' }}>
        <span>{devices.length} devices detected</span>
        <button className="secondary" onClick={onRefresh} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>
      <table className="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Platform</th>
            <th>UDID</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {devices.map(device => (
            <tr key={device.udid}>
              <td>{device.name}</td>
              <td>{device.platform}</td>
              <td>{device.udid}</td>
              <td>
                <button
                  className={device.udid === defaultDevice ? 'primary' : 'secondary'}
                  onClick={() => onSetDefault(device.udid)}
                >
                  {device.udid === defaultDevice ? 'Default' : 'Set default'}
                </button>
              </td>
            </tr>
          ))}
          {devices.length === 0 && (
            <tr>
              <td colSpan={4} style={{ textAlign: 'center', padding: '1rem' }}>
                {loading ? 'Scanning devices…' : 'No devices found. Connect a device and refresh.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
};

export default DevicesPanel;
