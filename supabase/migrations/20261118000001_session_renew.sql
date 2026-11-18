-- =====================================================================
-- 技高國文複習站｜登入自動續期（2026-11-18）
--   學生每次打開網站時，student_session 會順便簽發一張新的登入憑證（效期重新算 120 天），
--   前端收到後換掉舊的。只要 120 天內有回來過，同一個裝置就不必重新登入。
--   其餘規則不變：老師重設該生登入、學生或班級停用時，舊憑證一樣立刻失效。
--   只重新定義一個函式，不動任何資料；重複執行不會出錯。
-- =====================================================================

create or replace function public.student_session(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := private.student_from_token(p_token);
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_session');
  end if;
  return jsonb_build_object('ok', true, 'student', private.student_profile(v_id), 'token', private.issue_token(v_id));
end;
$$;

-- 檢查：應顯示「已啟用」
select case when pg_get_functiondef('public.student_session(text)'::regprocedure) like '%issue_token%'
            then '已啟用' else '未啟用' end as 登入自動續期;
