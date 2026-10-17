/* Shared helpers: Supabase client, auth guard, header, small UI utils */
const sb = window.supabase.createClient(window.APP_CONFIG.SUPABASE_URL, window.APP_CONFIG.SUPABASE_ANON_KEY);
const ROOT = document.body.dataset.root || '';          // '' for root pages, '../' for subfolders

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const qs = k => new URLSearchParams(location.search).get(k);
const fmtSize = b => b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB';
const fmtDate = d => new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
const fmtNum = n => Number(n || 0).toLocaleString('en-US');
const iconUrl = p => sb.storage.from('icons').getPublicUrl(p).data.publicUrl;
const fileExt = f => (f.name.split('.').pop() || '').toLowerCase();

function toast(msg, type = 'ok') {
  let box = document.getElementById('toast');
  if (!box) { box = document.createElement('div'); box.id = 'toast'; document.body.appendChild(box); }
  const t = document.createElement('div'); t.className = type; t.textContent = msg; box.appendChild(t);
  setTimeout(() => t.remove(), 3500);
}

function flash(el, msg, type = 'err') { el.innerHTML = msg ? `<div class="flash ${type}">${esc(msg)}</div>` : ''; }

// APK files are ZIP archives -> must start with "PK\x03\x04"
async function looksLikeApk(file) {
  if (fileExt(file) !== 'apk') return false;
  const b = new Uint8Array(await file.slice(0, 4).arrayBuffer());
  return b[0] === 0x50 && b[1] === 0x4B && b[2] === 0x03 && b[3] === 0x04;
}

/* ---------- auth ---------- */
async function getProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data } = await sb.from('profiles').select('id,email,full_name,role,is_banned,dev_approved').eq('id', session.user.id).single();
  if (!data) return null;
  if (data.is_banned) { await sb.auth.signOut(); return null; }
  return data;
}

async function requireRole(roles) {
  const p = await getProfile();
  if (!p || !roles.includes(p.role)) {
    location.href = ROOT + 'login.html?next=' + encodeURIComponent(location.pathname + location.search);
    throw new Error('redirecting to login');
  }
  return p;
}

/* ---------- sign-in helpers: email + password, email verified once with a code ---------- */
const validEmail = e => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
const AUTH = {
  verify: (email, code, type) => sb.auth.verifyOtp({ email, token: code, type }),   // type: 'signup' | 'recovery'
  resend: email => sb.auth.resend({ type: 'signup', email }),
  friendly(err) {
    const m = (err && err.message) || 'Something went wrong';
    if (/invalid login credentials/i.test(m)) return 'Wrong email or password.';
    if (/already (been )?registered/i.test(m)) return 'This email is already registered. Please sign in.';
    if (/rate|seconds|too many|limit/i.test(m)) return 'Too many requests. Please wait a minute and try again.';
    if (/not authorized|not allowed to send|error sending|smtp/i.test(m)) return 'Email could not be sent. Custom SMTP must be set up in Supabase (see README).';
    if (/expired|invalid/i.test(m)) return 'Invalid or expired code. Try again or request a new one.';
    return m;
  }
};
/* ---------- one-box-per-digit code input (works with typing, paste and SMS autofill) ---------- */
function mountCodeInput(el, onComplete) {
  const length = Number(window.APP_CONFIG.OTP_LENGTH) || 8;          // must match Supabase "Email OTP Length"
  el.className = 'code-boxes'; el.innerHTML = '';
  const boxes = Array.from({ length }, (_, i) => {
    const b = document.createElement('input');
    b.type = 'text'; b.inputMode = 'numeric'; b.autocomplete = i === 0 ? 'one-time-code' : 'off';
    b.setAttribute('aria-label', 'Digit ' + (i + 1)); b.className = 'code-box';
    el.appendChild(b); return b;
  });
  const value = () => boxes.map(b => b.value).join('');
  const fill = (from, digits) => {
    digits.split('').forEach((d, k) => { if (boxes[from + k]) boxes[from + k].value = d; });
    const next = Math.min(from + digits.length, length - 1); boxes[next].focus();
    if (value().length === length && onComplete) onComplete(value());
  };
  boxes.forEach((b, i) => {
    b.addEventListener('input', () => {
      const d = b.value.replace(/\D/g, ''); b.value = '';
      if (d) fill(i, d);
    });
    b.addEventListener('keydown', e => {
      if (e.key === 'Backspace' && !b.value && i > 0) { boxes[i - 1].value = ''; boxes[i - 1].focus(); e.preventDefault(); }
      else if (e.key === 'ArrowLeft' && i > 0) boxes[i - 1].focus();
      else if (e.key === 'ArrowRight' && i < length - 1) boxes[i + 1].focus();
      else if (e.key === 'Enter' && onComplete) onComplete(value());
    });
    b.addEventListener('paste', e => {
      e.preventDefault(); fill(i, (e.clipboardData.getData('text') || '').replace(/\D/g, '').slice(0, length - i));
    });
    b.addEventListener('focus', () => b.select());
  });
  return { value, focus: () => boxes[0].focus(), clear: () => { boxes.forEach(b => b.value = ''); boxes[0].focus(); } };
}

// "Resend in 42s" countdown on a link element
function cooldown(el, seconds = 60) {
  el.dataset.locked = '1';
  const t = setInterval(() => {
    seconds--;
    if (seconds <= 0) { clearInterval(t); el.dataset.locked = ''; el.textContent = 'Resend code'; }
    else el.textContent = 'Resend in ' + seconds + 's';
  }, 1000);
  el.textContent = 'Resend in ' + seconds + 's';
}
const safeNext = n => (n && n.startsWith('/') && !n.startsWith('//')) ? n : null;

function homeFor(role) {
  if (role === 'admin') return ROOT + 'admin/dashboard.html';
  if (role === 'developer') return ROOT + 'developer/dashboard.html';
  return ROOT + 'index.html';
}

async function logout() { await sb.auth.signOut(); location.href = ROOT + 'index.html'; }

/* ---------- favicon (same logo file) ---------- */
(() => { const l = document.createElement('link'); l.rel = 'icon'; l.href = ROOT + 'assets/logo.png'; document.head.appendChild(l); })();

/* ---------- header ---------- */
function renderHeader(profile, active = '') {
  const L = (href, label, key) => `<a href="${ROOT}${href}" class="${active === key ? 'active' : ''}">${label}</a>`;
  let nav = '';
  if (!profile) nav = L('login.html', 'Sign in', 'login') + `<a class="btn small" href="${ROOT}register.html">Register</a>`;
  else {
    if (profile.role === 'admin')
      nav = L('admin/dashboard.html', 'Dashboard', 'dash') + L('admin/approvals.html', 'Approvals', 'approvals') +
            L('admin/apps.html', 'Apps', 'apps') + L('admin/users.html', 'Users', 'users') + L('admin/invites.html', 'Invites', 'invites');
    else if (profile.role === 'developer')
      nav = L('developer/dashboard.html', 'Dashboard', 'dash') + L('developer/upload.html', 'Upload app', 'upload');
    nav += L('index.html', 'Store', 'store') +
           `<span class="who">${esc(profile.full_name || profile.email)}</span><button onclick="logout()">Sign out</button>`;
  }
  document.getElementById('header').innerHTML = `
    <div class="topbar"><div class="topbar-in">
      <a class="brand" href="${ROOT}index.html" aria-label="Appex">
        <img class="brand-img" src="${ROOT}assets/logo.png" alt="Appex" onerror="this.style.display='none';this.nextElementSibling.style.display='grid'">
        <span class="brand-logo" style="display:none"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.86l12-7.5a1 1 0 0 0 0-1.72l-12-7.5A1 1 0 0 0 7 4.5z"/></svg></span>
        ${window.APP_CONFIG.LOGO_ONLY ? '' : '<span class="brand-name">Appex</span>'}</a>
      <form class="search" action="${ROOT}index.html" method="get">
        <input name="q" type="search" placeholder="Search apps" value="${esc(qs('q') || '')}"></form>
      <nav class="nav">${nav}</nav>
    </div></div>`;
}

/* ---------- shared view helpers ---------- */
const ratingText = r => r ? `${r} <span class="star">★</span>` : 'New';

function appCard(a) {
  return `<a class="card" href="${ROOT}app.html?id=${a.id}">
    <img class="icon" loading="lazy" src="${iconUrl(a.icon_path)}" alt="">
    <div class="card-name">${esc(a.name)}</div>
    <div class="card-sub">${esc(a.developer_name)}</div>
    <div class="card-meta">${ratingText(a.avg_rating)} · ${esc(a.category_name)}</div></a>`;
}

const badge = (cls, text) => `<span class="badge ${cls}">${esc(text)}</span>`;
