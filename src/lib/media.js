// 雲端硬碟分享連結，例如 https://drive.google.com/file/d/<ID>/view?usp=sharing
export function driveFileId(url) {
  const match = /^https:\/\/drive\.google\.com\/(?:file\/d\/|open\?id=)([\w-]{10,})/.exec(url.trim());
  return match?.[1] ?? null;
}

export function drivePreviewUrl(url) {
  const id = driveFileId(url);
  return id ? `https://drive.google.com/file/d/${id}/preview` : null;
}

// Loom 分享連結，例如 https://www.loom.com/share/<ID>
export function loomVideoId(url) {
  const match = /^https:\/\/(?:www\.)?loom\.com\/(?:share|embed)\/([0-9a-f]{32})/.exec(url.trim());
  return match?.[1] ?? null;
}

// YouTube 連結，例如 https://www.youtube.com/watch?v=<ID>、https://youtu.be/<ID>
export function youtubeVideoId(url) {
  const match = /^https:\/\/(?:(?:www\.|m\.)?youtube\.com\/(?:watch\?(?:.*&)?v=|embed\/|shorts\/|live\/)|youtu\.be\/)([\w-]{11})(?![\w-])/.exec(url.trim());
  return match?.[1] ?? null;
}

// 影片頁內嵌網址；YouTube 使用不設追蹤 Cookie 的網域
export function videoEmbedUrl(url) {
  const loom = loomVideoId(url);
  if (loom) return `https://www.loom.com/embed/${loom}`;
  const youtube = youtubeVideoId(url);
  if (youtube) return `https://www.youtube-nocookie.com/embed/${youtube}`;
  return null;
}

// 影片長度：661 → 11:01、3725 → 1:02:05
export function formatDuration(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = String(seconds % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

// 後台輸入的長度：「11:01」「1:02:05」或純秒數；空白回傳 null，格式錯誤回傳 undefined
export function parseDuration(text) {
  const value = text.trim();
  if (!value) return null;
  if (!/^\d+(:\d{1,2}){0,2}$/.test(value)) return undefined;
  const seconds = value.split(':').reduce((total, part) => total * 60 + Number(part), 0);
  return seconds > 0 ? seconds : undefined;
}
