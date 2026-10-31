const Metro = require('metro');
const path = require('path');
const fs = require('fs');

(async () => {
  const root = path.resolve(__dirname, '..');
  const output = path.join(root, 'build', 'OmarchyReactNative.app');
  fs.mkdirSync(output, {recursive: true});
  const config = await Metro.loadConfig({cwd: root});
  await Metro.runBuild(config, {
    entry: path.join(root, 'index.js'),
    out: path.join(output, 'main.jsbundle'),
    platform: 'ios', dev: false, minify: false, sourceMap: true,
  });
  fs.renameSync(path.join(output, 'main.jsbundle.js'), path.join(output, 'main.jsbundle'));
})().catch(error => { console.error(error); process.exit(1); });
