import assert from "node:assert/strict";
import { test } from "node:test";
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

test("Sign in with ChatGPT uses the OAuth account catalog, not the API-key data list", async () => {
  const result = await resolveAvailability({
    credentials: { openai: {
      type: "oauth", access: "oauth-secret", expires: Date.now() + 60000,
      scopes: ["chatgpt.tokens.use.direct"],
    } },
    env: { OPENAI_API_KEY: "different-key" }, version: "1.0.0",
    fetchImpl: async (url, options) => {
      assert.equal(String(url), "https://api.openai.com/v1/models");
      assert.equal(options.headers.Authorization, "Bearer oauth-secret");
      return reply({ models: [
        { slug: "plan-model", visibility: "list", supported_in_api: true },
        { slug: "hidden-model", visibility: "hide", supported_in_api: true },
        { slug: "unsupported-route", visibility: "list", supported_in_api: false },
      ] });
    },
  });
  assert.deepEqual(result.providers, [{ provider: "openai", availableIds: ["plan-model"] }]);
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
