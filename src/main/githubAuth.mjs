const deviceCodeUrl = "https://github.com/login/device/code";
const accessTokenUrl = "https://github.com/login/oauth/access_token";
const deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code";

export function createGitHubOAuthClient({ clientId, fetcher = fetch, sleep = defaultSleep }) {
  if (!clientId) {
    throw new Error("GitHub OAuth client id is required");
  }

  async function requestDeviceCode({ scopes }) {
    const body = new URLSearchParams({
      client_id: clientId,
      scope: scopes.join(" ")
    });
    const payload = await postOAuth(deviceCodeUrl, body);

    return {
      deviceCode: payload.device_code,
      userCode: payload.user_code,
      verificationUri: payload.verification_uri,
      expiresIn: payload.expires_in,
      interval: payload.interval
    };
  }

  async function pollForAccessToken({ deviceCode, interval, maxAttempts = Number.POSITIVE_INFINITY }) {
    let currentInterval = interval;

    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      if (attempt > 0) {
        await sleep(currentInterval * 1000);
      }

      const body = new URLSearchParams({
        client_id: clientId,
        device_code: deviceCode,
        grant_type: deviceGrantType
      });
      const payload = await postOAuth(accessTokenUrl, body);

      if (payload.access_token) {
        return {
          accessToken: payload.access_token,
          tokenType: payload.token_type,
          scope: payload.scope
        };
      }

      if (payload.error === "authorization_pending") {
        continue;
      }

      if (payload.error === "slow_down") {
        currentInterval += 5;
        continue;
      }

      throw new Error(payload.error_description ?? payload.error ?? "GitHub OAuth polling failed");
    }

    throw new Error("GitHub OAuth polling timed out");
  }

  async function postOAuth(url, body) {
    const response = await fetcher(url, {
      method: "POST",
      headers: {
        accept: "application/json",
        "content-type": "application/x-www-form-urlencoded"
      },
      body
    });

    if (!response.ok) {
      throw new Error(`GitHub OAuth request failed with status ${response.status}`);
    }

    return response.json();
  }

  return {
    requestDeviceCode,
    pollForAccessToken
  };
}

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
