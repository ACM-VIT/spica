import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';

const inputLimit = 8192;
let sdkPromise;
function sdk() {
  return sdkPromise ??= (async () => {
    let directory = dirname(process.argv[2] || '');
    while (!existsSync(join(directory, 'core/model-runtime.js'))) {
      const parent = dirname(directory);
      if (parent === directory || directory === '.') throw new Error('Pi SDK unavailable');
      directory = parent;
    }
    const load = name => import(pathToFileURL(join(directory, `core/${name}.js`)).href);
    const [{ ModelRuntime }, { AuthStorage }, { SettingsManager }] = await Promise.all([
      load('model-runtime'), load('auth-storage'), load('settings-manager'),
    ]);
    return { ModelRuntime, AuthStorage, SettingsManager };
  })();
}

let active;
let latestAttempt = 0;
function emit(flow, fields) {
  flow.ui = { ...flow.ui, ...fields };
  process.stdout.write(JSON.stringify({ type: 'provider_ui', attempt: flow.attempt, ...flow.ui }) + '\n');
}
function request(flow, fields, signal = flow.controller.signal) {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const cleanup = () => {
      signal.removeEventListener('abort', abort);
      if (flow.pending?.id === id) flow.pending = undefined;
    };
    const abort = () => { cleanup(); reject(new Error('Cancelled')); };
    flow.pending = { id, resolve: value => { cleanup(); resolve(value); }, reject: abort };
    signal.addEventListener('abort', abort, { once: true });
    emit(flow, { ...fields, id });
  });
}
async function connect(flow) {
  const signal = flow.controller.signal;
  try {
    emit(flow, { kind: 'waiting', title: 'Connect a provider', message: 'Loading providers…', id: '', url: '', options: [] });
    const { ModelRuntime, AuthStorage, SettingsManager } = await sdk();
    signal.throwIfAborted();
    // Direct SDK construction deliberately bypasses extension discovery and execution.
    const runtime = await ModelRuntime.create({ credentials: AuthStorage.create(), allowModelNetwork: false, signal });
    signal.throwIfAborted();
    const settings = SettingsManager.create(process.cwd(), undefined, { projectTrusted: false });
    const providers = runtime.getProviders().filter(p => p.auth.oauth || p.auth.apiKey?.login).sort((a, b) => a.name.localeCompare(b.name));
    const counts = new Map();
    for (const p of providers) counts.set(p.name, (counts.get(p.name) || 0) + 1);
    const labels = providers.map(p => (counts.get(p.name) > 1 ? `${p.name} (${p.id})` : p.name) + (runtime.getProviderAuthStatus(p.id).configured ? ' · Configured' : ''));
    const choice = await request(flow, { kind: 'select', title: 'Choose a provider', message: '', options: labels, secret: false });
    const provider = providers[labels.indexOf(choice)];
    if (!provider) throw new Error('Invalid provider');
    const methods = [];
    if (provider.auth.oauth) methods.push({ type: 'oauth', label: provider.auth.oauth.loginLabel || provider.auth.oauth.name });
    if (provider.auth.apiKey?.login) methods.push({ type: 'api_key', label: provider.auth.apiKey.name });
    const methodChoice = await request(flow, { kind: 'select', title: provider.name, options: methods.map(m => m.label) });
    const method = methods.find(m => m.label === methodChoice);
    if (!method) throw new Error('Invalid method');
    emit(flow, { kind: 'waiting', id: '', options: [], message: 'Signing in…' });
    await runtime.login(provider.id, method.type, {
      signal,
      prompt: async prompt => {
        const promptSignal = prompt.signal ? AbortSignal.any([signal, prompt.signal]) : signal;
        let answer;
        if (prompt.type === 'select') {
          const options = prompt.options.map(o => o.label);
          const choice = await request(flow, { kind: 'select', title: prompt.message, message: '', options, secret: false }, promptSignal);
          answer = prompt.options[options.indexOf(choice)]?.id;
        } else {
          answer = await request(flow, {
            kind: 'input', title: flow.ui.url ? 'Sign in' : provider.name,
            message: prompt.type === 'manual_code' ? 'Authorization code or redirect URL' : prompt.message,
            placeholder: prompt.placeholder || '', options: [],
            secret: prompt.type === 'secret' || prompt.type === 'manual_code',
          }, promptSignal);
        }
        if (typeof answer !== 'string' || Buffer.byteLength(answer, 'utf8') > inputLimit) throw new Error('Invalid input');
        emit(flow, { kind: 'waiting', id: '', message: 'Signing in…', options: [] });
        return answer;
      },
      notify: event => {
        const fields = {};
        if (event.type === 'auth_url') {
          fields.url = event.url;
          if (!flow.pending) fields.message = event.instructions || 'Signing in…';
        } else if (event.type === 'device_code') {
          fields.url = event.verificationUri;
          fields.message = `Device code: ${event.userCode}`;
        } else if (event.type === 'info') {
          if (!flow.pending) fields.message = event.message;
          if (event.links?.[0]?.url) fields.url = event.links[0].url;
        }
        emit(flow, fields);
      },
    }, { getDeviceId: () => settings.getOrCreateDeviceId() });
    signal.throwIfAborted();
    emit(flow, { kind: 'done', title: provider.name, message: 'Connected', id: '', url: '', options: [] });
  } catch {
    // Provider errors may contain credentials. Never echo error objects or input.
    emit(flow, { kind: signal.aborted ? 'closed' : 'failed', title: 'Connect a provider', message: signal.aborted ? '' : 'Sign-in failed. Try again.', id: '', url: '', options: [] });
  } finally {
    flow.pending?.reject();
    if (active === flow) active = undefined;
  }
}

const reader = createInterface({ input: process.stdin, crlfDelay: Infinity });
reader.on('line', line => {
  try {
    if (Buffer.byteLength(line, 'utf8') > 65536) return;
    const command = JSON.parse(line);
    if (!Number.isSafeInteger(command.attempt) || command.attempt <= 0) return;
    if (command.type === 'connect') {
      if (command.attempt <= latestAttempt) return;
      latestAttempt = command.attempt;
      active?.controller.abort();
      const flow = { attempt: command.attempt, controller: new AbortController(), ui: {} };
      active = flow;
      void connect(flow);
    } else if (active?.attempt === command.attempt) {
      if (command.type === 'cancel') active.controller.abort();
      else if (command.type === 'respond' && active.pending?.id === command.id && typeof command.value === 'string' && Buffer.byteLength(command.value, 'utf8') <= inputLimit) {
        if (active.ui.kind === 'select' && !active.ui.options.includes(command.value)) return;
        active.pending.resolve(command.value);
      }
    }
  } catch { /* Malformed or obsolete commands never produce credential-bearing diagnostics. */ }
});
reader.on('close', () => active?.controller.abort());
