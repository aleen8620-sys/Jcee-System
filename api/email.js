// api/email.js — إرسال الدعوات والتذكيرات عبر Resend
//
// الأمان: الطلب لا يُقبل إلا بتوكن موظّف مسجّل دخوله.
//   • القراءة (mail_queue) تتم بتوكن الموظّف نفسه — فإن لم يكن موظفاً رفضتها القاعدة.
//   • الكتابة في السجل (record_mail) بمفتاح الخدمة، وهي دالة بلا منح لأحد.
//
// المتغيّرات المطلوبة في Vercel:
//   SUPABASE_URL · SUPABASE_SERVICE_KEY · RESEND_API_KEY · MAIL_FROM · PUBLIC_URL

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method' });

  const SUPA = process.env.SUPABASE_URL;
  const SKEY = process.env.SUPABASE_SERVICE_KEY;
  const RKEY = process.env.RESEND_API_KEY;
  const FROM = process.env.MAIL_FROM || 'onboarding@resend.dev';
  const BASE = process.env.PUBLIC_URL || '';

  if (!SUPA || !SKEY || !RKEY) return res.status(500).json({ error: 'missing_env' });

  // توكن الموظّف كما أرسله المتصفح
  const auth = req.headers.authorization || '';
  if (!/^Bearer\s+\S+/i.test(auth)) return res.status(401).json({ error: 'no_token' });

  const body    = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const partId  = body.part_id;
  const kind    = ['invite', 'remind'].includes(body.kind) ? body.kind : 'invite';
  const only    = Array.isArray(body.invite_ids) ? body.invite_ids : null;

  if (!partId || !/^[0-9a-f-]{36}$/i.test(partId)) {
    return res.status(400).json({ error: 'bad_part' });
  }

  try {
    // 1) اجلب الطابور بتوكن الموظّف — القاعدة هي التي تتحقّق من صلاحيته
    const qr = await fetch(`${SUPA}/rest/v1/rpc/mail_queue`, {
      method: 'POST',
      headers: {
        apikey: SKEY,                 // مفتاح المشروع العام مطلوب دائماً
        Authorization: auth,          // لكن الهوية هي هوية الموظّف
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ p_part: partId, p_kind: kind })
    });

    const q = await qr.json();
    if (!q || q.ok !== true) {
      return res.status(403).json({ error: q?.error || 'forbidden' });
    }

    let rows = q.rows || [];
    if (only) rows = rows.filter(r => only.includes(r.invite_id));
    if (!rows.length) return res.status(200).json({ ok: true, sent: 0, failed: 0, note: 'empty' });

    const when = q.starts
      ? new Date(q.starts).toLocaleString('ar-SA', { dateStyle: 'full', timeStyle: 'short' })
      : '';

    const fill = (t, r) => String(t || '')
      .replace(/\{\{name\}\}/g,  [r.title_ar, r.full_name].filter(Boolean).join(' '))
      .replace(/\{\{part\}\}/g,  q.part  || '')
      .replace(/\{\{event\}\}/g, q.event || '')
      .replace(/\{\{venue\}\}/g, q.venue || '')
      .replace(/\{\{when\}\}/g,  when)
      .replace(/\{\{seat\}\}/g,  r.seat ? `مقعدك: ${r.seat}` : '')
      .replace(/\{\{link\}\}/g,  `${BASE}/invite.html?t=${r.token}`);

    const esc = s => String(s == null ? '' : s)
      .replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

    let sent = 0, failed = 0;
    const errors = [];

    for (const r of rows) {
      const subject = fill(q.tpl?.subject_ar, r) || 'دعوة';
      const text    = fill(q.tpl?.body_ar, r);
      const html =
        `<div dir="rtl" style="font-family:system-ui,Tahoma,sans-serif;font-size:15px;` +
        `line-height:1.9;color:#0a2c47;white-space:pre-wrap">${esc(text)}</div>`;

      let ok = false, err = null;
      try {
        const sr = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${RKEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: `${q.from_name || 'غرفة جدة'} <${FROM}>`,
            to: [r.email], subject, text, html
          })
        });
        if (sr.ok) ok = true;
        else err = (await sr.text()).slice(0, 300);
      } catch (e) {
        err = String(e).slice(0, 300);
      }

      if (ok) sent++; else { failed++; errors.push({ to: r.email, err }); }

      // سجّل النتيجة بمفتاح الخدمة — record_mail بلا منح لأحد غيره
      await fetch(`${SUPA}/rest/v1/rpc/record_mail`, {
        method: 'POST',
        headers: { apikey: SKEY, Authorization: `Bearer ${SKEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          p_event:   q.event_id,
          p_to:      r.email,
          p_subject: subject,
          p_kind:    kind,
          p_ref:     r.invite_id,
          p_status:  ok ? 'sent' : 'failed',
          p_error:   err
        })
      }).catch(() => {});
    }

    return res.status(200).json({ ok: true, sent, failed, errors: errors.slice(0, 5) });

  } catch (e) {
    console.error('email_error', e);
    return res.status(500).json({ error: 'server_error' });
  }
}
