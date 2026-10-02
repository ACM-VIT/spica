import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const titlePrefix = "Connect provider: ";
const maxInput = 8192;
async function sdk() {
    let directory = dirname(process.env.SPICA_PI_ENTRY || "");
    while (!existsSync(join(directory, "core/model-runtime.js"))) {
        const parent = dirname(directory);
        if (parent === directory || directory === ".") throw new Error("Pi SDK unavailable");
        directory = parent;
    }
    const load = (name) => import(pathToFileURL(join(directory, `core/${name}.js`)).href);
    const [{ ModelRuntime }, { AuthStorage }, { SettingsManager }] = await Promise.all([load("model-runtime"), load("auth-storage"), load("settings-manager")]);
    return { ModelRuntime, AuthStorage, SettingsManager };
}

function authentication(ui, registry, createRuntime, getDeviceId) {
    let active;
    let promptPending = false;
    const notify = (kind, fields = {}) => ui.notify(JSON.stringify({ spica_provider: true, kind, pending: promptPending, title: "Connect a provider", ...fields }));
    const cancel = () => active?.abort();
    async function connect() {
        if (active) return;
        const controller = new AbortController();
        active = controller;
        const signal = controller.signal;
        try {
            notify("waiting", { message: "Loading providers…" });
            const runtime = await createRuntime(signal);
            const ids = new Set([...registry.getAll().map((model) => model.provider), ...registry.getRegisteredProviderIds()]);
            for (const id of ids) {
                const provider = registry.getProvider(id);
                if (provider) runtime.registerNativeProvider(provider);
            }
            await runtime.refresh({ allowNetwork: false, signal });
            signal.throwIfAborted();
            const providers = runtime.getProviders().filter((provider) => provider.auth.oauth || provider.auth.apiKey?.login)
                .sort((a, b) => a.name.localeCompare(b.name));
            const nameCounts = new Map();
            for (const provider of providers) nameCounts.set(provider.name, (nameCounts.get(provider.name) || 0) + 1);
            const labels = providers.map((provider) => {
                const name = nameCounts.get(provider.name) > 1 ? `${provider.name} (${provider.id})` : provider.name;
                return name + (runtime.getProviderAuthStatus(provider.id).configured ? " · Configured" : "");
            });
            const choice = await ui.select(titlePrefix + "Choose a provider", labels, { signal });
            if (choice === undefined) { controller.abort(); signal.throwIfAborted(); }
            const provider = providers[labels.indexOf(choice)];
            if (!provider) throw new Error("Invalid provider selection");
            const methods = [];
            if (provider.auth.oauth) methods.push({ type: "oauth", label: provider.auth.oauth.loginLabel || `Browser OAuth — ${provider.auth.oauth.name}` });
            if (provider.auth.apiKey?.login) methods.push({ type: "api_key", label: provider.auth.apiKey.name });
            const methodLabel = await ui.select(titlePrefix + provider.name, methods.map((method) => method.label), { signal });
            if (methodLabel === undefined) { controller.abort(); signal.throwIfAborted(); }
            const method = methods.find((entry) => entry.label === methodLabel);
            if (!method) throw new Error("Invalid authentication selection");
            notify("waiting", { message: "Waiting for authentication…", url: "" });
            await runtime.login(provider.id, method.type, {
                signal,
                prompt: async (prompt) => {
                    const promptSignal = prompt.signal ? AbortSignal.any([signal, prompt.signal]) : signal;
                    let answer;
                    promptPending = true;
                    try {
                        if (prompt.type === "select") {
                            const options = prompt.options.map((option) => option.label);
                            const selected = await ui.select(titlePrefix + prompt.message, options, { signal: promptSignal });
                            answer = prompt.options[options.indexOf(selected)]?.id;
                        } else {
                            const secret = prompt.type === "secret" || prompt.type === "manual_code";
                            const message = prompt.type === "manual_code" ? "Authorization code or redirect URL" : prompt.message;
                            answer = await ui.input(titlePrefix + (secret ? "[secret] " : "") + message, prompt.placeholder || "", { signal: promptSignal });
                        }
                    } finally {
                        promptPending = false;
                    }
                    if (answer === undefined) {
                        if (!promptSignal.aborted) controller.abort();
                        throw new Error("Authentication cancelled");
                    }
                    if (answer.length > maxInput) throw new Error("Authentication input too long");
                    notify("waiting", { message: "Continuing authentication…" });
                    return answer;
                },
                notify: (event) => {
                    if (event.type === "auth_url") notify("waiting", { message: event.instructions || "Open your browser to sign in.", url: event.url });
                    else if (event.type === "device_code") notify("waiting", { message: `Enter device code ${event.userCode} in your browser.`, url: event.verificationUri });
                    else if (event.type === "info") {
                        const fields = { message: event.message };
                        if (event.links?.[0]?.url) fields.url = event.links[0].url;
                        notify("waiting", fields);
                    }
                    else notify("waiting", { message: "Waiting for authentication…" });
                },
            }, { getDeviceId });
            signal.throwIfAborted();
            const refreshed = await registry.refresh({ allowNetwork: false, signal });
            if (refreshed.aborted) signal.throwIfAborted();
            notify("done", { message: `${provider.name} connected`, url: "" });
        } catch {
            // SDK errors can contain request headers or user-entered credentials.
            notify(controller.signal.aborted ? "closed" : "failed", { message: controller.signal.aborted ? "Sign-in cancelled" : "Sign-in failed. Try again.", url: "" });
        } finally {
            if (active === controller) active = undefined;
        }
    }
    return { connect, cancel, isActive: () => active !== undefined };
}

export default function providerExtension(pi) {
    let flow;
    pi.registerCommand("spica-connect-provider", {
        description: "Connect a provider using native Spica authentication",
        handler: async (_args, ctx) => {
            if (!flow?.isActive()) {
                let settings;
                flow = authentication(ctx.ui, ctx.modelRegistry, async (signal) => {
                    const { ModelRuntime, AuthStorage, SettingsManager } = await sdk();
                    settings = SettingsManager.create(ctx.cwd, undefined, { projectTrusted: false });
                    return ModelRuntime.create({ credentials: AuthStorage.create(), allowModelNetwork: false, signal });
                }, () => settings.getOrCreateDeviceId());
            }
            await flow.connect();
        },
    });
    pi.registerCommand("spica-cancel-provider", { description: "Cancel provider authentication", handler: async () => flow?.cancel() });
    pi.on("session_shutdown", async () => flow?.cancel());
}

