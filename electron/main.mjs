import { app, BrowserWindow, ipcMain, Menu, nativeImage, Notification, safeStorage, shell, Tray } from "electron";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createGitHubOAuthClient } from "../src/main/githubAuth.mjs";
import { createGitHubClient } from "../src/main/githubClient.mjs";
import { createMockPullRequestSource } from "../src/main/mockPullRequestSource.mjs";
import { createSyncEngine } from "../src/main/syncEngine.mjs";
import { createFileTokenStore } from "../src/main/tokenStore.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rendererUrl = process.env.ELECTRON_RENDERER_URL ?? "http://127.0.0.1:5173";
const mockSource = createMockPullRequestSource();
const syncEngine = createSyncEngine({ fetchPullRequests: fetchPullRequestsForCurrentAuth });

let mainWindow;
let tray;
let tokenStore;
let authRecord = null;
let authFlow = null;
let authPollPromise = null;
let authErrorMessage = null;
let latestState = {
  pullRequests: [],
  events: [],
  syncedAt: null,
  source: "mock",
  account: null,
  auth: {
    configured: Boolean(process.env.GITHUB_CLIENT_ID),
    status: "signed_out"
  }
};

async function fetchPullRequestsForCurrentAuth() {
  if (authRecord?.accessToken && authRecord?.login) {
    const client = createGitHubClient({ token: authRecord.accessToken });
    return client.fetchPullRequests({ login: authRecord.login });
  }

  if (process.env.GITHUB_TOKEN && process.env.GITHUB_LOGIN) {
    const client = createGitHubClient({ token: process.env.GITHUB_TOKEN });
    return client.fetchPullRequests({ login: process.env.GITHUB_LOGIN });
  }

  return mockSource.fetchPullRequests();
}

function getSourceName() {
  if (authRecord?.accessToken) return "github";
  if (process.env.GITHUB_TOKEN && process.env.GITHUB_LOGIN) return "github-env";
  return "mock";
}

function getAccount() {
  if (authRecord?.login) return { login: authRecord.login, avatarUrl: authRecord.avatarUrl };
  if (process.env.GITHUB_LOGIN) return { login: process.env.GITHUB_LOGIN };
  return null;
}

function getAuthState() {
  return {
    configured: Boolean(process.env.GITHUB_CLIENT_ID),
    status: authFlow ? "signing_in" : authRecord ? "signed_in" : "signed_out",
    error: authErrorMessage,
    flow: authFlow
      ? {
          userCode: authFlow.userCode,
          verificationUri: authFlow.verificationUri,
          expiresAt: authFlow.expiresAt
        }
      : null,
    account: getAccount()
  };
}

function decorateState(state) {
  return {
    ...state,
    source: getSourceName(),
    account: getAccount(),
    auth: getAuthState()
  };
}

async function runSync({ notify = true } = {}) {
  latestState = decorateState(await syncEngine.sync());
  updateTray();
  mainWindow?.webContents.send("dashboard:state", latestState);

  if (notify && latestState.events.length > 0 && Notification.isSupported()) {
    new Notification({
      title: "VC Dash",
      body: `${latestState.events.length} PR update${latestState.events.length === 1 ? "" : "s"} need attention`
    }).show();
  }

  return latestState;
}

async function startSignIn() {
  if (!process.env.GITHUB_CLIENT_ID) {
    throw new Error("Set GITHUB_CLIENT_ID to your GitHub OAuth app client id before signing in.");
  }

  authErrorMessage = null;

  if (authPollPromise) {
    return getAuthState();
  }

  const auth = createGitHubOAuthClient({ clientId: process.env.GITHUB_CLIENT_ID });
  const flow = await auth.requestDeviceCode({ scopes: ["repo", "read:user"] });
  authFlow = {
    ...flow,
    expiresAt: new Date(Date.now() + flow.expiresIn * 1000).toISOString()
  };
  shell.openExternal(authFlow.verificationUri);
  mainWindow?.webContents.send("dashboard:state", decorateState(latestState));

  authPollPromise = completeSignIn(auth, flow).finally(() => {
    authPollPromise = null;
  });

  return getAuthState();
}

async function completeSignIn(auth, flow) {
  try {
    const token = await auth.pollForAccessToken({
      deviceCode: flow.deviceCode,
      interval: flow.interval
    });
    const client = createGitHubClient({ token: token.accessToken });
    const viewer = await client.fetchViewer();
    authRecord = {
      accessToken: token.accessToken,
      scope: token.scope,
      login: viewer.login,
      avatarUrl: viewer.avatarUrl
    };
    await tokenStore.set(authRecord);
    authFlow = null;
    authErrorMessage = null;
    await runSync({ notify: false });
  } catch (error) {
    authFlow = null;
    authErrorMessage = error.message;
    mainWindow?.webContents.send("dashboard:state", decorateState(latestState));
  }
}

async function signOut() {
  authFlow = null;
  authErrorMessage = null;
  authRecord = null;
  await tokenStore.clear();
  latestState = decorateState({
    pullRequests: [],
    events: [],
    syncedAt: null
  });
  updateTray();
  mainWindow?.webContents.send("dashboard:state", latestState);
  return getAuthState();
}

function createTokenStore() {
  const authPath = path.join(app.getPath("userData"), "auth.json");
  return createFileTokenStore({
    filePath: authPath,
    writeFile: async (filePath, value) => {
      await fs.mkdir(path.dirname(filePath), { recursive: true });
      await fs.writeFile(filePath, value, "utf8");
    },
    encrypt: (value) => {
      if (safeStorage.isEncryptionAvailable()) {
        return safeStorage.encryptString(value).toString("base64");
      }
      return Buffer.from(value, "utf8").toString("base64");
    },
    decrypt: (value) => {
      const buffer = Buffer.from(value, "base64");
      if (safeStorage.isEncryptionAvailable()) {
        return safeStorage.decryptString(buffer);
      }
      return buffer.toString("utf8");
    }
  });
}

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 900,
    minHeight: 600,
    title: "VC Dash",
    webPreferences: {
      preload: path.join(__dirname, "preload.mjs"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadURL(rendererUrl);
  mainWindow.on("close", (event) => {
    if (!app.isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
}

function updateTray() {
  if (!tray) {
    return;
  }

  const attentionCount = latestState.events.length;
  tray.setToolTip(attentionCount > 0 ? `VC Dash: ${attentionCount} updates` : "VC Dash");
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: attentionCount > 0 ? `${attentionCount} updates need attention` : "No new PR updates", enabled: false },
      { type: "separator" },
      { label: "Open Dashboard", click: showMainWindow },
      { label: "Refresh Now", click: () => runSync() },
      { type: "separator" },
      {
        label: "Quit",
        click: () => {
          app.isQuitting = true;
          app.quit();
        }
      }
    ])
  );
}

function createTray() {
  const icon = nativeImage.createFromDataURL(
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAKUlEQVR4AWNgGAWjYBSMglEwCkbBKBgFo2AUjIJRMApGwSgYBQMA3bABHq8gxjQAAAAASUVORK5CYII="
  );
  icon.setTemplateImage(true);
  tray = new Tray(icon);
  tray.on("click", showMainWindow);
  updateTray();
}

function showMainWindow() {
  if (!mainWindow) {
    createMainWindow();
  }
  mainWindow.show();
  mainWindow.focus();
}

ipcMain.handle("dashboard:getState", () => latestState);
ipcMain.handle("dashboard:refresh", () => runSync());
ipcMain.handle("auth:getState", () => getAuthState());
ipcMain.handle("auth:startSignIn", () => startSignIn());
ipcMain.handle("auth:signOut", () => signOut());

app.whenReady().then(async () => {
  tokenStore = createTokenStore();
  authRecord = await tokenStore.get();
  latestState = decorateState(latestState);
  createMainWindow();
  createTray();
  await runSync({ notify: false });
  setInterval(() => runSync().catch(console.error), 1000 * 60 * 5);
});

app.on("activate", showMainWindow);
app.on("before-quit", () => {
  app.isQuitting = true;
});
