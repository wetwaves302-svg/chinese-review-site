// 選項換位：同一題每次作答的選項位置不同，避免學生記位置而不是讀選項。
// 資料庫裡的選項代號（原代號）不變，作答與判定都用原代號；畫面上依位置重新標成 (A)～(D)。
//   同一張卷內位置固定（重新整理不會變），不同卷、每次錯題重做都會換位置。
//   原圖印有 (A)～(D) 選項的圖片題（image_options 不是 false）、題幹或選項文字提到選項代號的題目不換位；
//   原圖只有題幹與表格／圖表的圖片題（image_options = false）改用文字選項，照常換位。

export const LETTERS = ['A', 'B', 'C', 'D'];

const LETTER_REF = /[(（][A-D][)）]/;

// 由種子字串產生固定的亂數序列
function randomFrom(seed) {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i += 1) h = Math.imul(h ^ seed.charCodeAt(i), 16777619);
  return () => {
    h = Math.imul(h ^ (h >>> 15), 2246822507);
    h = Math.imul(h ^ (h >>> 13), 3266489909);
    h ^= h >>> 16;
    return (h >>> 0) / 4294967296;
  };
}

// 圖內印有選項的圖片題
export const optionsInImage = (q) => Boolean(q.image) && q.image_options !== false;

export function canShuffle(q) {
  return !optionsInImage(q) && !LETTER_REF.test(q.stem) && !q.options.some((text) => LETTER_REF.test(text));
}

// 畫面由上到下各位置要放的原代號，例如 ['C','A','D','B']
export function optionOrder(q, seed) {
  if (!canShuffle(q)) return LETTERS;
  const random = randomFrom(seed);
  const order = [...LETTERS];
  for (let i = order.length - 1; i > 0; i -= 1) {
    const j = Math.floor(random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  return order;
}

// 原代號在畫面上顯示成哪個代號
export function shownLetter(order, letter) {
  const index = order.indexOf(letter);
  return index < 0 ? letter : LETTERS[index];
}

// 解析文字裡提到的選項代號（例如「說明見(B)」）一併換成畫面上的代號
export function remapLetters(order, text) {
  return text.replace(/([(（])([A-D])([)）])/g, (_, open, letter, close) => open + shownLetter(order, letter) + close);
}
