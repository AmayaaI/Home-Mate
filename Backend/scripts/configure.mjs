// Import only the Firebase public client configuration. Never import a service-account key.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
const config = process.argv[2];
if (!config) throw new Error('Usage: npm run configure -- /path/to/GoogleService-Info.plist');
const result = spawnSync('/usr/bin/python3', ['-c', `
import plistlib, pathlib, sys, json, re
source = pathlib.Path(sys.argv[1]).expanduser()
project = pathlib.Path(sys.argv[2])
with source.open('rb') as f: config = plistlib.load(f)
if any(key in config for key in ['private_key', 'private_key_id', 'client_email']):
    raise SystemExit('A service-account private key must never be bundled with an iOS app.')
api_key, project_id = config.get('API_KEY'), config.get('PROJECT_ID')
if not isinstance(api_key, str) or not api_key or not isinstance(project_id, str) or not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]', project_id):
    raise SystemExit('Expected a Firebase iOS GoogleService-Info.plist with valid API_KEY and PROJECT_ID.')
if config.get('BUNDLE_ID') != 'com.homemate.app':
    raise SystemExit('Register the Firebase iOS app with bundle ID com.homemate.app.')
path = project / 'HomeMate/Info.plist'
with path.open('rb') as f: values = plistlib.load(f)
values['FirebaseAPIKey'] = api_key
values['FirebaseProjectID'] = project_id
with path.open('wb') as f: plistlib.dump(values, f, sort_keys=False)
(project / '.firebaserc').write_text(json.dumps({'projects': {'default': project_id}}, indent=2) + '\\n')
print('Configured HomeMate for Firebase project ' + project_id + '. No admin credentials were imported.')
`, config, root], { encoding: 'utf8' });
if (result.status !== 0) throw new Error(result.stderr || result.stdout || 'Configuration failed');
process.stdout.write(result.stdout);
