/**
 * Expo config plugin for @fountispanel/connect-react-native.
 *
 *   plugins: [["@fountispanel/connect-react-native", { key: "pk_test_..." }]]
 *
 * iOS: adds the `fetch` background mode and the background refresh task id to Info.plist.
 * Android: nothing else is needed (permissions and the survey screen come with the library).
 * `key` / `apiBase` are optional. With a key the SDK starts while the app launches, which iOS
 * requires for background refresh. Without it, call start() from JS (background refresh stays off).
 * The key is a publishable key (pk_...), safe to ship in the app.
 */
const { withInfoPlist, withAndroidManifest, AndroidConfig, createRunOncePlugin } = require('expo/config-plugins');

const TASK_ID = 'org.fountis.connect.refresh';

function withFountisConnect(config, options = {}) {
  config = withInfoPlist(config, (c) => {
    const plist = c.modResults;
    const modes = new Set(plist.UIBackgroundModes ?? []);
    modes.add('fetch');
    plist.UIBackgroundModes = [...modes];
    const ids = new Set(plist.BGTaskSchedulerPermittedIdentifiers ?? []);
    ids.add(TASK_ID);
    plist.BGTaskSchedulerPermittedIdentifiers = [...ids];
    if (options.key) plist.FountisConnectKey = options.key;
    if (options.apiBase) plist.FountisConnectApiBase = options.apiBase;
    return c;
  });

  config = withAndroidManifest(config, (c) => {
    const app = AndroidConfig.Manifest.getMainApplicationOrThrow(c.modResults);
    if (options.key) AndroidConfig.Manifest.addMetaDataItemToMainApplication(app, 'org.fountis.connect.KEY', options.key);
    if (options.apiBase) AndroidConfig.Manifest.addMetaDataItemToMainApplication(app, 'org.fountis.connect.API_BASE', options.apiBase);
    return c;
  });

  return config;
}

const pkg = require('./package.json');
module.exports = createRunOncePlugin(withFountisConnect, pkg.name, pkg.version);
