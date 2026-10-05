-- =====================================================================
-- 技高國文複習站｜收回教師帳號用不到的資料表權限
-- 國立花蓮高工｜貞伊老師製作
--
--   2026-10-05：authenticated 角色在各資料表上帶有建立時預設給的
--   TRUNCATE（清空整張表）、REFERENCES、TRIGGER 權限，網站與後台都用不到。
--   TRUNCATE 不受 RLS 政策限制，因此一併收回，只保留讀寫資料列所需的權限。
--   同時再確認一次：anon（未登入，含學生）不能直接存取任何資料表，學生一律經由安全函式。
--   重複執行不會出錯。
-- =====================================================================

revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger on tables from authenticated;

revoke all on all tables in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;

-- 檢查一：應為 0（authenticated 已沒有這三項權限）
select count(*) as authenticated多餘權限數
from information_schema.role_table_grants
where table_schema = 'public' and grantee = 'authenticated'
  and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER');

-- 檢查二：應為 0（anon 沒有任何資料表權限）
select count(*) as anon資料表權限數
from information_schema.role_table_grants
where table_schema = 'public' and grantee = 'anon';

-- 檢查三：作答紀錄仍可由教師讀取（應列出 SELECT）
select table_name as 資料表, string_agg(privilege_type, '、' order by privilege_type) as authenticated的權限
from information_schema.role_table_grants
where table_schema = 'public' and grantee = 'authenticated'
  and table_name in ('paper_sessions', 'session_answers', 'courses', 'students')
group by table_name order by table_name;
