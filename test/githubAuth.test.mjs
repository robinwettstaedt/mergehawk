import test from "node:test";
import assert from "node:assert/strict";
import { createGitHubOAuthClient } from "../src/main/githubAuth.mjs";

test("requests a GitHub device code with the configured client id and scopes", async () => {
  const requests = [];
  const auth = createGitHubOAuthClient({
    clientId: "client_123",
    fetcher: async (url, options) => {
      requests.push({ url, options });
      return {
        ok: true,
        json: async () => ({
          device_code: "device_123",
          user_code: "ABCD-1234",
          verification_uri: "https://github.com/login/device",
          expires_in: 900,
          interval: 5
        })
      };
    }
  });

  const flow = await auth.requestDeviceCode({ scopes: ["repo", "read:user"] });

  assert.equal(requests[0].url, "https://github.com/login/device/code");
  assert.equal(requests[0].options.headers.accept, "application/json");
  assert.equal(String(requests[0].options.body), "client_id=client_123&scope=repo+read%3Auser");
  assert.deepEqual(flow, {
    deviceCode: "device_123",
    userCode: "ABCD-1234",
    verificationUri: "https://github.com/login/device",
    expiresIn: 900,
    interval: 5
  });
});

test("polls for an access token and waits through pending authorization", async () => {
  const requests = [];
  const sleeps = [];
  const auth = createGitHubOAuthClient({
    clientId: "client_123",
    sleep: async (ms) => sleeps.push(ms),
    fetcher: async (url, options) => {
      requests.push({ url, options });
      return {
        ok: true,
        json: async () =>
          requests.length === 1
            ? { error: "authorization_pending" }
            : { access_token: "gho_token", token_type: "bearer", scope: "repo,read:user" }
      };
    }
  });

  const token = await auth.pollForAccessToken({
    deviceCode: "device_123",
    interval: 5,
    maxAttempts: 2
  });

  assert.equal(requests.length, 2);
  assert.equal(sleeps[0], 5000);
  assert.equal(JSON.parse(JSON.stringify(token)).accessToken, "gho_token");
  assert.equal(String(requests[0].options.body), "client_id=client_123&device_code=device_123&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code");
});
