# Appex — Supabase + HTML/CSS/JS

Play Store-এর মতো একটি APK marketplace। তিনটি actor: **User**, **Developer**, **Admin**।

## ফোল্ডার স্ট্রাকচার

```
apk-portal/
├── index.html              Store হোম (user dashboard): search, category, top downloads
├── app.html                App details, download, rating/review
├── login.html / register.html   Email + password (email একবার verify)
├── developer/
│   ├── dashboard.html      launched apps, total downloads, overall rating, most downloaded app
│   ├── upload.html         নতুন app + APK upload
│   └── app.html            নিজের app-এর versions + নতুন version upload
├── admin/
│   ├── dashboard.html      total apps, downloads, pending approvals, developers, users
│   ├── approvals.html      APK ডাউনলোড করে test → approve / reject
│   ├── apps.html           সব app, suspend / restore
│   └── users.html          user/developer list, ban / unban
├── js/config.js            Supabase URL + anon key (এখানে বসাবে)
├── js/core.js              Supabase client, auth guard, header, helper
├── css/style.css           Play Store-style light theme
└── sql/                    01 → 05 ক্রমে run করতে হবে
```

## Setup

1. https://supabase.com এ project বানাও।
2. **SQL Editor**-এ `sql/01_schema.sql` → `05_seed.sql` **ক্রমানুযায়ী** run করো।
   - আগে থেকেই 01–05 চালানো থাকলে শুধু `06_developer_approval_migration.sql` চালাও (নতুন install-এ 06 লাগবে না)।
3. **Project Settings → API** থেকে Project URL ও publishable key `js/config.js`-এ বসাও।
4. Email পাঠানোর জন্য SMTP সেটআপ করো (নিচে দেখো)।
5. VS Code *Live Server* দিয়ে লোকালে চালাও, অথবা Vercel-এ deploy করো।

## Login: email + password (email শুধু একবার verify)

- **Register:** নাম, email, password (কমপক্ষে ৮ অক্ষর) দিলে email-এ একটা ৬ সংখ্যার **কোড** যায়। কোডটা একবার দিলেই email verified। 
- **এরপর সবসময়** শুধু email + password দিয়ে login, আর কোড লাগে না।
- **Password ভুলে গেলে:** Login পেজে *Forgot password?* → email-এ কোড → নতুন password।
- Password Supabase-এ plain text-এ থাকে না, শুধু hash থাকে।

### Email পাঠানোর জন্য custom SMTP (একবারের সেটআপ)

Supabase-এর নিজস্ব email সার্ভিস শুধু **তোমার team-এর সদস্যদের** email-এ পাঠায় এবং ঘণ্টায় মাত্র ২টা। তাই বাইরের কারো কাছে verification mail যায় না। সমাধান: custom SMTP।

1. Supabase → **Authentication → Emails → SMTP Settings** → *Enable custom SMTP*।
   - **Gmail:** Host `smtp.gmail.com`, Port `465`, Username = পুরো Gmail, Password = **App password** (Google Account → Security → 2-Step Verification চালু করে `myaccount.google.com/apppasswords`), Sender email = ওই Gmail।
   - **Brevo:** Host `smtp-relay.brevo.com`, Port `587`, Password = SMTP key।
2. **Authentication → Emails → Templates**-এ **Confirm signup** এবং **Reset Password** — দুটোর body-তে link-এর বদলে এটা বসাও:
   ```html
   <h2>Your Appex code</h2>
   <p>Enter this code to continue:</p>
   <p style="font-size:28px;letter-spacing:6px"><b>{{ .Token }}</b></p>
   <p>If you did not request it, ignore this email.</p>
   ```
3. **Authentication → Sign In / Providers → Email**-এ *Confirm email* **চালু** রাখো।

> SMTP ঠিক না হওয়া পর্যন্ত চাইলে *Confirm email* বন্ধ রাখো। তখন register করলেই সরাসরি ঢোকা যায় (কোড লাগে না) — কোডে কিছু বদলাতে হয় না, সাইট নিজেই বুঝে নেয়। তবে এই অবস্থায় email যাচাই হয় না, তাই লাইভে দেওয়ার আগে চালু করো।

## Admin বানানো

SQL Editor-এ নিজের email allow-list-এ বসাও (register করার **আগে**):

```sql
insert into public.admin_emails (email) values ('your-admin@email.com');
```

তারপর সাইটে ওই email + password দিয়ে Register করে কোড verify করলেই তুমি admin dashboard-এ ঢুকবে। (email verify না হওয়া পর্যন্ত admin হয় না, তাই অন্য কেউ তোমার email লিখে admin হতে পারবে না।)

account আগেই থাকলে অথবা *Confirm email* বন্ধ থাকলে SQL দিয়ে:
```sql
update public.profiles set role = 'admin' where email = 'your-admin@email.com';
```
এরপর Sign out করে আবার Sign in করো।

## Developer approval

নতুন Developer account আগে **Pending** থাকে; **Admin → Users → Approve** না করা পর্যন্ত app/APK upload করতে পারে না (database ও storage policy দিয়েই আটকানো)। Admin চাইলে পরে **Revoke** করতে পারে।

## Vercel-এ deploy

- সাইটটা static: Framework Preset **Other**, build command ও output directory ফাঁকা।
- `js/config.js` অবশ্যই repo-তে commit থাকতে হবে (না থাকলে সাইট Supabase-এ কানেক্ট হবে না)।
- Supabase → **Authentication → URL Configuration** → *Site URL*-এ তোমার Vercel লিংক দাও। (কোড দিয়ে verify হয়, তবু রাখা ভালো।)

## কীভাবে কাজ করে

- **Upload:** Developer APK → private bucket `apks/<uid>/<uuid>.apk`, icon → public bucket `icons/`। DB-তে `apps` + `app_versions` (status = `pending`)।
- **Approval:** Admin APK ডাউনলোড করে test করে approve/reject করে। Approve হলে app store-এ দেখা যায়।
- **Download:** `record_download()` function লগইন চেক করে, download গুনে, তারপর ৬০ সেকেন্ডের signed URL দেওয়া হয়। এক user এক version একবারই গোনা হয়।
- **Review:** শুধু যে user app ডাউনলোড করেছে সে-ই rating/review দিতে পারে।
- **নিরাপত্তা:** সব নিয়ম Postgres RLS + column grant দিয়ে database-এই বাধ্য করা। frontend বদলালেও role/status/ban পাল্টানো যায় না।

## সীমাবদ্ধতা

- Supabase **Free plan-এ প্রতি ফাইল max 50 MB**। বড় APK হলে Pro plan লাগবে (bucket limit-ও বাড়াতে হবে)।
- Free project ৭ দিন নিষ্ক্রিয় থাকলে pause হয়ে যায়।
- APK-এর ভেতরের package name/version অটো পড়া হয় না; developer নিজে লেখে।
- Malware scan নেই; admin-এর manual review-ই একমাত্র যাচাই।
