-- =====================================================================
-- 技高國文複習站｜補上教師讀取作答紀錄與題組、題圖的資料表權限
-- 國立花蓮高工｜貞伊老師製作
--
--   2026-10-05：教師後台「成績統計」讀取 paper_sessions 時出現
--   「permission denied for table paper_sessions」。
--   原因：第一步之後新增的資料表沒有自動取得 authenticated 角色的資料表權限，
--   只設了 RLS 政策；RLS 政策要在資料表權限之上才會生效。
--   這裡明確補上權限。實際能看到哪些列仍由既有的 RLS 政策（public.is_teacher()）決定，
--   非教師帳號與學生（anon）一樣看不到任何資料。重複執行不會出錯。
-- =====================================================================

-- 教師唯讀：每張卷與卷內作答
grant select on public.paper_sessions  to authenticated;
grant select on public.session_answers to authenticated;

-- 教師可管理：題組文章與題目原圖（對應 teacher_all 政策）
grant select, insert, update, delete on public.question_groups to authenticated;
grant select, insert, update, delete on public.question_images to authenticated;

-- 之後由 postgres 在 public 新增的資料表，自動給 authenticated 資料表權限（仍須另設 RLS 政策才看得到資料）
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to authenticated;

-- 檢查：四個資料表都應該列出 authenticated 的 SELECT
select table_name as 資料表, string_agg(privilege_type, '、' order by privilege_type) as authenticated的權限
from information_schema.role_table_grants
where table_schema = 'public' and grantee = 'authenticated'
  and table_name in ('paper_sessions', 'session_answers', 'question_groups', 'question_images')
group by table_name order by table_name;
