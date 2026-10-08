import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveAvailability as resolveDetailed } from "./model_availability.mjs";

// Most resolver tests assert public availability, independently of cache metadata.
async function resolveAvailability(options) {
  const result = await resolveDetailed(options);
  return { providers: result.providers.map(({ provider, availableIds }) => ({ provider, availableIds })) };
}

const reply = (body, status = 200) => new Response(JSON.stringify(body), { status });

test("Codex OAuth uses its account catalog while API-key OpenAI uses the API catalog", async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push([String(url), options.headers]);
    if (String(url).includes("/codex/models")) return reply({ models: [
      { slug: "current", visibility: "list", supported_in_api: true },
      { slug: "hidden", visibility: "hide", supported_in_api: true },
    ] });
    return reply({ data: [{ id: "api-current" }] });
  };
  const credentials = {
    "openai-codex": { type: "oauth", access: "secret", accountId: "account", expires: Date.now() + 60000 },
    openai: { type: "api_key", key: "api-secret" },
  };
  const result = await resolveAvailability({ credentials, env: {}, version: "1.0.0", fetchImpl });
  assert.deepEqual(result.providers, [
    { provider: "openai-codex", availableIds: ["current"] },
    { provider: "openai", availableIds: ["api-current"] },
  ]);
  assert.equal(calls.length, 2);
  assert.equal(calls[0][1]["ChatGPT-Account-ID"], "account");
  assert.equal(calls[1][1].Authorization, "Bearer api-secret");
});

test("Sign in with ChatGPT follows OpenAI's documented OAuth models/slug catalog", async () => {
  // Representative of the documented Sign in with ChatGPT response: models,
  // slug, display_name, visibility. supported_in_api is optional metadata.
  // https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
  const oauthCatalog = { models: [
    { slug: "plan-model", display_name: "Plan Model", visibility: "list" },
    { slug: "hidden-model", display_name: "Hidden Model", visibility: "hide" },
  ] };
  const result = await resolveAvailability({
    credentials: { openai: {
      type: "oauth", access: "oauth-secret", expires: Date.now() + 60000,
      scopes: ["chatgpt.tokens.use.direct"],
    } },
    env: { OPENAI_API_KEY: "different-key" }, version: "1.0.0",
    fetchImpl: async (url, options) => {
      assert.equal(String(url), "https://api.openai.com/v1/models");
      assert.equal(options.headers.Authorization, "Bearer oauth-secret");
      return reply(oauthCatalog);
    },
  });
  assert.deepEqual(result.providers, [{ provider: "openai", availableIds: ["plan-model"] }]);
});

test("an API-key-shaped or malformed response to ChatGPT OAuth stays unknown", async () => {
  const credentials = { openai: {
    type: "oauth", access: "oauth-secret", expires: Date.now() + 60000,
    scopes: ["chatgpt.tokens.use.direct"],
  } };
  for (const catalog of [
    { data: [{ id: "api-only" }] },
    { models: [{ id: "wrong-field", visibility: "list" }] },
    { models: [{ slug: "bad-visibility", visibility: "unknown" }] },
  ]) {
    const result = await resolveAvailability({ credentials, env: {}, version: "1.0.0", fetchImpl: async () => reply(catalog) });
    assert.deepEqual(result.providers, []);
  }
});

test("an explicit identity-only OpenAI grant cannot use plan models", async () => {
  const result = await resolveAvailability({
    credentials: { openai: { type: "oauth", access: "identity-token", expires: Date.now() + 60000, scopes: ["openid", "email"] } },
    env: { OPENAI_API_KEY: "different-key" }, version: "1.0.0",
    fetchImpl: () => { throw new Error("must not borrow API key or call inference"); },
  });
  assert.deepEqual(result.providers, [{ provider: "openai", availableIds: [] }]);
});

test("temporary outages retain a recent catalog only for the identical credential", async () => {
  for (const provider of ["openai", "openai-codex", "google"]) {
    const credential = provider === "google" ? { type: "api_key", key: "a" } : {
      type: "oauth", access: "a", accountId: "account", expires: Date.now() + 60000, scopes: ["chatgpt.tokens.use.direct"],
    };
    const options = { credentials: { [provider]: credential }, env: {}, version: "1.0.0", now: Date.now() };
    const previousPolicy = await resolveDetailed({ ...options, fetchImpl: async () => reply(provider === "google" ?
      { models: [{ name: "models/chat", supportedGenerationMethods: ["generateContent"] }] } :
      { models: [{ slug: "chat", visibility: "list" }] }) });
    const failed = { ...options, previousPolicy, fetchImpl: async () => reply({}, 503) };
    assert.deepEqual(await resolveDetailed(failed), previousPolicy);
    assert.deepEqual(await resolveDetailed({ ...failed, now: options.now + 300_000 }), { providers: [] });
    assert.deepEqual(await resolveDetailed({ ...failed, credentials: { [provider]: { ...credential, access: "b", key: "b" } } }), { providers: [] });
    assert.deepEqual(await resolveDetailed({ ...failed, overriddenProviders: [provider] }), { providers: [] });
    const revoked = await resolveDetailed({ ...failed, fetchImpl: async () => reply({ models: [] }) });
    assert.deepEqual(revoked.providers[0].availableIds, []);
    assert.equal(JSON.stringify(previousPolicy).includes('"access"'), false);
  }
});

test("both OpenAI OAuth routes reject malformed visibility or capability metadata", async () => {
  const credential = { type: "oauth", access: "a", accountId: "account", expires: Date.now() + 60000, scopes: ["chatgpt.tokens.use.direct"] };
  for (const model of [{ slug: "bad", visibility: "maybe" }, { slug: "bad", visibility: "list", supported_in_api: "false" }]) {
    const result = await resolveAvailability({ credentials: { openai: credential, "openai-codex": credential }, env: {}, version: "1.0.0",
      fetchImpl: async () => reply({ models: [model] }),
    });
    assert.deepEqual(result.providers, []);
  }
});

test("invalid OAuth context is unknown and never inherits API-key restrictions", async () => {
  const result = await resolveAvailability({
    credentials: { openai: { type: "oauth", access: "secret" } },
    env: { OPENAI_API_KEY: "different-key" }, version: "1.0.0",
    fetchImpl: () => { throw new Error("must not request"); },
  });
  assert.deepEqual(result.providers, []);
});

test("Anthropic and Google use different paginated authenticated catalogs", async () => {
  const fetchImpl = async (url) => {
    const u = new URL(url);
    if (u.hostname === "api.anthropic.com") {
      return u.searchParams.has("after_id")
        ? reply({ data: [{ id: "claude-b" }], has_more: false })
        : reply({ data: [{ id: "claude-a" }], has_more: true, last_id: "claude-a" });
    }
    return u.searchParams.has("pageToken")
      ? reply({ models: [{ name: "models/gemini-b", supportedGenerationMethods: ["generateContent"] }] })
      : reply({ models: [
        { name: "models/gemini-a", supportedGenerationMethods: ["generateContent"] },
        { name: "models/embedding", supportedGenerationMethods: ["embedContent"] },
      ], nextPageToken: "next" });
  };
  const result = await resolveAvailability({ credentials: {
    anthropic: { type: "api_key", key: "a" }, google: { type: "api_key", key: "g" },
  }, env: {}, version: "1.0.0", fetchImpl });
  assert.deepEqual(result.providers, [
    { provider: "anthropic", availableIds: ["claude-a", "claude-b"] },
    { provider: "google", availableIds: ["gemini-a", "gemini-b"] },
  ]);
});

test("Gemini rejects malformed page tokens instead of accepting a partial catalog", async () => {
  for (const nextPageToken of [false, 0, {}, []]) {
    const result = await resolveAvailability({
      credentials: { google: { type: "api_key", key: "g" } }, env: {}, version: "1.0.0",
      fetchImpl: async () => reply({
        models: [{ name: "models/partial", supportedGenerationMethods: ["generateContent"] }],
        nextPageToken,
      }),
    });
    assert.deepEqual(result.providers, []);
  }
});

test("failures and incomplete pages become unknown, never empty entitlements", async () => {
  const result = await resolveAvailability({ credentials: {
    "openai-codex": { type: "oauth", access: "x", accountId: "a", expires: Date.now() + 60000 },
    anthropic: { type: "api_key", key: "a" },
  }, env: {}, version: "1.0.0", fetchImpl: async (url) => {
    if (String(url).includes("/codex/models")) return reply({ error: "outage" }, 503);
    return reply({ data: [{ id: "partial" }], has_more: true, last_id: "partial" });
  } });
  assert.deepEqual(result.providers, []);
});

test("custom provider overrides keep Pi's existing model behavior", async () => {
  const result = await resolveAvailability({
    credentials: { openai: { type: "api_key", key: "secret" } },
    env: {}, version: "1.0.0", overriddenProviders: ["openai"],
    fetchImpl: () => { throw new Error("must not request public endpoint for custom provider"); },
  });
  assert.deepEqual(result.providers, []);
});

test("OpenRouter uses the signed-in account catalog and omits batch-only variants", async () => {
  const result = await resolveAvailability({
    credentials: { openrouter: { type: "oauth", access: "oauth-key" } }, env: {}, version: "1.0.0",
    fetchImpl: async (url, options) => {
      assert.equal(String(url), "https://openrouter.ai/api/v1/models/user");
      assert.equal(options.headers.Authorization, "Bearer oauth-key");
      return reply({ data: [
        { id: "vendor/chat" }, { id: "vendor/chat:batch" }, { id: "vendor/chat:free" },
      ], total_count: 3, links: { next: null } });
    },
  });
  assert.deepEqual(result.providers, [{ provider: "openrouter", availableIds: ["vendor/chat", "vendor/chat:free"] }]);
});

test("OpenRouter incomplete catalogs stay unknown", async () => {
  const result = await resolveAvailability({
    credentials: { openrouter: { type: "api_key", key: "key" } }, env: {}, version: "1.0.0",
    fetchImpl: async () => reply({ data: [{ id: "partial" }], total_count: 2, links: { next: "cursor" } }),
  });
  assert.deepEqual(result.providers, []);
});

test("Groq only exposes active text generation models", async () => {
  const result = await resolveAvailability({
    credentials: { groq: { type: "api_key", key: "groq-key" } }, env: {}, version: "1.0.0",
    fetchImpl: async (url, options) => {
      assert.equal(String(url), "https://api.groq.com/openai/v1/models");
      assert.equal(options.headers.Authorization, "Bearer groq-key");
      return reply({ data: [
        { id: "chat", active: true, input_modalities: ["text"], output_modalities: ["text"] },
        { id: "speech", active: true, input_modalities: ["text"], output_modalities: ["audio"] },
        { id: "retired", active: false, input_modalities: ["text"], output_modalities: ["text"] },
      ] });
    },
  });
  assert.deepEqual(result.providers, [{ provider: "groq", availableIds: ["chat"] }]);
});

test("logout is distinct from unreadable credentials and unsupported auth never borrows another key", async () => {
  const result = await resolveAvailability({
    credentials: { openrouter: null, google: { type: "unknown" }, groq: { type: "oauth", access: "other-context" } },
    env: { GEMINI_API_KEY: "different-key", GROQ_API_KEY: "different-key" }, version: "1.0.0",
    fetchImpl: () => { throw new Error("must not use a different authentication context"); },
  });
  assert.deepEqual(result.providers, [{ provider: "openrouter", availableIds: [] }]);
});

function piFixture() {
  const root = mkdtempSync(join(tmpdir(), "spica-pi-layout-"));
  const agent = join(root, "agent");
  mkdirSync(join(root, "dist/bundle"), { recursive: true });
  mkdirSync(join(root, "dist/core"), { recursive: true });
  mkdirSync(join(root, "node_modules/@earendil-works/pi-ai/dist/auth/oauth"), { recursive: true });
  mkdirSync(agent);
  writeFileSync(join(root, "package.json"), JSON.stringify({ type: "module", version: "fixture" }));
  writeFileSync(join(root, "dist/bundle/cli.js"), "");
  writeFileSync(join(root, "dist/config.js"), `
    export const getAgentDir = () => process.env.PI_CODING_AGENT_DIR;
    export const getModelsPath = () => process.env.PI_CODING_AGENT_DIR + "/models.json";
  `);
  writeFileSync(join(root, "dist/core/auth-storage.js"), `
    import { readFile, writeFile } from "node:fs/promises";
    export class AuthStorage {
      static create(path) { return new AuthStorage(path); }
      constructor(path) { this.path = path; }
      async read(provider) { return JSON.parse(await readFile(this.path, "utf8"))[provider]; }
      async modify(provider, update) {
        const all = JSON.parse(await readFile(this.path, "utf8"));
        const changed = await update(all[provider]);
        if (changed !== undefined) { all[provider] = changed; await writeFile(this.path, JSON.stringify(all)); }
        return all[provider];
      }
    }
  `);
  writeFileSync(join(root, "node_modules/@earendil-works/pi-ai/dist/auth/oauth/load.js"), `
    const flow = async () => ({ refresh: async () => ({ type: "unknown" }) });
    export const loadOpenAICodexOAuth = flow;
    export const loadOpenAIChatGPTOAuth = flow;
  `);
  return { root, agent, entry: join(root, "dist/bundle/cli.js") };
}

function runFixture(fixture, inherited = {}) {
  const env = { ...process.env, ...inherited, PI_CODING_AGENT_DIR: fixture.agent };
  for (const key of ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "OPENROUTER_API_KEY", "GROQ_API_KEY"]) delete env[key];
  return spawnSync(process.execPath, [resolve(dirname(fileURLToPath(import.meta.url)), "model_availability.mjs"), fixture.entry], {
    encoding: "utf8", env,
  });
}

test("helper starts against Pi's package layout and handles expired or unreadable credentials safely", () => {
  const fixture = piFixture();
  try {
    writeFileSync(join(fixture.agent, "auth.json"), JSON.stringify({
      openai: { type: "oauth", access: "expired", refresh: "refresh", expires: 0 },
    }));
    writeFileSync(join(fixture.agent, "models.json"), JSON.stringify({ providers: { openai: {} } }));
    let child = runFixture(fixture, { GROQ_API_KEY: "must-never-reach-a-provider" });
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout).providers.map(({ provider }) => provider).sort(),
      ["anthropic", "google", "groq", "openai-codex", "openrouter"].sort());

    writeFileSync(join(fixture.agent, "auth.json"), "not json");
    child = runFixture(fixture);
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout), { providers: [] });

    writeFileSync(join(fixture.agent, "auth.json"), "{}");
    writeFileSync(join(fixture.agent, "models.json"), "not json");
    child = runFixture(fixture);
    assert.equal(child.status, 0, child.stderr);
    assert.deepEqual(JSON.parse(child.stdout), { providers: [] });
  } finally {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("helper startup failures are observable instead of masquerading as normal unknown availability", () => {
  const child = spawnSync(process.execPath, [resolve(dirname(fileURLToPath(import.meta.url)), "model_availability.mjs"), "/missing/pi/dist/bundle/cli.js"], { encoding: "utf8" });
  assert.notEqual(child.status, 0);
  assert.equal(child.stdout, "");
  assert.match(child.stderr, /Cannot find module|ENOENT/);
});
