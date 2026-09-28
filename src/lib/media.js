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
