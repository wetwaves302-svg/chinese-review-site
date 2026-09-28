# 技高國文複習站｜第一步建置說明

國立花蓮高工｜貞伊老師製作

本步驟完成資料庫結構、資料列安全（RLS）、學生與教師的登入流程，以及備份與健康檢查兩套排程。完成後資料庫即可運作，前端介面從第二步開始製作。

## 檔案說明

`supabase/migrations/20260927000001_init.sql` 是資料庫結構與登入函式，可放進公開儲存庫。
`supabase/seed/seed_115_roster.sql` 是三班名冊與初始碼雜湊，含課程通行碼，只在 SQL Editor 執行，已列入 `.gitignore`，不得提交。
`review-site-ops/` 是另一個私人儲存庫的內容，放每日備份與健康檢查兩個排程。

## 一、建立 Supabase 專案

1. 以 GitHub 帳號登入 supabase.com，建立新專案，區域選 Northeast Asia (Tokyo)，離花蓮最近。
2. 專案建立時設定的資料庫密碼請存進密碼管理工具，之後備份排程會用到。

## 二、驗證設定

到 Authentication 的設定頁：

1. 關閉開放註冊（Allow new users to sign up），教師帳號一律由您在後台手動建立，其他人無法自行註冊。
2. 匿名登入（Anonymous sign-ins）保持關閉，本站學生登入不使用 Supabase Auth。
3. Email 登入方式保持開啟，供教師使用。

## 三、建立資料庫

1. 開啟 SQL Editor，貼上 `20260927000001_init.sql` 全文執行。
2. 再貼上 `seed_115_roster.sql` 全文執行，最後的檢查結果應為電機二乙 21 人、電機三乙 28 人、電子三乙 17 人。

## 四、建立教師帳號

1. 到 Authentication 的使用者頁，新增使用者，填入您的信箱與密碼，勾選自動確認（Auto Confirm）。
2. 回到 SQL Editor 執行下列語句，把信箱換成剛才建立的信箱：

```sql
insert into public.teachers (user_id, email, name)
select id, email, '柯貞伊' from auth.users where email = '您的信箱';
```

## 五、自我檢查

在 SQL Editor 執行，確認登入流程運作正常：

```sql
-- 通行碼錯誤應回傳 bad_passcode；正確應回傳三個班級
select public.list_classes('0000');
select public.list_classes('1234');

-- 備份與登入憑證所在的 private schema 不應出現在 API 公開 schema 清單中
select nspname from pg_namespace where nspname = 'private';
```

學生端函式的完整行為（錯誤計數、鎖定、初始碼換 PIN、token 失效）已在本機以 anon 身分逐項測試通過，前端完成後再以實機驗證一次。

## 六、記下前端需要的兩個值

到專案設定的 API 頁，記下 Project URL 與 Publishable key（若專案只提供舊式 anon key 亦可），第二步製作前端時會用到。這兩個值本來就設計成可以公開，資料的安全由資料庫規則把關。

## 七、備份與健康檢查（私人儲存庫）

1. 在 GitHub 建立一個**私人**儲存庫，例如 `review-site-ops`，把 `review-site-ops/` 內的檔案放進去。
2. 到該儲存庫的 Settings → Secrets and variables → Actions，新增三個 Repository secrets：

| 名稱 | 內容 |
|---|---|
| `SUPABASE_DB_URL` | 專案頁「Connect」中的 **Session pooler** 連線字串，把 `[YOUR-PASSWORD]` 換成資料庫密碼 |
| `SUPABASE_URL` | Project URL |
| `SUPABASE_PUBLISHABLE_KEY` | Publishable key（或舊式 anon key） |

   連線字串務必選 Session pooler，直接連線（Direct connection）只支援 IPv6，GitHub 的執行環境連不上。
3. 到 Actions 頁，分別手動執行一次「資料庫每日備份」與「服務健康檢查」，兩者都顯示綠色勾號，且儲存庫出現 `backups/` 資料夾，即設定完成。

## 八、關於休眠與還原

每日備份與健康檢查是兩件分開的事。備份的目的是資料可還原，健康檢查的目的是及早發現服務異常，兩者都會對資料庫發出真實查詢，但 Supabase 免費方案是否因閒置而暫停專案，由 Supabase 的政策判定，這兩個排程都不能保證專案永不暫停。

健康檢查失敗時，GitHub 會寄信通知儲存庫擁有者；收到通知請登入 Supabase 查看專案狀態，若顯示已暫停，在專案頁按下恢復即可；暫停後可恢復的期限與細節以 Supabase 當時的說明為準，這也是每日備份必須獨立存在的原因。若真的發生資料損毀，依 `review-site-ops/README.md` 的步驟從備份還原。
