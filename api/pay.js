// api/pay.js — ينشئ فاتورة مُيسِّر لطلب موجود
//
// لا يثق هذا الملف بأي مبلغ قادم من المتصفح.
// يقرأ الطلب من قاعدة البيانات ويأخذ المبلغ منها وحدها.
//
// متغيرات البيئة المطلوبة في Vercel:
//   SUPABASE_URL          رابط مشروعك
//   SUPABASE_SERVICE_KEY  مفتاح service_role  ← سرّي
//   MOYASAR_SECRET_KEY    مفتاح sk_test_ أو sk_live_  ← سرّي

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const SUPA   = process.env.SUPABASE_URL;
  const SKEY   = process.env.SUPABASE_SERVICE_KEY;
  const MKEY   = process.env.MOYASAR_SECRET_KEY;

  if (!SUPA || !SKEY || !MKEY) {
    return res.status(500).json({ error: 'missing_env' });
  }

  const { order_id, slug } = req.body || {};
  if (!order_id || !/^[0-9a-f-]{36}$/i.test(order_id)) {
    return res.status(400).json({ error: 'bad_order_id' });
  }

  try {
    // 1) اقرأ الطلب من قاعدة البيانات — المصدر الوحيد الموثوق للمبلغ
    const q = await fetch(
      `${SUPA}/rest/v1/orders?id=eq.${order_id}` +
      `&select=id,amount,currency,status,buyer_name,buyer_email,event_id`,
      { headers: { apikey: SKEY, Authorization: `Bearer ${SKEY}` } }
    );
    const rows = await q.json();
    const order = Array.isArray(rows) ? rows[0] : null;

    if (!order)                      return res.status(404).json({ error: 'order_not_found' });
    if (order.status !== 'pending')  return res.status(409).json({ error: 'order_not_pending' });
    if (!order.amount || order.amount < 100) {
      return res.status(400).json({ error: 'bad_amount' });
    }

    // 2) جهّز روابط العودة
    const proto = (req.headers['x-forwarded-proto'] || 'https').split(',')[0];
    const host  = req.headers['x-forwarded-host'] || req.headers.host;
    const base  = `${proto}://${host}`;
    const back  = `${base}/?e=${encodeURIComponent(slug || '')}`;

    // 3) أنشئ فاتورة عند مُيسِّر
    const auth = Buffer.from(`${MKEY}:`).toString('base64');

    const inv = await fetch('https://api.moyasar.com/v1/invoices', {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        amount:      order.amount,              // بالهللات
        currency:    order.currency || 'SAR',
        description: `تذكرة — ${order.buyer_name}`,
        success_url: `${base}/api/return?order=${order.id}&slug=${encodeURIComponent(slug || '')}`,
        back_url:    back,
        callback_url:`${base}/api/return?order=${order.id}&slug=${encodeURIComponent(slug || '')}`,
        metadata:    { order_id: order.id }
      })
    });

    const data = await inv.json();

    if (!inv.ok) {
      console.error('moyasar_create_failed', inv.status, data);
      return res.status(502).json({ error: 'gateway_error', detail: data?.message || null });
    }

    const url = data.url || data.invoice_url || data?.source?.transaction_url;
    if (!url) {
      console.error('moyasar_no_url', data);
      return res.status(502).json({ error: 'no_payment_url' });
    }

    return res.status(200).json({ url, invoice_id: data.id });

  } catch (e) {
    console.error('pay_error', e);
    return res.status(500).json({ error: 'server_error' });
  }
}
