import { app, BrowserWindow, ipcMain, Menu, nativeImage, Notification, Tray } from "electron";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createGitHubClient } from "../src/main/githubClient.mjs";
import { createMockPullRequestSource } from "../src/main/mockPullRequestSource.mjs";
import { createSyncEngine } from "../src/main/syncEngine.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rendererUrl = process.env.ELECTRON_RENDERER_URL ?? "http://127.0.0.1:5173";
const pullRequestSource = createPullRequestSource();
const syncEngine = createSyncEngine({ fetchPullRequests: pullRequestSource.fetchPullRequests });

let mainWindow;
let tray;
let latestState = {
  pullRequests: [],
  events: [],
  syncedAt: null,
  source: pullRequestSource.source
};

function createPullRequestSource() {
  if (process.env.GITHUB_TOKEN && process.env.GITHUB_LOGIN) {
    const client = createGitHubClient({ token: process.env.GITHUB_TOKEN });
    return {
      source: "github",
      fetchPullRequests: () => client.fetchPullRequests({ login: process.env.GITHUB_LOGIN })
    };
  }

  const mockSource = createMockPullRequestSource();
  return {
    source: "mock",
    fetchPullRequests: mockSource.fetchPullRequests
  };
}

async function runSync({ notify = true } = {}) {
  latestState = await syncEngine.sync();
  latestState.source = pullRequestSource.source;
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

app.whenReady().then(async () => {
  createMainWindow();
  createTray();
  await runSync({ notify: false });
  setInterval(() => runSync().catch(console.error), 1000 * 60 * 5);
});

app.on("activate", showMainWindow);
app.on("before-quit", () => {
  app.isQuitting = true;
});
