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

export function loomEmbedUrl(url) {
  const id = loomVideoId(url);
  return id ? `https://www.loom.com/embed/${id}` : null;
}
