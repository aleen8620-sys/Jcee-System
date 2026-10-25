// api/return.js — يتحقّق من الدفع ويصدر الرمز
//
// يُستدعى مرتين عادةً:
//   • success_url  — المتصفح يعود إليه بعد الدفع (GET)  → يحوّل الزائر للصفحة
//   • callback_url — مُيسِّر يُشعره من خادمه (POST)      → يضمن التأكيد ولو أغلق الزائر المتصفح
//
// القاعدة الأهم: لا نصدّق أبداً ما يصل في الرابط.
// نسأل مُيسِّر مباشرة عن حالة الفاتورة بمفتاحنا السرّي، ثم نقارن المبلغ.

export default async function handler(req, res) {
  const SUPA = process.env.SUPABASE_URL;
  const SKEY = process.env.SUPABASE_SERVICE_KEY;
  const MKEY = process.env.MOYASAR_SECRET_KEY;

  const orderId = req.query.order;
  const slug    = req.query.slug || '';
  const isPost  = req.method === 'POST';

  const home = `/?e=${encodeURIComponent(slug)}&order=${encodeURIComponent(orderId || '')}`;

  if (!SUPA || !SKEY || !MKEY) {
    return isPost ? res.status(500).json({ error: 'missing_env' }) : res.redirect(302, home);
  }
  if (!orderId || !/^[0-9a-f-]{36}$/i.test(orderId)) {
    return isPost ? res.status(400).json({ error: 'bad_order' }) : res.redirect(302, '/');
  }

  try {
    // 1) هات الطلب من قاعدتنا
    const q = await fetch(
      `${SUPA}/rest/v1/orders?id=eq.${orderId}&select=id,amount,status`,
      { headers: { apikey: SKEY, Authorization: `Bearer ${SKEY}` } }
    );
    const order = (await q.json())?.[0];
    if (!order) {
      return isPost ? res.status(404).json({ error: 'no_order' }) : res.redirect(302, home);
    }

    // مؤكَّد سابقاً — لا تعمل شيئاً
    if (order.status === 'paid' || order.status === 'free') {
      return isPost ? res.status(200).json({ ok: true, already: true })
                    : res.redirect(302, home);
    }

    // 2) معرّف الفاتورة أو الدفعة كما أرسله مُيسِّر
    const body = isPost ? (req.body || {}) : {};
    const refId = body.id || req.query.id || body?.invoice?.id || null;

    let paid = false, ref = refId, reason = null;

    if (refId) {
      const auth = Buffer.from(`${MKEY}:`).toString('base64');

      // جرّب الفاتورة أولاً ثم الدفعة
      for (const path of ['invoices', 'payments']) {
        const r = await fetch(`https://api.moyasar.com/v1/${path}/${refId}`, {
          headers: { Authorization: `Basic ${auth}` }
        });
        if (!r.ok) continue;

        const d = await r.json();
        const amount = d.amount;
        const status = d.status;

        // تحقّق مزدوج: الحالة مدفوعة **والمبلغ مطابق لطلبنا**
        if (status === 'paid' && Number(amount) === Number(order.amount)) {
          paid = true;
        } else {
          reason = `status=${status} amount=${amount}`;
        }
        break;
      }
    } else {
      reason = 'no_reference';
    }

    // 3) بلّغ قاعدة البيانات — confirm_payment لا ينفّذها إلا service_role
    const c = await fetch(`${SUPA}/rest/v1/rpc/confirm_payment`, {
      method: 'POST',
      headers: {
        apikey: SKEY,
        Authorization: `Bearer ${SKEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        p_order_id: orderId,
        p_ref:      ref || 'unknown',
        p_status:   paid ? 'paid' : 'failed',
        p_reason:   paid ? null : reason
      })
    });
    const out = await c.json();

    if (isPost) return res.status(200).json({ ok: true, paid, result: out });
    return res.redirect(302, home);

  } catch (e) {
    console.error('return_error', e);
    return isPost ? res.status(500).json({ error: 'server_error' })
                  : res.redirect(302, home);
  }
}
