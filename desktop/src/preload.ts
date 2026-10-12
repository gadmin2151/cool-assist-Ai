import { contextBridge, ipcRenderer } from "electron";
import type { Bridge } from "./contracts";
const invoke = <T>(channel: string, ...args: unknown[]): Promise<T> =>
  ipcRenderer.invoke(channel, ...args);
const api: Bridge = {
  snapshot: () => invoke("snapshot"),
  meeting: (id) => invoke("meeting", id),
  start: (options) => invoke("record:start", options),
  append: (id, samples) => invoke("record:append", id, samples),
  pauseCapture: (id, paused) => invoke("record:pause", id, paused),
  stop: (id) => invoke("record:stop", id),
  mark: (id) => invoke("record:mark", id),
  queue: (id, action) => invoke("queue", id, action),
  saveMeeting: (id, patch) => invoke("meeting:save", id, patch),
  setTaskDone: (id, taskID, done) => invoke("task:done", id, taskID, done),
  remove: (id) => invoke("meeting:remove", id),
  exportMarkdown: (id) => invoke("meeting:export", id),
  saveSettings: (value) => invoke("settings:save", value),
  saveKey: (key, persist) => invoke("key:save", key, persist),
  removeKey: () => invoke("key:remove"),
  models: () => invoke("models"),
  downloadModels: () => invoke("local:download"),
  cancelModels: () => invoke("local:cancel"),
  compact: (enabled) => invoke("compact", enabled),
  onUpdate: (fn) => {
    const listener = () => fn();
    ipcRenderer.on("updated", listener);
    return () => ipcRenderer.removeListener("updated", listener);
  },
  onCommand: (fn) => {
    const listener = (_: unknown, command: "stop" | "pause") => fn(command);
    ipcRenderer.on("command", listener);
    return () => ipcRenderer.removeListener("command", listener);
  },
};
contextBridge.exposeInMainWorld("cool", api);
