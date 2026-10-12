export type Status =
  | "recording"
  | "captured"
  | "processing"
  | "ready"
  | "paused"
  | "error"
  | "interrupted";
export interface Settings {
  provider?: "local" | "openai";
  transcriptionModel: string;
  summaryModel: string;
  language: string;
  glossary: string;
  cloudConsent: boolean;
}
export const DEFAULT_SETTINGS: Settings = {
  provider: "local",
  transcriptionModel: "gpt-4o-transcribe",
  summaryModel: "gpt-5.4",
  language: "ru",
  glossary: "",
  cloudConsent: false,
};
export interface Chunk {
  id: string;
  start: number;
  duration: number;
  samples: number;
  voiced: boolean;
  text?: string;
}
export interface Evidence {
  source: string;
  quote: string;
}
export interface Point {
  text: string;
  evidence: Evidence[];
}
export interface Action extends Point {
  owner: string;
  due: string;
}
export interface Topic extends Point {
  title: string;
}
export interface Brief {
  overview: string;
  topics: Topic[];
  decisions: Point[];
  actions: Action[];
  questions: Point[];
}
export interface TaskItem {
  id: string;
  text: string;
  owner: string;
  due: string;
  done: boolean;
  source?: string;
}
export interface Meeting {
  schema: 1;
  id: string;
  title: string;
  project: string;
  startedAt: string;
  duration: number;
  status: Status;
  chunks: Chunk[];
  notes: string;
  bookmarks: number[];
  tasks: TaskItem[];
  settings: Settings;
  brief?: Brief;
  error?: string;
  summaryModelUsed?: string;
  source: "microphone" | "microphone+system";
  capturePaused?: boolean;
}
export type MeetingInfo = Omit<
  Meeting,
  "chunks" | "brief" | "notes" | "bookmarks" | "settings"
> & { chunkCount: number; completedChunks: number };
export interface LocalModelState {
  ready: boolean;
  checking: boolean;
  downloading: boolean;
  active: string;
  downloaded: number;
  total: number;
  completed: number;
  error?: string;
}
export interface Snapshot {
  localModels: LocalModelState;
  meetings: MeetingInfo[];
  settings: Settings;
  hasKey: boolean;
  persistentKey: boolean;
  secureStorage: boolean;
  activeID: string | null;
  platform: string;
  version: string;
}
export interface RecordingOptions {
  title: string;
  project: string;
  systemAudio: boolean;
}
export interface Bridge {
  snapshot(): Promise<Snapshot>;
  meeting(id: string): Promise<Meeting>;
  start(options: RecordingOptions): Promise<Meeting>;
  append(id: string, samples: ArrayBuffer): Promise<void>;
  pauseCapture(id: string, paused: boolean): Promise<void>;
  stop(id: string): Promise<void>;
  mark(id: string): Promise<void>;
  queue(id: string, action: "resume" | "pause" | "summarize"): Promise<void>;
  saveMeeting(
    id: string,
    patch: {
      title?: string;
      project?: string;
      notes?: string;
      tasks?: TaskItem[];
    },
  ): Promise<void>;
  setTaskDone(id: string, taskID: string, done: boolean): Promise<void>;
  remove(id: string): Promise<void>;
  exportMarkdown(id: string): Promise<boolean>;
  saveSettings(settings: Settings): Promise<void>;
  saveKey(key: string, persist: boolean): Promise<void>;
  removeKey(): Promise<void>;
  models(): Promise<string[]>;
  downloadModels(): Promise<void>;
  cancelModels(): Promise<void>;
  compact(enabled: boolean): Promise<void>;
  onUpdate(fn: () => void): () => void;
  onCommand(fn: (command: "stop" | "pause") => void): () => void;
}
declare global {
  interface Window {
    cool: Bridge;
  }
}
