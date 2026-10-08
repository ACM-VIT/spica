// Runs in a short-lived Node child, off Spica's UI thread. This process reads
// Pi's credential store and emits normalized availability; credentials never enter RPC
// records, Spica snapshots, or the UI.
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const responseLimit = 2 * 1024 * 1024;

async function jsonResponse(url, headers, fetchImpl) {
  const response = await fetchImpl(url, { headers, signal: AbortSignal.timeout(3500) });
  if (!response.ok || !response.body) throw new Error("availability request failed");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > responseLimit) {
      await reader.cancel();
      throw new Error("availability response too large");
    }
    chunks.push(value);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function modelIds(items, field) {
  if (!Array.isArray(items) || !items.every((item) => item && typeof item[field] === "string")) {
    throw new Error("invalid model list");
  }
  return items.map((item) => item[field]);
}

function listedSlugs(result) {
  const ids = modelIds(result.models, "slug");
  if (!result.models.every((model) => model.visibility === "list" || model.visibility === "hide")) {
    throw new Error("invalid model visibility");
  }
  if (!result.models.every((model) => model.supported_in_api === undefined || typeof model.supported_in_api === "boolean")) {
    throw new Error("invalid model API capability");
  }
  return ids.filter((_, i) => result.models[i].visibility === "list" && result.models[i].supported_in_api !== false);
}

async function codexModels(credential, version, fetchImpl) {
  if (credential?.type !== "oauth" || !credential.access || !credential.accountId ||
      !Number.isFinite(credential.expires) || credential.expires <= Date.now()) return null;
  const url = `https://chatgpt.com/backend-api/codex/models?client_version=${encodeURIComponent(version)}`;
  const result = await jsonResponse(url, {
    Authorization: `Bearer ${credential.access}`,
    "ChatGPT-Account-ID": credential.accountId,
    originator: "pi",
  }, fetchImpl);
  return listedSlugs(result);
}

async function openaiOAuthModels(credential, fetchImpl) {
  if (!credential?.access || !Number.isFinite(credential.expires) || credential.expires <= Date.now() ||
      !Array.isArray(credential.scopes) || !credential.scopes.every((scope) => typeof scope === "string")) return null;
  // An explicit identity-only grant cannot power plan-backed inference.
  // Missing/malformed scope metadata remains unknown instead.
  if (!credential.scopes.includes("chatgpt.tokens.use.direct")) return [];
  // Sign in with ChatGPT documents this OAuth-specific /v1/models response as
  // {models:[{slug,display_name,visibility}]}; API keys receive {data:[{id}]}.
  // https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
  const result = await jsonResponse("https://api.openai.com/v1/models", {
    Authorization: `Bearer ${credential.access}`,
  }, fetchImpl);
  return listedSlugs(result);
}

async function openaiModels(key, fetchImpl) {
  const result = await jsonResponse("https://api.openai.com/v1/models", { Authorization: `Bearer ${key}` }, fetchImpl);
  return modelIds(result.data, "id");
}

async function anthropicModels(key, fetchImpl) {
  const ids = [];
  let after = "";
  for (let page = 0; page < 10; page++) {
    const url = new URL("https://api.anthropic.com/v1/models");
    url.searchParams.set("limit", "1000");
    if (after) url.searchParams.set("after_id", after);
    const result = await jsonResponse(url, { "x-api-key": key, "anthropic-version": "2023-06-01" }, fetchImpl);
    const batch = modelIds(result.data, "id");
    ids.push(...batch);
    if (result.has_more === false) return ids;
    if (result.has_more !== true || !batch.length || result.last_id === after || typeof result.last_id !== "string") {
      throw new Error("incomplete Anthropic model list");
    }
    after = result.last_id;
  }
  throw new Error("Anthropic model list page limit");
}

async function googleModels(key, fetchImpl) {
  const ids = [];
  let pageToken = "";
  for (let page = 0; page < 10; page++) {
    const url = new URL("https://generativelanguage.googleapis.com/v1beta/models");
    url.searchParams.set("pageSize", "1000");
    if (pageToken) url.searchParams.set("pageToken", pageToken);
    const result = await jsonResponse(url, { "x-goog-api-key": key }, fetchImpl);
    const names = modelIds(result.models, "name");
    for (const model of result.models) {
      if (!Array.isArray(model.supportedGenerationMethods)) throw new Error("invalid Gemini model methods");
      if (model.supportedGenerationMethods.includes("generateContent")) ids.push(model.name.replace(/^models\//, ""));
    }
    if (result.nextPageToken === undefined || result.nextPageToken === null || result.nextPageToken === "") return ids;
    if (typeof result.nextPageToken !== "string" || result.nextPageToken === pageToken || !names.length) {
      throw new Error("incomplete Gemini model list");
    }
    pageToken = result.nextPageToken;
  }
  throw new Error("Gemini model list page limit");
}

async function openrouterModels(key, fetchImpl) {
  // /models/user applies this credential's provider, privacy, and guardrail
  // settings. OpenRouter also lists :batch variants, which only work through
  // its batch API and cannot be used by Pi's interactive chat request.
  const result = await jsonResponse("https://openrouter.ai/api/v1/models/user", {
    Authorization: `Bearer ${key}`,
  }, fetchImpl);
  const ids = modelIds(result.data, "id");
  if (result.total_count !== ids.length || result.links?.next != null) {
    throw new Error("incomplete OpenRouter model list");
  }
  return ids.filter((id) => !id.endsWith(":batch"));
}

async function groqModels(key, fetchImpl) {
  const result = await jsonResponse("https://api.groq.com/openai/v1/models", {
    Authorization: `Bearer ${key}`,
  }, fetchImpl);
  const ids = modelIds(result.data, "id");
  if (!result.data.every((model) => typeof model.active === "boolean" &&
      Array.isArray(model.input_modalities) && Array.isArray(model.output_modalities))) {
    throw new Error("invalid Groq model capabilities");
  }
  return ids.filter((_, i) => {
    const model = result.data[i];
    return model.active && model.input_modalities.includes("text") && model.output_modalities.includes("text");
  });
}

function apiKeyFor(credential, environmentKey) {
  if (credential?.type === "api_key") return credential.key;
  return credential == null ? environmentKey : null;
}

export async function resolveAvailability({ credentials, env, version, overriddenProviders = [], fetchImpl = fetch, previousPolicy, now = Date.now() }) {
  const tasks = [];
  const overrides = new Set(overriddenProviders);
  const add = (provider, request) => {
    if (overrides.has(provider)) return;
    const credential = credentials[provider];
    const environmentKey = { openai: "OPENAI_API_KEY", anthropic: "ANTHROPIC_API_KEY", google: "GEMINI_API_KEY", openrouter: "OPENROUTER_API_KEY", groq: "GROQ_API_KEY" }[provider];
    const context = credential?.type === "unknown" ? null : createHash("sha256")
      .update(JSON.stringify([provider, credential ?? null, credential == null ? env[environmentKey] ?? null : null]))
      .digest("hex");
    const fallback = () => {
      // Only a recent result for exactly the same credential may survive a
      // temporary failure. Never carry restrictions into a different login.
      const previous = previousPolicy?.providers?.find((entry) => entry.provider === provider);
      return context && previous?.context === context && Number.isFinite(previous.checkedAt) &&
        now >= previous.checkedAt && now - previous.checkedAt < 5 * 60_000 &&
        Array.isArray(previous.availableIds) && previous.availableIds.every((id) => typeof id === "string")
        ? previous : null;
    };
    tasks.push((async () => {
      try {
        const availableIds = await request();
        return availableIds === null ? fallback() : { provider, availableIds, context, checkedAt: now };
      } catch {
        // A failed or incomplete lookup is unknown, never an empty entitlement.
        return fallback();
      }
    })());
  };
  add("openai-codex", () => codexModels(credentials["openai-codex"], version, fetchImpl));
  const openai = credentials.openai;
  if (openai?.type === "oauth") add("openai", () => openaiOAuthModels(openai, fetchImpl));
  else {
    const openaiKey = apiKeyFor(openai, env.OPENAI_API_KEY);
    if (openaiKey) add("openai", () => openaiModels(openaiKey, fetchImpl));
  }
  const anthropic = credentials.anthropic;
  const anthropicKey = apiKeyFor(anthropic, env.ANTHROPIC_API_KEY);
  if (anthropicKey) add("anthropic", () => anthropicModels(anthropicKey, fetchImpl));
  const google = credentials.google;
  const googleKey = apiKeyFor(google, env.GEMINI_API_KEY);
  if (googleKey) add("google", () => googleModels(googleKey, fetchImpl));
  const openrouter = credentials.openrouter;
  const openrouterKey = openrouter?.type === "oauth" ? openrouter.access :
    apiKeyFor(openrouter, env.OPENROUTER_API_KEY);
  if (openrouterKey) add("openrouter", () => openrouterModels(openrouterKey, fetchImpl));
  const groq = credentials.groq;
  const groqKey = apiKeyFor(groq, env.GROQ_API_KEY);
  if (groqKey) add("groq", () => groqModels(groqKey, fetchImpl));
  // null means a successful credential-store read confirmed no saved login.
  // undefined/unknown means the read failed, so never interpret it as logout.
  for (const [provider, environmentKey] of [
    ["openai-codex", null], ["openai", "OPENAI_API_KEY"], ["anthropic", "ANTHROPIC_API_KEY"],
    ["google", "GEMINI_API_KEY"], ["openrouter", "OPENROUTER_API_KEY"], ["groq", "GROQ_API_KEY"],
  ]) {
    if (credentials[provider] === null && (!environmentKey || !env[environmentKey])) add(provider, async () => []);
  }
  return { providers: (await Promise.all(tasks)).filter(Boolean) };
}

async function main() {
  const entry = resolve(process.argv[2]);
  const packageDir = dirname(dirname(dirname(entry)));
  const { getAgentDir, getModelsPath } = await import(pathToFileURL(join(packageDir, "dist/config.js")).href);
  const { version } = JSON.parse(await readFile(join(packageDir, "package.json"), "utf8"));
  const { AuthStorage } = await import(pathToFileURL(join(packageDir, "dist/core/auth-storage.js")).href);
  const store = AuthStorage.create(join(getAgentDir(), "auth.json"));
  const credentials = {};
  for (const provider of ["openai-codex", "openai", "anthropic", "google", "openrouter", "groq"]) {
    try { credentials[provider] = (await store.read(provider)) ?? null; }
    catch { credentials[provider] = { type: "unknown" }; }
  }
  // Reuse Pi's OAuth refresh implementation and credential lock, so a token
  // expiring while Spica is open does not restore the unfiltered list.
  await Promise.all([
    ["openai-codex", "loadOpenAICodexOAuth"],
    ["openai", "loadOpenAIChatGPTOAuth"],
  ].map(async ([provider, loader]) => {
    const credential = credentials[provider];
    if (credential?.type !== "oauth" || credential.expires > Date.now()) return;
    try {
      const loaders = await import(pathToFileURL(join(packageDir, "node_modules/@earendil-works/pi-ai/dist/auth/oauth/load.js")).href);
      const flow = await loaders[loader]();
      const signal = AbortSignal.timeout(3000);
      credentials[provider] = await store.modify(provider, async (current) => {
        if (current?.type !== "oauth" || current.expires > Date.now()) return undefined;
        return flow.refresh(current, signal);
      }, { signal });
      // modify() returns the current credential when another Pi process won the refresh.
    } catch { credentials[provider] = { type: "unknown" }; }
  }));
  let overriddenProviders = [];
  try {
    const config = JSON.parse(await readFile(getModelsPath(), "utf8"));
    overriddenProviders = Object.keys(config.providers ?? {});
  } catch (error) {
    // A missing file means there are no overrides. Any other read or parse
    // failure leaves every provider unknown because overrides cannot be ruled out.
    if (error?.code !== "ENOENT") {
      process.stdout.write('{"providers":[]}');
      return;
    }
  }
  let previousPolicy;
  try { previousPolicy = JSON.parse(process.argv[3]); } catch { /* first lookup */ }
  const result = await resolveAvailability({ credentials, env: process.env, version, overriddenProviders, previousPolicy });
  process.stdout.write(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    process.stderr.write(`${error?.message ?? "model availability startup failed"}\n`);
    process.exitCode = 1;
  });
}
