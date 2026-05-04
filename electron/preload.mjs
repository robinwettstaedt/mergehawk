import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("vcDash", {
  getState: () => ipcRenderer.invoke("dashboard:getState"),
  refresh: () => ipcRenderer.invoke("dashboard:refresh"),
  getAuthState: () => ipcRenderer.invoke("auth:getState"),
  startSignIn: () => ipcRenderer.invoke("auth:startSignIn"),
  signOut: () => ipcRenderer.invoke("auth:signOut"),
  onState: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on("dashboard:state", listener);
    return () => ipcRenderer.removeListener("dashboard:state", listener);
  }
});
