# ☁️ Suny

<p align="center">
<strong>مدیریت هوشمند IP مقصد تانل پشت Cloudflare</strong><br>
مانیتور دقیقه‌ای • Failover خودکار • چرخش زمان‌بندی‌شده فقط بین IPهای سالم
</p>

---

## 🚀 نصب

اگر با `root` هستید، فقط همین دستور را اجرا کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sunyro/suny/main/install.sh)
```

بعد از نصب:

```bash
suny
```

> ⚠️ دستور نصب و اجرای `suny` را در یک خط پشت سر هم ننویسید.

---

# 🔥 قابلیت اصلی جدید: 1-Minute Failover Monitor

Suny می‌تواند **هر 1 دقیقه IP فعلی دامنه را بررسی کند**.

```text
هر 1 دقیقه
    ↓
IP فعلی Health Check می‌شود
    ↓
┌── سالم است؟ ── بله ──→ هیچ کاری نکن
│
└── خیر
      ↓
IPهای بعدی را یکی‌یکی بررسی کن
      ↓
اولین IP سالم
      ↓
Cloudflare DNS را فوراً روی آن منتقل کن
```

### مثال

```text
12:00 → IP 1 → سالم → بدون تغییر
12:01 → IP 1 → سالم → بدون تغییر
12:02 → IP 1 → ناسالم
         ↓
       IP 2 → سالم
         ↓
       DNS → IP 2
```

این قابلیت باعث می‌شود تا زمانی که IP فعلی سالم است، **هیچ Rotate بی‌موردی انجام نشود**.

برای فعال‌سازی از منو:

```text
11) Install 1-Minute Failover Monitor
```

برای خاموش کردن:

```text
12) Remove 1-Minute Monitor
```

---

# 🔄 قابلیت دوم: Timed Healthy IP Rotation

این قابلیت از Failover جدا است.

مثلاً تنظیم می‌کنید:

```text
هر 1 ساعت
```

Suny به شکل حلقه‌ای فقط بین IPهایی که Health Check آن‌ها موفق باشد می‌چرخد:

```text
IP 1 سالم
   ↓ 1 ساعت
IP 2 سالم
   ↓ 1 ساعت
IP 3 سالم
   ↓ 1 ساعت
IP 1 سالم
```

اگر IP بعدی خراب باشد:

```text
IP 1 🟢
   ↓
IP 2 🔴 خراب → Skip
   ↓
IP 3 🟢
```

پس DNS روی IP ناسالم منتقل نمی‌شود.

فعال‌سازی:

```text
7) Install Timed Healthy IP Rotation
```

مثلاً عدد `1` یعنی هر یک ساعت.

خاموش کردن:

```text
8) Remove Timed Rotation
```

---

# 🧠 هر دو قابلیت هم‌زمان کار می‌کنند

```text
┌─────────────────────────────────┐
│ Minute Failover Monitor         │
│ هر 1 دقیقه                      │
│                                 │
│ IP فعلی خراب شد؟                │
│ → انتقال فوری به IP سالم        │
└───────────────┬─────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│ Timed Healthy Rotation          │
│ هر X ساعت                       │
│                                 │
│ چرخش بین IPهای سالم             │
└─────────────────────────────────┘
```

یک Lock مشترک از تداخل هم‌زمان Monitor و Rotation جلوگیری می‌کند.

---

## 🩺 Health Check

Suny پورت واقعی تانل شما را با Check-Host بررسی می‌کند؛ مثلاً:

```text
443
8443
2053
یا هر پورت دیگر
```

برای هر IP درصد دسترسی موفق محاسبه می‌شود. مثلاً اگر حداقل موفقیت را روی `60%` تنظیم کنید، IPی که کمتر از این مقدار موفقیت داشته باشد سالم محسوب نمی‌شود.

> نتیجه Health Check به معنی اثبات قطعی فیلترینگ نیست؛ مشکل فایروال، Routing، سرور یا بسته بودن پورت هم می‌تواند باعث شکست تست شود.

برای تست دستی همه IPهای یک دامنه:

```text
9) Health Check Domain
```

---

## 🎯 سناریوی استفاده

فرض کنید دارید:

```text
tunnel.example.com
```

و چند سرور ایران:

```text
1.2.3.4
5.6.7.8
9.10.11.12
```

Suny:

- هر دقیقه IP فعلی را بررسی می‌کند.
- اگر سالم باشد، به آن دست نمی‌زند.
- اگر خراب شود، اولین IP سالم جایگزین را پیدا می‌کند.
- هر زمان‌بندی دلخواه، بین IPهای سالم به‌صورت حلقه‌ای Rotate می‌کند.

---

## 🔐 Cloudflare API Token

یک Token محدود بسازید با دسترسی:

```text
Zone → DNS → Edit
Zone → Zone → Read
```

Token را فقط به Zoneهای موردنیاز محدود کنید.

برای تنظیم در Suny:

```text
1) Set Cloudflare API Token
```

---

## 📋 منوی جدید

```text
1) Set Cloudflare API Token
2) Add Domain
3) List Domains
4) Delete Domain
5) Rotate All Now
6) Rotate One Domain
7) Install Timed Healthy IP Rotation
8) Remove Timed Rotation
9) Health Check Domain
10) Set Check-Host API Key (optional)
11) Install 1-Minute Failover Monitor
12) Remove 1-Minute Monitor
13) Help
14) Uninstall suny
0) Exit
```

---

## 🗑️ حذف کامل

گزینه:

```text
14) Uninstall suny
```

فایل‌های برنامه، تنظیمات، State و Cronهای Suny حذف می‌شوند. DNS Recordهای Cloudflare و سرورهای شما حذف نمی‌شوند.

---

## ❤️ نکته

برای Monitor دقیقه‌ای، تعداد زیادی Health Check انجام می‌شود. استفاده از API Key اختیاری Check-Host می‌تواند برای کاهش محدودیت‌های سرویس مفید باشد:

```text
10) Set Check-Host API Key (optional)
```
