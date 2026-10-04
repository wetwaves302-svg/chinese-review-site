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

// ---------------------------------------------------------------------
// 自動偵測影片長度（教師後台用）：成功回傳秒數，偵測不到回傳 null
//   Loom：公開的 oEmbed 資料內含 duration
//   YouTube：oEmbed 不含長度，改用官方播放器 API 載入影片後讀取
// ---------------------------------------------------------------------

async function loomDuration(id) {
  const response = await fetch(`https://www.loom.com/v1/oembed?url=${encodeURIComponent(`https://www.loom.com/share/${id}`)}`);
  if (!response.ok) return null;
  const seconds = Math.round(Number((await response.json()).duration));
  return seconds > 0 ? seconds : null;
}

let youtubeApi = null;

function loadYoutubeApi() {
  youtubeApi ??= new Promise((resolve, reject) => {
    if (window.YT?.Player) return resolve(window.YT);
    const previous = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => { previous?.(); resolve(window.YT); };
    const script = document.createElement('script');
    script.src = 'https://www.youtube.com/iframe_api';
    script.onerror = () => { youtubeApi = null; reject(new Error('youtube api')); };
    document.head.append(script);
  });
  return youtubeApi;
}

async function youtubeDuration(id) {
  const YT = await loadYoutubeApi();
  const holder = document.createElement('div');
  holder.style.cssText = 'position:absolute;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none';
  holder.append(document.createElement('div'));
  document.body.append(holder);
  try {
    return await new Promise((resolve) => {
      let timer;
      const finish = (seconds) => { clearInterval(timer); resolve(seconds > 0 ? Math.round(seconds) : null); };
      const player = new YT.Player(holder.firstChild, {
        videoId: id,
        width: 200,
        height: 113,
        events: {
          onReady: () => {
            // 影片資料載入後才讀得到長度，最多等 8 秒
            let tries = 0;
            timer = setInterval(() => {
              const seconds = player.getDuration?.() ?? 0;
              if (seconds > 0 || ++tries >= 32) finish(seconds);
            }, 250);
          },
          onError: () => finish(0),
        },
      });
      setTimeout(() => finish(0), 12000);
    });
  } finally {
    holder.remove();
  }
}

export async function detectDuration(url) {
  try {
    const loom = loomVideoId(url);
    if (loom) return await loomDuration(loom);
    const youtube = youtubeVideoId(url);
    if (youtube) return await youtubeDuration(youtube);
  } catch {
    // 偵測失敗時由老師手動填寫
  }
  return null;
}
