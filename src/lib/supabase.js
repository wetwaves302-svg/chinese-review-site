import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) {
  throw new Error('缺少 VITE_SUPABASE_URL 或 VITE_SUPABASE_PUBLISHABLE_KEY');
}

export const supabase = createClient(url, key);

// 呼叫資料庫函式；連線或權限錯誤一律丟出，由呼叫端決定如何提示
export async function rpc(name, params = {}) {
  const { data, error } = await supabase.rpc(name, params);
  if (error) throw error;
  return data;
}
